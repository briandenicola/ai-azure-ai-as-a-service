# CRITICAL: SDK Endpoint Routing Verification

**Status:** ✅ RESOLVED — Network-layer enforcement  
**Risk Level:** LOW (mitigated)  
**Mitigation:** Both Foundry accounts have `publicNetworkAccess: 'Disabled'` (see `infrastructure/bicep/foundry-hub-project.bicep`). Even if the SDK constructs internal Azure URLs, those requests are physically blocked at the network layer — the only egress path is via APIM private endpoint.

## The Problem

Your architecture assumes that setting `endpoint` on `AIProjectClient` routes ALL operations through APIM:

```python
client = AIProjectClient(
    credential=DefaultAzureCredential(),
    endpoint="https://my-apim.azure-api.net",  # Assumption: ALL calls use this
    project_id="my-project"
)
```

**But this is unverified.** If the SDK constructs URLs internally, some operations might bypass APIM.

---

## What We Know

### ✅ Confirmed Behavior

1. **Azure OpenAI SDK** honors custom `azure_endpoint` parameter:
   ```python
   from openai import AzureOpenAI
   client = AzureOpenAI(
       azure_endpoint="https://my-apim.azure-api.net"  # Works!
   )
   # All chat.completions.create() calls go through APIM
   ```

2. **Your APIM gateway** is configured to proxy Foundry endpoints

### ❌ Unknown / Risky

1. **AIProjectClient.agents.create_agent()** - Does it use the endpoint parameter?
2. **AIProjectClient.agents.create_thread()** - Does it construct its own URL?
3. **AIProjectClient.agents.create_run()** - Does it call discovery APIs directly?
4. **AIProjectClient.agents.list_messages()** - Does it use Azure ML URLs directly?

**Why this matters:** If any operation bypasses APIM:
- Token quotas are NOT enforced
- Semantic caching is NOT applied  
- Circuit breakers won't trigger
- Audit logs are incomplete
- Cost attribution fails

---

## How the SDK Might Bypass APIM

### Scenario 1: Discovery API
```python
# SDK might do this internally:
def _get_agent_endpoint(self):
    # Uses discovery to find the "real" endpoint
    discovery_url = f"https://{region}.api.azureml.ms/discovery/workspaces/{project_id}"
    response = requests.get(discovery_url)  # ❌ Bypasses APIM!
    return response.json()['agent_endpoint']
```

### Scenario 2: Hardcoded Service URLs
```python
# SDK might hardcode service-specific URLs:
class AgentsClient:
    def __init__(self, project_id, region):
        # Ignores AIProjectClient.endpoint!
        self.base_url = f"https://{region}.api.azureml.ms/agents"  # ❌ Bypass!
```

### Scenario 3: ARM Resource Queries
```python
# SDK might query Azure Resource Manager directly:
def _resolve_project(self, project_id):
    arm_url = f"https://management.azure.com/subscriptions/{sub}/..."
    # Queries ARM for project properties, gets real endpoint
    # ❌ Never touches APIM!
```

---

## Verification Methods

### Method 1: HTTP Traffic Capture (RECOMMENDED)

Use `mitmproxy` to see every HTTP request:

```bash
# 1. Install mitmproxy
pip install mitmproxy

# 2. Start proxy
mitmproxy --port 8080

# 3. Configure environment
export HTTPS_PROXY=http://localhost:8080
export HTTP_PROXY=http://localhost:8080

# 4. Run your code
python examples/python/6-foundry-agent-via-apim.py

# 5. Check mitmproxy output - you should see:
#    ✅ ALL requests to: your-company-ai.azure-api.net
#    ❌ ZERO requests to: *.api.azureml.ms
```

**If you see `api.azureml.ms` requests, you have a bypass!**

### Method 2: Mock Test (See test-sdk-endpoint-routing.py)

```python
# Patches HTTP libraries to capture URLs
with patch('requests.Session.request') as mock:
    client = AIProjectClient(endpoint=apim_url, ...)
    client.agents.create_agent(...)
    
    # Check all capture URLs
    for call in mock.call_args_list:
        url = call[0][1]  # Extract URL
        assert apim_url in url, f"BYPASS DETECTED: {url}"
```

### Method 3: SDK Source Code Review

Check the actual Azure SDK source:
```bash
git clone https://github.com/Azure/azure-sdk-for-python
cd azure-sdk-for-python/sdk/ai/azure-ai-projects

# Look for URL construction:
grep -r "api.azureml.ms" .
grep -r "def.*endpoint" .
grep -r "base_url" .
```

**Key files to check:**
- `azure/ai/projects/_client.py` - Main client
- `azure/ai/projects/agents/_client.py` - Agents operations
- `azure/ai/projects/inference/_client.py` - Inference operations

### Method 4: Azure Monitor Logs

Query logs to see if direct Foundry access occurs:

```kusto
// Check if requests bypass APIM
AzureDiagnostics
| where ResourceType == "WORKSPACES"  // Foundry = ML Workspaces
| where OperationName startswith "Microsoft.MachineLearningServices"
| where CallerIpAddress != "YOUR_APIM_IP"  // Not from APIM
| summarize DirectAccessCount = count() by CallerIpAddress, OperationName
```

If `DirectAccessCount > 0` and the IP isn't your APIM, you have bypass!

---

## Mitigation Strategies

### Option 1: Network-Level Enforcement (BEST)

Force ALL traffic through APIM at the network layer:

```bicep
// In foundry-hub-project.bicep
resource foundryProject 'Microsoft.MachineLearningServices/workspaces@2023-04-01' = {
  properties: {
    publicNetworkAccess: 'Disabled'  // ✅ Block internet access
  }
}

// Private endpoint ONLY accessible to APIM
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-04-01' = {
  properties: {
    subnet: apimSubnet  // Only APIM can reach this
  }
}
```

**Result:** Even if SDK tries to bypass, network layer blocks it.

### Option 2: Azure Firewall Rules

The Foundry AIServices accounts have `publicNetworkAccess: 'Disabled'` declared in
`infrastructure/bicep/apim-gateway.bicep`. This is enforced at provision time via
`azd provision` — no runtime command is needed. Verify the current state:

```bash
# Read-only: confirm public network access is disabled
az cognitiveservices account show \
  --name <foundry-account-name> \
  --resource-group <rg-name> \
  --query "properties.publicNetworkAccess" --output tsv
# Expected output: Disabled
```

### Option 3: Custom SDK Wrapper (If bypass detected)

```python
from azure.ai.projects import AIProjectClient
from azure.core.pipeline.policies import HTTPPolicy

class EnforceAPIMPolicy(HTTPPolicy):
    """Fails if any request doesn't go through APIM."""
    
    def send(self, request):
        if "azure-api.net" not in request.http_request.url:
            raise SecurityError(
                f"BLOCKED: Request to {request.http_request.url} bypasses APIM"
            )
        return self.next.send(request)

# Use it
client = AIProjectClient(
    endpoint=apim_url,
    policies=[EnforceAPIMPolicy()]
)
```

### Option 4: Monitor & Alert

Set up alerts for any direct Foundry access:

```bicep
resource apimBypassAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  properties: {
    criteria: {
      allOf: [
        {
          metricName: 'Requests'
          dimensions: [
            {
              name: 'CallerIpAddress'
              operator: 'NotEquals'
              values: [apimPublicIp]
            }
          ]
        }
      ]
    }
    actions: [
      {
        actionGroupId: securityTeamAlertGroup.id
      }
    ]
  }
}
```

---

## Testing Checklist

Before deploying to production:

- [ ] Run `test-sdk-endpoint-routing.py`
- [ ] Capture traffic with mitmproxy
- [ ] Review SDK source code on GitHub
- [ ] Test with `publicNetworkAccess: Disabled` on Foundry
- [ ] Verify Azure Monitor shows zero direct access
- [ ] Test ALL SDK operations:
  - [ ] `create_agent`
  - [ ] `create_thread`
  - [ ] `create_message`
  - [ ] `create_run`
  - [ ] `submit_tool_outputs`
  - [ ] `list_messages`
  - [ ] `inference.get_chat_completions_client()`
  - [ ] `inference.get_embeddings_client()`

---

## Microsoft Documentation Gap

As of March 2026, Microsoft docs do NOT provide:
- Explicit guarantee that `endpoint` parameter routes ALL operations
- Examples of custom endpoints (APIM) with AIProjectClient
- Architecture diagrams showing APIM integration with azure-ai-projects SDK

**Recommended action:** Open a Microsoft support ticket asking:
> "Does AIProjectClient honor the endpoint parameter for ALL operations 
> (agents, inference, telemetry), or does the SDK construct Azure-specific 
> URLs that would bypass a custom endpoint like APIM?"

---

## Recommended Architecture

**Until verified, use defense-in-depth:**

```
┌──────────────┐
│  Your App    │
└──────┬───────┘
       │ AIProjectClient(endpoint=APIM_URL)
       ▼
┌────────────────────────────────┐
│  APIM Gateway                  │
│  https://your-apim.azure-api.net
└──────┬─────────────────────────┘
       │ Private Link ONLY
       ▼
┌────────────────────────────────┐
│  Azure AI Foundry Project      │
│  publicNetworkAccess: Disabled │ ✅ Network-level enforcement
└────────────────────────────────┘
```

**Why:** Even if SDK tries to bypass endpoint parameter, network layer prevents it.

---

## Action Items

1. **Immediate:**
   - Run traffic capture test
   - Deploy `publicNetworkAccess: Disabled`
   
2. **Short-term:**
   - Review SDK source code
   - Open Microsoft support ticket
   - Add Azure Monitor alerts
   
3. **Long-term:**
   - Migrate to network-enforced APIM routing
   - Contribute SDK documentation to Microsoft
   - Share findings with community

---

## References

- Azure SDK for Python (azure-ai-projects): https://github.com/Azure/azure-sdk-for-python/tree/main/sdk/ai/azure-ai-projects
- Azure AI Foundry Documentation: https://learn.microsoft.com/azure/ai-foundry/
- APIM with Azure OpenAI: https://learn.microsoft.com/azure/api-management/azure-openai-api-from-specification
- Private Link for ML Workspaces: https://learn.microsoft.com/azure/machine-learning/how-to-configure-private-link
