# Developer Quick Start: Using Azure AI as a Managed Service

Welcome! Your organization has deployed Azure AI as a **managed, governed platform**. This guide shows you how to build with it.

## Key Concept: Use APIM Instead of Direct Model Keys

Instead of managing Azure OpenAI keys directly, you work through **Azure API Management (APIM)**, which acts as your gateway. This gives you:

✅ Cost controls (your team's **token quota** — see below)  
✅ Automatic caching (faster responses)  
✅ Audit trails (all requests logged)  
✅ Simple auth (use your corporate identity)  

> **What is token quota?** A *token* is roughly ¾ of a word. A short chat message might be 50 tokens; a 2-page document summary might be 4,000 tokens. Your subscription key is assigned a **Tier** (Bronze / Silver / Gold) that caps how many tokens per minute (TPM) and requests per minute (RPM) your team can send through the gateway. If you exceed the cap, the gateway returns HTTP 429 — back-off and retry. Your IT manager can increase the cap via ServiceNow. See [quota-management.md](../docs/playbooks/quota-management.md) for full details.

---

## 1-Minute Setup

### Step 1: Get Your Credentials

Ask your IT manager for:
- APIM gateway URL (e.g., `https://your-company-ai.azure-api.net`)
- Your Azure AI **project ID** (found in Azure Portal)
- You already have Azure corporate identity → **That's your auth!**

### Step 2: Install SDK

```bash
pip install azure-ai-projects
```

### Step 3: Run Your First Chat

```python
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

client = AIProjectClient(
    credential=DefaultAzureCredential(),
    project_id="your-project-id",
    endpoint="https://your-company-ai.azure-api.net"  # <- Your APIM gateway
)

response = client.agents.create_agent(
    name="first-agent",
    model="gpt-4o",
    instructions="You are a helpful assistant."
)

print(f"Agent created: {response.id}")
```

**Boom.** You're done. No keys to manage, no direct Azure OpenAI endpoint, everything routed through governance.

---

## 2. Common Developer Patterns

### Pattern A: Simple Chat (No Agents)

```python
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

client = AIProjectClient(
    credential=DefaultAzureCredential(),
    project_id="my-project",
    endpoint="https://your-company-ai.azure-api.net"
)

# Get the chat client
chat_client = client.inference.get_chat_completions_client()

response = chat_client.complete(
    model="gpt-4o",
    messages=[
        {"role": "user", "content": "What's 2+2?"}
    ]
)

print(response.choices[0].message.content)
```

---

### Pattern B: Agents with Tools

```python
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential
import json

client = AIProjectClient(
    credential=DefaultAzureCredential(),
    project_id="my-project",
    endpoint="https://your-company-ai.azure-api.net"
)

# 1. Define a tool (function the agent can call)
functions = [
    {
        "type": "function",
        "function": {
            "name": "get_stock_price",
            "description": "Get the current stock price for a ticker",
            "parameters": {
                "type": "object",
                "properties": {
                    "ticker": {
                        "type": "string",
                        "description": "Stock ticker symbol (e.g., MSFT)"
                    }
                },
                "required": ["ticker"]
            }
        }
    }
]

# 2. Create agent with tools
agent = client.agents.create_agent(
    name="stock-analyst",
    model="gpt-4o",
    instructions="You are a helpful stock analyst. Use the get_stock_price tool to fetch prices.",
    tools=functions
)

# 3. Run the agent
thread = client.agents.create_thread()
message = client.agents.create_message(
    thread_id=thread.id,
    role="user",
    content="What's the current price of Microsoft stock?"
)

run = client.agents.create_run(
    thread_id=thread.id,
    assistant_id=agent.id
)

# 4. Handle tool calls
while run.status == "requires_action":
    tool_calls = run.required_action.submit_tool_outputs.tool_calls
    tool_outputs = []
    
    for tool_call in tool_calls:
        if tool_call.function.name == "get_stock_price":
            ticker = json.loads(tool_call.function.arguments)["ticker"]
            # Call your backend API to get price
            price = fetch_stock_price(ticker)  # Your function
            tool_outputs.append({
                "tool_call_id": tool_call.id,
                "output": str(price)
            })
    
    run = client.agents.submit_tool_outputs(
        thread_id=thread.id,
        run_id=run.id,
        tool_outputs=tool_outputs
    )

# 5. Get final response
messages = client.agents.list_messages(thread_id=thread.id)
print(messages.data[0].content[0].text)
```

---

### Pattern C: Using Foundry Models (Non-OpenAI)

```python
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

client = AIProjectClient(
    credential=DefaultAzureCredential(),
    project_id="my-project",
    endpoint="https://your-company-ai.azure-api.net"
)

# Use Meta's Llama or other Foundry models
response = client.inference.get_chat_completions_client().complete(
    model="meta-llama-3.1-405b",  # or any model in your Foundry catalog
    messages=[
        {"role": "user", "content": "Explain quantum computing"}
    ]
)

print(response.choices[0].message.content)
```

---

### Pattern D: Agent with Knowledge Base (RAG)

```python
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

client = AIProjectClient(
    credential=DefaultAzureCredential(),
    project_id="my-project",
    endpoint="https://your-company-ai.azure-api.net"
)

# 1. Create a knowledge index from your documents
# (Your IT team usually sets this up once per project)
knowledge = client.knowledge.get_or_create_knowledge(
    name="company-policies",
    resource_id="https://your-azure-ai-search.search.windows.net",
    index_name="policies"
)

# 2. Create agent that uses the knowledge base
agent = client.agents.create_agent(
    name="policy-bot",
    model="gpt-4o",
    instructions="Answer questions about company policies. Use the knowledge base to ground your answers.",
    tool_resources={"file_search": {"vector_store_ids": [knowledge.id]}}
)

# 3. Ask questions grounded in your company docs
thread = client.agents.create_thread()
message = client.agents.create_message(
    thread_id=thread.id,
    role="user",
    content="What's our privacy policy on customer data?"
)

run = client.agents.create_run(thread_id=thread.id, assistant_id=agent.id)

# Wait for completion
while run.status != "completed":
    run = client.agents.get_run(thread_id=thread.id, run_id=run.id)

messages = client.agents.list_messages(thread_id=thread.id)
print(messages.data[0].content[0].text)
```

---

## 3. What Happens Behind the Scenes

```
Your Code
    ↓
AIProjectClient (uses Managed Identity)
    ↓
APIM Gateway (https://your-company-ai.azure-api.net)
    ↓ [APIM Policies:]
    ├─ Rate limiting (your team's token quota)
    ├─ Request logging (audit trail)
    ├─ Semantic caching (save on tokens)
    ├─ Auth validation (Managed Identity check)
    ↓
Azure OpenAI / Foundry Model
    ↓ [Response logged to Application Insights]
    ↓
Your Code
```

**You don't need to think about this.** It just works. But knowing it exists helps you understand why certain things happen (e.g., "Why did my request get throttled?").

---

## 4. Monitoring Your Usage

Your IT manager set up dashboards showing:
- **Tokens consumed** by your team
- **Cost per request** 
- **Performance (latency)**
- **Errors & failures**

Check [Grafana dashboard](https://your-grafana.azure.com) or ask your IT manager for the URL.

---

## 5. Troubleshooting

### "401 Unauthorized"

You're not authenticated. Make sure:
```python
from azure.identity import DefaultAzureCredential
credential = DefaultAzureCredential()
```

If using in CI/CD, ensure the service principal has:
- `Cognitive Services User` role on the AI Foundry project
- Access to APIM

### "429 Too Many Requests"

Your team hit its token quota. There are two possible causes — the response headers tell you which:

| Header present | Cause | Action |
|---|---|---|
| `Retry-After` set by APIM | Your subscription key exceeded its tier's TPM or RPM cap | Back-off for the number of seconds in `Retry-After`, then retry. File a ServiceNow request to increase your tier. |
| No `Retry-After`, or it comes from Foundry | Platform-wide capacity saturated (rare — circuit-breaker should have failed over) | Contact your IT manager; this needs platform-level investigation. |

Always implement **exponential back-off with jitter** in your client — do not retry immediately in a tight loop, as this makes the 429 worse.

To request a higher quota: file a request in ServiceNow (ask your IT manager). See [quota-management.md](../docs/playbooks/quota-management.md) for the full process.

### "Model not found"

The model exists in Foundry but isn't exposed through your APIM endpoint yet. Contact your IT team.

### Slow responses?

Check [Application Insights](https://portal.azure.com) for latency. If APIM cache hit rate is low, your queries aren't repetitive enough to benefit from caching.

---

## 6. Advanced: Custom Backend Tools

If your agent needs to call **your company's internal APIs** (e.g., HR system, CRM):

```python
# 1. Define your backend API as a tool
tools = [
    {
        "type": "function",
        "function": {
            "name": "lookup_employee",
            "description": "Look up employee information",
            "parameters": {
                "type": "object",
                "properties": {
                    "employee_id": {"type": "string"}
                },
                "required": ["employee_id"]
            }
        }
    }
]

# 2. Your IT team registers this tool in APIM with proper auth
# 3. Agent calls it, APIM handles security & logging automatically

agent = client.agents.create_agent(
    name="hr-assistant",
    model="gpt-4o",
    instructions="Help employees find information about colleagues.",
    tools=tools
)
```

**Your backend API is also behind APIM**, so:
- ✅ Secrets are managed (no hardcoding)
- ✅ All calls are logged
- ✅ Rate limits apply
- ✅ Your API is protected

---

## 7. Getting Help

| Question | Who to Ask |
|----------|-----------|
| "How do I set up logging?" | Your IT manager / Platform team |
| "Can I increase my token quota?" | File a request in ServiceNow (your IT manager) |
| "I need a new model" | File a request in ServiceNow; your IT manager evaluates & deploys |
| "My agent is slow" | Check [Grafana dashboards](#4-monitoring-your-usage); log a ticket if needed |
| "How do I debug a tool call failure?" | Check Application Insights traces (your IT team can show you how) |

---

## 8. Best Practices

✅ **Use Managed Identity** - Never hardcode keys  
✅ **Design agents with fewer tool calls** - Reduces latency & cost  
✅ **Reuse threads** - Store `thread_id` for conversation continuity  
✅ **Monitor token usage** - Check dashboards to optimize prompts  
✅ **Cache knowledge indexes** - If using RAG, let APIM's semantic cache work  
✅ **Test locally first** - Use the same APIM endpoint locally and in prod  

---

**Next Steps:**
- 👉 Explore [code examples](../examples/)
- 👉 Read [Architecture Decisions](../adr/) if you're curious about why we built it this way
- 👉 Ask your IT manager for Grafana dashboard access
- 👉 SDK routing questions? See [SDK Endpoint FAQ](reference/sdk-endpoint-questions.md)
