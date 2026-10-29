# Deep-Dive: OS Stall Protection, Forensic Dumps & Self-Healing Runbook

When an EC2 instance experiences severe memory exhaustion, swap thrashing, 100% root filesystem exhaustion, or EBS IOPS/throughput saturation, traditional monitoring and remediation agents often fail because:
1. The Linux **OOM Killer** terminates `amazon-ssm-agent` or `amazon-cloudwatch-agent`.
2. Root disk exhaustion (`100% /`) causes scripts and log writers to fail with `ENOSPC: No space left on device`.
3. Saturated EBS queues starve the agent processes in uninterruptible sleep (`D` state).

This project solves all three failure modes at the operating system level.

---

## 1. Four-Layer OS Stall Protection

### Layer 1: Dedicated RAM-Backed `tmpfs` Forensic Log Mount (`/var/log/da-forensics`)
During EC2 bootstrap (`UserData`), the instance mounts a dedicated 64 MB `tmpfs` filesystem in RAM at `/var/log/da-forensics`:
```fstab
tmpfs /var/log/da-forensics tmpfs defaults,size=64m,mode=0755 0 0
```
- Because `/var/log/da-forensics` resides in memory rather than on the EBS root volume, the SSM Forensic Runbook can always write diagnostic dumps even when `/` is 100% full (`ENOSPC`) or when the EBS volume's I/O queue is completely stalled.
- The CloudWatch Agent tails `/var/log/da-forensics/forensics.log` with a 5-second `force_flush_interval` and streams it directly over HTTPS to CloudWatch Logs.

### Layer 2: Kernel OOM Immunity & Real-Time I/O Priority
Systemd drop-in overrides are installed for both `amazon-ssm-agent.service` and `amazon-cloudwatch-agent.service`:
```ini
[Service]
OOMScoreAdjust=-1000
Nice=-15
CPUWeight=10000
IOWeight=10000
IOSchedulingClass=realtime
IOSchedulingPriority=0
```
- `OOMScoreAdjust=-1000` instructs the Linux kernel OOM killer to **never** kill the SSM Agent or CloudWatch Agent.
- `IOSchedulingClass=realtime` and `CPUWeight=10000` ensure that even when `stress-ng` or `fio` saturates CPU and disk queues, SSM commands and CloudWatch telemetry preempt user-space load generators.

### Layer 3: High-Resolution 10-Second CloudWatch Telemetry
Instead of standard 5-minute hypervisor metrics, the CloudWatch Agent collects OS metrics every **10 seconds** and evaluates 1-minute alarms so forensic collection begins as soon as the threshold is crossed.

### Layer 4: On-Box Emergency Stall Watchdog (`/usr/local/bin/da-local-watchdog.sh`)
If sudden memory + swap exhaustion occurs faster than the 60-second alarm evaluation window, the local watchdog automatically dumps top memory consumers and `vmstat` output into `/var/log/da-forensics/forensics.log`.

---

## 2. What the `OSForensicsAndSelfHeal` SSM Runbook Captures

Every time a CloudWatch Alarm fires (or when invoked directly by AWS DevOps Agent), the runbook writes an 8-part forensic snapshot tagged with `incident_id`:

| Section | Commands Executed | Root-Cause Question Answered |
| :--- | :--- | :--- |
| **1. Kernel Pressure Stall Information (PSI)** | `uptime`, `/proc/loadavg`, `/proc/pressure/memory`, `/proc/pressure/io`, `/proc/pressure/cpu` | Is the kernel actively stalling tasks on Memory, I/O, or CPU? |
| **2. Memory & Swap Breakdown** | `free -m`, `swapon --show`, `/proc/meminfo` (`Dirty`, `Writeback`, `AnonPages`, `Slab`, `SwapCached`) | Is memory consumed by anonymous process pages, dirty page cache, or kernel slab? |
| **3. Top 15 Memory Consumers** | `ps -eo pid,ppid,user,%mem,%cpu,rss,vsz,stat,comm,args --sort=-%mem` | Which exact PID and command line allocated the physical RAM? |
| **4. Top 10 Swap Consumers** | Per-PID scan of `/proc/[0-9]*/status` (`VmSwap`) | Which exact PID pushed the system into swap exhaustion? |
| **5. Top CPU & Uninterruptible `D`-State Processes** | `ps --sort=-%cpu`, `awk '$3 ~ /D/'` with kernel `wchan` wait channel | Which processes are blocked waiting on saturated disk/EBS I/O? |
| **6. Disk Space, Inodes & Open Deleted Files** | `df -hT`, `df -i`, `find /var/tmp /tmp`, `lsof +L1` | Which file or unlinked open file descriptor filled the root filesystem? |
| **7. EBS Disk I/O & Throughput Saturation** | `iostat -xz 1 2`, `pidstat -d 1 2`, `vmstat 1 2` | What is the exact `aqu-sz` (queue depth), `await` latency, `%util`, and per-PID KB_wr/s? |
| **8. Kernel & OOM Killer Events** | `dmesg -T \| grep -iE "oom\|killed process\|hung_task\|io error"` | Did the kernel invoke the OOM killer or log hung I/O tasks? |

---

## 3. Automated Self-Healing Lifecycle

When `EnableSelfHealing` is set to `'true'` (default):
1. **Forensic Capture First**: The runbook writes the complete 8-section diagnostic dump to `/var/log/da-forensics/forensics.log` and calls `sync`.
2. **Sustained Telemetry Window (`HealDelaySeconds`, default `30s`)**: Waits 30 seconds so CloudWatch Metrics and the AWS DevOps Agent capture the active breach state and flushed forensic logs.
3. **Targeted Remediation**:
   - Terminates runaway load processes (`stress-ng`, `fio`, `dd if=/dev/zero`, `da-chained-load`).
   - Deletes disk ballast and scratch files (`/var/tmp/da-disk-ballast*`, `/var/tmp/da-io-test*`, `/tmp/fio-*`).
   - Drops clean filesystem caches (`echo 3 > /proc/sys/vm/drop_caches`) and cycles swap (`swapoff -a && swapon -a`) if sufficient free RAM is available.
4. **Post-Remediation Verification**: Logs `free -m`, `df -h /`, and `[SELF_HEALING_COMPLETE] status=RECOVERED` to CloudWatch Logs, allowing the CloudWatch Alarms to transition back to `OK` and automatically send a `"resolved"` notification to the AWS DevOps Agent.
