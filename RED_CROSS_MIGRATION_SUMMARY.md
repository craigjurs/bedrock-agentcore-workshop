# American Red Cross Chatbot Migration Summary

This document summarizes the changes made to transform the customer support agent into an American Red Cross customer service chatbot.

## Overview

The chatbot now supports three lines of business (LOBs) with separate knowledge bases:
1. **Biomedical Services** - Blood drive appointments, locations, and sign-up information
2. **Humanitarian Services** - Relief center locations, grant applications, and aid programs  
3. **Training Services** - First aid training classes, schedules, locations, and registrations

## Files Modified

### 1. Agent Implementation
- **`lab_helpers/lab1_strands_agent.py`**
  - Updated system prompt for Red Cross use case
  - Replaced old tools (`get_return_policy`, `get_product_info`, `get_technical_support`) with three new knowledge base tools:
    - `search_biomedical_knowledge_base()` - Searches Biomedical Services KB
    - `search_humanitarian_knowledge_base()` - Searches Humanitarian Services KB
    - `search_training_services_knowledge_base()` - Searches Training Services KB
  - Kept `web_search()` tool for general web searches

- **`lab_helpers/lab4_runtime.py`**
  - Updated imports to use new knowledge base tools
  - Updated tool list in runtime entrypoint

### 2. Knowledge Base Data Files
Created three comprehensive knowledge base data files with synthetic data:

- **`knowledge_base_data/biomedical/blood-drive-appointments.txt`**
  - Existing blood drive appointments with donor information
  - Future blood drive locations and sign-up information
  - Eligibility requirements and donation process
  - Cancellation and rescheduling policies

- **`knowledge_base_data/humanitarian/relief-centers-grants.txt`**
  - Relief center locations across multiple cities
  - Grant application database with status information
  - How to apply for aid grants
  - Grant application status check procedures
  - Available grant types and amounts

- **`knowledge_base_data/training/first-aid-classes-registrations.txt`**
  - Upcoming first aid training classes with schedules
  - Registered student accounts and class information
  - How to register for training classes
  - Student account management
  - Class locations and course descriptions

### 3. Frontend Updates
- **`lab_helpers/lab5_frontend/main.py`**
  - Changed title from "Customer Support Agent" to "American Red Cross Customer Service Chatbot"
  - Updated thinking/processing messages to reference "American Red Cross Assistant"

- **`lab_helpers/lab5_frontend/chat.py`**
  - Updated assistant messages to reference "American Red Cross Assistant"

### 4. Documentation
- **`README.md`**
  - Updated project description for Red Cross use case
  - Updated lab descriptions to reflect three knowledge bases
  - Updated architecture evolution section

### 5. Setup Scripts
- **`scripts/setup_redcross_knowledge_bases.py`** (NEW)
  - Python script to set up all three knowledge bases
  - Uploads knowledge base files to S3
  - Creates vector buckets, indexes, knowledge bases, and data sources
  - Stores knowledge base IDs in Parameter Store for agent access

## How the Knowledge Bases Work

Each knowledge base tool:
1. Retrieves the appropriate knowledge base ID from AWS Systems Manager Parameter Store
2. Uses the Strands `retrieve` tool to search the knowledge base
3. Returns relevant information from the vector database

The knowledge base IDs are stored in Parameter Store at:
- `/{account_id}-{region}/kb/biomedical/knowledge-base-id`
- `/{account_id}-{region}/kb/humanitarian/knowledge-base-id`
- `/{account_id}-{region}/kb/training/knowledge-base-id`

## Setup Instructions

### Prerequisites
1. Deploy the CloudFormation infrastructure stack (creates S3 bucket, IAM roles, etc.)
2. Ensure you have AWS credentials configured with appropriate permissions

### Setting Up Knowledge Bases

After the infrastructure is deployed, run the setup script:

```bash
python scripts/setup_redcross_knowledge_bases.py
```

**From SageMaker Studio or a Notebook Instance:** Use the `--knowledge-base-data-dir` argument (or `KNOWLEDGE_BASE_DATA_DIR` env var) to point to the `knowledge_base_data` folder, and ensure the SageMaker execution role has `s3`, `bedrock-agent`, `s3vectors`, and `ssm` permissions. A ready-to-run notebook is in `notebooks/sagemaker_setup_redcross_vector_dbs.ipynb`.

This script will:
1. Upload knowledge base files to S3 (organized by LOB prefix)
2. Create three separate vector buckets and indexes
3. Create three knowledge bases in Bedrock
4. Create three data sources pointing to the S3 prefixes
5. Store knowledge base IDs in Parameter Store

### Manual Setup Alternative

If you prefer to set up knowledge bases manually:
1. Upload files to S3 bucket with prefixes: `biomedical/`, `humanitarian/`, `training/`
2. Create vector buckets and indexes for each LOB
3. Create knowledge bases in Bedrock Agent console
4. Create data sources pointing to respective S3 prefixes
5. Store knowledge base IDs in Parameter Store at the paths listed above

## Agent Behavior

The agent will:
- Automatically determine which knowledge base to search based on the user's question
- Search multiple knowledge bases if the question spans multiple LOBs
- Use web search for general information not in the knowledge bases
- Provide professional and helpful responses in the Red Cross context

## Example Queries

**Biomedical:**
- "I have a blood drive appointment on March 15th, what time is it?"
- "Where are the upcoming blood drives in Seattle?"
- "How do I sign up for a blood donation?"

**Humanitarian:**
- "Where is the nearest relief center?"
- "What's the status of my grant application GR-2024-001234?"
- "How do I apply for emergency housing assistance?"

**Training Services:**
- "What first aid classes are available in April?"
- "I'm registered for class FA-2024-001, what time does it start?"
- "How do I register for a CPR class?"

## Notes

- The knowledge base data is synthetic and for demonstration purposes only
- In production, these would be connected to real databases and systems
- The agent uses semantic search, so it can understand questions in natural language
- All three knowledge bases use the same embedding model (Amazon Titan Embed Text v2)

## Next Steps

1. Deploy infrastructure stack
2. Run knowledge base setup script
3. Test agent with queries across all three LOBs
4. Customize knowledge base content as needed
5. Add additional tools or integrations as required

