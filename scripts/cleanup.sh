#!/bin/bash

set -e
set -o pipefail

# ----- Config -----
BUCKET_NAME=${1:-redcross}
INFRA_STACK_NAME=${2:-RedCrossStackInfra}
COGNITO_STACK_NAME=${3:-RedCrossStackCognito}
REGION=$(aws configure get region 2>/dev/null || echo "us-west-2")
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
FULL_BUCKET_NAME="${BUCKET_NAME}-${ACCOUNT_ID}-${REGION}"
ZIP_FILE="lambda.zip"
S3_KEY="lambda.zip"

if [ $? -ne 0 ] || [ -z "$ACCOUNT_ID" ] || [ "$ACCOUNT_ID" = "None" ]; then
    echo "❌ Failed to get AWS Account ID. Please check your AWS credentials and network connectivity."
    echo "Error: $ACCOUNT_ID"
    exit 1
fi

# ----- Confirm Deletion -----
read -p "⚠️ Are you sure you want to delete stacks '$INFRA_STACK_NAME', '$COGNITO_STACK_NAME', the 3 Red Cross vector buckets, and clean up S3? (y/N): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "❌ Cleanup cancelled."
  exit 1
fi

# ----- 1. Delete CloudFormation stacks -----
echo "🧨 Deleting stack: $INFRA_STACK_NAME..."
aws cloudformation delete-stack --stack-name "$INFRA_STACK_NAME" --region "$REGION"
echo "⏳ Waiting for $INFRA_STACK_NAME to be deleted..."
aws cloudformation wait stack-delete-complete --stack-name "$INFRA_STACK_NAME" --region "$REGION"
echo "✅ Stack $INFRA_STACK_NAME deleted."

echo "🧨 Deleting stack: $COGNITO_STACK_NAME..."
aws cloudformation delete-stack --stack-name "$COGNITO_STACK_NAME" --region "$REGION"
echo "⏳ Waiting for $COGNITO_STACK_NAME to be deleted..."
aws cloudformation wait stack-delete-complete --stack-name "$COGNITO_STACK_NAME" --region "$REGION"
echo "✅ Stack $COGNITO_STACK_NAME deleted."

# ----- 2. Delete 3 Red Cross vector buckets (S3 Vectors for biomedical, humanitarian, training) -----
echo "🗑️ Deleting Red Cross knowledge base vector buckets (biomedical, humanitarian, training)..."
export REGION ACCOUNT_ID
python3 -c "
import boto3, os
r, acc = os.environ.get('REGION'), os.environ.get('ACCOUNT_ID')
if not r or not acc:
    exit(0)
try:
    c = boto3.client('s3vectors', region_name=r)
    for lob in ['biomedical', 'humanitarian', 'training']:
        vb = f'{acc}-{r}-kb-{lob}-vector-bucket'
        idx = f'{acc}-{r}-kb-{lob}-vector-index'
        try:
            c.delete_index(vectorBucketName=vb, indexName=idx)
            print('  ✅ Deleted index:', idx)
        except Exception:
            pass
        try:
            c.delete_vector_bucket(vectorBucketName=vb)
            print('  ✅ Deleted vector bucket:', vb)
        except Exception:
            pass
except Exception as e:
    print('  ⚠️ Vector bucket cleanup:', e)
" 2>/dev/null || echo "  ⚠️ Could not delete vector buckets (ensure boto3/s3vectors is available). Delete manually in AWS console if needed."
echo "✅ Vector bucket cleanup attempted."

# ----- 3. Delete zip file from S3 -----
echo "🧹 Deleting all contents of s3://$FULL_BUCKET_NAME..."
aws s3 rm "s3://$FULL_BUCKET_NAME" --recursive || echo "⚠️ Failed to clean bucket or it is already empty."

# ----- 4. Optionally delete the bucket -----
read -p "🪣 Do you want to delete the bucket '$FULL_BUCKET_NAME'? (y/N): " delete_bucket
if [[ "$delete_bucket" == "y" || "$delete_bucket" == "Y" ]]; then
  echo "🚮 Deleting bucket $FULL_BUCKET_NAME..."
  aws s3 rb "s3://$FULL_BUCKET_NAME" --force
  echo "✅ Bucket deleted."
else
  echo "🪣 Bucket retained: $FULL_BUCKET_NAME"
fi

# ----- 5. Clean up local zip file -----
echo "🗑️ Removing local file $ZIP_FILE..."
rm -f "$ZIP_FILE"

echo "✅ Cleanup complete."