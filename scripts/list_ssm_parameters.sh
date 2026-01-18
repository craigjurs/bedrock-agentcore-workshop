#!/bin/bash

set -e
set -o pipefail

REGION=$(aws configure get region 2>/dev/null || echo "us-west-2")
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "🔍 Listing SSM parameters for American Red Cross chatbot"
echo "📍 Region: $REGION"
echo ""

# 1. App/AgentCore parameters (/app/redcross)
echo "=== /app/redcross (AgentCore, DynamoDB, Memory, etc.) ==="
aws ssm get-parameters-by-path \
  --path "/app/redcross" \
  --recursive \
  --with-decryption \
  --region "$REGION" \
  --query "Parameters[*].{Name:Name,Value:Value}" \
  --output table 2>/dev/null || echo "(none or path not found)"
echo ""

# 2. Three Red Cross knowledge base parameters (vector DBs: biomedical, humanitarian, training)
KB_PATH="/${ACCOUNT_ID}-${REGION}/kb"
echo "=== ${KB_PATH} (3 Red Cross KBs: biomedical, humanitarian, training) ==="
aws ssm get-parameters-by-path \
  --path "$KB_PATH" \
  --recursive \
  --with-decryption \
  --region "$REGION" \
  --query "Parameters[*].{Name:Name,Value:Value}" \
  --output table 2>/dev/null || echo "(none or path not found)"
