param(
    [ValidateSet("chained", "memory", "swap", "disk_space", "ebs_io", "stop")]
    [string]$Mode = "chained",
    [int]$DurationSeconds = 90,
    [string]$StackName = "da-auto-investigation",
    [string]$Region = "us-east-1"
)

$LambdaName = "$StackName-LoadInducer"
$Payload = (@{ mode = $Mode; duration_seconds = $DurationSeconds } | ConvertTo-Json -Compress)
$OutFile = Join-Path $env:TEMP "da-load-response.json"

Write-Host "[+] Invoking $LambdaName ($Region) with mode='$Mode', duration_seconds=$DurationSeconds..." -ForegroundColor Cyan

aws lambda invoke `
    --region $Region `
    --function-name $LambdaName `
    --cli-binary-format raw-in-base64-out `
    --payload $Payload `
    $OutFile | Out-Null

Get-Content $OutFile
Write-Host "`n[i] Tail live OS forensics & load logs in CloudWatch Logs:" -ForegroundColor Yellow
Write-Host "    aws logs tail /aws/ec2/$StackName/os-forensics --follow --region $Region"
