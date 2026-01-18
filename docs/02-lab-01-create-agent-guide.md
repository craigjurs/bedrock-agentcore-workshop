# Lab 1: Creating an American Red Cross Customer Service Chatbot

## A Detailed Pedagogical Guide

---

## Overview: What You'll Build

In Lab 1, you create a **functional AI agent prototype** that serves as a customer service chatbot for the American Red Cross. This agent can:

1. **Search 3 Knowledge Bases** for Red Cross-specific information
2. **Search the Web** for general information using DuckDuckGo
3. **Respond Intelligently** to customer queries using Claude Haiku 4.5

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         LAB 1 ARCHITECTURE                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│     User Query                                                               │
│         │                                                                    │
│         ▼                                                                    │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                    STRANDS AGENT (Local Prototype)                    │   │
│  │                                                                       │   │
│  │   ┌─────────────┐    ┌───────────────────────────────────────────┐   │   │
│  │   │  Claude     │    │                  TOOLS                     │   │   │
│  │   │  Haiku 4.5  │───▶│  ┌───────────────────────────────────────┐│   │   │
│  │   │  (Bedrock)  │    │  │ search_biomedical_knowledge_base()   ││   │   │
│  │   └─────────────┘    │  │ search_humanitarian_knowledge_base()  ││   │   │
│  │                      │  │ search_training_services_kb()         ││   │   │
│  │                      │  │ web_search()                          ││   │   │
│  │                      │  └───────────────────────────────────────┘│   │   │
│  │                      └───────────────────────────────────────────┘   │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│         │                          │                                         │
│         │                          ▼                                         │
│         │           ┌──────────────────────────────┐                        │
│         │           │    BEDROCK KNOWLEDGE BASES    │                        │
│         │           │  ┌────────────────────────┐  │                        │
│         │           │  │ Biomedical Services KB │  │                        │
│         │           │  │ (blood drives, appts)  │  │                        │
│         │           │  ├────────────────────────┤  │                        │
│         │           │  │ Humanitarian Services  │  │                        │
│         │           │  │ (relief, grants)       │  │                        │
│         │           │  ├────────────────────────┤  │                        │
│         │           │  │ Training Services KB   │  │                        │
│         │           │  │ (first aid classes)    │  │                        │
│         │           │  └────────────────────────┘  │                        │
│         │           └──────────────────────────────┘                        │
│         ▼                                                                    │
│     Response                                                                 │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites: What Must Be Set Up First

Before running Lab 1, these resources must exist (created by `prereq.sh`):

| Resource | How It's Created | What It Provides |
|----------|------------------|------------------|
| **3 Knowledge Bases** | CloudFormation Custom Resource | Vector databases with Red Cross content |
| **SSM Parameters** | CloudFormation | KB IDs stored at `/{account}-{region}/kb/{lob}/knowledge-base-id` |
| **IAM Roles** | CloudFormation | Permissions for Bedrock model invocation |
| **S3 Data Bucket** | CloudFormation | Source documents for knowledge bases |

---

## Cell-by-Cell Walkthrough

### Cell 0-4: Introduction and Setup Context (Markdown)

These cells provide:
- Workshop overview and learning objectives
- Architecture diagram reference
- Prerequisites checklist
- Self-paced lab instructions (optional)

**Key Points:**
- This is the **first of 6 labs** building toward production
- Uses **Strands Agents** framework (code-first, simple)
- Uses **Claude Haiku 4.5** via Amazon Bedrock

---

### Cell 5: Install Dependencies

```python
%pip install -U -r requirements.txt -q
```

**What's Happening:**
- `%pip` is a Jupyter magic command that runs pip in the notebook kernel
- `-U` upgrades packages to latest versions
- `-r requirements.txt` installs from the requirements file
- `-q` runs quietly (less output)

**Dependencies Installed (from `requirements.txt`):**

| Package | Version | Purpose |
|---------|---------|---------|
| `strands-agents` | latest | Core agent framework |
| `strands-agents-tools` | latest | Pre-built tools including `retrieve` |
| `boto3` | >=1.42.3 | AWS SDK for Python |
| `botocore` | >=1.42.3 | Low-level AWS interface |
| `bedrock-agentcore` | 1.1.1 | AgentCore client library |
| `bedrock-agentcore-starter-toolkit` | 0.2.3 | Helper utilities |
| `aws-opentelemetry-distro` | 0.14.0 | Observability (used in later labs) |
| `ddgs` | latest | DuckDuckGo Search library |
| `pyyaml` | latest | YAML parsing |

**Note:** Dependency conflicts are expected and safe to ignore for this workshop.

---

### Cell 7: Import Libraries

```python
# Import libraries
import boto3
from boto3.session import Session

from ddgs.exceptions import DDGSException, RatelimitException
from ddgs import DDGS

from strands.tools import tool
```

**Library Breakdown:**

| Import | Purpose |
|--------|---------|
| `boto3` | AWS SDK - interact with AWS services |
| `boto3.session.Session` | Manage AWS credentials and region |
| `ddgs.exceptions.DDGSException` | Handle DuckDuckGo search errors |
| `ddgs.exceptions.RatelimitException` | Handle rate limiting |
| `ddgs.DDGS` | DuckDuckGo search client |
| `strands.tools.tool` | Decorator to define agent tools |

---

### Cell 8: Initialize Boto Session

```python
# Get boto session
boto_session = Session()
region = boto_session.region_name
```

**What's Happening:**
1. `Session()` creates a boto3 session using:
   - Environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)
   - Or AWS credentials file (`~/.aws/credentials`)
   - Or IAM role (if running on EC2/SageMaker)

2. `region_name` extracts the configured region (e.g., `us-west-2`)

**Why This Matters:**
- All subsequent AWS API calls use this session
- Region determines which AWS endpoints are called
- Knowledge bases are region-specific

---

### Cell 11: Tool 1 - Biomedical Knowledge Base Search

```python
from strands_tools import retrieve
import boto3

@tool
def search_biomedical_knowledge_base(query: str) -> str:
    """
    Search the Biomedical Services knowledge base for information about
    blood drives, appointments, locations, and sign-up.

    Args:
        query: The search query about blood drives, appointments, locations,
               or sign-up information

    Returns:
        Relevant information from the Biomedical Services knowledge base
    """
    try:
        # Get KB ID from parameter store
        ssm = boto3.client("ssm")
        account_id = boto3.client("sts").get_caller_identity()["Account"]
        region = boto3.Session().region_name

        kb_id = ssm.get_parameter(
            Name=f"/{account_id}-{region}/kb/biomedical/knowledge-base-id"
        )["Parameter"]["Value"]
        print(f"Successfully retrieved Biomedical KB ID: {kb_id}")

        # Use strands retrieve tool
        tool_use = {
            "toolUseId": "biomedical_query",
            "input": {
                "text": query,
                "knowledgeBaseId": kb_id,
                "region": region,
                "numberOfResults": 3,
                "score": 0.4,
            },
        }

        result = retrieve.retrieve(tool_use)

        if result["status"] == "success":
            return result["content"][0]["text"]
        else:
            return f"Unable to access Biomedical Services knowledge base. Error: {result['content'][0]['text']}"

    except Exception as e:
        print(f"Detailed error in search_biomedical_knowledge_base: {str(e)}")
        return f"Unable to access Biomedical Services knowledge base. Error: {str(e)}"
```

**Detailed Breakdown:**

#### The `@tool` Decorator
```python
@tool
def search_biomedical_knowledge_base(query: str) -> str:
```
- **What it does:** Registers this function as an agent tool
- **How Strands uses it:**
  1. Extracts function name → tool name
  2. Parses docstring → tool description for the LLM
  3. Inspects type hints → parameter schema
  4. The agent can then "decide" to call this tool

#### Getting the Knowledge Base ID
```python
ssm = boto3.client("ssm")
account_id = boto3.client("sts").get_caller_identity()["Account"]
region = boto3.Session().region_name

kb_id = ssm.get_parameter(
    Name=f"/{account_id}-{region}/kb/biomedical/knowledge-base-id"
)["Parameter"]["Value"]
```

**Step by step:**
1. Create SSM (Parameter Store) client
2. Get AWS account ID from STS (Security Token Service)
3. Get current region from session
4. Construct parameter name: `/{account}-{region}/kb/biomedical/knowledge-base-id`
5. Retrieve the KB ID value

**Example parameter path:** `/123456789012-us-west-2/kb/biomedical/knowledge-base-id`

#### Calling the Strands Retrieve Tool
```python
tool_use = {
    "toolUseId": "biomedical_query",
    "input": {
        "text": query,                  # User's question
        "knowledgeBaseId": kb_id,       # Which KB to search
        "region": region,               # AWS region
        "numberOfResults": 3,           # Return top 3 matches
        "score": 0.4,                   # Minimum relevance score (0-1)
    },
}

result = retrieve.retrieve(tool_use)
```

**How `strands_tools.retrieve` works:**
1. Converts query text to embeddings using Bedrock
2. Searches the vector index for similar documents
3. Returns documents with relevance score >= 0.4
4. Limited to top 3 results

**Response structure:**
```python
{
    "status": "success",  # or "error"
    "content": [
        {"text": "Retrieved document content..."}
    ]
}
```

---

### Cell 13: Tool 2 - Humanitarian Knowledge Base Search

```python
@tool
def search_humanitarian_knowledge_base(query: str) -> str:
    """
    Search the Humanitarian Services knowledge base for information about
    relief centers, grant applications, and aid programs.
    ...
    """
```

**Same pattern as Tool 1, but:**
- Different SSM parameter: `/{account}-{region}/kb/humanitarian/knowledge-base-id`
- Different tool ID: `humanitarian_query`
- Searches different content (relief centers, grants)

---

### Cell 15: Tool 3 - Training Services Knowledge Base Search

```python
@tool
def search_training_services_knowledge_base(query: str) -> str:
    """
    Search the Training Services knowledge base for information about
    first aid training classes, schedules, locations, sign-up, and account information.
    ...
    """
```

**Same pattern, different KB:**
- SSM parameter: `/{account}-{region}/kb/training/knowledge-base-id`
- Tool ID: `training_query`
- Content: First aid classes, schedules, registrations

---

### Cell 17: Tool 4 - Web Search

```python
@tool
def web_search(keywords: str, region: str = "us-en", max_results: int = 5) -> str:
    """Search the web for updated information.

    Args:
        keywords (str): The search query keywords.
        region (str): The search region: wt-wt, us-en, uk-en, ru-ru, etc..
        max_results (int | None): The maximum number of results to return.
    Returns:
        List of dictionaries with search results.
    """
    try:
        results = DDGS().text(keywords, region=region, max_results=max_results)
        return results if results else "No results found."
    except RatelimitException:
        return "Rate limit reached. Please try again later."
    except DDGSException as e:
        return f"Search error: {e}"
    except Exception as e:
        return f"Search error: {str(e)}"
```

**How DuckDuckGo Search Works:**

1. **DDGS() instantiation:** Creates a search client
2. **`.text()` method:** Performs text search
3. **Parameters:**
   - `keywords`: Search query
   - `region`: Geographic region for results (default: US English)
   - `max_results`: Limit returned results (default: 5)

**Return format:**
```python
[
    {
        "title": "Result Title",
        "href": "https://example.com/page",
        "body": "Snippet of the page content..."
    },
    ...
]
```

**Error handling:**
- `RatelimitException`: Too many requests (DuckDuckGo rate limits)
- `DDGSException`: General search errors
- Generic `Exception`: Catch-all for unexpected errors

**Why DuckDuckGo?**
- No API key required
- Free to use
- Privacy-focused (no tracking)
- Returns structured results

---

### Cell 19: Verify Knowledge Bases

```python
# Verify knowledge bases are set up
import boto3

ssm = boto3.client("ssm")
account_id = boto3.client("sts").get_caller_identity()["Account"]
region = boto3.Session().region_name

try:
    biomedical_kb = ssm.get_parameter(
        Name=f"/{account_id}-{region}/kb/biomedical/knowledge-base-id"
    )
    humanitarian_kb = ssm.get_parameter(
        Name=f"/{account_id}-{region}/kb/humanitarian/knowledge-base-id"
    )
    training_kb = ssm.get_parameter(
        Name=f"/{account_id}-{region}/kb/training/knowledge-base-id"
    )

    print("✅ All three knowledge bases are configured:")
    print(f"   - Biomedical Services KB ID: {biomedical_kb['Parameter']['Value']}")
    print(f"   - Humanitarian Services KB ID: {humanitarian_kb['Parameter']['Value']}")
    print(f"   - Training Services KB ID: {training_kb['Parameter']['Value']}")
except Exception as e:
    # Error handling for missing KBs...
```

**Purpose:** Validates that the CloudFormation stack successfully created all 3 knowledge bases.

**Expected Output:**
```
✅ All three knowledge bases are configured:
   - Biomedical Services KB ID: ABCD1234XY
   - Humanitarian Services KB ID: EFGH5678ZW
   - Training Services KB ID: IJKL9012MN
```

---

### Cell 20: Download Knowledge Base Files

```python
import os
import boto3

def download_files():
    account_id = boto3.client("sts").get_caller_identity()["Account"]
    region = boto3.Session().region_name
    bucket_name = f"{account_id}-{region}-kb-data-bucket"

    os.makedirs("knowledge_base_data", exist_ok=True)

    s3 = boto3.client("s3")
    objects = s3.list_objects_v2(Bucket=bucket_name)

    for obj in objects.get("Contents", []):
        file_name = obj["Key"]
        s3.download_file(bucket_name, file_name, f"knowledge_base_data/{file_name}")
        print(f"Downloaded: {file_name}")

    print("All files saved to: knowledge_base_data/")

download_files()
```

**What's Happening:**
1. Construct S3 bucket name: `{account_id}-{region}-kb-data-bucket`
2. Create local directory `knowledge_base_data/`
3. List all objects in the S3 bucket
4. Download each file to local directory

**Downloaded Files:**
```
knowledge_base_data/
├── biomedical/
│   └── blood-drive-appointments.txt
├── humanitarian/
│   └── relief-centers-grants.txt
└── training/
    └── first-aid-classes-registrations.txt
```

**Why Download?**
- Allows you to inspect the actual knowledge base content
- Useful for debugging if queries don't return expected results
- Shows what information the agent has access to

---

### Cell 22: Sync Knowledge Bases (Optional)

```python
import time
import boto3

ssm = boto3.client("ssm")
bedrock = boto3.client("bedrock-agent")
s3 = boto3.client("s3")

account_id = boto3.client("sts").get_caller_identity()["Account"]
region = boto3.Session().region_name
bucket_name = f"{account_id}-{region}-kb-data-bucket"

lobs = ["biomedical", "humanitarian", "training"]

for lob in lobs:
    kb_id = ssm.get_parameter(
        Name=f"/{account_id}-{region}/kb/{lob}/knowledge-base-id"
    )["Parameter"]["Value"]
    ds_id = ssm.get_parameter(
        Name=f"/{account_id}-{region}/kb/{lob}/data-source-id"
    )["Parameter"]["Value"]

    # Start ingestion job
    response = bedrock.start_ingestion_job(
        knowledgeBaseId=kb_id,
        dataSourceId=ds_id,
        description=f"Quick sync {lob}"
    )
    job_id = response["ingestionJob"]["ingestionJobId"]

    # Wait for completion
    while True:
        job = bedrock.get_ingestion_job(
            knowledgeBaseId=kb_id,
            dataSourceId=ds_id,
            ingestionJobId=job_id
        )["ingestionJob"]
        status = job["status"]
        if status in ["COMPLETE", "FAILED"]:
            break
        time.sleep(10)
```

**Ingestion Job Process:**

```
┌─────────────────────────────────────────────────────────────────┐
│                    KNOWLEDGE BASE INGESTION                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   1. SOURCE DOCUMENTS (S3)                                       │
│      └── biomedical/blood-drive-appointments.txt                 │
│                                                                  │
│   2. CHUNKING                                                    │
│      ├── Split into 200-token chunks                            │
│      └── 10% overlap between chunks                              │
│                                                                  │
│   3. EMBEDDING                                                   │
│      ├── Each chunk → Amazon Titan Text Embeddings v2           │
│      └── Output: 1024-dimensional vectors                        │
│                                                                  │
│   4. INDEXING                                                    │
│      ├── Store vectors in S3 Vector Index                        │
│      └── Enable semantic search                                  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**When to Run This Cell:**
- Initial ingestion jobs didn't complete
- You've updated files in S3
- You want to manually trigger a resync

---

### Cell 24: Create the Agent

```python
from strands.models import BedrockModel
from strands import Agent

SYSTEM_PROMPT = """You are a helpful and professional customer service chatbot
for the American Red Cross.
Your role is to:
- Provide accurate information using the knowledge bases and tools available to you
- Assist users with questions about Biomedical services (blood drives, appointments, locations)
- Help with Humanitarian services (relief centers, grant applications, aid programs)
- Support Training Services inquiries (first aid classes, schedules, registrations)
- Be friendly, patient, and understanding with all users
- Always offer additional help after answering questions
- If you can't help with something, direct users to the appropriate Red Cross contact or resource

You have access to the following tools:
1. search_biomedical_knowledge_base() - For blood drive appointments, locations, and sign-up information
2. search_humanitarian_knowledge_base() - For relief center locations, grant applications, and aid programs
3. search_training_services_knowledge_base() - For first aid training classes, schedules, locations, and account information
4. web_search() - To search the web for current information or additional resources

Always use the appropriate knowledge base tool to get accurate, up-to-date information.
Use web_search for general information or when knowledge bases don't contain the specific
information needed."""

# Initialize the Bedrock model (Anthropic Claude Haiku 4.5)
model = BedrockModel(
    model_id="global.anthropic.claude-haiku-4-5-20251001-v1:0",
    temperature=0.3,
    region_name=region,
)

# Create the American Red Cross chatbot with all knowledge base tools
agent = Agent(
    model=model,
    tools=[
        search_biomedical_knowledge_base,   # Tool 1
        search_humanitarian_knowledge_base,  # Tool 2
        search_training_services_knowledge_base,  # Tool 3
        web_search,  # Tool 4
    ],
    system_prompt=SYSTEM_PROMPT,
)

print("✅ American Red Cross Customer Service Chatbot created successfully!")
```

**Detailed Breakdown:**

#### System Prompt
The system prompt is **critical** - it defines the agent's:
- **Identity:** "customer service chatbot for the American Red Cross"
- **Responsibilities:** What it should help with
- **Behavior:** "friendly, patient, understanding"
- **Tool Usage:** When to use which tool
- **Fallback:** What to do if it can't help

#### BedrockModel Configuration
```python
model = BedrockModel(
    model_id="global.anthropic.claude-haiku-4-5-20251001-v1:0",
    temperature=0.3,
    region_name=region,
)
```

| Parameter | Value | Meaning |
|-----------|-------|---------|
| `model_id` | `global.anthropic.claude-haiku-4-5-20251001-v1:0` | Claude Haiku 4.5 (fast, cost-effective) |
| `temperature` | `0.3` | Lower = more deterministic responses |
| `region_name` | `us-west-2` (or configured region) | Which Bedrock endpoint |

**Why Claude Haiku 4.5?**
- **Fast:** Low latency for interactive use
- **Cost-effective:** Cheaper than Sonnet/Opus
- **Capable:** Good enough for customer service tasks
- **`global.` prefix:** Uses cross-region inference for availability

#### Agent Creation
```python
agent = Agent(
    model=model,
    tools=[...],
    system_prompt=SYSTEM_PROMPT,
)
```

**How the Agent Works:**

```
┌─────────────────────────────────────────────────────────────────┐
│                        AGENT LOOP                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. USER INPUT                                                   │
│     "What blood drives are available in Seattle?"               │
│                       │                                          │
│                       ▼                                          │
│  2. LLM REASONING (Claude Haiku 4.5)                            │
│     "This is about blood drives → use biomedical KB"            │
│                       │                                          │
│                       ▼                                          │
│  3. TOOL CALL                                                    │
│     search_biomedical_knowledge_base("blood drives Seattle")    │
│                       │                                          │
│                       ▼                                          │
│  4. TOOL RESULT                                                  │
│     [Retrieved information about Seattle blood drives]          │
│                       │                                          │
│                       ▼                                          │
│  5. LLM RESPONSE GENERATION                                      │
│     Formats retrieved information into helpful response          │
│                       │                                          │
│                       ▼                                          │
│  6. FINAL RESPONSE TO USER                                       │
│     "Here are the upcoming blood drives in Seattle..."          │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

### Cells 28-32: Test the Agent

```python
# Test query about blood drives
response = agent("What's the return policy for my thinkpad X1 Carbon?")

# Test query about technical issues
response = agent("My laptop won't turn on, what should I check?")

# Test query about training classes
response = agent("What first aid classes are available in April? I'm looking for classes in Seattle.")
```

**What Happens During Each Query:**

1. **Query Analysis:** Claude analyzes the question
2. **Tool Selection:** Agent decides which tool(s) to use
3. **Tool Execution:** Calls the appropriate knowledge base
4. **Response Synthesis:** Claude combines tool results into a coherent answer

---

## Supporting Files Deep Dive

### `lab_helpers/lab1_strands_agent.py`

This file contains a **reusable version** of the tools defined in the notebook, plus additional tools from a previous version of the workshop.

**Key Components:**

```python
MODEL_ID = "global.anthropic.claude-haiku-4-5-20251001-v1:0"

SYSTEM_PROMPT = """You are a helpful and professional customer support assistant..."""
```

**Additional Tools (from previous version):**

| Tool | Purpose |
|------|---------|
| `get_return_policy(product_category)` | Mock return policy lookup |
| `get_product_info(product_type)` | Mock product information |
| `get_technical_support(issue_description)` | KB search for technical docs |
| `web_search(keywords)` | DuckDuckGo search |

---

### `lab_helpers/utils.py`

This is the **utility library** used across all labs. It provides:

#### SSM Parameter Functions
```python
def get_ssm_parameter(name: str, with_decryption: bool = True) -> str:
    """Retrieve a parameter from AWS SSM Parameter Store."""
    ssm = boto3.client("ssm")
    response = ssm.get_parameter(Name=name, WithDecryption=with_decryption)
    return response["Parameter"]["Value"]

def put_ssm_parameter(name: str, value: str, ...) -> None:
    """Store a parameter in AWS SSM Parameter Store."""
```

#### AWS Identity Functions
```python
def get_aws_region() -> str:
    """Get the current AWS region."""

def get_aws_account_id() -> str:
    """Get the current AWS account ID."""
```

#### Cognito Functions (Used in Later Labs)
```python
def get_cognito_client_secret() -> str:
    """Retrieve Cognito client secret."""

def get_or_create_cognito_pool(refresh_token=False):
    """Create or retrieve Cognito user pool configuration."""
```

#### IAM Role Functions (Used in Lab 4)
```python
def create_agentcore_runtime_execution_role():
    """Create IAM role for AgentCore Runtime."""
```

#### Cleanup Functions (Used in Lab 7)
```python
def agentcore_memory_cleanup(memory_id: str = None):
    """Delete AgentCore memory resources."""

def runtime_resource_cleanup(runtime_arn: str = None):
    """Delete AgentCore runtime resources."""
```

---

## Knowledge Base Data Files

### `biomedical/blood-drive-appointments.txt`

**Content Structure:**

```
EXISTING APPOINTMENTS DATABASE
├── Appointment records (5 examples)
│   ├── Appointment ID: BD-2024-XXXXXX
│   ├── Donor Name, Email, Phone
│   ├── Date, Time, Location
│   ├── Appointment Type (Whole Blood, Power Red, Platelets)
│   └── Status, Confirmation Code

FUTURE BLOOD DRIVE LOCATIONS
├── Upcoming drives (5 examples)
│   ├── Date, Location, Address
│   ├── Available Slots
│   └── Appointment Types Available

ELIGIBILITY REQUIREMENTS
├── Age, Weight, Health requirements
└── Donation frequency rules

HOW TO SIGN UP
├── Online, Phone, Walk-in options
└── Cancellation/Rescheduling policies
```

**Sample Data:**
```
Appointment ID: BD-2024-001234
Donor Name: Sarah Johnson
Appointment Date: March 15, 2024
Location: Red Cross Center - Downtown Seattle
Appointment Type: Whole Blood Donation
Status: Confirmed
```

---

### `humanitarian/relief-centers-grants.txt`

**Content Structure:**

```
RELIEF CENTER LOCATIONS
├── 4 physical centers + 1 mobile unit
│   ├── Address, Phone, Hours
│   ├── Services offered
│   └── Accessibility info

GRANT APPLICATION DATABASE
├── 5 sample applications
│   ├── Application ID: GR-2024-XXXXXX
│   ├── Applicant info
│   ├── Grant Type, Amount
│   └── Status (Approved, Under Review, Pending)

HOW TO APPLY FOR GRANTS
├── Eligibility requirements
├── Required documents
├── Application methods (Online, In-Person, Phone)
└── Review process timeline

AVAILABLE GRANT TYPES
├── Emergency Housing ($3,000 max)
├── Disaster Relief ($5,000 max)
├── Food Assistance ($500 max)
├── Medical Emergency ($2,000 max)
├── Utility Assistance ($1,000 max)
└── Emergency Transportation ($750 max)
```

---

### `training/first-aid-classes-registrations.txt`

**Content Structure:**

```
UPCOMING CLASSES
├── 6 scheduled classes
│   ├── Class ID: FA-2024-XXX
│   ├── Course Name, Date, Time
│   ├── Location, Instructor
│   ├── Available Seats, Cost
│   └── Prerequisites, Materials

REGISTERED STUDENTS
├── 5 sample student accounts
│   ├── Student ID: ST-2024-XXXXXX
│   ├── Registered Classes
│   ├── Certifications Held
│   └── Payment Status

HOW TO REGISTER
├── Online, Phone, In-Person options

COURSE DESCRIPTIONS
├── Adult and Pediatric First Aid/CPR/AED
├── Basic Life Support (BLS)
├── Blended Learning options
├── Wilderness First Aid
└── Pediatric-specific courses
```

---

## How Everything Connects

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         DATA FLOW IN LAB 1                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                        PREREQUISITE SETUP                             │   │
│  │  (prereq.sh → CloudFormation)                                        │   │
│  └────────────────────────────────┬─────────────────────────────────────┘   │
│                                   │                                          │
│                                   ▼                                          │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  SSM PARAMETER STORE                                                  │   │
│  │  /{account}-{region}/kb/biomedical/knowledge-base-id = "ABCD1234"    │   │
│  │  /{account}-{region}/kb/humanitarian/knowledge-base-id = "EFGH5678"  │   │
│  │  /{account}-{region}/kb/training/knowledge-base-id = "IJKL9012"      │   │
│  └────────────────────────────────┬─────────────────────────────────────┘   │
│                                   │                                          │
│                                   ▼                                          │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  LAB 1 NOTEBOOK                                                       │   │
│  │  1. Import libraries                                                  │   │
│  │  2. Define tools (read KB IDs from SSM)                              │   │
│  │  3. Create Agent with tools                                          │   │
│  │  4. Test with queries                                                │   │
│  └────────────────────────────────┬─────────────────────────────────────┘   │
│                                   │                                          │
│                                   ▼                                          │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  RUNTIME FLOW                                                         │   │
│  │                                                                       │   │
│  │  User Query ──▶ Agent ──▶ Tool Decision ──▶ KB Search ──▶ Response   │   │
│  │                   │                              │                    │   │
│  │                   ▼                              ▼                    │   │
│  │            Claude Haiku 4.5              Bedrock KBs                  │   │
│  │            (via Bedrock)                 (Vector Search)              │   │
│  │                                                                       │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Current Limitations (Fixed in Later Labs)

| Limitation | Fixed In |
|------------|----------|
| Single user, single session memory | Lab 2 (AgentCore Memory) |
| No cross-session context | Lab 2 (AgentCore Memory) |
| Tools not shareable across agents | Lab 3 (AgentCore Gateway) |
| No user authentication | Lab 3 (AgentCore Identity) |
| Running locally only | Lab 4 (AgentCore Runtime) |
| Limited observability | Lab 4 (CloudWatch/X-Ray) |
| No production monitoring | Lab 5 (AgentCore Evaluations) |
| No user interface | Lab 6 (Streamlit Frontend) |

---

## Key Concepts Summary

### Strands Agents Framework
- **Code-first:** Define agents in Python
- **`@tool` decorator:** Register functions as agent tools
- **Automatic schema:** Extracts from docstrings and type hints
- **Model agnostic:** Works with any LLM provider

### Amazon Bedrock Knowledge Bases
- **Vector storage:** Documents converted to embeddings
- **Semantic search:** Find relevant content by meaning
- **Managed service:** No infrastructure to maintain

### Tool Pattern
```python
@tool
def my_tool(param: str) -> str:
    """Description for the LLM.

    Args:
        param: What this parameter is for

    Returns:
        What the tool returns
    """
    # Implementation
    return result
```

### Agent Loop
1. Receive user input
2. LLM decides which tool(s) to use
3. Execute tool(s)
4. LLM synthesizes response
5. Return to user

---

## Next Steps

Continue to **[Lab 2: AgentCore Memory](./03-lab-02-agentcore-memory-guide.md)** to add persistent conversation memory and user preferences.
