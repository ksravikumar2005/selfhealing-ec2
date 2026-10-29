#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Deploy AWS DevOps Agent Autonomous Investigation & Self-Healing EC2 Stack
# Auto-discovers Default VPC/Subnet and existing AWS_DevOps_Agent_Role
# ==============================================================================

STACK_NAME="${STACK_NAME:-da-auto-investigation}"
REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo 'us-east-1')}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.medium}"
WEBHOOK_URL="${DEVOPS_AGENT_WEBHOOK_URL:-https://placeholder.aidevops.amazonaws.com/webhook/v1/incident}"
WEBHOOK_SECRET="${DEVOPS_AGENT_WEBHOOK_SECRET:-PLACEHOLDER_WEBHOOK_SECRET_CHANGE_ME}"
AGENT_ROLE_NAME="${DEVOPS_AGENT_ROLE_NAME:-AWS_DevOps_Agent_Role}"
ENABLE_SELF_HEALING="${ENABLE_SELF_HEALING:-true}"
ANOMALY_BAND_WIDTH="${ANOMALY_BAND_WIDTH:-2}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/../cloudformation/da-auto-investigation-stack.yaml"

echo "=================================================================="
echo " Deploying Stack : ${STACK_NAME}"
echo " Region          : ${REGION}"
echo " Instance Type   : ${INSTANCE_TYPE}"
echo " Anomaly Band    : ${ANOMALY_BAND_WIDTH} std devs"
echo "=================================================================="

# 1. Auto-discover VPC if VPC_ID not provided
if [ -z "${VPC_ID:-}" ]; then
  VPC_ID=$(aws ec2 describe-vpcs \
    --region "${REGION}" \
    --filters "Name=is-default,Values=true" \
    --query "Vpcs[0].VpcId" \
    --output text 2>/dev/null || true)

  if [ -z "${VPC_ID}" ] || [ "${VPC_ID}" = "None" ]; then
    VPC_ID=$(aws ec2 describe-vpcs \
      --region "${REGION}" \
      --query "Vpcs[0].VpcId" \
      --output text)
  fi
fi
echo "[+] Using VPC ID    : ${VPC_ID}"

# 2. Auto-discover Subnet in the selected VPC if SUBNET_ID not provided
if [ -z "${SUBNET_ID:-}" ]; then
  SUBNET_ID=$(aws ec2 describe-subnets \
    --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "Subnets[?MapPublicIpOnLaunch==\`true\`]|[0].SubnetId" \
    --output text 2>/dev/null || true)

  if [ -z "${SUBNET_ID}" ] || [ "${SUBNET_ID}" = "None" ]; then
    SUBNET_ID=$(aws ec2 describe-subnets \
      --region "${REGION}" \
      --filters "Name=vpc-id,Values=${VPC_ID}" \
      --query "Subnets[0].SubnetId" \
      --output text)
  fi
fi
echo "[+] Using Subnet ID : ${SUBNET_ID}"

# 3. Check if AWS_DevOps_Agent_Role exists in this account
ATTACH_AGENT_POLICY="false"
if aws iam get-role --role-name "${AGENT_ROLE_NAME}" >/dev/null 2>&1; then
  echo "[+] Found existing DevOps Agent Role '${AGENT_ROLE_NAME}' -> attaching SSM Runbook execution permissions."
  ATTACH_AGENT_POLICY="true"
else
  echo "[i] Role '${AGENT_ROLE_NAME}' not found -> skipping direct role attachment (Bridge Lambda will still trigger SSM Runbook)."
fi

# 4. Ensure an S3 bucket exists for the packaged template (required for templates > 51,200 bytes)
if [ -z "${DEPLOY_BUCKET:-}" ]; then
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  DEPLOY_BUCKET="${STACK_NAME}-cfn-${ACCOUNT_ID}-${REGION}"
fi

if aws s3api head-bucket --bucket "${DEPLOY_BUCKET}" >/dev/null 2>&1; then
  echo "[+] Using existing deployment bucket : ${DEPLOY_BUCKET}"
else
  echo "[+] Creating deployment bucket       : ${DEPLOY_BUCKET}"
  if [ "${REGION}" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "${DEPLOY_BUCKET}" --region "${REGION}" >/dev/null
  else
    aws s3api create-bucket --bucket "${DEPLOY_BUCKET}" --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}" >/dev/null
  fi
  aws s3api put-public-access-block --bucket "${DEPLOY_BUCKET}" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
fi

# 5. Deploy CloudFormation stack
aws cloudformation deploy \
  --region "${REGION}" \
  --stack-name "${STACK_NAME}" \
  --template-file "${TEMPLATE_FILE}" \
  --s3-bucket "${DEPLOY_BUCKET}" \
  --s3-prefix "${STACK_NAME}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    VpcId="${VPC_ID}" \
    SubnetId="${SUBNET_ID}" \
    InstanceType="${INSTANCE_TYPE}" \
    DevOpsAgentWebhookUrl="${WEBHOOK_URL}" \
    DevOpsAgentWebhookSecret="${WEBHOOK_SECRET}" \
    DevOpsAgentRoleName="${AGENT_ROLE_NAME}" \
    AttachRunbookPolicyToAgentRole="${ATTACH_AGENT_POLICY}" \
    EnableAutoSelfHealing="${ENABLE_SELF_HEALING}" \
    AnomalyDetectionBandWidth="${ANOMALY_BAND_WIDTH}"

echo ""
echo "=================================================================="
echo " Deployment Complete! Stack Outputs:"
echo "=================================================================="
aws cloudformation describe-stacks \
  --region "${REGION}" \
  --stack-name "${STACK_NAME}" \
  --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" \
  --output table
