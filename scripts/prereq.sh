#!/bin/sh

# Enable strict error handling
set -euo pipefail

# ----- Config -----
BUCKET_NAME=${1:-redcross}
INFRA_STACK_NAME=${2:-RedCrossStackInfra}
COGNITO_STACK_NAME=${3:-RedCrossStackCognito}
INFRA_TEMPLATE_FILE="prerequisite/infrastructure.yaml"
COGNITO_TEMPLATE_FILE="prerequisite/cognito.yaml"

# First try to get region from environment variable
if [ -z "${AWS_REGION-}" ]; then
    # If AWS_REGION is not set, try to get it from AWS CLI config
    REGION=$(aws configure get region 2>/dev/null || echo "us-west-2")
    # Export it as an environment variable
    export AWS_REGION="${REGION}"
fi
echo "Region is set to: ${AWS_REGION}"
export REGION="${AWS_REGION}"
    

# Get AWS Account ID with proper error handling
echo "🔍 Getting AWS Account ID..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>&1)
if [ $? -ne 0 ] || [ -z "$ACCOUNT_ID" ] || [ "$ACCOUNT_ID" = "None" ]; then
    echo "❌ Failed to get AWS Account ID. Please check your AWS credentials and network connectivity."
    echo "Error: $ACCOUNT_ID"
    exit 1
fi

FULL_BUCKET_NAME="${BUCKET_NAME}-${ACCOUNT_ID}-${REGION}"
ZIP_FILE="lambda.zip"
LAYER_ZIP_FILE="ddgs-layer.zip"
LAYER_SOURCE="prerequisite/lambda/python"
S3_LAYER_KEY="${LAYER_ZIP_FILE}"
LAMBDA_SRC="prerequisite/lambda/python"
S3_KEY="${ZIP_FILE}"

USER_POOL_NAME="RedCrossGatewayPool"
MACHINE_APP_CLIENT_NAME="RedCrossMachineClient"
WEB_APP_CLIENT_NAME="RedCrossWebClient"

echo "Region: $REGION"
echo "Account ID: $ACCOUNT_ID"
# ----- 1. Create S3 bucket -----
echo "🪣 Using S3 bucket: $FULL_BUCKET_NAME"
if [ "$REGION" = "us-east-1" ]; then
  aws s3api create-bucket \
    --bucket "$FULL_BUCKET_NAME" \
    2>/dev/null || echo "ℹ️ Bucket may already exist or be owned by you."
else
  aws s3api create-bucket \
    --bucket "$FULL_BUCKET_NAME" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" \
    2>/dev/null || echo "ℹ️ Bucket may already exist or be owned by you."
fi

# ----- Verify S3 bucket ownership -----
echo "🔍 Verifying S3 bucket ownership..."
aws s3api head-bucket --bucket "$FULL_BUCKET_NAME" --expected-bucket-owner "$ACCOUNT_ID"
if [ $? -ne 0 ]; then
    echo "❌ S3 bucket $FULL_BUCKET_NAME is not owned by account $ACCOUNT_ID"
    exit 1
fi
echo "✅ S3 bucket ownership verified"

# ----- 2. Zip Lambda code -----
echo "📦 Zipping contents of $LAMBDA_SRC into $ZIP_FILE..."
if ! command -v zip &>/dev/null; then
    echo "❌ 'zip' is required. Install it (e.g. apt install zip, yum install zip, or brew install zip)."
    exit 1
fi
cd "$LAMBDA_SRC"
zip -r "../../../$ZIP_FILE" . > /dev/null

cd - > /dev/null

# ----- 3. Upload to S3 -----
echo "☁️ Uploading $ZIP_FILE to s3://$FULL_BUCKET_NAME/$S3_KEY..."
aws s3api put-object --bucket "$FULL_BUCKET_NAME" --key "$S3_KEY" --body "$ZIP_FILE" --expected-bucket-owner "$ACCOUNT_ID"

echo "☁️ Uploading $LAYER_ZIP_FILE to s3://$FULL_BUCKET_NAME/$S3_LAYER_KEY..."
cd "$LAMBDA_SRC"
aws s3api put-object --bucket "$FULL_BUCKET_NAME" --key "$S3_LAYER_KEY" --body "$LAYER_ZIP_FILE" --expected-bucket-owner "$ACCOUNT_ID"
cd - > /dev/null
# ----- 4. Deploy CloudFormation -----
describe_failed_events() {
  local stack_name="$1"
  echo "📋 Diagnosing failure for $stack_name..."
  echo ""
  
  # First, try to get change set status (works even if stack doesn't exist yet)
  local latest_cs=$(aws cloudformation list-change-sets \
    --stack-name "$stack_name" \
    --region "$REGION" \
    --query "Summaries | sort_by(@, &CreationTime) | [-1].ChangeSetName" \
    --output text 2>/dev/null)
  
  if [ -n "$latest_cs" ] && [ "$latest_cs" != "None" ] && [ "$latest_cs" != "null" ]; then
    echo "📋 Latest change set: $latest_cs"
    aws cloudformation describe-change-set \
      --stack-name "$stack_name" \
      --change-set-name "$latest_cs" \
      --region "$REGION" \
      --query "{Status:Status,StatusReason:StatusReason,ExecutionStatus:ExecutionStatus}" \
      --output table 2>/dev/null || true
    echo ""
  fi
  
  # Then try to get stack events (only if stack exists)
  echo "📋 Stack events (if stack exists):"
  if aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" >/dev/null 2>&1; then
    aws cloudformation describe-stack-events \
      --stack-name "$stack_name" \
      --region "$REGION" \
      --query "reverse(@)[0:25].[Timestamp,ResourceType,LogicalResourceId,ResourceStatus,ResourceStatusReason]" \
      --output table 2>/dev/null || echo "  (Could not fetch events)"
  else
    echo "  (Stack does not exist - check change set StatusReason above)"
  fi
}

deploy_stack() {
  set +e

  local stack_name=$1
  local template_file=$2
  shift 2
  local params=("$@")

  echo "🚀 Deploying CloudFormation stack: $stack_name"

  output=$(aws cloudformation deploy \
    --stack-name "$stack_name" \
    --template-file "$template_file" \
    --s3-bucket "$FULL_BUCKET_NAME" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "$REGION" \
    "${params[@]}" 2>&1)

  exit_code=$?

  echo "$output"

  # If stack is in ROLLBACK_COMPLETE, delete and retry once
  if echo "$output" | grep -q "is in ROLLBACK_COMPLETE state and can not be updated"; then
    echo ""
    echo "🗑️ Stack $stack_name is in ROLLBACK_COMPLETE; deleting before redeploy..."
    aws cloudformation delete-stack --stack-name "$stack_name" --region "$REGION"
    aws cloudformation wait stack-delete-complete --stack-name "$stack_name" --region "$REGION" || true
    echo "🔁 Retrying deployment of $stack_name..."
    output=$(aws cloudformation deploy \
      --stack-name "$stack_name" \
      --template-file "$template_file" \
      --s3-bucket "$FULL_BUCKET_NAME" \
      --capabilities CAPABILITY_NAMED_IAM \
      --region "$REGION" \
      "${params[@]}" 2>&1)
    exit_code=$?
    echo "$output"
  fi

  if [ $exit_code -ne 0 ]; then
    if echo "$output" | grep -qi "No changes to deploy"; then
      echo "ℹ️ No updates for stack $stack_name, continuing..."
      return 0
    else
      echo ""
      echo "❌ Error deploying stack $stack_name:"
      echo "$output"
      echo ""
      describe_failed_events "$stack_name"
      return $exit_code
    fi
  else
    echo "✅ Stack $stack_name deployed successfully."
    return 0
  fi
}

# ----- Run both stacks -----
# If infrastructure stack is in ROLLBACK_COMPLETE, it cannot be updated—delete it first
infra_status=$(aws cloudformation describe-stacks --stack-name "$INFRA_STACK_NAME" --query "Stacks[0].StackStatus" --output text 2>/dev/null) || infra_status=""
if [ "$infra_status" = "ROLLBACK_COMPLETE" ]; then
  echo "🗑️ Stack $INFRA_STACK_NAME is in ROLLBACK_COMPLETE; deleting before redeploy..."
  aws cloudformation delete-stack --stack-name "$INFRA_STACK_NAME" --region "$REGION"
  aws cloudformation wait stack-delete-complete --stack-name "$INFRA_STACK_NAME" --region "$REGION"
  echo "✅ Stack $INFRA_STACK_NAME deleted."
fi

echo "🔧 Starting deployment of infrastructure stack with LambdaS3Bucket = $FULL_BUCKET_NAME..."
deploy_stack "$INFRA_STACK_NAME" "$INFRA_TEMPLATE_FILE" --parameter-overrides LambdaS3Bucket="$FULL_BUCKET_NAME" LambdaS3Key="$S3_KEY" LayerS3Key="$S3_LAYER_KEY"
infra_exit_code=$?

# If Cognito stack is in ROLLBACK_COMPLETE, it cannot be updated—delete it first
cognito_status=$(aws cloudformation describe-stacks --stack-name "$COGNITO_STACK_NAME" --query "Stacks[0].StackStatus" --output text 2>/dev/null) || cognito_status=""
if [ "$cognito_status" = "ROLLBACK_COMPLETE" ]; then
  echo "🗑️ Stack $COGNITO_STACK_NAME is in ROLLBACK_COMPLETE; deleting before redeploy..."
  aws cloudformation delete-stack --stack-name "$COGNITO_STACK_NAME" --region "$REGION"
  aws cloudformation wait stack-delete-complete --stack-name "$COGNITO_STACK_NAME" --region "$REGION"
  echo "✅ Stack $COGNITO_STACK_NAME deleted."
fi

echo "🔧 Starting deployment of Cognito stack..."
deploy_stack "$COGNITO_STACK_NAME" "$COGNITO_TEMPLATE_FILE" --parameter-overrides UserPoolName="$USER_POOL_NAME" MachineAppClientName="$MACHINE_APP_CLIENT_NAME" WebAppClientName="$WEB_APP_CLIENT_NAME"
cognito_exit_code=$?

echo "✅ Deployment complete."
