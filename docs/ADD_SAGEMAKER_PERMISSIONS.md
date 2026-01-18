# How to Add Permissions to Your SageMaker Execution Role

Your CloudFormation stacks are failing because your SageMaker execution role lacks necessary permissions. Here's how to fix it.

## Step 1: Identify Your SageMaker Role

### Method A: From SageMaker Console
1. Go to **AWS Console** → **Amazon SageMaker**
2. Click **Notebook instances** in the left menu
3. Find your notebook instance (likely named something like `default` or similar)
4. Click on the instance name
5. Look for **IAM role ARN** - it will look like:
   ```
   arn:aws:iam::426068478522:role/service-role/AmazonSageMaker-ExecutionRole-XXXXXXXXX
   ```
6. **Copy the role name** (the part after `/role/` or `/service-role/`)
   - Example: `AmazonSageMaker-ExecutionRole-20231215T123456`

### Method B: From Your Notebook Terminal
Run this command in a SageMaker terminal:
```bash
# This gets your instance metadata
curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/
```

The output will be your role name.

---

## Step 2: Add the Permissions Policy

You have **3 options** to add permissions:

### 🎯 Option 1: AWS Console (Recommended - No CLI Required)

1. **Open IAM Console:**
   - Go to **AWS Console** → **IAM** → **Roles**
   - Search for your SageMaker role name (from Step 1)
   - Click on the role name

2. **Add Inline Policy:**
   - Click the **Permissions** tab
   - Click **Add permissions** → **Create inline policy**
   - Click the **JSON** tab
   - Delete the existing JSON and paste the contents from:
     `scripts/sagemaker-permissions-policy.json`

   Or copy this JSON:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CloudFormationAccess",
      "Effect": "Allow",
      "Action": [
        "cloudformation:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "IAMRoleManagement",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:GetRole",
        "iam:GetRolePolicy",
        "iam:PassRole",
        "iam:ListRoles",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:TagRole"
      ],
      "Resource": "*"
    },
    {
      "Sid": "LambdaManagement",
      "Effect": "Allow",
      "Action": [
        "lambda:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CognitoManagement",
      "Effect": "Allow",
      "Action": [
        "cognito-idp:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DynamoDBManagement",
      "Effect": "Allow",
      "Action": [
        "dynamodb:CreateTable",
        "dynamodb:DeleteTable",
        "dynamodb:DescribeTable",
        "dynamodb:UpdateTable",
        "dynamodb:PutItem",
        "dynamodb:BatchWriteItem",
        "dynamodb:TagResource"
      ],
      "Resource": "*"
    },
    {
      "Sid": "BedrockAndS3Vectors",
      "Effect": "Allow",
      "Action": [
        "bedrock:*",
        "bedrock-agent:*",
        "s3vectors:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SSMParameterStore",
      "Effect": "Allow",
      "Action": [
        "ssm:PutParameter",
        "ssm:GetParameter",
        "ssm:DeleteParameter",
        "ssm:AddTagsToResource"
      ],
      "Resource": "*"
    }
  ]
}
```

3. **Name and Save:**
   - Click **Next**
   - Name the policy: `BedrockWorkshopPermissions`
   - Click **Create policy**

4. **Verify:**
   - You should see the new policy listed under the role's permissions

---

### 🔧 Option 2: AWS CLI (If You Have Admin Access)

If you have AWS CLI configured with admin credentials on your local machine:

```bash
# Replace YOUR_ROLE_NAME with the actual role name from Step 1
aws iam put-role-policy \
  --role-name YOUR_ROLE_NAME \
  --policy-name BedrockWorkshopPermissions \
  --policy-document file://scripts/sagemaker-permissions-policy.json
```

Example:
```bash
aws iam put-role-policy \
  --role-name AmazonSageMaker-ExecutionRole-20231215T123456 \
  --policy-name BedrockWorkshopPermissions \
  --policy-document file://scripts/sagemaker-permissions-policy.json
```

---

### 👥 Option 3: Ask Your AWS Administrator

If you don't have permissions to modify IAM roles, send this to your AWS admin:

**Email Template:**

```
Subject: Request to Add Permissions to SageMaker Role for Bedrock Workshop

Hi [Admin Name],

I'm working on the Bedrock AgentCore Workshop and need additional permissions
added to my SageMaker execution role to deploy CloudFormation stacks.

Role Name: [YOUR_ROLE_NAME from Step 1]
Region: us-west-2

Please attach the inline policy "BedrockWorkshopPermissions" with the JSON
content found in this file:
https://github.com/craigjurs/bedrock-agentcore-workshop/blob/claude/repo-overview-7RC8L/scripts/sagemaker-permissions-policy.json

Or use this AWS CLI command:

aws iam put-role-policy \
  --role-name [YOUR_ROLE_NAME] \
  --policy-name BedrockWorkshopPermissions \
  --policy-document file://sagemaker-permissions-policy.json

This will allow me to:
- Deploy CloudFormation stacks
- Create IAM roles, Lambda functions, Cognito user pools
- Create Bedrock knowledge bases and S3 vector stores
- Manage SSM parameters

Thank you!
```

---

## Step 3: Verify Permissions Were Added

After adding the permissions, verify they work:

1. **From SageMaker Notebook Terminal**, run:
   ```bash
   cd ~/bedrock-agentcore-workshop
   bash scripts/diagnose_cf_errors.sh
   ```

2. You should now see **✅** for permission checks instead of **❌**

---

## Step 4: Deploy CloudFormation Stacks

Once permissions are verified, run the setup:

```bash
cd ~/bedrock-agentcore-workshop
bash scripts/prereq.sh
```

This will:
1. ✅ Create S3 buckets
2. ✅ Upload Lambda code
3. ✅ Deploy Infrastructure stack (IAM roles, Lambda, DynamoDB, Knowledge Bases)
4. ✅ Deploy Cognito stack (User pools, app clients)
5. ✅ Create SSM parameters

---

## Troubleshooting

### "Access Denied" Error
- You don't have permission to modify IAM roles
- Use **Option 3** (ask your admin)

### Permissions Added but Still Failing
- **Refresh your notebook kernel** or restart the notebook instance
- Sometimes IAM permission changes take 1-2 minutes to propagate

### Can't Find My Role Name
- Try running this in a notebook cell:
  ```python
  import boto3
  sts = boto3.client('sts')
  identity = sts.get_caller_identity()
  print(identity['Arn'])
  ```
- The role name will be in the ARN

---

## Alternative: Use AWS CloudShell Instead

If you can't modify the SageMaker role, use **AWS CloudShell** (has permissions by default):

1. Open **AWS Console** → Click CloudShell icon (top-right)
2. Run:
   ```bash
   git clone https://github.com/craigjurs/bedrock-agentcore-workshop.git
   cd bedrock-agentcore-workshop
   bash scripts/prereq.sh
   ```

---

## Security Note

These permissions are broad for the workshop. In production:
- Scope permissions to specific resources
- Use condition statements
- Follow principle of least privilege

After the workshop, you can remove this policy from your SageMaker role.
