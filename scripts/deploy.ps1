param(
    [string]$StackName = "da-auto-investigation",
    [string]$Region = "us-east-1",
    [string]$InstanceType = "t3.medium",
    [string]$VpcId = "",
    [string]$SubnetId = "",
    [string]$WebhookUrl = "https://placeholder.aidevops.amazonaws.com/webhook/v1/incident",
    [string]$WebhookSecret = "PLACEHOLDER_WEBHOOK_SECRET_CHANGE_ME",
    [string]$AgentRoleName = "AWS_DevOps_Agent_Role",
    [string]$EnableSelfHealing = "true",
    [string]$DeployBucket = ""
)

$ErrorActionPreference = "Stop"
$TemplateFile = Join-Path $PSScriptRoot "..\cloudformation\da-auto-investigation-stack.yaml"

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " Deploying Stack : $StackName ($Region)" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

if ([string]::IsNullOrWhiteSpace($VpcId)) {
    $VpcId = (aws ec2 describe-vpcs --region $Region --filters "Name=is-default,Values=true" --query "Vpcs[0].VpcId" --output text 2>$null)
    if ([string]::IsNullOrWhiteSpace($VpcId) -or $VpcId -eq "None") {
        $VpcId = (aws ec2 describe-vpcs --region $Region --query "Vpcs[0].VpcId" --output text)
    }
}
Write-Host "[+] Using VPC ID    : $VpcId" -ForegroundColor Green

if ([string]::IsNullOrWhiteSpace($SubnetId)) {
    $SubnetId = (aws ec2 describe-subnets --region $Region --filters "Name=vpc-id,Values=$VpcId" --query "Subnets[?MapPublicIpOnLaunch==``true``]|[0].SubnetId" --output text 2>$null)
    if ([string]::IsNullOrWhiteSpace($SubnetId) -or $SubnetId -eq "None") {
        $SubnetId = (aws ec2 describe-subnets --region $Region --filters "Name=vpc-id,Values=$VpcId" --query "Subnets[0].SubnetId" --output text)
    }
}
Write-Host "[+] Using Subnet ID : $SubnetId" -ForegroundColor Green

$AttachAgentPolicy = "false"
try {
    aws iam get-role --role-name $AgentRoleName | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $AttachAgentPolicy = "true"
        Write-Host "[+] Found existing DevOps Agent Role '$AgentRoleName' -> attaching SSM Runbook permissions." -ForegroundColor Green
    }
} catch {
    Write-Host "[i] Role '$AgentRoleName' not found -> skipping direct role attachment." -ForegroundColor Yellow
}

# Templates > 51,200 bytes must be uploaded to S3 before deploy
if ([string]::IsNullOrWhiteSpace($DeployBucket)) {
    $AccountId = (aws sts get-caller-identity --query Account --output text)
    $DeployBucket = "$StackName-cfn-$AccountId-$Region"
}
aws s3api head-bucket --bucket $DeployBucket 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "[+] Using existing deployment bucket : $DeployBucket" -ForegroundColor Green
} else {
    Write-Host "[+] Creating deployment bucket       : $DeployBucket" -ForegroundColor Green
    if ($Region -eq "us-east-1") {
        aws s3api create-bucket --bucket $DeployBucket --region $Region | Out-Null
    } else {
        aws s3api create-bucket --bucket $DeployBucket --region $Region --create-bucket-configuration "LocationConstraint=$Region" | Out-Null
    }
    aws s3api put-public-access-block --bucket $DeployBucket --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
}

aws cloudformation deploy `
    --region $Region `
    --stack-name $StackName `
    --template-file $TemplateFile `
    --s3-bucket $DeployBucket `
    --s3-prefix $StackName `
    --capabilities CAPABILITY_NAMED_IAM `
    --parameter-overrides `
        "VpcId=$VpcId" `
        "SubnetId=$SubnetId" `
        "InstanceType=$InstanceType" `
        "DevOpsAgentWebhookUrl=$WebhookUrl" `
        "DevOpsAgentWebhookSecret=$WebhookSecret" `
        "DevOpsAgentRoleName=$AgentRoleName" `
        "AttachRunbookPolicyToAgentRole=$AttachAgentPolicy" `
        "EnableAutoSelfHealing=$EnableSelfHealing"

Write-Host "`n==================================================================" -ForegroundColor Cyan
Write-Host " Deployment Complete! Stack Outputs:" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
aws cloudformation describe-stacks --region $Region --stack-name $StackName --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" --output table
