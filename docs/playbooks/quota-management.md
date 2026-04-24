# Playbook: Quota Management — Azure AI as a Service

**Audience:** Platform Engineers, IT Managers  
**Complexity:** Intermediate

> **All infrastructure is managed via `azd provision`.** Bicep is the single source of truth for all APIM policy values and Foundry deployment capacities. Do not patch resources in the Azure Portal or via mutating `az` commands — they will be overwritten on the next provision.

> **Disclaimer:** Azure AI Foundry is an evolving platform. Quota values, tier structures, and limits described here align with official Microsoft documentation as of April 2026. Always verify current limits at [learn.microsoft.com/azure/foundry/openai/quotas-limits](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits).

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

> **Capacity Sizing Rule:** The Foundry deployment `capacity` (Layer 1) must always be greater than or equal to the maximum number of *simultaneously active* APIM subscription keys multiplied by their per-key TPM limit. Concretely: if you have 10 Silver keys (5,000 TPM each) that could all fire at once, your Foundry deployment needs at least 50,000 TPM of capacity, or APIM will shed load to Foundry before it sheds it at the gateway — breaking the per-LOB accounting model. When adding new APIM products or approving new LOB subscriptions, always verify Layer 1 capacity can absorb the worst-case combined load.

---

## Quota Fundamentals

### How TPM Is Calculated

TPM is the primary unit of throughput. Azure OpenAI **estimates** the maximum token count for each request at the moment it is received using:

- The prompt text and its token count
- The `max_tokens` parameter
- The `best_of` parameter

This estimated count is added to a running token counter for the current minute window. A 429 is returned once the TPM limit is reached within that window.

> **Critical nuance:** The estimation uses the *maximum potential output* (`max_tokens`), not the actual tokens generated. A request with `max_tokens=4096` reserves 4,096 tokens of budget even if the model returns only 200 tokens. Setting `max_tokens` unnecessarily high is the most common cause of unexpected 429s at low observed usage.

### RPM Enforcement Timing

Rate limits are evaluated on a **per-second rolling basis**, not only at the per-minute boundary. If you exceed the tokens-per-second threshold or the RPM threshold over a 1–10 second window, a 429 is returned before the full minute has elapsed. This means bursty traffic can be throttled even when the total tokens-per-minute is well below the limit.

**Practical implication for this platform:** Spread requests over time rather than batching. The APIM `estimate-prompt-tokens="true"` setting causes APIM itself to reject oversized burst windows at the gateway level before the request reaches Foundry.

### 429 vs. 403 in This Platform

When using APIM policies, the error code distinguishes the cause:

| Error | Source | Meaning |
|---|---|---|
| **429 Too Many Requests** | APIM `azure-openai-token-limit` (rate) or Foundry | TPM or RPM limit exceeded within the current rolling window |
| **403 Forbidden** | APIM `azure-openai-token-limit` (quota) | Cumulative token budget for the configured window (e.g., monthly) is exhausted |

Azure OpenAI itself only returns 429. A 403 in this platform means the APIM product's fixed-window quota (if configured) has been fully consumed and won't reset until the window resets.

### Concurrent Request Limits

Each model has a maximum number of simultaneous in-flight requests. Representative limits for models relevant to this platform:

| Model family | Max concurrent requests |
|---|---|
| Azure OpenAI models (gpt-4o, gpt-4o-mini, etc.) | Varies by SKU — see [quotas-limits](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits) |
| Llama 3.3 70B Instruct | 300 |
| DeepSeek-R1, DeepSeek-V3 | 300 |
| Most other Foundry Models | 300 |

### Distributed Rate-Limit Enforcement

Azure OpenAI's rate-limit enforcement is **distributed**, meaning enforcement is not perfectly precise or immediately reflected in aggregated metrics. In practice you may occasionally exceed the limit by a small margin before throttling activates, or be throttled slightly before your own metrics show you've hit the exact limit. Treat 429s as capacity signals rather than exact threshold indicators.

### Hard Resource Limits

| Limit | Value |
|---|---|
| Foundry resources per region per Azure subscription | **100** |
| Max projects per Foundry resource | 250 |
| Max deployments per Foundry resource | **32** |
| Max custom request headers | 10 (HTTP 431 if exceeded) |

> **32 deployments per resource is a hard limit.** If you need more model deployments than 32, create an additional Foundry resource. Do not design around this limit using workarounds — add a new resource in `foundry-hub-project.bicep` and provision it.

> **Custom headers:** Future API versions will not pass through custom headers. Do not design systems that depend on more than 10 custom headers or rely on header pass-through behaviour.

### Client-Side Timeout Recommendations

| Scenario | Recommended client timeout |
|---|---|
| Reasoning models (o1, o3, o3-mini, o4-mini) | Up to 29 minutes |
| Non-reasoning models — streaming | Up to 60 seconds |
| Non-reasoning models — non-streaming | Up to 29 minutes |

Set these timeouts in your SDK client configuration. The default timeout in most HTTP clients (30 seconds) is too low for non-streaming long completions.

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
RPM is derived automatically (ratio varies by model — see [TPM→RPM Ratios](#tpmrpm-ratios)).

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

| Model family | RPM per 1,000 TPM |
|---|---|
| Chat models (gpt-4o, gpt-4.1 family) | 6 RPM |
| o1, o3, o4-mini | 1 RPM |
| o1-mini, o3-mini, o3-pro | 1 RPM per 10,000 TPM |

Example: a `gpt-4o` deployment with `capacity: 5` (5,000 TPM) gets 30 RPM automatically.

> **Source:** [Azure OpenAI in Microsoft Foundry Models quotas and limits](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits) (updated April 2026)

---

## Quota Tier System (Microsoft Foundry — April 2026)

Microsoft assigns subscriptions to quota **tiers (Free, 1–6)** rather than a single default:

- Your initial tier is based on **consumption trends** and your **Microsoft agreement type** (EA / MCA-E customers start higher).
- Tiers **auto-upgrade** as usage grows — no support ticket required.
- Tier 6 has the highest default limits; Tier 1 represents new subscriptions with minimal history.
- Manual increases are still possible at any tier via the [quota request form](https://aka.ms/oai/stuquotarequest).
- The exact thresholds and timelines for auto-upgrades are **not publicly disclosed**. If you need capacity immediately, submit a manual request rather than waiting for auto-upgrade.

### Tier 6 Reference Values (highest published)

| Model | Tier 6 TPM |
|---|---|
| gpt-4.1 | 5,000,000,000 (5B) |
| gpt-4.1-mini | 1,500,000,000 (1.5B) |
| gpt-4o | 500,000,000 (500M) |
| gpt-4o-mini | 1,500,000,000 (1.5B) |
| o3-mini | 1,500,000,000 (1.5B) |
| gpt-5 | 5,000,000,000 (5B) |

Always verify current values at [learn.microsoft.com/azure/foundry/openai/quotas-limits#quota-tier-reference](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits).

### Usage Tier and Latency

Operating above your **usage tier** can degrade response latency even without triggering a hard 429:

- Response latency may increase by more than **2×** compared to operating within your tier.
- Latency variability is most pronounced for high sustained usage or bursty traffic.
- Usage is measured **per tenant** (across all subscriptions and regions in your tenant for that model), not per individual Azure subscription.

If you observe persistent latency degradation at scale, this is a signal you have outgrown your current tier. Options: request a quota increase, wait for an automatic upgrade, or consider Provisioned Throughput Units (PTUs).

### Check Your Subscription's Current Tier

```bash
# Requires: az login + Owner or Contributor on the subscription
az account get-access-token --resource https://management.azure.com --query accessToken -o tsv | \
  xargs -I{} curl -s -H "Authorization: Bearer {}" \
  "https://management.azure.com/subscriptions/<SUB_ID>/providers/Microsoft.CognitiveServices/quotaTiers?api-version=2025-10-01-preview"
```

### Opt Out of Automatic Tier Upgrades

If you use quota ceilings as a cost-control mechanism, disable auto-upgrades:

```bash
az account get-access-token --resource https://management.azure.com --query accessToken -o tsv | \
  xargs -I{} curl -X PATCH \
  -H "Authorization: Bearer {}" \
  -H "Content-Type: application/json" \
  -d '{"properties":{"tierUpgradePolicy":"NoAutoUpgrade"}}' \
  "https://management.azure.com/subscriptions/<SUB_ID>/providers/Microsoft.CognitiveServices/quotaTiers/default?api-version=2025-10-01-preview"
```

> **Note:** The opt-out API is in preview and may change. Microsoft recommends using Azure Cost Management for billing control rather than quota caps as the primary cost-control mechanism.

---

## Viewing Current Quota and Usage

### Foundry portal (read-only)

1. Open [Microsoft Foundry portal](https://ai.azure.com) → **Operate** → **Quota**.
2. Select **Token per minute** tab.
3. Click any deployment to see its current allocation, usage bar, and affiliated projects.

Required RBAC: **Cognitive Services Usages Reader** at the subscription level (minimum). Define this role assignment in [`infrastructure/bicep/foundry-apim-rbac.bicep`](../../infrastructure/bicep/foundry-apim-rbac.bicep) and run `azd provision`. Do not assign it ad hoc with `az role assignment create`.

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

> **Ownership reminder:** This is a **Platform Engineer** responsibility. Developers and IT Managers should not contact Microsoft directly — they escalate via ServiceNow.

### RBAC Required Before Requesting

| Action | Required role |
|---|---|
| View quota | Cognitive Services Usages Reader (subscription level) |
| Request increase | Owner or Contributor (subscription level) |
| Edit allocation in portal | Cognitive Services Contributor + Usages Reader |

### What to Include in the Request

Providing evidence of real usage is the most important factor — requests without demonstrated utilisation may be denied.

| Element | Why it matters |
|---|---|
| Azure subscription ID and organisational email | Routes the request to the correct team |
| Region(s) and model(s) | Quota is regional; capacity varies by region |
| Current TPM and target TPM with justification | Makes the request actionable |
| Evidence of sustained utilisation and 429 counts | Demonstrates real usage and impact |
| Business impact and timeline | Helps justify prioritisation |

**TPM sizing formula:**

```
Required TPM ≈ (avg input tokens + avg output tokens) × requests per minute × safety factor (1.5–2×)

Example: 50 users × (1,000 input + 500 output tokens) × 0.5 req/min × 1.5 = 56,250 TPM
```

### Process

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
    capacity: 30  // 30K TPM — enough for all LOBs at peak
  }
  ...
}
```

Then apply:

```bash
azd provision
```

**Capacity increments:** `capacity: 1` = 1,000 TPM, `capacity: 30` = 30,000 TPM. The maximum is capped by your subscription's quota in that region and model family. If `azd provision` fails with `QuotaExceeded`, submit the increase form first (see above).

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

**Rate limit vs. fixed-window quota:** The policy supports both:
- `tokens-per-minute` — rolling per-minute rate limit → **429** when exceeded
- `token-quota` + `token-quota-period` — fixed-window budget (e.g., monthly) → **403** when exhausted

Example with a monthly budget in addition to per-minute rate limit:

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
resource deptQuotaApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-05-01-preview' = {
  parent: openaiInferenceApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../../policies/apim/token-quota-by-department.xml')
  }
}
```

> **Multi-region note:** APIM tracks token counters **per gateway node** independently, not aggregated across the entire Premium multi-region instance. If you have APIM units in East US and West US, each unit maintains its own counter. A caller could consume up to 2× the configured `tokens-per-minute` by load-balancing across both units. Account for this in your limit values.

---

## Strategies for Increasing Throughput

| Strategy | Best for | Trade-off |
|---|---|---|
| **Multi-region deployment** | Doubling effective TPM with minimal cost change | Adds routing complexity; not all models available in all regions |
| **Manual quota increase request** | Fast boost when capacity exists in-region | Approval not guaranteed; requires demonstrated utilisation |
| **Automatic tier upgrade** | Steady organic growth | Timeline not predictable; requires sustained utilisation signals |
| **Provisioned Throughput Units (PTUs)** | Production workloads needing predictable latency | Billed hourly whether used or not; requires right-sizing |
| **Model diversification** | Workloads where multiple models are acceptable | Each model has its own independent quota pool |

### Multi-Region Deployment

Deploying a model to an additional Azure region gives access to another set of TPM/RPM quotas for that model. This platform already provisions a secondary Foundry account in West US — to increase platform capacity, raise its `capacity` value in Bicep first before adding a new region.

### Provisioned Throughput Units (PTUs)

PTUs provide dedicated, reserved capacity for a model, separate from the shared quota system. They are billed hourly based on deployed PTUs (prorated for partial hours).

Key operational notes:
- **Deploy first, reserve second:** Quota does not guarantee physical capacity — deploy to confirm capacity exists, then purchase a reservation for long-term cost savings.
- **PTU ≠ free scaling:** You pay for deployed PTUs whether used or not; right-sizing is essential.
- **Output token weighting:** For some models (e.g., GPT-5), 1 output token counts as 8 input tokens toward utilisation. Workloads with large completions need more PTUs than prompt size alone suggests.
- **PTU 429s are fast-fail signals:** A PTU deployment returns 429 when utilisation exceeds 100% — this is by design. Configure routing to fall back to standard deployments on PTU 429s.

PTU sizing rule of thumb:

```
Input-equivalent tokens/min = RPM × (input_tokens + output_tokens × weight)
Estimated PTU = input-equivalent tokens/min ÷ (input TPM per PTU)

Example: 40 RPM × (1,000 + 400 × 8) = 168,000 input-equiv/min ÷ 4,750 ≈ 36 PTU
```

---

## RBAC Roles for Quota Management

Understanding which roles govern quota vs. inference is essential for proper access control.

| Role | Can make inference calls | Can manage deployments | Can view/modify quota |
|---|---|---|---|
| **Cognitive Services OpenAI User** | Yes (via Entra ID) | No | No |
| **Cognitive Services OpenAI Contributor** | Yes | Yes (create/edit deployments, fine-tuning) | No |
| **Cognitive Services Contributor** | Yes | Yes | Yes (create resources, view/copy keys) |
| **Cognitive Services Usages Reader** | No | No | View only |
| **Subscription Owner / Contributor** | Yes (inherited) | Yes | Yes |

> **Key finding:** Neither `Cognitive Services OpenAI User` nor `Cognitive Services OpenAI Contributor` grants access to quota management. To view or modify quota, deployment TPM settings, or tier configurations, you need at minimum `Cognitive Services Usages Reader` for read access, or `Owner`/`Contributor` at subscription level for modifications.

**Recommended configuration for this platform:**

| Identity | Role | Scope | Where defined |
|---|---|---|---|
| APIM managed identity | Cognitive Services OpenAI User | Foundry resource | `foundry-apim-rbac.bicep` |
| Platform Engineer | Cognitive Services Contributor | Subscription | `foundry-apim-rbac.bicep` |
| IT Manager (quota view only) | Cognitive Services Usages Reader | Subscription | `foundry-apim-rbac.bicep` |
| Developer / app service principal | Cognitive Services OpenAI User | Foundry project | `foundry-apim-rbac.bicep` |

All RBAC assignments must be defined in [`infrastructure/bicep/foundry-apim-rbac.bicep`](../../infrastructure/bicep/foundry-apim-rbac.bicep) and applied via `azd provision`.

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

Create this as a Scheduled Query Rule in Log Analytics pointing at the `ai-logs` workspace. Define the alert rule in `infrastructure/bicep/supporting-infra.bicep` and apply via `azd provision`.

---

## Troubleshooting — 429 FAQ

### Why am I seeing 429s when my usage metrics appear below quota?

APIM token counting and Azure Monitor metrics are **not the same signal**:

- **Rate limiting** is evaluated on *estimated* token usage (prompt size + `max_tokens`) at request-arrival time, using the per-second rolling window.
- **Azure Monitor metrics** reflect *billed* tokens from completed responses — after processing.

A request can hit the rate limit before any tokens are billed. Common causes:

| Scenario | Explanation |
|---|---|
| Large `max_tokens` values | APIM reserves the full `max_tokens` budget even if the model returns fewer tokens |
| Bursty traffic | Per-second RPM threshold exceeded even though per-minute total is fine |
| Streaming responses | Completion tokens are estimated, not exact, until the stream ends |
| Concurrent burst | Multiple requests arrive simultaneously; rate-limit counter is eventually consistent |
| HTTP 400 requests | Rejected requests (context too long) count against rate limits but don't appear in token metrics |

**Fix:** Reduce `max_tokens` to the minimum your scenario needs. Set `estimate-prompt-tokens="false"` in the APIM policy if you want actual post-response counting (reduces performance, improves accuracy).

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

### What is the difference between a quota increase and deploying more capacity?

| Action | What it does | Who does it |
|---|---|---|
| **Quota increase (Microsoft)** | Raises the ceiling of TPM your subscription is *allowed* to allocate in a region | Platform Engineer via quota request form |
| **Increasing Foundry `capacity` (Bicep)** | Allocates more of your existing quota to a specific deployment | Platform Engineer via `azd provision` |

You need both: quota headroom from Microsoft, and the `capacity` value in Bicep set to use it.

---

## Reference

| Resource | Purpose |
|---|---|
| [Azure OpenAI quotas and limits](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits) | Default limits, quota tier reference, batch quotas |
| [Foundry Models quotas and limits](https://learn.microsoft.com/en-us/azure/ai-foundry/model-inference/quotas-limits) | Non-OpenAI model limits |
| [Manage quota — Foundry portal](https://learn.microsoft.com/en-us/azure/foundry/how-to/quota) | How to view and request quota in the portal |
| [Quota increase request form](https://aka.ms/oai/stuquotarequest) | Submit a quota increase to Microsoft |
| [APIM azure-openai-token-limit policy](https://learn.microsoft.com/en-us/azure/api-management/azure-openai-token-limit-policy) | Policy attributes, examples, streaming notes |
| [Enforce Token Limits with AI Gateway](https://learn.microsoft.com/en-us/azure/ai-foundry/configuration/enable-ai-api-management-gateway-portal) | Foundry portal AI Gateway setup |
| `infrastructure/bicep/foundry-hub-project.bicep` | Foundry deployment `capacity` values |
| `infrastructure/bicep/apim-gateway.bicep` | APIM product policy with token limits |
| `infrastructure/bicep/foundry-apim-rbac.bicep` | RBAC assignments |
| `policies/apim/token-quota-by-department.xml` | Per-department secondary rate limit |
| `automation/servicenow/quota_increase_workflow.py` | ServiceNow quota increase request client |
| `scripts/check-foundry-capacity.ps1` | PowerShell script to query current Foundry capacity |
# Azure OpenAI / Azure AI Foundry — Quota & Capacity Management Playbook

## Overview

This playbook provides IT professionals and platform engineers with operational guidance on managing quotas, rate limits, and capacity for **Azure OpenAI in Microsoft Foundry Models** (formerly referred to as Azure OpenAI Service). All guidance is aligned with official Microsoft documentation as of April 2026.

Effective quota management ensures applications avoid throttling (HTTP 429 errors), maintain predictable latency, and scale cost-efficiently across teams and regions. This document covers how quotas are scoped and allocated, the new tier system, rate-limit enforcement mechanics, APIM-based routing and failover patterns, RBAC roles, monitoring, and operational best practices.

---

## Scope of Quota

Quotas are enforced at the **Azure subscription** level — not the tenant level[1](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits). Within a subscription, quotas are defined **per region, per model, and per deployment type**[1](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits).

**Practical effect:** If a model such as `gpt-4.1` Global Standard is listed with **5 million TPM** and **5,000 RPM**, then *each region* where that model/deployment type is available has its own dedicated quota pool of that amount for *each* of your Azure subscriptions[1](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits). A single subscription can therefore consume a larger total of TPM and RPM for a given model across multiple regions, as long as resources and deployments are distributed accordingly[1](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits).

**Resource limit:** Each subscription is limited to a maximum of **30 Azure OpenAI resource instances per region**[2](https://techcommunity.microsoft.com/blog/fasttrackforazureblog/optimizing-azure-openai-a-guide-to-limits-quotas-and-best-practices/4076268)[3](https://github.com/Azure/aoai-apim).

### Quota vs. Capacity

Having subscription quota does **not** guarantee that a region can physically allocate the deployment. If a region's compute resources for a model are fully consumed, you may see deployment errors even though your subscription's quota shows availability. You can check per-region capacity in two ways:

- **Foundry portal** at [ai.azure.com](https://ai.azure.com)[1](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits)
- **Capacity API** — query `subscriptionId`, `model_name`, and `model_version` to get available capacity across all regions and deployment types for your subscription[1](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits)

> **Note:** Both the Foundry portal and the capacity API currently return quota/capacity information for models that are retired and no longer available for new deployments[1](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits). Confirm model availability separately before planning capacity.

---

## Quota Tiers

Microsoft has replaced the former binary "Default" and "Enterprise" quota levels with a **seven-tier system**: **Free Tier** and **Tiers 1 through 6**, with Tier 6 offering the highest quotas[1](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits).

### How Tiers Are Assigned

A subscription's initial tier is based on **current usage of that model** and the **customer's relationship with Microsoft** — Enterprise Agreement (EA) or MCA-E customers are assigned higher tiers[1](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits). Any previously approved quota increases are retained and will not be reduced when transitioning to the new system[1](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits).

### Automatic Tier Upgrades

As a customer's consumption increases such that the current tier is limiting usage of Foundry Models, the system **automatically upgrades** the subscription to the next higher tier[1](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits). Microsoft considers:

- **Consumption trends** across Foundry Models over time[1](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits)
- **Enterprise relationship** status (EA, MCA-E)[1](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits)
- **Payment history**[1](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits)

### Opting Out of Auto-Upgrades

You can opt out by setting the `NoAutoUpgrade` flag via the management API. Microsoft acknowledges that some customers use quota ceilings to manage billing, and the opt-out prevents unintended quota expansion[1](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits).

```bash
curl -X PATCH \
   "https://management.azure.com/subscriptions/{subscriptionId}/providers/Microsoft.CognitiveServices/quotaTiers/default?api-version=2025-10-01-preview" \
  -H "Authorization: Bearer <your_access_token>" \
  -H "Content-Type: application/json" \
  -d '{
    "properties": {
      "tier