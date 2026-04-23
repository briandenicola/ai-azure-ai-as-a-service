# Developer Workflow: Day 1 to Day 30

A practical guide showing how developers interact with the managed Azure AI platform from first day through production.

---

## Day 1: Get Your Credentials

### What You'll Do

1. **Request access** in ServiceNow
   - Form: "AI Platform Access Request"
   - Fields: Your name, team, use case, expected token usage
     > **What to put for "expected token usage":** Estimate based on your use case. A short chat app with ~10 users making 20 requests/day ≈ Bronze tier (500 TPM). A production app with multiple users running document summaries ≈ Silver (5,000 TPM). Not sure? Start with Bronze — you can increase it later via ServiceNow without re-onboarding.
   - Approval: Usually within 24 hours

2. **Receive credentials** via email:
   ```
   Subject: AI Platform Access Granted ✅
   
   Hi [Developer],
   
   Your AI Platform access is ready!
   
   Credentials:
   - Project ID: my-hub-project
   - Gateway URL: https://your-company-ai.azure-api.net
   - Subscription Key: [hidden-key-shown-in-portal]
   
   Next: Read the Developer Quick Start guide
   ```

3. **Verify your identity**
   ```bash
   # This works immediately (your corporate login)
   az login
   
   # Verify APIM gateway is accessible
   curl -I https://your-company-ai.azure-api.net
   ```

---

## Day 2-3: Run Your First Chat

### Setup (30 minutes)

```bash
# 1. Create a Python environment
python -m venv venv
source venv/Scripts/activate  # Windows: venv\Scripts\activate

# 2. Install SDK
pip install azure-ai-projects azure-identity

# 3. Create your first script
cat > hello-ai.py << 'EOF'
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

# Configuration from your email
PROJECT_ID = "my-hub-project"
GATEWAY_URL = "https://your-company-ai.azure-api.net"

# Authenticate with your corporate identity
credential = DefaultAzureCredential()

# Point to the APIM gateway (not direct Azure OpenAI!)
client = AIProjectClient(
    credential=credential,
    project_id=PROJECT_ID,
    endpoint=GATEWAY_URL
)

# Send a message
chat_client = client.inference.get_chat_completions_client()
response = chat_client.complete(
    model="gpt-4o",
    messages=[{"role": "user", "content": "Hello, world!"}]
)

print(f"Response: {response.choices[0].message.content}")
print(f"Tokens used: {response.usage.total_tokens}")
EOF

# 4. Run it
python hello-ai.py
```

### What Happens Behind the Scenes

```
Your Script
    ↓
DefaultAzureCredential (uses your corporate login)
    ↓
APIM Gateway
    ├─ ✅ Validates your credential
    ├─ ✅ Logs request to Application Insights
    ├─ ✅ Checks token quota (your tier's Tokens Per Minute cap — returns 429 with a Retry-After header if exceeded)
    ├─ ✅ Routes to Azure OpenAI
    └─ ✅ Caches response for future use
    ↓
Azure OpenAI Backend
    ↓
Response + Token Count → Your Script
```

### Verify in Portal

```bash
# Check your token usage
az monitor app-insights query --app your-app-insights --analytics "
  customEvents
  | where name == 'ai_request'
  | where customDimensions['user'] == 'your-email'
  | limit 5
"
```

---

## Day 4-7: Build Your First Agent

### Create Agent with Tools

```python
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

PROJECT_ID = "my-hub-project"
GATEWAY_URL = "https://your-company-ai.azure-api.net"

client = AIProjectClient(
    credential=DefaultAzureCredential(),
    project_id=PROJECT_ID,
    endpoint=GATEWAY_URL
)

# 1. Define tools (functions the agent can call)
tools = [{
    "type": "function",
    "function": {
        "name": "get_employee_info",
        "description": "Look up employee information from HR system",
        "parameters": {
            "type": "object",
            "properties": {
                "employee_id": {"type": "string", "description": "Employee ID"}
            },
            "required": ["employee_id"]
        }
    }
}]

# 2. Create agent
agent = client.agents.create_agent(
    name="hr-assistant",
    model="gpt-4o",
    instructions="You are an HR assistant. Help employees find information.",
    tools=tools
)

print(f"Agent created: {agent.id}")

# 3. Save for later use
with open("agent_id.txt", "w") as f:
    f.write(agent.id)
```

### Run the Agent

```python
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

PROJECT_ID = "my-hub-project"
GATEWAY_URL = "https://your-company-ai.azure-api.net"

client = AIProjectClient(
    credential=DefaultAzureCredential(),
    project_id=PROJECT_ID,
    endpoint=GATEWAY_URL
)

# Load agent ID from file
with open("agent_id.txt") as f:
    agent_id = f.read().strip()

# Create conversation thread
thread = client.agents.create_thread()

# Send message
message = client.agents.create_message(
    thread_id=thread.id,
    role="user",
    content="What's the salary for employee 12345?"
)

# Run agent
run = client.agents.create_run(
    thread_id=thread.id,
    assistant_id=agent_id
)

# Wait for tool calls
while run.status in ["queued", "in_progress", "requires_action"]:
    run = client.agents.get_run(thread_id=thread.id, run_id=run.id)
    
    if run.status == "requires_action":
        # Agent wants to call get_employee_info
        # Call your backend API here
        tool_outputs = []
        
        for tool_call in run.required_action.submit_tool_outputs.tool_calls:
            # You implement this
            result = call_your_hr_api(tool_call.function.arguments)
            tool_outputs.append({
                "tool_call_id": tool_call.id,
                "output": result
            })
        
        run = client.agents.submit_tool_outputs(
            thread_id=thread.id,
            run_id=run.id,
            tool_outputs=tool_outputs
        )

# Get response
messages = client.agents.list_messages(thread_id=thread.id)
print(messages.data[0].content[0].text)
```

---

## Day 8-14: Move to Production

### What Changes

1. **Authentication** - Still using corporate identity, but now in a service principal context
2. **Error handling** - Retry logic for transient failures
3. **Logging** - Log to your application's logger
4. **Monitoring** - Track token usage and latency

### Production Code Template

```python
import logging
import json
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential, ClientAssertionCredential
from tenacity import retry, stop_after_attempt, wait_exponential

logger = logging.getLogger(__name__)

class AIService:
    def __init__(self, project_id: str, gateway_url: str):
        self.project_id = project_id
        self.gateway_url = gateway_url
        self.client = self._create_client()
    
    def _create_client(self) -> AIProjectClient:
        """Create authenticated client."""
        credential = DefaultAzureCredential()
        return AIProjectClient(
            credential=credential,
            project_id=self.project_id,
            endpoint=self.gateway_url
        )
    
    @retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=1, min=2, max=10))
    def chat(self, message: str, model: str = "gpt-4o") -> str:
        """Send chat message with retry logic."""
        try:
            chat_client = self.client.inference.get_chat_completions_client()
            
            response = chat_client.complete(
                model=model,
                messages=[{"role": "user", "content": message}]
            )
            
            # Log for monitoring
            logger.info(f"Chat completed", extra={
                "tokens_used": response.usage.total_tokens,
                "model": model,
                "message_length": len(message)
            })
            
            return response.choices[0].message.content
            
        except Exception as e:
            logger.error(f"Chat failed: {str(e)}")
            raise

    def create_persistent_agent(self, name: str, instructions: str, tools: list = None):
        """Create an agent that persists across requests."""
        agent = self.client.agents.create_agent(
            name=name,
            model="gpt-4o",
            instructions=instructions,
            tools=tools or []
        )
        
        logger.info(f"Agent created: {agent.id}")
        return agent

# Usage
ai = AIService(
    project_id="my-hub-project",
    gateway_url="https://your-company-ai.azure-api.net"
)

# Simple chat
response = ai.chat("What's our privacy policy?")
print(response)

# Create agent for reuse
agent = ai.create_persistent_agent(
    name="policy-bot",
    instructions="Answer questions about company policies"
)
```

---

## Day 15-30: Optimization & Monitoring

### Monitor Your Token Usage

```python
# Check your montly consumption
az monitor app-insights query --app your-app-insights --analytics "
  customEvents
  | where name == 'ai_request'
  | where customDimensions['user'] == 'your-email'
  | summarize 
    TotalTokens = sum(todouble(customDimensions['completion_tokens']) 
                    + todouble(customDimensions['prompt_tokens'])),
    RequestCount = count()
    by tostring(customDimensions['model'])
  | render barchart
"
```

### Optimize Costs

**Strategy 1: Use Cheaper Models**

```python
# For simple classification → Llama 3.1 (cheaper)
response = client.complete(
    model="meta-llama-3.1-70b",  # Lower cost
    messages=[...]
)

# For complex reasoning → GPT-4o (more capable)
response = client.complete(
    model="gpt-4o",
    messages=[...]
)
```

**Strategy 2: Leverage Caching**

```python
# Cached responses don't consume tokens!
# These will be served from cache:
response1 = client.complete(
    model="gpt-4o",
    messages=[{"role": "user", "content": "Explain quantum computing"}]
)

time.sleep(2)

# Exact same prompt → cached response
response2 = client.complete(
    model="gpt-4o",
    messages=[{"role": "user", "content": "Explain quantum computing"}]
)
```

**Strategy 3: Batch Processing**

```python
# Instead of 1000 individual requests:
prompts = ["What is...", "Explain...", ...] * 1000

# Batch them for efficiency
responses = []
for batch in chunks(prompts, 10):
    # Process 10 at a time
    response = client.complete(
        model="gpt-4o",
        messages=[{"role": "user", "content": msg} for msg in batch]
    )
    responses.append(response)
```

### Common Issues & Solutions

**Issue: "Token quota exceeded" (HTTP 429)**
```
Your subscription key hit its tier's Tokens Per Minute (TPM) or Requests Per Minute (RPM) cap.
Check the Retry-After header in the response — wait that many seconds, then retry.
Longer fix: request a tier upgrade via ServiceNow, or reduce max_tokens in your requests.
```

**Issue: "Rate limited (429)"**
```
Same as above. APIM does NOT automatically retry on your behalf — the 429 is returned to your
client. You must implement exponential back-off with jitter in your code:
  1. Read the Retry-After header value (seconds to wait)
  2. Wait at least that long before retrying (add random jitter to avoid thundering herd)
  3. If 429s persist after back-off, request a quota increase via ServiceNow
  4. Consider using a smaller/cheaper model (e.g. gpt-4o-mini instead of gpt-4o) to stay within Bronze
```

**Issue: "Tool call failed"**
```python
# Debug tool issues
if run.status == "failed":
    last_error = run.last_error
    print(f"Error: {last_error.message}")
    
    # Common causes:
    # - Tool function signature doesn't match schema
    # - Tool endpoint is down
    # - Auth failed for backend API
```

---

## Day 31+: Going Multiregional

As you scale:

```python
# APIM automatically failover to another region on rate limit
# Your code stays the same:
client = AIProjectClient(
    credential=DefaultAzureCredential(),
    project_id="my-hub-project",
    endpoint="https://your-company-ai.azure-api.net"  # Single endpoint
)

# Behind the scenes:
# - Request hits eastus2
# - If rate limited, APIM tries southcentralus
# - Automatic, no code changes
```

---

## Resource Links

- **Getting Started:** [Developer Quick Start](../developer-quickstart.md)
- **Code Examples:** [Python](../examples/python/), [C#](../examples/csharp/)
- **Troubleshooting:** [#ai-platform Slack channel](slack://channel/)
- **Architecture:** [Architecture Decision Records](../adr/)
- **SDK Endpoint Reference:** [SDK Endpoint FAQ](reference/sdk-endpoint-questions.md) · [Endpoint Verification](reference/sdk-endpoint-verification.md)
- **Glossary:** See below

---

## Glossary

| Term | Meaning |
|------|---------|
| **APIM Gateway** | Azure API Management—your central AI endpoint |
| **Project ID** | Azure AI Foundry project identifier |
| **Thread** | A conversation session with an agent |
| **Tool** | A function an agent can call (like "get_employee_info") |
| **Token** | Unit of text (~4 characters). LLMs charge by tokens. |
| **Quota** | Your team's monthly token limit (e.g., 50M tokens) |
| **Managed Identity** | Your corporate identity (no API keys needed) |

---

**Support:** 📧 ai-platform-support@your-company.com  
**Last Updated:** Feb 2026
