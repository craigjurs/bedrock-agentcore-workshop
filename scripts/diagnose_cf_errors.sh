#!/bin/bash

# Script to diagnose CloudFormation deployment failures

REGION="${AWS_REGION:-us-west-2}"
INFRA_STACK="RedCrossStackInfra"
COGNITO_STACK="RedCrossStackCognito"

echo "========================================"
echo "CloudFormation Deployment Diagnostics"
echo "========================================"
echo "Region: $REGION"
echo ""

check_stack() {
    local stack_name=$1
    echo "----------------------------------------"
    echo "Checking stack: $stack_name"
    echo "----------------------------------------"

    # Check if stack exists
    if ! aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" >/dev/null 2>&1; then
        echo "❌ Stack does not exist yet"

        # Try to find failed change sets
        echo ""
        echo "Looking for failed change sets..."
        aws cloudformation list-change-sets \
            --stack-name "$stack_name" \
            --region "$REGION" \
            --query "Summaries[?Status=='FAILED'].{Name:ChangeSetName,Status:Status,StatusReason:StatusReason,CreationTime:CreationTime}" \
            --output table 2>/dev/null || echo "No change sets found"

        return 1
    fi

    # Get stack status
    stack_status=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --region "$REGION" \
        --query "Stacks[0].StackStatus" \
        --output text 2>/dev/null)

    echo "Stack Status: $stack_status"

    # Get stack status reason if available
    status_reason=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --region "$REGION" \
        --query "Stacks[0].StackStatusReason" \
        --output text 2>/dev/null)

    if [ -n "$status_reason" ] && [ "$status_reason" != "None" ]; then
        echo "Status Reason: $status_reason"
    fi

    echo ""
    echo "Recent stack events (last 20):"
    aws cloudformation describe-stack-events \
        --stack-name "$stack_name" \
        --region "$REGION" \
        --max-items 20 \
        --query "StackEvents[?contains(ResourceStatus, 'FAILED') || contains(ResourceStatus, 'ROLLBACK')].[Timestamp,LogicalResourceId,ResourceType,ResourceStatus,ResourceStatusReason]" \
        --output table 2>/dev/null || echo "Could not fetch events"

    echo ""
    echo "ALL recent events (last 10):"
    aws cloudformation describe-stack-events \
        --stack-name "$stack_name" \
        --region "$REGION" \
        --max-items 10 \
        --query "StackEvents[].[Timestamp,LogicalResourceId,ResourceType,ResourceStatus,ResourceStatusReason]" \
        --output table 2>/dev/null || echo "Could not fetch events"
}

# Check IAM permissions
echo "========================================"
echo "Checking IAM Permissions"
echo "========================================"
echo "Current identity:"
aws sts get-caller-identity --output table

echo ""
echo "Testing key IAM permissions..."

# Test CloudFormation permissions
aws cloudformation list-stacks --region "$REGION" >/dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "✅ CloudFormation:ListStacks - OK"
else
    echo "❌ CloudFormation:ListStacks - FAILED"
fi

# Test IAM permissions
aws iam list-roles --max-items 1 >/dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "✅ IAM:ListRoles - OK"
else
    echo "⚠️  IAM:ListRoles - FAILED (may need iam:CreateRole, iam:PassRole)"
fi

# Test Lambda permissions
aws lambda list-functions --max-items 1 --region "$REGION" >/dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "✅ Lambda:ListFunctions - OK"
else
    echo "⚠️  Lambda:ListFunctions - FAILED (may need lambda:CreateFunction)"
fi

# Test Cognito permissions
aws cognito-idp list-user-pools --max-results 1 --region "$REGION" >/dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "✅ Cognito:ListUserPools - OK"
else
    echo "⚠️  Cognito:ListUserPools - FAILED (may need cognito-idp:CreateUserPool)"
fi

echo ""
echo "========================================"
echo "Checking Stacks"
echo "========================================"

check_stack "$INFRA_STACK"
echo ""
check_stack "$COGNITO_STACK"

echo ""
echo "========================================"
echo "Diagnostic Summary"
echo "========================================"
echo "If you see permission errors above, the SageMaker execution role"
echo "may need additional IAM permissions for:"
echo "  - iam:CreateRole, iam:PassRole, iam:PutRolePolicy"
echo "  - lambda:CreateFunction, lambda:PublishLayerVersion"
echo "  - cognito-idp:CreateUserPool, cognito-idp:CreateUserPoolClient"
echo "  - bedrock:CreateKnowledgeBase"
echo "  - s3vectors:CreateVectorBucket, s3vectors:CreateIndex"
echo ""
echo "If you see resource-specific errors, those will be shown above."
