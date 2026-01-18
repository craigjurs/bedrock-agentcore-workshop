# Lab 2: Adding AgentCore Memory for Personalization

## A Detailed Pedagogical Guide

---

## Overview: The Problem We're Solving

In Lab 1, you built a working chatbot, but it had a critical limitation: **it forgets everything after each session**. This is the "Goldfish Agent" problem.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      THE GOLDFISH AGENT PROBLEM                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   Session 1                          Session 2                               │
│   ┌────────────────────┐            ┌────────────────────┐                  │
│   │ User: "I prefer    │            │ User: "What laptop │                  │
│   │ ThinkPads and need │            │ should I get?"     │                  │
│   │ Linux support"     │            │                    │                  │
│   │                    │            │ Agent: "I don't    │                  │
│   │ Agent: "Great, I'll│    ❌      │ know your prefs.   │                  │
│   │ remember that!"    │ ───────▶   │ What do you need?" │                  │
│   └────────────────────┘   FORGOT   └────────────────────┘                  │
│                            EVERYTHING!                                       │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Lab 2 Solution: Amazon Bedrock AgentCore Memory**

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      THE MEMORY-ENHANCED AGENT                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   Session 1                          Session 2                               │
│   ┌────────────────────┐            ┌────────────────────┐                  │
│   │ User: "I prefer    │            │ User: "What laptop │                  │
│   │ ThinkPads and need │            │ should I get?"     │                  │
│   │ Linux support"     │            │                    │                  │
│   │                    │            │ Agent: "Based on   │                  │
│   │ Agent: "Great, I'll│    ✅      │ your ThinkPad pref │                  │
│   │ remember that!"    │ ───────▶   │ and Linux needs...│                  │
│   └────────────────────┘  REMEMBERS └────────────────────┘                  │
│            │               ACROSS                                            │
│            ▼              SESSIONS!                                          │
│   ┌────────────────────────────────────────┐                                │
│   │      AGENTCORE MEMORY                   │                                │
│   │  ┌─────────────────┐ ┌───────────────┐ │                                │
│   │  │ Short-Term      │ │ Long-Term     │ │                                │
│   │  │ Memory (STM)    │ │ Memory (LTM)  │ │                                │
│   │  │                 │ │               │ │                                │
│   │  │ Current session │ │ • Preferences │ │                                │
│   │  │ context         │ │ • Facts       │ │                                │
│   │  └─────────────────┘ │ • Patterns    │ │                                │
│   │                      └───────────────┘ │                                │
│   └────────────────────────────────────────┘                                │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Architecture for Lab 2

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         LAB 2 ARCHITECTURE                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│     User Query                                                               │
│         │                                                                    │
│         ▼                                                                    │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                    STRANDS AGENT WITH MEMORY                          │   │
│  │                                                                       │   │
│  │   ┌─────────────────────────────────────────────────────────────┐    │   │
│  │   │  AgentCoreMemorySessionManager                               │    │   │
│  │   │  ┌─────────────────────────────────────────────────────────┐│    │   │
│  │   │  │  1. BEFORE Query: Retrieve relevant memories            ││    │   │
│  │   │  │  2. INJECT context into user message                    ││    │   │
│  │   │  │  3. AFTER Response: Save interaction to memory          ││    │   │
│  │   │  └─────────────────────────────────────────────────────────┘│    │   │
│  │   └─────────────────────────────────────────────────────────────┘    │   │
│  │                           │                                           │   │
│  │   ┌─────────────┐        │         ┌──────────────────────────┐      │   │
│  │   │  Claude     │        │         │         TOOLS            │      │   │
│  │   │  Haiku 4.5  │◀───────┴────────▶│  (Same as Lab 1)         │      │   │
│  │   │  (Bedrock)  │                  │                          │      │   │
│  │   └─────────────┘                  └──────────────────────────┘      │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│         │                                                                    │
│         ▼                                                                    │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                    AGENTCORE MEMORY SERVICE                           │   │
│  │                                                                       │   │
│  │   ┌─────────────────────────────────────────────────────────────┐    │   │
│  │   │  SHORT-TERM MEMORY (STM)                                     │    │   │
│  │   │  • Immediate storage of conversations                        │    │   │
│  │   │  • Session-based context                                     │    │   │
│  │   │  • Fast read/write                                           │    │   │
│  │   └──────────────────────────┬──────────────────────────────────┘    │   │
│  │                              │ Async Processing                       │   │
│  │                              ▼                                        │   │
│  │   ┌─────────────────────────────────────────────────────────────┐    │   │
│  │   │  LONG-TERM MEMORY (LTM) STRATEGIES                           │    │   │
│  │   │                                                               │    │   │
│  │   │  ┌─────────────────────┐  ┌─────────────────────┐           │    │   │
│  │   │  │  USER_PREFERENCE    │  │    SEMANTIC         │           │    │   │
│  │   │  │  Strategy           │  │    Strategy         │           │    │   │
│  │   │  │                     │  │                     │           │    │   │
│  │   │  │  • Likes/dislikes   │  │  • Facts & data     │           │    │   │
│  │   │  │  • Brand prefs      │  │  • Past issues      │           │    │   │
│  │   │  │  • Budget ranges    │  │  • Order history    │           │    │   │
│  │   │  │  • Tech preferences │  │  • Semantic search  │           │    │   │
│  │   │  └─────────────────────┘  └─────────────────────┘           │    │   │
│  │   │                                                               │    │   │
│  │   │  Namespace: support/customer/{actorId}/preferences           │    │   │
│  │   │  Namespace: support/customer/{actorId}/semantic              │    │   │
│  │   └─────────────────────────────────────────────────────────────┘    │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Key Concepts: AgentCore Memory

### Memory Types

| Memory Type | Purpose | Timing | Use Case |
|-------------|---------|--------|----------|
| **Short-Term Memory (STM)** | Immediate conversation context | Synchronous | Current session continuity |
| **Long-Term Memory (LTM)** | Persistent patterns & facts | Asynchronous | Cross-session personalization |

### Memory Strategies

| Strategy | What It Extracts | Example |
|----------|------------------|---------|
| **USER_PREFERENCE** | Likes, dislikes, behaviors | "User prefers ThinkPad laptops" |
| **SEMANTIC** | Facts, data, entities | "User has order #MB-78432 under warranty" |

### Namespaces

Namespaces organize memories by user and context type:

```
support/customer/{actorId}/preferences  → User's preferences
support/customer/{actorId}/semantic     → Factual information
```

**Why `{actorId}`?**
- Enables **multi-tenant** memory
- Each user's data is isolated
- Easy to retrieve all memories for a specific user

---

## Cell-by-Cell Walkthrough

### Cell 2: Import Libraries

```python
import logging
from boto3.session import Session

from bedrock_agentcore_starter_toolkit.operations.memory.manager import MemoryManager
from bedrock_agentcore.memory import MemoryClient
from bedrock_agentcore.memory.constants import StrategyType

from lab_helpers.utils import put_ssm_parameter

boto_session = Session()
REGION = boto_session.region_name

logger = logging.getLogger(__name__)
```

**Library Breakdown:**

| Import | Purpose |
|--------|---------|
| `MemoryManager` | High-level helper for creating/managing memory resources |
| `MemoryClient` | Low-level client for memory operations (create_event, retrieve_memories) |
| `StrategyType` | Enum for memory strategies (USER_PREFERENCE, SEMANTIC) |
| `put_ssm_parameter` | Store memory ID in Parameter Store for later retrieval |

---

### Cell 4: Create AgentCore Memory Resources

```python
memory_name = "CustomerSupportMemory"

memory_manager = MemoryManager(region_name=REGION)
memory = memory_manager.get_or_create_memory(
    name=memory_name,
    strategies=[
        {
            StrategyType.USER_PREFERENCE.value: {
                "name": "CustomerPreferences",
                "description": "Captures customer preferences and behavior",
                "namespaces": ["support/customer/{actorId}/preferences"],
            }
        },
        {
            StrategyType.SEMANTIC.value: {
                "name": "CustomerSupportSemantic",
                "description": "Stores facts from conversations",
                "namespaces": ["support/customer/{actorId}/semantic"],
            }
        },
    ]
)
memory_id = memory["id"]
put_ssm_parameter("/app/customersupport/agentcore/memory_id", memory_id)
```

**Detailed Breakdown:**

#### MemoryManager.get_or_create_memory()

This is a **convenience method** that:
1. Checks if memory with this name already exists
2. If yes, returns the existing memory
3. If no, creates a new memory resource

#### Strategy Configuration

Each strategy is a dictionary with:

```python
{
    StrategyType.USER_PREFERENCE.value: {  # "user_preference"
        "name": "CustomerPreferences",       # Human-readable name
        "description": "Captures...",        # What it does
        "namespaces": ["support/customer/{actorId}/preferences"],
    }
}
```

**The `{actorId}` Placeholder:**
- Replaced at runtime with the actual user ID
- Example: `support/customer/user_001/preferences`
- Enables per-user memory isolation

#### What Happens Behind the Scenes

```
┌─────────────────────────────────────────────────────────────────┐
│                MEMORY RESOURCE CREATION                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   1. API Call to AgentCore                                       │
│      └── create_memory(name, strategies, ...)                    │
│                                                                  │
│   2. AWS Provisions Infrastructure (2-3 minutes)                 │
│      ├── Vector database for semantic search                     │
│      ├── Processing pipeline for LTM extraction                  │
│      ├── Storage for STM events                                  │
│      └── Embedding model connection                              │
│                                                                  │
│   3. Memory Resource Ready                                       │
│      └── Returns memory_id: "CustomerSupportMemory-XXXXXX"       │
│                                                                  │
│   4. Store ID in SSM                                             │
│      └── /app/customersupport/agentcore/memory_id                │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

### Cell 7: Seed Previous Customer Interactions

```python
from lab_helpers.lab2_memory import ACTOR_ID

# Seed with previous customer interactions
previous_interactions = [
    ("I'm having issues with my MacBook Pro overheating during video editing.", "USER"),
    (
        "I can help with that thermal issue. For video editing workloads, let's check your Activity Monitor and adjust performance settings. Your MacBook Pro order #MB-78432 is still under warranty.",
        "ASSISTANT",
    ),
    # ... more interactions
]

# Save previous interactions
if memory_id:
    try:
        memory_client = MemoryClient(region_name=REGION)
        memory_client.create_event(
            memory_id=memory_id,
            actor_id=ACTOR_ID,
            session_id="previous_session",
            messages=previous_interactions,
        )
        print("✅ Seeded customer history successfully")
    except Exception as e:
        print(f"⚠️ Error seeding history: {e}")
```

**Understanding `create_event()`**

This is the **core method** for storing interactions in memory.

```python
memory_client.create_event(
    memory_id=memory_id,           # Which memory resource
    actor_id=ACTOR_ID,             # User identifier (e.g., "user_001")
    session_id="previous_session", # Session grouping
    messages=previous_interactions, # List of (message, role) tuples
)
```

**Message Format:**
```python
[
    ("User's message", "USER"),
    ("Agent's response", "ASSISTANT"),
]
```

**What Happens After create_event():**

```
┌─────────────────────────────────────────────────────────────────┐
│                    EVENT PROCESSING FLOW                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   1. IMMEDIATE (Synchronous)                                     │
│      └── Messages stored in Short-Term Memory (STM)              │
│                                                                  │
│   2. BACKGROUND (Asynchronous - 20-30 seconds)                   │
│      ├── STM processed by LTM strategies                         │
│      │                                                           │
│      ├── USER_PREFERENCE Strategy:                               │
│      │   └── Extracts: "User prefers ThinkPad laptops"          │
│      │   └── Extracts: "User needs Linux compatibility"         │
│      │   └── Extracts: "User budget under $1200"                │
│      │                                                           │
│      └── SEMANTIC Strategy:                                      │
│          └── Creates embeddings for factual content              │
│          └── Stores: "MacBook Pro order #MB-78432"              │
│          └── Enables similarity search                           │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Seeded Interactions Content:**

| Interaction | What LTM Extracts |
|-------------|-------------------|
| MacBook overheating issue | Preference: "Uses MacBook Pro for video editing" |
| Gaming headphones question | Preference: "Low latency gaming headphones for FPS" |
| Laptop requirements | Preference: "Linux compatibility", "ThinkPad", "$1200 budget" |

---

### Cell 9: Wait for LTM Processing and Verify

```python
import time

# Wait for Long-Term Memory processing to complete
print("🔍 Checking for processed Long-Term Memories...")
retries = 0
max_retries = 6  # 1 minute wait

while retries < max_retries:
    memories = memory_client.retrieve_memories(
        memory_id=memory_id,
        namespace=f"support/customer/{ACTOR_ID}/preferences",
        query="can you summarize the support issue",
    )

    if memories:
        print(f"✅ Found {len(memories)} preference memories after {retries * 10} seconds!")
        break

    retries += 1
    if retries < max_retries:
        print(f"⏳ Still processing... waiting 10 more seconds (attempt {retries}/{max_retries})")
        time.sleep(10)
```

**Understanding `retrieve_memories()`**

```python
memories = memory_client.retrieve_memories(
    memory_id=memory_id,                                    # Which memory resource
    namespace=f"support/customer/{ACTOR_ID}/preferences",   # Which namespace
    query="can you summarize the support issue",            # Semantic search query
)
```

**How Retrieval Works:**

1. **Query Embedding:** Your query is converted to a vector
2. **Similarity Search:** Finds memories with similar embeddings
3. **Ranking:** Returns top-k most relevant memories
4. **Result:** List of memory objects with content

**Example Retrieved Memory:**
```python
{
    "content": {
        "text": '{"context":"The user explicitly mentioned they want good Linux compatibility for their laptop.","preference":"Good Linux compatibility for laptop","categories":["technology","computers","operating systems"]}'
    }
}
```

**Note:** USER_PREFERENCE strategy extracts structured JSON with:
- `context`: Why this preference was identified
- `preference`: The actual preference
- `categories`: Classification tags

---

### Cell 11: Explore Semantic Memory

```python
semantic_memories = memory_client.retrieve_memories(
    memory_id=memory_id,
    namespace=f"support/customer/{ACTOR_ID}/semantic",
    query="information on the technical support issue",
)
```

**Difference Between Strategies:**

| USER_PREFERENCE | SEMANTIC |
|-----------------|----------|
| Extracts behavioral patterns | Stores factual information |
| JSON structure with categories | Plain text facts |
| "User prefers X" format | "User has/needs/did X" format |
| Best for personalization | Best for context retrieval |

**Example Semantic Memories:**
```
1. The user needs a laptop under $1200 for programming.
2. The user plays competitive FPS games and requires low latency headphones.
3. The user likes ThinkPad models.
```

---

### Cell 13: Create Memory-Enhanced Agent

```python
import uuid
from strands import Agent
from strands.models import BedrockModel
from bedrock_agentcore.memory.integrations.strands.config import (
    AgentCoreMemoryConfig,
    RetrievalConfig
)
from bedrock_agentcore.memory.integrations.strands.session_manager import (
    AgentCoreMemorySessionManager
)

from lab_helpers.lab1_strands_agent import (
    SYSTEM_PROMPT,
    get_return_policy,
    web_search,
    get_product_info,
    get_technical_support,
    MODEL_ID,
)

session_id = uuid.uuid4()

memory_config = AgentCoreMemoryConfig(
    memory_id=memory_id,
    session_id=str(session_id),
    actor_id=ACTOR_ID,
    retrieval_config={
        "support/customer/{actorId}/semantic": RetrievalConfig(top_k=3, relevance_score=0.2),
        "support/customer/{actorId}/preferences": RetrievalConfig(top_k=3, relevance_score=0.2)
    }
)

# Initialize the Bedrock model
model = BedrockModel(model_id=MODEL_ID, region_name=REGION)

# Create the customer support agent with memory
agent = Agent(
    model=model,
    session_manager=AgentCoreMemorySessionManager(memory_config, REGION),
    tools=[
        get_product_info,
        get_return_policy,
        web_search,
        get_technical_support,
    ],
    system_prompt=SYSTEM_PROMPT,
)
```

**Detailed Breakdown:**

#### AgentCoreMemoryConfig

```python
memory_config = AgentCoreMemoryConfig(
    memory_id=memory_id,           # Memory resource to use
    session_id=str(session_id),    # Current session identifier
    actor_id=ACTOR_ID,             # User identifier
    retrieval_config={             # How to retrieve from each namespace
        "support/customer/{actorId}/semantic": RetrievalConfig(
            top_k=3,               # Return top 3 matches
            relevance_score=0.2    # Minimum similarity threshold
        ),
        "support/customer/{actorId}/preferences": RetrievalConfig(
            top_k=3,
            relevance_score=0.2
        )
    }
)
```

**RetrievalConfig Parameters:**

| Parameter | Purpose | Typical Value |
|-----------|---------|---------------|
| `top_k` | Max memories to retrieve | 3-5 |
| `relevance_score` | Minimum similarity (0-1) | 0.2-0.5 |

#### AgentCoreMemorySessionManager

This is the **key integration** between Strands Agents and AgentCore Memory.

```python
session_manager=AgentCoreMemorySessionManager(memory_config, REGION)
```

**What the Session Manager Does:**

```
┌─────────────────────────────────────────────────────────────────┐
│            AgentCoreMemorySessionManager LIFECYCLE               │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   BEFORE AGENT PROCESSES QUERY                                   │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │  1. Receive user query: "Which headphones do you        │   │
│   │     recommend?"                                          │   │
│   │                                                          │   │
│   │  2. Retrieve relevant memories from both namespaces      │   │
│   │     • Preferences: "Low latency gaming headphones"      │   │
│   │     • Semantic: "User plays competitive FPS games"      │   │
│   │                                                          │   │
│   │  3. Inject context into query:                          │   │
│   │     "User Context:                                       │   │
│   │      [PREFERENCE] Low latency gaming headphones for FPS │   │
│   │      [SEMANTIC] User plays competitive FPS games        │   │
│   │                                                          │   │
│   │      Which headphones do you recommend?"                │   │
│   └─────────────────────────────────────────────────────────┘   │
│                              │                                   │
│                              ▼                                   │
│   AGENT PROCESSES (with injected context)                        │
│                              │                                   │
│                              ▼                                   │
│   AFTER AGENT RESPONDS                                           │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │  4. Save interaction to memory:                          │   │
│   │     memory_client.create_event(                          │   │
│   │         messages=[                                        │   │
│   │             (user_query, "USER"),                        │   │
│   │             (agent_response, "ASSISTANT")                │   │
│   │         ]                                                 │   │
│   │     )                                                     │   │
│   │                                                          │   │
│   │  5. LTM processing extracts new patterns (async)        │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

### Cells 15-16: Test Personalized Agent

#### Test 1: Headphone Recommendation

```python
print("🎧 Testing headphone recommendation with customer memory...\n\n")
response1 = agent("Which headphones would you recommend?")
```

**What Happens:**

1. **Memory Retrieval:** Agent retrieves customer preferences
   - Found: "Low latency gaming headphones for competitive FPS games"

2. **Context Injection:** Query becomes:
   ```
   User Context:
   [PREFERENCE] Low latency gaming headphones for competitive FPS games

   Which headphones would you recommend?
   ```

3. **Personalized Response:** Agent recommends wired, low-latency gaming headphones

#### Test 2: Laptop Preference Recall

```python
print("\n💻 Testing laptop preference recall...\n\n")
response2 = agent("What is my preferred laptop brand and requirements?")
```

**What Happens:**

1. **Memory Retrieval:** Agent retrieves:
   - "Good Linux compatibility for laptop"
   - "Uses MacBook Pro for video editing"
   - Budget: $1200
   - Preferred brand: ThinkPad

2. **Response:** Agent accurately recalls all preferences without being told

---

## Supporting File: `lab_helpers/lab2_memory.py`

This file provides a **reusable memory integration** with Strands hooks.

### Constants

```python
ACTOR_ID = "user_001"
SESSION_ID = str(uuid.uuid4())

memory_client = MemoryClient(region_name=REGION)
memory_name = "RedCrossChatbotMemory"
```

### `create_or_get_memory_resource()`

```python
def create_or_get_memory_resource():
    try:
        # Try to get existing memory from SSM
        memory_id = get_ssm_parameter("/app/redcross/agentcore/memory_id")
        memory_client.gmcp_client.get_memory(memoryId=memory_id)
        return memory_id
    except Exception:
        # Create new memory if not found
        strategies = [
            {
                StrategyType.USER_PREFERENCE.value: {
                    "name": "UserPreferences",
                    "description": "Captures user preferences and behavior",
                    "namespaces": ["redcross/user/{actorId}/preferences"],
                }
            },
            {
                StrategyType.SEMANTIC.value: {
                    "name": "RedCrossChatbotSemantic",
                    "description": "Stores facts from conversations",
                    "namespaces": ["redcross/user/{actorId}/semantic"],
                }
            },
        ]

        response = memory_client.create_memory_and_wait(
            name=memory_name,
            description="American Red Cross chatbot memory",
            strategies=strategies,
            event_expiry_days=90,  # Memories expire after 90 days
        )
        memory_id = response["id"]
        put_ssm_parameter("/app/redcross/agentcore/memory_id", memory_id)
        return memory_id
```

**Key Parameter: `event_expiry_days=90`**
- Memories automatically expire after 90 days
- Prevents stale data accumulation
- Configurable based on use case

### `RedCrossChatbotMemoryHooks` Class

This class implements Strands **hooks** for memory integration.

```python
class RedCrossChatbotMemoryHooks(HookProvider):
    """Memory hooks for American Red Cross chatbot"""

    def __init__(self, memory_id, client, actor_id, session_id):
        self.memory_id = memory_id
        self.client = client
        self.actor_id = actor_id
        self.session_id = session_id
        # Get namespaces from memory strategies
        self.namespaces = {
            i["type"]: i["namespaces"][0]
            for i in self.client.get_memory_strategies(self.memory_id)
        }
```

#### Hook 1: `retrieve_user_context()`

**Triggered:** Before each user message is processed

```python
def retrieve_user_context(self, event: MessageAddedEvent):
    """Retrieve user context before processing query"""
    messages = event.agent.messages

    # Only process user messages (not tool results)
    if messages[-1]["role"] == "user" and "toolResult" not in messages[-1]["content"][0]:
        user_query = messages[-1]["content"][0]["text"]

        all_context = []
        for context_type, namespace in self.namespaces.items():
            # Retrieve memories from each namespace
            memories = self.client.retrieve_memories(
                memory_id=self.memory_id,
                namespace=namespace.format(actorId=self.actor_id),
                query=user_query,
                top_k=3,
            )
            # Format memories into context strings
            for memory in memories:
                text = memory.get("content", {}).get("text", "").strip()
                if text:
                    all_context.append(f"[{context_type.upper()}] {text}")

        # Inject context into the query
        if all_context:
            context_text = "\n".join(all_context)
            original_text = messages[-1]["content"][0]["text"]
            messages[-1]["content"][0]["text"] = (
                f"User Context:\n{context_text}\n\n{original_text}"
            )
```

**How Context Injection Works:**

```
BEFORE INJECTION:
┌─────────────────────────────────────┐
│ "Which headphones do you recommend?"│
└─────────────────────────────────────┘

AFTER INJECTION:
┌─────────────────────────────────────────────────────────────┐
│ "User Context:                                               │
│  [USER_PREFERENCE] Low latency gaming headphones for FPS    │
│  [SEMANTIC] User plays competitive FPS games                │
│                                                              │
│  Which headphones do you recommend?"                        │
└─────────────────────────────────────────────────────────────┘
```

#### Hook 2: `save_chatbot_interaction()`

**Triggered:** After agent produces a response

```python
def save_chatbot_interaction(self, event: AfterInvocationEvent):
    """Save chatbot interaction after agent response"""
    messages = event.agent.messages

    if len(messages) >= 2 and messages[-1]["role"] == "assistant":
        # Find the last user query and agent response
        user_query = None
        agent_response = None

        for msg in reversed(messages):
            if msg["role"] == "assistant" and not agent_response:
                agent_response = msg["content"][0]["text"]
            elif msg["role"] == "user" and not user_query:
                if "toolResult" not in msg["content"][0]:
                    user_query = msg["content"][0]["text"]
                    break

        if user_query and agent_response:
            # Save to memory
            self.client.create_event(
                memory_id=self.memory_id,
                actor_id=self.actor_id,
                session_id=self.session_id,
                messages=[
                    (user_query, "USER"),
                    (agent_response, "ASSISTANT"),
                ],
            )
```

#### Hook Registration

```python
def register_hooks(self, registry: HookRegistry) -> None:
    """Register Red Cross chatbot memory hooks"""
    registry.add_callback(MessageAddedEvent, self.retrieve_user_context)
    registry.add_callback(AfterInvocationEvent, self.save_chatbot_interaction)
```

**Strands Hook Events:**

| Event | When Triggered |
|-------|----------------|
| `MessageAddedEvent` | After a message is added to conversation |
| `AfterInvocationEvent` | After agent finishes processing |

---

## Memory Data Flow Summary

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         COMPLETE MEMORY FLOW                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   SESSION 1: User asks about laptops                                         │
│   ┌────────────────────────────────────────────────────────────────────┐    │
│   │  1. User: "I need a laptop under $1200 with Linux support"         │    │
│   │  2. Agent responds with recommendations                            │    │
│   │  3. Hook saves interaction → STM                                   │    │
│   │  4. LTM processes STM (async):                                     │    │
│   │     • USER_PREFERENCE: "Budget $1200", "Linux compatibility"       │    │
│   │     • SEMANTIC: "Looking for programming laptop"                   │    │
│   └────────────────────────────────────────────────────────────────────┘    │
│                                    │                                         │
│                                    ▼                                         │
│   SESSION 2: User asks about laptops (next week)                            │
│   ┌────────────────────────────────────────────────────────────────────┐    │
│   │  1. User: "What laptop should I get?"                              │    │
│   │  2. Hook retrieves from LTM:                                       │    │
│   │     • [PREFERENCE] Budget under $1200                              │    │
│   │     • [PREFERENCE] Linux compatibility required                    │    │
│   │     • [SEMANTIC] Needs for programming                             │    │
│   │  3. Context injected into query                                    │    │
│   │  4. Agent: "Based on your $1200 budget and Linux needs..."        │    │
│   └────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## API Reference

### MemoryClient Methods

| Method | Purpose | Parameters |
|--------|---------|------------|
| `create_memory_and_wait()` | Create memory resource | name, description, strategies, event_expiry_days |
| `create_event()` | Store interaction | memory_id, actor_id, session_id, messages |
| `retrieve_memories()` | Search memories | memory_id, namespace, query, top_k |
| `get_memory_strategies()` | List strategies | memory_id |
| `delete_memory()` | Delete memory resource | memory_id |

### Memory Response Structure

```python
# create_event response
{
    "id": "event-id",
    "status": "CREATED"
}

# retrieve_memories response
[
    {
        "content": {
            "text": "Memory content here"
        },
        "score": 0.85  # Relevance score
    }
]
```

---

## What You Accomplished in Lab 2

| Capability | Before Lab 2 | After Lab 2 |
|------------|--------------|-------------|
| Session Memory | Within session only | Persistent across sessions |
| User Preferences | None | Automatically extracted |
| Factual Recall | None | Semantic search |
| Personalization | Generic responses | Context-aware responses |
| Multi-User | Single user | Per-user isolation via actorId |

---

## Current Limitations (Fixed in Later Labs)

| Limitation | Fixed In |
|------------|----------|
| Tools defined per-agent | Lab 3 (AgentCore Gateway) |
| No authentication | Lab 3 (AgentCore Identity) |
| Running locally only | Lab 4 (AgentCore Runtime) |
| No observability | Lab 4 (CloudWatch/X-Ray) |
| No quality metrics | Lab 5 (AgentCore Evaluations) |
| No UI | Lab 6 (Streamlit Frontend) |

---

## Next Steps

Continue to **[Lab 3: AgentCore Gateway & Identity](./04-lab-03-agentcore-gateway-guide.md)** to share tools across agents and add authentication.
