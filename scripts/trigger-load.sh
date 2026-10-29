#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Helper to invoke the LoadInducer Lambda Function
# Usage:
#   ./scripts/trigger-load.sh [chained|memory|swap|disk_space|ebs_io|stop] [duration_seconds]
# ==============================================================================

MODE="${1:-chained}"
DURATION="${2:-90}"
STACK_NAME="${STACK_NAME:-da-auto-investigation}"
REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo 'us-east-1')}"

LAMBDA_NAME="${STACK_NAME}-LoadInducer"
RESPONSE_FILE="/tmp/da-load-response.json"

echo "[+] Invoking ${LAMBDA_NAME} in ${REGION} with mode='${MODE}', duration_seconds=${DURATION}..."

aws lambda invoke \
  --region "${REGION}" \
  --function-name "${LAMBDA_NAME}" \
  --cli-binary-format raw-in-base64-out \
  --payload "{\"mode\": \"${MODE}\", \"duration_seconds\": ${DURATION}}" \
  "${RESPONSE_FILE}" >/dev/null

cat "${RESPONSE_FILE}" | jq . 2>/dev/null || cat "${RESPONSE_FILE}"
echo ""
echo "[i] OS forensic dumps and self-healing logs are automatically streamed to Amazon CloudWatch Logs:"
echo "    Log Group: /aws/ec2/${STACK_NAME}/os-forensics"
