# Foundry Agent + APIM Gateway - Reference Implementation

This reference implementation demonstrates **best practices** for building Azure AI Foundry agents that route all inference traffic through Azure API Management (APIM), ensuring governance, cost controls, and enterprise-grade security.

## 📂 Files in This Reference

```
examples/
├── python/
│   └── 6-foundry-agent-via-apim.py       # Python reference (complete)
└── csharp/
    └── 6-foundry-agent-via-apim.cs       # C# reference (complete)
```

## 🎯 What This Demonstrates

### ✅ Core Features
- **APIM Gateway Routing**: All model calls go through APIM (never direct)
- **Endpoint Validation**: Code rejects non-APIM endpoints at startup
- **Tool/Function Calling**: Agent can execute business logic
- **Multi-turn Conversations**: Context-aware responses across messages
- **Error Handling**: Graceful handling of tool failures
- **Lifecycle Management**: Create, run, and cleanup agents

### ✅ Enterprise Patterns
- **Configuration Management**: Environment variables (12-factor app)
- **Defense in Depth**: APIM routing + network isolation + RBAC
- **Observability**: All calls logged through APIM
- **Cost Controls**: Token quotas enforced by APIM policies
- **Security**: No API keys in code, uses Azure AD authentication

## 🏗️ Architecture

```
┌─────────────┐
│   Your App  │  (Python/C#/Java/Node.js)
└──────┬──────┘
       │ DefaultAzureCredential (Azure AD)
       ▼
┌─────────────────────────────────────────────────────────────┐
│              Azure API Management (APIM)                    │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  🚦 Policies Applied Here:                           │  │
│  │  • Token Quota (500–5,500 TPM by product tier)        │  │
│  │  • Semantic Caching (30% cost reduction)             │  │
│  │  • Circuit Breaker (multi-region failover)           │  │
│  │  • Content Safety Filters                            │  │
│  │  • Audit Logging (compliance)                        │  │
│  └───────────────────────────────────────────────────────┘  │
└────────┬──────────────────────────────────┬─────────────────┘
         │                                  │
         ▼                                  ▼
┌────────────────────┐          ┌──────────────────────┐
│  Azure AI Foundry  │          │   Azure OpenAI       │
│  (gpt-4o, etc.)    │          │   (fallback)         │
└────────────────────┘          └──────────────────────┘
         ▲
         │ publicNetworkAccess: Disabled
         │ (Only APIM can reach via private endpoint)
```

## 🚀 Quick Start

### Prerequisites

1. **Azure Resources** (see infrastructure setup below)
2. **Azure CLI** logged in: `az login`
3. **Python 3.9+** or **.NET 8.0+**
4. **Environment Variables** configured

### Step 1: Set Environment Variables

**Bash/Linux/macOS:**
```bash
export AI_GATEWAY_ENDPOINT="https://your-company-ai.azure-api.net"
export AI_PROJECT_ID="ai-hub-project"
export AI_DEPLOYMENT_NAME="gpt-4o"
```

**PowerShell:**
```powershell
$env:AI_GATEWAY_ENDPOINT = "https://your-company-ai.azure-api.net"
$env:AI_PROJECT_ID = "ai-hub-project"
$env:AI_DEPLOYMENT_NAME = "gpt-4o"
```

**Windows CMD:**
```cmd
set AI_GATEWAY_ENDPOINT=https://your-company-ai.azure-api.net
set AI_PROJECT_ID=ai-hub-project
set AI_DEPLOYMENT_NAME=gpt-4o
```

### Step 2: Install Dependencies

**Python:**
```bash
pip install azure-ai-projects azure-identity
```

**C#:**
```bash
dotnet add package Azure.AI.Projects
dotnet add package Azure.Identity
```

### Step 3: Run the Example

**Python:**
```bash
python examples/python/6-foundry-agent-via-apim.py
```

**C#:**
```bash
dotnet run examples/csharp/6-foundry-agent-via-apim.cs
```

## 📊 Expected Output

```
================================================================================
FOUNDRY AGENT + APIM GATEWAY - FULL REFERENCE IMPLEMENTATION
================================================================================
✅ Using APIM gateway: https://your-company-ai.azure-api.net
✅ Connected to project: ai-hub-project
   via APIM gateway: https://your-company-ai.azure-api.net

✅ Agent created: asst_abc123
   Name: customer-service-agent
   Model: gpt-4o
   Tools: 3

================================================================================
SCENARIO 1: Order Status Inquiry
================================================================================
✅ Thread created: thread_xyz789

👤 User: Hi! Can you check the status of order ORD-12345?
🤖 Running agent...
🔧 Agent requesting 1 tool call(s):
   - get_customer_order_status({'order_id': 'ORD-12345'})
     ✅ Result: {"status": "shipped", "tracking": "1Z999AA10123456784", ...}
✅ Run completed: run_def456

================================================================================
CONVERSATION HISTORY
================================================================================

👤 USER:
   Hi! Can you check the status of order ORD-12345?

🤖 ASSISTANT:
   Your order ORD-12345 has been shipped! The tracking number is 
   1Z999AA10123456784 and it's estimated to arrive on March 7, 2026.
================================================================================

✅ All scenarios completed successfully!

Note: All inference calls went through APIM gateway at:
      https://your-company-ai.azure-api.net

This means:
  ✅ Token quotas were enforced
  ✅ Semantic caching was applied
  ✅ Circuit breaker protected against failures
  ✅ All requests were logged for audit
```

## 🔧 Infrastructure Setup

All infrastructure is managed via `azd provision`. Run once from the repo root:

```powershell
azd auth login
azd env new <env-name>
azd provision --no-prompt
```

This provisions APIM, both Foundry accounts (East US + West US), private endpoints, VNet, RBAC, and the Event Grid automation pipeline. See the [setup playbook](../docs/playbooks/setup-apim-gateway.md) for detailed steps.

After provisioning, retrieve your APIM gateway URL:

```bash
az apim show --name <apim-name> --resource-group <rg> --query gatewayUrl -o tsv
```

## 🔐 Security Configuration

Security is enforced at three layers, all configured by `azd provision` via Bicep — **no manual steps are required**:

### 1. Public Access Disabled on Foundry (Network Layer)

Both Foundry accounts have `publicNetworkAccess: 'Disabled'` in `infrastructure/bicep/foundry-hub-project.bicep`. All SDK traffic must transit the APIM private endpoint — there is no path to bypass APIM regardless of SDK behavior.

### 2. APIM Managed Identity → Foundry RBAC (Identity Layer)

The APIM system-assigned MSI is granted `Cognitive Services User` on both Foundry accounts in `infrastructure/bicep/foundry-apim-rbac.bicep`. No API keys are used or distributed.

### 3. Private Endpoints + DNS (Network Isolation)

APIM reaches Foundry exclusively via private endpoints declared in `infrastructure/bicep/networking.bicep`. Private DNS zones are linked to the VNet for name resolution.

To verify the configuration after provisioning:

```bash
# Check public access is disabled
az cognitiveservices account show \
  --name <foundry-account-name> --resource-group <rg> \
  --query properties.publicNetworkAccess
# Expected: "Disabled"
```

## ⚠️ CRITICAL: SDK Endpoint Verification

**IMPORTANT:** This architecture assumes `AIProjectClient` honors the `endpoint` parameter for ALL operations. 
However, **this is unverified**. If the SDK constructs Azure-specific URLs internally, some operations might 
bypass APIM.

**📖 Read this FIRST:** [sdk-endpoint-verification.md](../docs/reference/sdk-endpoint-verification.md)

**Before deploying to production:**
1. Run traffic capture test: `tests/test-sdk-endpoint-routing.py`
2. Use `mitmproxy` to verify ALL requests go through APIM
3. Enable network-level enforcement: `publicNetworkAccess: Disabled`

**Defense-in-Depth Strategy:**  
✅ SDK endpoint parameter (application layer)  
✅ + Private Link only (network layer)  
✅ + RBAC restrictions (identity layer)

## 🎓 Key Concepts

### Why APIM Instead of Direct Access?

| Feature | Direct Foundry | Via APIM Gateway |
|---------|---------------|------------------|
| Token Quotas | ❌ Must implement yourself | ✅ Built-in policy |
| Semantic Caching | ❌ No caching | ✅ 30-50% cost savings |
| Circuit Breaker | ❌ Manual failover | ✅ Automatic multi-region |
| Audit Logging | ⚠️ Basic Azure logs | ✅ Full request/response logs |
| Content Safety | ❌ Must add separately | ✅ Built-in filter |
| Developer Experience | 😐 Manage keys per team | 😊 Azure AD auth |

### Tool/Function Calling Flow

```
1. User: "Check order ORD-12345"
   ↓
2. Agent analyzes message → decides to call get_customer_order_status tool
   ↓
3. Agent sends request to APIM: POST /agents/{agent_id}/runs
   ↓
4. APIM applies policies (quota, cache, etc.) → forwards to Foundry
   ↓
5. Foundry returns: status = "requires_action" + tool_calls = [{...}]
   ↓
6. Your code executes: result = get_customer_order_status("ORD-12345")
   ↓
7. Submit tool outputs back to agent via APIM
   ↓
8. Agent formulates response: "Your order has been shipped..."
```

## 🧪 Testing

### Test 1: Verify APIM Routing Works

```python
# Should succeed
python examples/python/6-foundry-agent-via-apim.py
```

### Test 2: Verify Direct Access Fails

```python
# Temporarily change endpoint to direct Foundry URL
export AI_GATEWAY_ENDPOINT="https://my-foundry.api.azureml.ms"  # Direct (bad!)
python examples/python/6-foundry-agent-via-apim.py

# Expected: ValueError with message about requiring APIM gateway
```

### Test 3: Verify Token Quotas Work

```bash
# Run a load test to exceed your quota
for i in {1..1000}; do
  python examples/python/6-foundry-agent-via-apim.py &
done

# Expected: APIM returns 429 Too Many Requests after hitting quota
```

## 📈 Monitoring

### View Request Logs in APIM

```bash
az apim api diagnosis create \
  --api-id foundry-api \
  --resource-group rg-ai \
  --service-name your-company-ai \
  --enable-sampling true
```

### Query Logs in Application Insights (KQL)

```kql
// All agent requests
traces
| where cloud_RoleName == "your-company-ai"
| where message has "agent"
| project timestamp, message, customDimensions

// Token usage by agent
customMetrics
| where name == "TokensUsed"
| summarize TotalTokens = sum(value) by AgentId = tostring(customDimensions.agent_id)
```

### Grafana Dashboards

Import the pre-built dashboards:
- `observability/grafana/dashboards/token-usage-dashboard.json`
- `observability/grafana/dashboards/performance-dashboard.json`

## 🔧 Customization

### Add Your Own Tools

In Python:
```python
# 1. Add function implementation
def check_inventory(product_id: str) -> Dict[str, Any]:
    # Your logic here
    return {"in_stock": True, "quantity": 42}

# 2. Add tool definition
AGENT_TOOLS.append({
    "type": "function",
    "function": {
        "name": "check_inventory",
        "description": "Check if a product is in stock",
        "parameters": {
            "type": "object",
            "properties": {
                "product_id": {"type": "string", "description": "Product ID"}
            },
            "required": ["product_id"]
        }
    }
})

# 3. Register function
TOOL_FUNCTIONS["check_inventory"] = check_inventory
```

### Change Model

```bash
# Use a different deployment
export AI_DEPLOYMENT_NAME="gpt-4o-mini"  # Cost-effective
export AI_DEPLOYMENT_NAME="o1-preview"   # Advanced reasoning
```

### Store Config in Key Vault

```python
from azure.keyvault.secrets import SecretClient
from azure.identity import DefaultAzureCredential

kv = SecretClient(
    vault_url="https://your-keyvault.vault.azure.net",
    credential=DefaultAzureCredential()
)

APIM_ENDPOINT = kv.get_secret("AI-Gateway-Endpoint").value
PROJECT_ID = kv.get_secret("AI-Project-ID").value
```

## 🐛 Troubleshooting

### Error: "Invalid endpoint... Must use APIM gateway"

**Cause**: Your `AI_GATEWAY_ENDPOINT` is pointing to Foundry directly, not APIM.

**Fix**: Update to your APIM gateway URL:
```bash
export AI_GATEWAY_ENDPOINT="https://your-company-ai.azure-api.net"
```

### Error: "403 Forbidden" when creating agent

**Cause**: Your identity doesn't have access to the Foundry project.

**Fix**: Grant yourself "Azure AI Developer" role:
```bash
az role assignment create \
  --assignee YOUR_EMAIL@company.com \
  --role "Azure AI Developer" \
  --scope /subscriptions/.../resourceGroups/rg-ai/providers/Microsoft.MachineLearningServices/workspaces/ai-hub-project
```

### Error: "Network error" when APIM tries to reach Foundry

**Cause**: Public access disabled but no private endpoint configured.

**Fix**: Set up private endpoint (see Security Configuration above).

### Agent takes too long to respond

**Possible causes**:
1. **Cold start**: First request after deploy is slower (expected)
2. **Complex tools**: Agent is calling multiple tools sequentially
3. **APIM caching**: Enable semantic caching to speed up repeated queries

**Fix**: Add caching policy to APIM (see `policies/apim/semantic-caching.xml`)

## 📚 Related Documentation

- [APIM Gateway Setup Guide](../docs/playbooks/setup-apim-gateway.md)
- [Enforce APIM-Only Access](../docs/playbooks/enforce-apim-gateway-only.md)
- [Token Quota Policy](../policies/apim/token-quota-by-department.xml)
- [Developer Quickstart](../docs/developer-quickstart.md)
- [Azure AI Foundry Docs](https://learn.microsoft.com/azure/ai-foundry/)

## 🤝 Contributing

When adding new examples:
1. ✅ Always validate APIM endpoint (reject direct Foundry URLs)
2. ✅ Read config from environment (never hardcode)
3. ✅ Use `DefaultAzureCredential` (no API keys)
4. ✅ Include error handling for tool calls
5. ✅ Add comprehensive docstrings

## 📄 License

See [LICENSE](../../LICENSE) at root of repository.
