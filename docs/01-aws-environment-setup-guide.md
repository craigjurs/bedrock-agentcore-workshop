# AWS Environment Setup: A Detailed Pedagogical Guide

## Overview: What Are We Building?

Before diving into the code, let's understand the **big picture**. This workshop sets up an AI-powered **American Red Cross Customer Service Chatbot** with the following components:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     AWS Environment Setup                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐  │
│  │  infrastructure  │    │     cognito      │    │    Lambda        │  │
│  │     .yaml        │    │      .yaml       │    │   Functions      │  │
│  │                  │    │                  │    │                  │  │
│  │  • IAM Roles     │    │  • User Pool     │    │  • Web Search    │  │
│  │  • DynamoDB      │    │  • App Clients   │    │  • Data Setup    │  │
│  │  • Lambda        │    │  • OAuth2        │    │  • KB Creation   │  │
│  │  • Knowledge     │    │  • SSM Params    │    │                  │  │
│  │    Bases (3)     │    │                  │    │                  │  │
│  │  • S3 Buckets    │    │                  │    │                  │  │
│  └──────────────────┘    └──────────────────┘    └──────────────────┘  │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                     prereq.sh (Orchestrator)                      │  │
│  │  1. Create S3 bucket for Lambda code                             │  │
│  │  2. Zip and upload Lambda functions                              │  │
│  │  3. Deploy infrastructure.yaml stack                             │  │
│  │  4. Deploy cognito.yaml stack                                    │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Part 1: The Orchestrator Script (`prereq.sh`)

This is the **main entry point** that orchestrates the entire setup. Let's walk through it step by step.

### 1.1 Script Configuration (Lines 1-43)

```bash
#!/bin/sh

# Enable strict error handling
set -euo pipefail
```

**What this means:**
- `set -e` → Exit immediately if any command fails
- `set -u` → Treat unset variables as errors
- `set -o pipefail` → Capture errors in piped commands

```bash
# ----- Config -----
BUCKET_NAME=${1:-redcross}                    # Default: "redcross" (can be overridden)
INFRA_STACK_NAME=${2:-RedCrossStackInfra}     # Infrastructure stack name
COGNITO_STACK_NAME=${3:-RedCrossStackCognito} # Cognito stack name
```

**Concept: Parameterization**
- The script uses **default values with override capability**
- Running `./prereq.sh myprefix` would use "myprefix" instead of "redcross"
- This allows multiple people to deploy without bucket name conflicts

### 1.2 AWS Region and Account Discovery (Lines 13-32)

```bash
# First try to get region from environment variable
if [ -z "${AWS_REGION-}" ]; then
    REGION=$(aws configure get region 2>/dev/null || echo "us-west-2")
    export AWS_REGION="${REGION}"
fi
```

**Order of precedence for region:**
1. `AWS_REGION` environment variable (if set)
2. AWS CLI configured region (`~/.aws/config`)
3. Fallback to `us-west-2`

```bash
# Get AWS Account ID with proper error handling
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>&1)
```

**What's happening:**
- `aws sts get-caller-identity` → Returns info about the current IAM credentials
- `--query Account` → Extracts just the account ID (e.g., "123456789012")
- This is used to create **globally unique** resource names

### 1.3 Create S3 Bucket for Lambda Code (Lines 47-68)

```bash
FULL_BUCKET_NAME="${BUCKET_NAME}-${ACCOUNT_ID}-${REGION}"
```

**Why this naming pattern?**
- S3 bucket names are **globally unique across all AWS accounts**
- Including account ID and region prevents conflicts
- Example: `redcross-123456789012-us-west-2`

```bash
if [ "$REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$FULL_BUCKET_NAME"
else
  aws s3api create-bucket \
    --bucket "$FULL_BUCKET_NAME" \
    --create-bucket-configuration LocationConstraint="$REGION"
fi
```

**AWS Quirk:**
- `us-east-1` is the "default" region and doesn't need `LocationConstraint`
- All other regions require it explicitly

### 1.4 Zip and Upload Lambda Code (Lines 70-88)

```bash
echo "📦 Zipping contents of $LAMBDA_SRC into $ZIP_FILE..."
cd "$LAMBDA_SRC"
zip -r "../../../$ZIP_FILE" . > /dev/null
cd - > /dev/null
```

**What's being packaged:**
```
prerequisite/lambda/python/
├── lambda_function.py    # Main handler
├── web_search.py         # DuckDuckGo search
├── ddgs-layer.zip        # Pre-packaged DDGS library
└── __init__.py
```

```bash
# Upload Lambda code
aws s3api put-object --bucket "$FULL_BUCKET_NAME" --key "$S3_KEY" --body "$ZIP_FILE"

# Upload DDGS layer
aws s3api put-object --bucket "$FULL_BUCKET_NAME" --key "$S3_LAYER_KEY" --body "$LAYER_ZIP_FILE"
```

**Why upload to S3 first?**
- CloudFormation Lambda deployments **require** code in S3 for packages > 50MB
- Even for smaller packages, S3 deployment is cleaner and more reliable
- The CloudFormation template references these S3 locations

### 1.5 Deploy CloudFormation Stacks (Lines 126-182)

```bash
deploy_stack() {
  local stack_name=$1
  local template_file=$2

  aws cloudformation deploy \
    --stack-name "$stack_name" \
    --template-file "$template_file" \
    --s3-bucket "$FULL_BUCKET_NAME" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "$REGION" \
    "${params[@]}"
```

**Key flags:**
- `--capabilities CAPABILITY_NAMED_IAM` → Required when creating IAM roles with custom names
- `--s3-bucket` → CloudFormation uploads large templates here automatically

**ROLLBACK_COMPLETE Handling:**

```bash
if echo "$output" | grep -q "is in ROLLBACK_COMPLETE state"; then
    aws cloudformation delete-stack --stack-name "$stack_name"
    aws cloudformation wait stack-delete-complete --stack-name "$stack_name"
    # Retry deployment...
fi
```

**What's ROLLBACK_COMPLETE?**
- When a stack creation fails, CloudFormation rolls back
- The stack remains in `ROLLBACK_COMPLETE` state
- It **cannot be updated** - must be deleted first
- This script handles this automatically

---

## Part 2: Infrastructure Template (`infrastructure.yaml`)

This is the **heart** of the AWS setup. Let's examine each major section.

### 2.1 Template Header and Parameters (Lines 1-27)

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: 'CloudFormation template for American Red Cross Chatbot System...'

Parameters:
  LambdaS3Bucket:
    Description: The name of S3 bucket which contains lambda code
    Type: String
    MinLength: 1

  LambdaS3Key:
    Description: The S3 object key which contains Lambda function code
    Type: String

  LayerS3Key:
    Type: String
    Description: 'S3 key for the DDGS layer zip file'
```

**Concept: CloudFormation Parameters**
- Parameters make templates **reusable**
- Values are passed from the `prereq.sh` script:
  ```bash
  --parameter-overrides LambdaS3Bucket="$FULL_BUCKET_NAME" LambdaS3Key="$S3_KEY"
  ```

### 2.2 RuntimeAgentCoreRole - IAM Role for AgentCore Runtime (Lines 31-141)

This is the **most important** IAM role. It grants permissions for the Bedrock AgentCore Runtime.

```yaml
RuntimeAgentCoreRole:
  Type: AWS::IAM::Role
  Properties:
    AssumeRolePolicyDocument:
      Version: '2012-10-17'
      Statement:
        - Effect: Allow
          Principal:
            Service:
              - bedrock-agentcore.amazonaws.com
          Action:
            - sts:AssumeRole
```

**What's AssumeRolePolicyDocument?**
- This is the **trust policy** - who can "become" this role
- Here, the `bedrock-agentcore.amazonaws.com` service can assume this role
- Think of it as: "AgentCore is allowed to wear this hat"

**Permission Categories in this role:**

#### A. ECR Access (Container Registry)
```yaml
- Sid: ECRImageAccess
  Effect: Allow
  Action:
    - ecr:BatchGetImage
    - ecr:GetDownloadUrlForLayer
  Resource:
    - !Sub arn:aws:ecr:${AWS::Region}:${AWS::AccountId}:repository/bedrock_agentcore-redcross*
```
**Why?** AgentCore Runtime pulls your agent's Docker image from ECR.

#### B. CloudWatch Logs
```yaml
- Effect: Allow
  Action:
    - logs:CreateLogStream
    - logs:PutLogEvents
  Resource:
    - !Sub arn:aws:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/bedrock-agentcore/runtimes/*
```
**Why?** Your agent needs to write logs for debugging and observability.

#### C. X-Ray Tracing
```yaml
- Effect: Allow
  Action:
    - xray:PutTraceSegments
    - xray:PutTelemetryRecords
  Resource: "*"
```
**Why?** Distributed tracing for request flow visualization.

#### D. Bedrock Model Invocation
```yaml
- Sid: ProvisionedThroughputModelInvocation
  Effect: Allow
  Action:
    - bedrock:InvokeModel
    - bedrock:InvokeModelWithResponseStream
  Resource:
    - "arn:aws:bedrock:*::foundation-model/*"
```
**Why?** The agent needs to call Claude and embedding models.

#### E. AgentCore Memory Access
```yaml
- Sid: AgentCoreMemory
  Effect: Allow
  Action:
    - bedrock-agentcore:ListMemories
    - bedrock-agentcore:RetrieveMemoryRecords
    - bedrock-agentcore:CreateEvent
  Resource:
    - !Sub arn:aws:bedrock-agentcore:${AWS::Region}:${AWS::AccountId}:memory/redcross*
```
**Why?** The agent needs to read/write conversation memory.

### 2.3 GatewayAgentCoreRole (Lines 143-166)

```yaml
GatewayAgentCoreRole:
  Type: AWS::IAM::Role
  Properties:
    Policies:
      - PolicyName: BedrockAgentPolicy
        PolicyDocument:
          Statement:
            - Sid: InvokeFunction
              Effect: Allow
              Action:
                - lambda:InvokeFunction
              Resource:
                - !GetAtt CustomerSupportLambda.Arn
```

**Purpose:** The Gateway role is simpler - it only needs to invoke Lambda functions that implement tools.

### 2.4 DynamoDB Tables (Lines 167-229)

```yaml
WarrantyTable:
  Type: AWS::DynamoDB::Table
  Properties:
    BillingMode: PAY_PER_REQUEST
    AttributeDefinitions:
      - AttributeName: serial_number
        AttributeType: S
    KeySchema:
      - AttributeName: serial_number
        KeyType: HASH
    GlobalSecondaryIndexes:
      - IndexName: customer-index
        KeySchema:
          - AttributeName: customer_id
            KeyType: HASH
```

**DynamoDB Concepts:**
- **Partition Key (HASH):** The primary way to look up items (like `serial_number`)
- **Global Secondary Index (GSI):** Allows querying by different attributes (like `customer_id`)
- **PAY_PER_REQUEST:** No capacity planning needed - pay per operation
- **PointInTimeRecoveryEnabled:** Continuous backups (35-day retention)

**Note:** These tables are marked as "legacy" in comments - they're from a previous version but kept for compatibility.

### 2.5 PopulateDataFunction - Custom Resource Lambda (Lines 231-574)

This is a **CloudFormation Custom Resource** - a Lambda that runs during stack creation.

```yaml
PopulateDataFunction:
  Type: AWS::Lambda::Function
  Properties:
    Runtime: python3.12
    Handler: index.lambda_handler
    Code:
      ZipFile: |
        import boto3
        # ... inline Python code ...
```

**What it does:**
1. Creates sample customer data (5 customers)
2. Creates sample warranty records (8 warranties)
3. Populates DynamoDB tables during stack creation

**Custom Resource Pattern:**
```python
def send_response(event, context, status, data=None, reason=None):
    responseUrl = event['ResponseURL']
    responseBody = {
        'Status': status,  # 'SUCCESS' or 'FAILED'
        'PhysicalResourceId': context.log_stream_name,
        # ... other fields
    }
    # Send response back to CloudFormation
    urllib.request.Request(responseUrl, data=dataBytes, method='PUT')
```

**How Custom Resources Work:**
1. CloudFormation calls the Lambda with a **pre-signed S3 URL**
2. Lambda does its work
3. Lambda **must** respond to that URL (success or failure)
4. CloudFormation waits for the response to continue

### 2.6 CustomerSupportLambda - The Web Search Tool (Lines 577-696)

```yaml
DDGSLayer:
  Type: AWS::Lambda::LayerVersion
  Properties:
    LayerName: !Sub "${AWS::StackName}-ddgs-layer"
    Content:
      S3Bucket: !Ref LambdaS3Bucket
      S3Key: !Ref LayerS3Key
    CompatibleRuntimes:
      - python3.12

CustomerSupportLambda:
  Type: AWS::Lambda::Function
  Properties:
    Handler: lambda_function.lambda_handler
    Code:
      S3Bucket: !Ref LambdaS3Bucket
      S3Key: !Ref LambdaS3Key
    Layers:
      - !Ref DDGSLayer
```

**Lambda Layers Concept:**
- Layers are **reusable code packages** (libraries, dependencies)
- The DDGS (DuckDuckGo Search) library is packaged as a layer
- Multiple Lambdas can share the same layer

### 2.7 SSM Parameter Store (Lines 698-748)

```yaml
WarrantyTableNameParameter:
  Type: AWS::SSM::Parameter
  Properties:
    Name: /app/redcross/dynamodb/warranty_table_name
    Type: String
    Value: !Ref WarrantyTable

RuntimeAgentcoreIAMRoleParameter:
  Type: AWS::SSM::Parameter
  Properties:
    Name: /app/redcross/agentcore/runtime_iam_role
    Value: !GetAtt RuntimeAgentCoreRole.Arn
```

**SSM Parameter Store Concept:**
- A **centralized configuration store**
- Avoids hardcoding values in code
- The labs will retrieve these values:
  ```python
  # In notebook code:
  role_arn = get_ssm_parameter('/app/redcross/agentcore/runtime_iam_role')
  ```

**Parameter Hierarchy:**
```
/app/redcross/
├── dynamodb/
│   ├── warranty_table_name
│   └── customer_profile_table_name
├── agentcore/
│   ├── runtime_iam_role
│   ├── gateway_iam_role
│   ├── lambda_arn
│   ├── memory_id
│   ├── client_id
│   ├── pool_id
│   └── ...
```

### 2.8 Knowledge Base Infrastructure (Lines 750-1533)

This is the **most complex** part - setting up 3 Bedrock Knowledge Bases.

#### S3 Bucket for Knowledge Base Data
```yaml
BedrockKnowledgeBaseDataBucket:
  Type: AWS::S3::Bucket
  Properties:
    BucketName: !Sub '${AWS::StackName}-kb-data-bucket'
    PublicAccessBlockConfiguration:
      BlockPublicAcls: true
      BlockPublicPolicy: true
```

#### Boto3 Layer Creator Lambda
```yaml
Boto3LayerCreator:
  Type: AWS::Lambda::Function
  Properties:
    Code:
      ZipFile: |
        # Dynamically creates a Lambda layer with latest boto3
        subprocess.check_call([
            sys.executable, '-m', 'pip', 'install',
            'boto3>=1.34.0', 'botocore>=1.34.0',
            '--target', python_dir
        ])
```

**Why create a boto3 layer dynamically?**
- Lambda's built-in boto3 may be outdated
- New AWS services (like `s3vectors`) require recent boto3
- This ensures we have the latest SDK

#### KnowledgeBaseSetupFunction - The KB Creation Lambda

This Lambda (embedded in the template) does:

1. **Uploads knowledge base content to S3:**
```python
biomedical_docs = {'biomedical/blood-drive-appointments.txt': """..."""}
humanitarian_docs = {'humanitarian/relief-centers-grants.txt': """..."""}
training_docs = {'training/first-aid-classes-registrations.txt': """..."""}

for filename, content in all_docs.items():
    s3_client.put_object(Bucket=data_bucket_name, Key=filename, Body=content)
```

2. **Creates S3 Vector Buckets (for vector storage):**
```python
s3vectors.create_vector_bucket(
    vectorBucketName=vector_bucket_name,
    encryptionConfiguration={'sseType': 'AES256'}
)
```

3. **Creates Vector Indexes:**
```python
s3vectors.create_index(
    vectorBucketName=vector_bucket_name,
    indexName=index_name,
    dimension=1024,           # Titan embedding dimension
    distanceMetric='cosine',  # How to measure similarity
    dataType='float32'
)
```

4. **Creates Bedrock Knowledge Bases:**
```python
bedrock.create_knowledge_base(
    name=kb_name,
    roleArn=execution_role_arn,
    knowledgeBaseConfiguration={
        'type': 'VECTOR',
        'vectorKnowledgeBaseConfiguration': {
            'embeddingModelArn': 'arn:aws:bedrock:...:foundation-model/amazon.titan-embed-text-v2:0',
            'embeddingModelConfiguration': {
                'dimensions': 1024,
                'embeddingDataType': 'FLOAT32'
            }
        }
    },
    storageConfiguration={
        'type': 'S3_VECTORS',
        's3VectorsConfiguration': {'indexArn': index_arn}
    }
)
```

5. **Creates Data Sources:**
```python
bedrock.create_data_source(
    knowledgeBaseId=kb_id,
    name=datasource_name,
    dataSourceConfiguration={
        'type': 'S3',
        's3Configuration': {
            'bucketArn': f"arn:aws:s3:::{data_bucket_name}",
            'inclusionPrefixes': [f"{lob_name}/"]  # Only files in this folder
        }
    },
    vectorIngestionConfiguration={
        'chunkingConfiguration': {
            'chunkingStrategy': 'FIXED_SIZE',
            'fixedSizeChunkingConfiguration': {
                'maxTokens': 200,
                'overlapPercentage': 10
            }
        }
    }
)
```

6. **Triggers ingestion jobs** to process documents into vectors

7. **Stores KB IDs in SSM Parameter Store:**
```python
ssm_client.put_parameter(
    Name=f"/{account_id}-{region}/kb/{lob_name}/knowledge-base-id",
    Value=result['kb_id'],
    Type='String'
)
```

---

## Part 3: Cognito Authentication (`cognito.yaml`)

This template sets up **user authentication** for the chatbot.

### 3.1 User Pool (Lines 32-43)

```yaml
UserPool:
  Type: AWS::Cognito::UserPool
  Properties:
    UserPoolName: !Ref UserPoolName
    MfaConfiguration: 'OFF'
    UsernameAttributes:
      - email           # Use email as username
    AutoVerifiedAttributes:
      - email           # Auto-verify email (skip confirmation)
```

**Cognito User Pool Concept:**
- A **user directory** that stores user accounts
- Handles sign-up, sign-in, password reset, etc.
- Users identified by email in this setup

### 3.2 User Groups (Lines 46-60)

```yaml
AdminGroup:
  Type: AWS::Cognito::UserPoolGroup
  Properties:
    GroupName: admin
    Precedence: 1       # Higher priority

CustomerGroup:
  Type: AWS::Cognito::UserPoolGroup
  Properties:
    GroupName: customer
    Precedence: 2
```

**Concept: Role-Based Access**
- Users can belong to groups
- Groups can have different permissions
- The chatbot can check group membership

### 3.3 App Clients (Lines 62-124)

**WebUserPoolClient** (for browser/Streamlit):
```yaml
WebUserPoolClient:
  Properties:
    GenerateSecret: false      # SPAs can't keep secrets
    AllowedOAuthFlows:
      - code                   # Authorization code flow
    AllowedOAuthScopes:
      - openid
      - email
      - profile
    CallbackURLs:
      - http://localhost:8501/  # Streamlit default port
```

**MachineUserPoolClient** (for server-to-server):
```yaml
MachineUserPoolClient:
  Properties:
    GenerateSecret: true       # Servers can store secrets
    AllowedOAuthFlows:
      - client_credentials     # M2M authentication
```

**OAuth2 Flows Explained:**
- **Authorization Code:** User logs in via browser → gets code → exchanges for tokens
- **Client Credentials:** Server-to-server auth with client ID + secret

### 3.4 Resource Server (Lines 126-140)

```yaml
ResourceServer:
  Type: AWS::Cognito::UserPoolResourceServer
  Properties:
    Identifier: default-m2m-resource-server-...
    Scopes:
      - ScopeName: 'read'
        ScopeDescription: 'An example scope'
```

**Concept: OAuth2 Scopes**
- Define **what** an application can do
- The agent gateway requires the `read` scope
- Format: `{resource-server-identifier}/read`

### 3.5 User Pool Domain (Lines 142-149)

```yaml
UserPoolDomain:
  Type: AWS::Cognito::UserPoolDomain
  Properties:
    Domain: !Join ['', [!Ref 'AWS::Region', ...]]
```

**Why a domain?**
- Cognito hosts login pages at this domain
- Example: `https://us-west-2abc123.auth.us-west-2.amazoncognito.com`
- The Streamlit app redirects here for login

### 3.6 SSM Parameters for Cognito (Lines 211-306)

```yaml
CognitoMachineClientIdParameter:
  Properties:
    Name: /app/redcross/agentcore/client_id
    Value: !Ref MachineUserPoolClient

CognitoTokenURLParameter:
  Properties:
    Name: /app/redcross/agentcore/cognito_token_url
    Value: !Sub 'https://${domain}.auth.${AWS::Region}.amazoncognito.com/oauth2/token'
```

**Why store these in SSM?**
- The notebooks and Lambda functions need these values
- Avoids hardcoding or manual configuration
- Lab 3 retrieves these to authenticate with the Gateway

---

## Part 4: Lambda Functions (The Tools)

### 4.1 lambda_function.py - Tool Router

```python
def lambda_handler(event, context):
    # Get the tool name from AgentCore
    extended_tool_name = context.client_context.custom["bedrockAgentCoreToolName"]
    resource = extended_tool_name.split("___")[1]  # Extract tool name

    if resource == "web_search":
        keywords = get_named_parameter(event, "keywords")
        search_results = web_search(keywords=keywords, ...)
        return {"statusCode": 200, "body": f"🔍 Search Results: {search_results}"}

    return {"statusCode": 400, "body": f"❌ Unknown toolname: {resource}"}
```

**How AgentCore Tools Work:**
1. Agent decides it needs to search the web
2. AgentCore Gateway invokes this Lambda
3. Tool name is passed in `context.client_context.custom`
4. Lambda routes to the correct handler
5. Results returned to the agent

### 4.2 web_search.py - DuckDuckGo Search

```python
from ddgs import DDGS

def web_search(keywords: str, region: str = "us-en", max_results: int = 5) -> str:
    results = DDGS().text(keywords, region=region, max_results=max_results)
    return results if results else "No results found."
```

**Why DuckDuckGo?**
- No API key required
- Free to use
- Returns structured results (title, URL, body)

---

## Part 5: Supporting Scripts

### 5.1 cleanup.sh - Teardown

```bash
# 1. Delete CloudFormation stacks
aws cloudformation delete-stack --stack-name "$INFRA_STACK_NAME"
aws cloudformation wait stack-delete-complete --stack-name "$INFRA_STACK_NAME"

# 2. Delete vector buckets (special S3 vectors cleanup)
python3 -c "
    c = boto3.client('s3vectors')
    for lob in ['biomedical', 'humanitarian', 'training']:
        c.delete_index(vectorBucketName=vb, indexName=idx)
        c.delete_vector_bucket(vectorBucketName=vb)
"

# 3. Empty and optionally delete S3 bucket
aws s3 rm "s3://$FULL_BUCKET_NAME" --recursive
```

**Note:** Vector buckets must be deleted **before** the stack, since they're created by the custom resource, not directly by CloudFormation.

### 5.2 diagnose_cf_errors.sh - Troubleshooting

```bash
# Check IAM permissions
aws sts get-caller-identity
aws iam list-roles --max-items 1
aws lambda list-functions --max-items 1

# Check stack status
aws cloudformation describe-stacks --stack-name "$stack_name"

# Get failure events
aws cloudformation describe-stack-events \
    --query "StackEvents[?contains(ResourceStatus, 'FAILED')]"
```

**Common issues this helps diagnose:**
- Missing IAM permissions
- Failed resource creation
- ROLLBACK_COMPLETE states

---

## Summary: The Complete Flow

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              SETUP FLOW                                       │
└──────────────────────────────────────────────────────────────────────────────┘

1. Run prereq.sh
   │
   ├─→ Get AWS account ID and region
   │
   ├─→ Create S3 bucket: redcross-{account}-{region}
   │
   ├─→ Zip Lambda code from prerequisite/lambda/python/
   │
   ├─→ Upload lambda.zip and ddgs-layer.zip to S3
   │
   ├─→ Deploy infrastructure.yaml (RedCrossStackInfra)
   │   │
   │   ├─→ Create IAM Roles (Runtime, Gateway, Lambda)
   │   │
   │   ├─→ Create DynamoDB Tables
   │   │
   │   ├─→ Create Lambda Function + Layer
   │   │
   │   ├─→ [Custom Resource] Create boto3 layer dynamically
   │   │
   │   ├─→ [Custom Resource] Populate DynamoDB with sample data
   │   │
   │   ├─→ [Custom Resource] Create 3 Knowledge Bases:
   │   │   ├─→ Biomedical (blood drives, appointments)
   │   │   ├─→ Humanitarian (relief centers, grants)
   │   │   └─→ Training (first aid classes)
   │   │
   │   └─→ Store all resource IDs in SSM Parameter Store
   │
   └─→ Deploy cognito.yaml (RedCrossStackCognito)
       │
       ├─→ Create User Pool
       │
       ├─→ Create User Groups (admin, customer)
       │
       ├─→ Create App Clients (web, machine)
       │
       ├─→ Create OAuth2 Resource Server
       │
       └─→ Store Cognito config in SSM Parameter Store
```

After setup completes, you have:
- **3 Knowledge Bases** with Red Cross data
- **1 Lambda Function** for web search
- **Authentication** via Cognito
- **All configuration** stored in SSM Parameter Store

The notebooks can then:
1. Retrieve configuration from SSM
2. Connect to Knowledge Bases
3. Authenticate with Cognito
4. Use the web search Lambda
5. Deploy to AgentCore Runtime

---

## Appendix: Key AWS Services Reference

| Service | Purpose in This Workshop |
|---------|-------------------------|
| **CloudFormation** | Infrastructure as Code - defines all resources |
| **S3** | Storage for Lambda code and knowledge base documents |
| **S3 Vectors** | Vector storage for semantic search (new service) |
| **Lambda** | Serverless functions for tools and setup |
| **DynamoDB** | NoSQL database for customer/warranty data |
| **Cognito** | User authentication and OAuth2 |
| **SSM Parameter Store** | Configuration management |
| **IAM** | Identity and access management |
| **Bedrock** | Foundation models and knowledge bases |
| **Bedrock AgentCore** | Agent runtime, gateway, and memory |
| **CloudWatch** | Logging and monitoring |
| **X-Ray** | Distributed tracing |
| **ECR** | Container registry for agent images |

---

## Next Steps

Continue to **[Lab 1: Create an Agent](./02-lab-01-create-agent.md)** to see how the notebooks use this infrastructure to build the Red Cross chatbot.
