# AWS DevOps Agent Webhook & HMAC-SHA256 Specification

This document details how the `AlarmToDevOpsAgentBridge` Lambda function transforms Amazon CloudWatch OS threshold alarms into authenticated incident events for your **AWS DevOps Agent Space**.

---

## 1. End-to-End Trigger Flow

1. A CloudWatch Alarm (`CWAgent` namespace) detects an OS metric breach on the EC2 instance (`mem_used_percent`, `swap_used_percent`, `disk_used_percent`, `diskio_io_time`, or `cpu_usage_iowait`).
2. The alarm publishes a notification to the stack's **Amazon SNS Topic**.
3. SNS invokes the **`AlarmToDevOpsAgentBridge`** Lambda function.
4. The Lambda function immediately:
   - Triggers the **SSM Forensic & Self-Healing Runbook (`OSForensicsAndSelfHeal`)** on the target EC2 instance and records the `ssmForensicCommandId`.
   - Retrieves `WEBHOOK_URL` and `WEBHOOK_SECRET` from **AWS Secrets Manager** (`<stack-name>-devops-agent-webhook`).
   - Builds the structured JSON incident payload, computes the **HMAC-SHA256** signature over `${timestamp}:${payload}`, and sends an HTTP `POST` to your AWS DevOps Agent Space Webhook endpoint.

---

## 2. Required HTTP Headers

| Header | Format | Description |
| :--- | :--- | :--- |
| `Content-Type` | `application/json` | JSON body encoding |
| `x-amzn-event-timestamp` | `YYYY-MM-DDTHH:MM:SSZ` | ISO-8601 UTC timestamp used for replay protection |
| `x-amzn-event-signature` | `<base64-encoded HMAC-SHA256>` | Base64 digest of `HMAC-SHA256(secret, "${timestamp}:${raw_json_body}")` |

---

## 3. Sample Incident Payload Sent to AWS DevOps Agent

```json
{
  "eventType": "incident",
  "incidentId": "ec2-i-0abc12345def67890-memory-1761742000",
  "action": "created",
  "priority": "HIGH",
  "title": "EC2 OS MEMORY Exhaustion on i-0abc12345def67890 (da-auto-investigation-1-HighMemoryUtilization)",
  "description": "CloudWatch Alarm 'da-auto-investigation-1-HighMemoryUtilization' transitioned to ALARM on EC2 instance i-0abc12345def67890. Reason: Threshold Crossed: 1 datapoint [86.4] was greater than or equal to the threshold (80.0). Automated SSM Forensic Runbook (da-auto-investigation-OSForensicsAndSelfHeal) was triggered (CommandId: 8f9c2a1b-3344-5566-7788-99aabbccddee) and streamed OS process/memory/swap/disk/IO dumps into CloudWatch Log Group '/aws/ec2/da-auto-investigation/os-forensics' stream 'i-0abc12345def67890/forensic-dumps'.",
  "timestamp": "2026-10-29T18:06:40Z",
  "service": "AmazonEC2",
  "data": {
    "metadata": {
      "accountId": "123456789012",
      "region": "us-east-1",
      "instanceId": "i-0abc12345def67890",
      "instanceArn": "arn:aws:ec2:us-east-1:123456789012:instance/i-0abc12345def67890",
      "alarmName": "da-auto-investigation-1-HighMemoryUtilization",
      "alarmState": "ALARM",
      "breachCategory": "MEMORY",
      "metricName": "mem_used_percent",
      "forensicsLogGroup": "/aws/ec2/da-auto-investigation/os-forensics",
      "forensicsLogStream": "i-0abc12345def67890/forensic-dumps",
      "loadGeneratorLogStream": "i-0abc12345def67890/load-generator",
      "ssmForensicDocument": "da-auto-investigation-OSForensicsAndSelfHeal",
      "ssmForensicCommandId": "8f9c2a1b-3344-5566-7788-99aabbccddee",
      "investigationHint": "Query CloudWatch Logs group '/aws/ec2/da-auto-investigation/os-forensics' stream 'i-0abc12345def67890/forensic-dumps' for incident_id='ec2-i-0abc12345def67890-memory-1761742000' to inspect exact offending PIDs, VmSwap, RSS, uninterruptible D-state processes, and iostat saturation."
    }
  }
}
```

---

## 4. Updating the Webhook URL & Secret After Deployment

If you deployed the stack with the default placeholder URL, you can update the live webhook credentials at any time without redeploying CloudFormation:

```bash
aws secretsmanager put-secret-value \
  --secret-id da-auto-investigation-devops-agent-webhook \
  --secret-string '{
    "WEBHOOK_URL": "https://<your-devops-agent-webhook-url>",
    "WEBHOOK_SECRET": "<your-webhook-hmac-secret>"
  }'
```
