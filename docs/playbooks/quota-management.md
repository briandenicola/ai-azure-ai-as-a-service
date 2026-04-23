# Playbook: Quota Management — Azure AI as a Service

**Audience:** Platform Engineers, IT Managers  
**Complexity:** Intermediate

> **All infrastructure is managed via `azd provision`.** Bicep is the single source of truth for all APIM policy values and Foundry deployment capacities. Do not patch resources in the Azure Portal or via mutating `az` commands — they will be overwritten on the next provision.

---

## Overview

Quota in this platform operates at **two independent layers** that must be kept in alignment. Understanding both is essential before adjusting any limit.

| Layer | Enforced by | Where configured | Scope |
|---|---|---|---|
| **1. Foundry deployment capacity** | Azure CognitiveServices | `infrastructure/bicep/foundry-hub-project.bicep` | Per deployment, per region, per Azure subscription |
| **2a. APIM product token limit** | APIM `azure-openai-token-limit` policy | `infrastructure/bicep/apim-gateway.bicep` (product policies) | Per APIM subscription key — actual token count |
| **2b. APIM department call limit** | APIM `rate-limit-by-key` policy | `policies/apim/token-quota-by-department.xml` | Per `X-Department-Id` header — counts HTTP requests, not tokens |

**The relationship:**

```
Caller
  │
  ▼
APIM (Layer 2 — enforces per-LOB TPM limits before requests leave the gateway)
  │  429 if LOB exceeds APIM limit
  ▼
Azure Foundry (Layer 1 — enforces subscription-wide deployment capacity)
  │  429 if all callers combined exceed the Foundry deployment's TPM cap
  ▼
Model
```

APIM limits should always be the effective constraint. If the sum of all APIM product limits can exceed the Foundry deployment capacity, 429s will pass through to callers from Foundry — bypassing APIM's rate-limit accounting entirely, and without the `Retry-After` header APIM would normally set.

---

## Current Configured Values

### Layer 1 — Foundry deployment capacity (`foundry-hub-project.bicep`)

| Account | Region | Model deployment | SKU | `capacity` | Effective TPM |
|---|---|---|---|---|---|
| Primary | East US | `gpt-4o-mini` (gpt-4o 2024-11-20) | Standard | 1 | **1,000 TPM** |
| Primary | East US | `phi-4` (Phi-4 v2) | GlobalStandard | 1 | **1,000 TPM** |
| Secondary | West US | `gpt-4o-mini` (gpt-4o 2024-11-20) | Standard | 30 | **30,000 TPM** |
| Secondary | West US | `phi-4` (Phi-4 v2) | GlobalStandard | 1 | **1,000 TPM** |

> **Why is primary `capacity=1`?** This is intentionally low to trigger the APIM circuit-breaker failover during load tests. Raise to `5` or higher for production (`5` = 5,000 TPM). See [`policies/apim/circuit-breaker-multi-region.xml`](../../policies/apim/circuit-breaker-multi-region.xml).

In Bicep, `capacity` = thousands of TPM. `capacity: 5` = 5,000 TPM.  
RPM is derived automatically (ratio varies by model — see [TPM→RPM ratios](#tpmrpm-ratios)).

### Layer 2 — APIM product limits (`apim-gateway.bicep`)

| Product | Models available | TPM limit | RPM limit |
|---|---|---|---|
| Bronze (`ai-bronze`) | gpt-4o-mini, Phi-4 | 500 | 60 |
| Silver (`ai-silver`) | + gpt-4o, Llama-3-70b, Agents API | 5,000 | 300 |
| Gold (`ai-gold`) | All models incl. o1 | 5,500 | 330 |

APIM enforces product-level token limits via the `azure-openai-token-limit` policy embedded in each product policy in `apim-gateway.bicep`, keyed on `context.Subscription.Id`. This counts actual prompt + completion tokens and returns a 429 when the per-minute budget is exhausted.

#### Department-level secondary limit (`token-quota-by-department.xml`) — call-count based

A supplementary policy in `policies/apim/token-quota-by-department.xml` applies a secondary limit keyed on the `X-Department-Id` request header. **Important:** this policy uses `rate-limit-by-key` which counts **HTTP requests (calls)**, not tokens. It is currently configured at 100,000 calls over a 30-day rolling window — a coarse safety net to prevent any single department from monopolising gateway capacity.

> **Known gap:** `rate-limit-by-key` is not token-aware — a single large 8K-token request and a single 10-token request count equally. For true per-department token enforcement, this policy should be upgraded to `azure-openai-token-limit` keyed on `X-Department-Id`. See the `azure-openai-token-limit` policy reference in the [Reference](#reference) section.

> **Deployment note:** `token-quota-by-department.xml` is **not currently wired into any Bicep resource** — it exists as a reference/design file. Editing it and running `azd provision` has **no effect** on the deployed APIM instance. To deploy it, it must be referenced from a Bicep `Microsoft.ApiManagement/service/apis/policies` resource. See [Adjusting APIM Product Limits](#adjusting-apim-product-limits-iac-only) for the integration pattern.

---

## TPM→RPM Ratios

Microsoft sets RPM proportionally to TPM. The ratios vary by model family:

| Model family | Units | RPM per unit | TPM per unit |
|---|---|---|---|
| Chat models (gpt-4o, gpt-4.1 family) | 1 | 6 RPM | 1,000 TPM |
| o1, o3, o4-mini | 1 | 1 RPM | 1,000 TPM |
| o1-mini, o3-mini, o3-pro | 1 | 1 RPM | 10,000 TPM |

Example: a `gpt-4o` deployment with `capacity: 5` (5,000 TPM) gets 30 RPM automatically.

> **Source:** [Azure OpenAI in Microsoft Foundry Models quotas and limits](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits) (updated April 2026)

---

## Quota Tier System (Microsoft Foundry — April 2026)

Microsoft now assigns subscriptions to quota **tiers (Free, 1–6)** rather than a single default:

- Your initial tier is based on **consumption trends** and your **Microsoft agreement type** (EA / MCA-E customers start higher).
- Tiers **auto-upgrade** as usage grows — no support ticket required.
- Tier 6 has the highest default limits; Tier 1 represents new subscriptions with minimal history.
- Manual increases are still possible at any tier via the [quota request form](https://aka.ms/oai/stuquotarequest).

Check your current tier:

```bash
# Requires: az login + Owner or Contributor on the subscription
az account get-access-token --resource https://management.azure.com --query accessToken -o tsv | \
  xargs -I{} curl -s -H "Authorization: Bearer {}" \
  "https://management.azure.com/subscriptions/<SUB_ID>/providers/Microsoft.CognitiveServices/quotaTiers?api-version=2025-10-01-preview"
```

To opt out of automatic tier upgrades (e.g., to keep billing predictable):

```bash
az account get-access-token --resource https://management.azure.com --query accessToken -o tsv | \
  xargs -I{} curl -X PATCH \
  -H "Authorization: Bearer {}" \
  -H "Content-Type: application/json" \
  -d '{"properties":{"tierUpgradePolicy":"NoAutoUpgrade"}}' \
  "https://management.azure.com/subscriptions/<SUB_ID>/providers/Microsoft.CognitiveServices/quotaTiers/default?api-version=2025-10-01-preview"
```

---

## Viewing Current Quota and Usage

### Foundry portal (read-only)

1. Open [Microsoft Foundry portal](https://ai.azure.com) → **Operate** → **Quota**.
2. Select **Token per minute** tab.
3. Click any deployment to see its current allocation, usage bar, and affiliated projects.

Required RBAC: **Cognitive Services Usages Reader** at the subscription level (minimum). Do not assign this role via `az role assignment create` as a permanent fix — define it in [`infrastructure/bicep/foundry-apim-rbac.bicep`](../../infrastructure/bicep/foundry-apim-rbac.bicep) and run `azd provision`.

### REST API — query usage per region

```python
# pip install azure-identity requests
import requests
from azure.identity import DefaultAzureCredential

subscription_id = "<SUB_ID>"
location        = "eastus"   # or "westus"

token = DefaultAzureCredential().get_token("https://management.azure.com/.default").token
r = requests.get(
    f"https://management.azure.com/subscriptions/{subscription_id}"
    f"/providers/Microsoft.CognitiveServices/locations/{location}/usages"
    "?api-version=2023-05-01",
    headers={"Authorization": f"Bearer {token}"}
)
r.raise_for_status()
for usage in r.json()["value"]:
    print(f"{usage['name']['localizedValue']:50s}  {usage['currentValue']:>8} / {usage['limit']}")
```

### REST API — check available capacity by model and region

```python
import requests, json
from azure.identity import DefaultAzureCredential

subscription_id = "<SUB_ID>"
model_name      = "gpt-4o"
model_version   = "2024-11-20"

token = DefaultAzureCredential().get_token("https://management.azure.com/.default").token
r = requests.get(
    f"https://management.azure.com/subscriptions/{subscription_id}"
    "/providers/Microsoft.CognitiveServices/modelCapacities",
    params={
        "api-version":    "2024-06-01-preview",
        "modelFormat":    "OpenAI",
        "modelName":      model_name,
        "modelVersion":   model_version,
    },
    headers={"Authorization": f"Bearer {token}"}
)
print(json.dumps(r.json(), indent=2))
```

### Log Analytics — APIM token consumption by subscription (KQL)

> **Prerequisite:** The `BackendResponseBody` column in `ApiManagementGatewayLogs` is only populated when APIM diagnostic settings have response body logging enabled. This is disabled by default (PCI DSS Req 3.3 — avoid logging sensitive data). If body logging is off, `TokensConsumed` will be `null` for every row.
>
> For reliable token tracking **without** enabling body logging, add the [`azure-openai-emit-token-metric`](https://learn.microsoft.com/en-us/azure/api-management/azure-openai-emit-token-metric-policy) policy to `apim-gateway.bicep` — it writes token counts directly to Application Insights custom metrics without capturing the response body.

```kql
// Token usage per APIM subscription in the last 24 hours
// Requires: APIM diagnostics with response body logging enabled,
//           OR azure-openai-emit-token-metric policy sending to App Insights.
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where IsRequestSuccess == true
| extend TokensConsumed = toint(BackendResponseBody.usage.total_tokens)
| summarize
    TotalTokens   = sum(TokensConsumed),
    RequestCount  = count(),
    AvgTokens     = avg(TokensConsumed)
  by SubscriptionId
| order by TotalTokens desc
```

```kql
// Rate-limit (429) events by subscription — identify who is being throttled
ApiManagementGatewayLogs
| where TimeGenerated > ago(1h)
| where ResponseCode == 429
| summarize ThrottledRequests = count() by SubscriptionId, bin(TimeGenerated, 5m)
| order by ThrottledRequests desc
```

See also: [`scripts/check-foundry-capacity.ps1`](../../scripts/check-foundry-capacity.ps1) for a PowerShell wrapper.

---

## Requesting a Foundry Quota Increase (Microsoft)

When the combined throughput needs of all APIM products exceed what the Foundry deployment can sustain, request a quota increase from Microsoft.

**RBAC required before requesting:**

| Action | Required role |
|---|---|
| View quota | Cognitive Services Usages Reader (subscription level) |
| Request increase | Owner or Contributor (subscription level) |
| Edit allocation in portal | Cognitive Services Contributor + Usages Reader |

**Process:**

1. Confirm the current limit is actually the bottleneck — check for Foundry 429s in Log Analytics, not just APIM throttles.
2. Submit the [quota increase request form](https://aka.ms/oai/stuquotarequest).
3. Requests are processed **in order received**; priority goes to subscriptions actively using their existing quota allocation.
4. EA / MCA-E subscribers may be auto-assigned higher tiers without a request.
5. Allow up to **5 business days** for a response. Shared quota pool is available for temporary testing while waiting.
6. After approval, update `capacity` in [`infrastructure/bicep/foundry-hub-project.bicep`](../../infrastructure/bicep/foundry-hub-project.bicep) to match the new limit and run `azd provision`.

> **Do not** submit a support ticket for short-term testing quota. Use the [Foundry shared quota pool](https://learn.microsoft.com/en-us/azure/foundry/how-to/quota#foundry-shared-quota) instead (temporary, usage-billed).

---

## Adjusting Foundry Deployment Capacity (IaC-only)

To raise or lower the TPM allocated to a Foundry deployment, edit `infrastructure/bicep/foundry-hub-project.bicep`:

```bicep
// Before — intentionally low for failover demo
resource gpt4oMini1 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: foundry1
  name: 'gpt-4o-mini'
  sku: {
    name: 'Standard'
    capacity: 1  // 1K TPM
  }
  ...
}

// After — raise for production load
resource gpt4oMini1 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: foundry1
  name: 'gpt-4o-mini'
  sku: {
    name: 'Standard'
    capacity: 30  // 30K TPM — Gold tier max, enough for all LOBs at peak
  }
  ...
}
```

Then apply:

```bash
azd provision
```

**Capacity increments:** Foundry `capacity` values are set in units of 1,000 TPM (`capacity: 1` = 1K TPM, `capacity: 30` = 30K TPM). The maximum you can set is capped by your subscription's quota in that region and model family. If `azd provision` fails with `QuotaExceeded`, submit the increase form first (see above).

**Sequential deployment constraint:** Multiple model deployments on the same Foundry account must be created sequentially — hence the `dependsOn` in the Bicep. Do not remove those dependencies.

---

## Adjusting APIM Product Limits (IaC-only)

APIM limits are enforced by two mechanisms — edit both together:

### 1. Per-product TPM/RPM in `apim-gateway.bicep`

Locate the APIM product policy definitions and update the `azure-openai-token-limit` attributes:

```xml
<!-- Bronze product policy — 500 TPM -->
<azure-openai-token-limit
    counter-key="@(context.Subscription.Id)"
    tokens-per-minute="500"
    estimate-prompt-tokens="true"
    remaining-tokens-header-name="X-Remaining-Tokens" />
```

To change Bronze to 1,000 TPM, set `tokens-per-minute="1000"`.

**Quota vs rate limit:** The policy supports both:
- `tokens-per-minute` — rolling per-minute rate limit (429 when exceeded)
- `token-quota` + `token-quota-period` — fixed-window budget, e.g. monthly (403 when exceeded)

Example with a monthly budget:

```xml
<azure-openai-token-limit
    counter-key="@(context.Subscription.Id)"
    tokens-per-minute="500"
    token-quota="500000"
    token-quota-period="Monthly"
    remaining-quota-tokens-header-name="X-Remaining-Monthly-Tokens"
    estimate-prompt-tokens="true" />
```

### 2. Per-department secondary limit in `token-quota-by-department.xml`

The `X-Department-Id` header enables a secondary layer of enforcement independent of the APIM subscription key. This policy uses `rate-limit-by-key` (HTTP request count), **not** `azure-openai-token-limit`. The current limit is 100,000 requests per 30-day window.

> **Deployment requirement:** This file is not currently wired into any Bicep resource. Editing the XML alone and running `azd provision` will **not** update the deployed APIM instance. To apply it, integrate it into `apim-gateway.bicep` first:

```bicep
// Add to infrastructure/bicep/apim-gateway.bicep
// This deploys token-quota-by-department.xml as the openai-inference API-level policy.
// Note: this replaces the existing openaiInferenceApiPolicy resource — merge the two
// policies rather than adding a second api/policy resource for the same parent.
resource deptQuotaApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-05-01-preview' = {
  parent: openaiInferenceApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../../policies/apim/token-quota-by-department.xml')
  }
}
```

To update the call limit without integrating into Bicep yet, apply directly via the APIM REST API, then run:

```bash
azd provision
```

once the Bicep integration is in place.

> **Multi-region note:** APIM tracks token counters **per gateway node** independently, not aggregated across the entire Premium multi-region instance. If you have APIM units in East US and West US, each unit maintains its own counter. A caller could consume up to 2× the configured `tokens-per-minute` by load-balancing across both units. Account for this in your limit values.

---

## ServiceNow Quota Increase Workflow

For LOBs that need a quota increase (higher APIM product tier or a new monthly budget), the request flows through ServiceNow governance:

1. LOB submits request using `QuotaManager.request_quota_increase()` in [`automation/servicenow/quota_increase_workflow.py`](../../automation/servicenow/quota_increase_workflow.py).
2. Record created in `u_ai_quota_requests` with urgency routing:

   | Monthly cost increase | Urgency | Approver |
   |---|---|---|
   | > $1,000 | High | VP |
   | > $100 | Medium | Manager |
   | ≤ $100 | Low | Auto-approved |

3. On approval, ServiceNow calls the outbound REST Message to the Azure Function App.
4. Function App updates the APIM subscription limit **via the APIM Management API** — or, for permanent limit changes, creates a Bicep PR for platform team review.

For ServiceNow setup prerequisites, see [`automation/servicenow/setup/setup-guide.md`](../../automation/servicenow/setup/setup-guide.md).

---

## Monitoring and Alerting

### Key metrics to watch

| Metric | Where | Alarm threshold |
|---|---|---|
| `TokensConsumed` (APIM) | Application Insights | > 90% of product TPM limit sustained for 5 min |
| `BlockedCalls` (APIM) | Application Insights | Any spike — indicates callers are being throttled |
| `SuccessfulCalls` drop | Application Insights | > 20% drop from baseline |
| Foundry 429 rate | Log Analytics `ApiManagementGatewayLogs` | > 5% of requests return 429 from backend |

### Recommended Log Analytics alert (Foundry 429s)

```kql
// Alert: Foundry backend is rate-limiting APIM (Layer 1 exhausted)
ApiManagementGatewayLogs
| where TimeGenerated > ago(5m)
| where BackendResponseCode == 429
| summarize Count = count()
| where Count > 50
```

Create this as a Scheduled Query Rule in Log Analytics, pointing at the `ai-logs` workspace. Define the alert rule in `infrastructure/bicep/supporting-infra.bicep` and apply via `azd provision`.

---

## Troubleshooting — 429 FAQ

### Why am I seeing 429s when my usage metrics appear below quota?

APIM token counting and Azure Monitor metrics are **not the same signal**:

- **Rate limiting** is evaluated on estimated token usage (prompt size + `max_tokens`) at request-arrival time.
- **Azure Monitor metrics** reflect *billed* tokens from completed responses — after processing.

A request can hit the rate limit before any tokens are billed. Common causes:

| Scenario | Explanation |
|---|---|
| Large `max_tokens` values | APIM reserves the full `max_tokens` capacity even if the model returns fewer |
| Streaming responses | Completion tokens are estimated, not exact, until the stream ends |
| Concurrent burst | Multiple requests arriving simultaneously; APIM counter is eventually consistent, not atomic |
| HTTP 400 requests | Rejected requests (context too long) count against rate limits but don't appear in token metrics |

**Fix:** Reduce `max_tokens` to the minimum your scenario needs. Set `estimate-prompt-tokens="false"` in the APIM policy if you want actual post-response counting (reduces performance but improves accuracy).

### Why is the secondary Foundry account capacity so much higher?

The secondary account (West US, 30K TPM) must absorb **100% of primary traffic** during a failover event. The circuit-breaker in [`policies/apim/circuit-breaker-multi-region.xml`](../../policies/apim/circuit-breaker-multi-region.xml) routes all requests to West US when East US returns 429 or 5xx. The 1K primary capacity is intentional for load-test demos; raise it to match secondary for production.

### Quota is freed but deployments still fail with `QuotaExceeded`

When a Foundry account is **deleted via REST API** (not through Bicep/portal), its quota allocation is frozen for **48 hours** even though the resource is gone. To release quota immediately, purge the deleted resource:

```bash
# List soft-deleted resources
az cognitiveservices account list-deleted

# Purge (immediate quota release)
az cognitiveservices account purge \
  --name <account-name> \
  --resource-group <rg> \
  --location <location>
```

This is the only `az` command in this playbook that is acceptable as a break-glass operation; it does not modify any live infrastructure.

### The Foundry portal quota page is empty

Check: you need **Cognitive Services Usages Reader** at the subscription level, not just the resource group. This role must be assigned in [`infrastructure/bicep/foundry-apim-rbac.bicep`](../../infrastructure/bicep/foundry-apim-rbac.bicep) and applied via `azd provision`.

---

## Reference

| Resource | Purpose |
|---|---|
| [Azure OpenAI quotas and limits](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits) | Default limits, quota tier reference, batch quotas |
| [Manage quota — Foundry portal](https://learn.microsoft.com/en-us/azure/foundry/how-to/quota) | How to view and request quota in the portal |
| [Quota increase request form](https://aka.ms/oai/stuquotarequest) | Submit a quota increase to Microsoft |
| [APIM azure-openai-token-limit policy](https://learn.microsoft.com/en-us/azure/api-management/azure-openai-token-limit-policy) | Policy attributes, examples, streaming notes |
| `infrastructure/bicep/foundry-hub-project.bicep` | Foundry deployment `capacity` values |
| `infrastructure/bicep/apim-gateway.bicep` | APIM product policy with token limits |
| `policies/apim/token-quota-by-department.xml` | Per-department secondary rate limit |
| `automation/servicenow/quota_increase_workflow.py` | ServiceNow quota increase request client |
| `scripts/check-foundry-capacity.ps1` | PowerShell script to query current Foundry capacity |
