#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Cleanly tear down the DevOps Agent Autonomous Investigation & Self-Healing Stack
# ==============================================================================

STACK_NAME="${STACK_NAME:-da-auto-investigation}"
REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo 'us-east-1')}"

echo "=================================================================="
echo " Deleting CloudFormation Stack : ${STACK_NAME} (${REGION})"
echo "=================================================================="

aws cloudformation delete-stack \
  --region "${REGION}" \
  --stack-name "${STACK_NAME}"

echo "[+] Waiting for stack deletion to complete..."
aws cloudformation wait stack-delete-complete \
  --region "${REGION}" \
  --stack-name "${STACK_NAME}"

echo "[+] Stack '${STACK_NAME}' deleted successfully."

# ------------------------------------------------------------------------------
# Remove the S3 bucket / objects used by deploy.sh to stage the template.
# - Default (auto-created) bucket: emptied and deleted.
# - User-supplied DEPLOY_BUCKET: only the "${STACK_NAME}/" prefix is removed,
#   so a shared, pre-existing bucket is never deleted.
# ------------------------------------------------------------------------------
if [ -n "${DEPLOY_BUCKET:-}" ]; then
  if aws s3api head-bucket --bucket "${DEPLOY_BUCKET}" >/dev/null 2>&1; then
    echo "[+] Removing staged templates under s3://${DEPLOY_BUCKET}/${STACK_NAME}/ ..."
    aws s3 rm "s3://${DEPLOY_BUCKET}/${STACK_NAME}/" --recursive --region "${REGION}"
  else
    echo "[i] Deployment bucket '${DEPLOY_BUCKET}' not found -> nothing to clean."
  fi
else
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  DEFAULT_BUCKET="${STACK_NAME}-cfn-${ACCOUNT_ID}-${REGION}"
  if aws s3api head-bucket --bucket "${DEFAULT_BUCKET}" >/dev/null 2>&1; then
    echo "[+] Emptying and deleting deployment bucket '${DEFAULT_BUCKET}' ..."
    aws s3 rb "s3://${DEFAULT_BUCKET}" --force --region "${REGION}"
    echo "[+] Bucket '${DEFAULT_BUCKET}' deleted."
  else
    echo "[i] Deployment bucket '${DEFAULT_BUCKET}' not found -> nothing to clean."
  fi
fi
