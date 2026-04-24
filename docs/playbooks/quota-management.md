# Playbook: Quota Management — Azure AI as a Service

**Audience:** Platform Engineers, IT Managers  
**Complexity:** Intermediate

> **All infrastructure is managed via `azd provision`.** Bicep is the single source of truth for all APIM policy values and Foundry deployment capacities. Do not patch resources in the Azure Portal or via mutating `az` commands — they will be overwritten on the next provision.

> **Disclaimer:** Azure AI Foundry is an evolving platform. Quota values, tier structures, and limits described here align with official Microsoft documentation as of April 2026. Always verify current limits at [learn.microsoft.com/azure/foundry/openai/quotas-limits](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits).

---

## Overview

### Key Concepts

Before diving in, keep these definitions in mind — every section of this playbook uses them, and confusing them is the most common source of miscommunication between developers, platform engineers, and IT managers.

#### Core Terms

| Term | What it is |
|---|---|
| **Quota** | Your *allowed allocation* — the maximum rate limits you may assign across deployments in your subscription, assigned per subscription, per region, and per model in TPM and RPM. Quota is a customer-adjustable logical ceiling; you can request increases or redistribute it between deployments without opening a support ticket. |
| **Capacity** | The *physical hardware availability* in an Azure region. Having quota does **not** guarantee capacity: if a region's compute resources for a model are fully consumed, a deployment will fail even when your subscription quota shows room. Capacity is Microsoft-controlled; you cannot increase it directly. |
| **Deployment** | *What you provision* — a specific model instance within a Foundry resource, configured with a deployment type and a capacity value (TPM ceiling). Deployment is where quota and capacity intersect: it succeeds only when both your quota allocation and regional physical capacity are available. |
| **Usage** | *What you consume* — the running token count against your quota. For Usage Tier purposes, Microsoft measures usage *per tenant* across all subscriptions, all regions, and all deployments simultaneously. Usage drives throttling (429s), billing, and is the signal that prompts quota or capacity adjustments. |

> **Why Azure separates these four things:** Quota is customer-adjustable. Capacity is a Microsoft-controlled physical reality. Deployment is the act that requires both simultaneously. Usage is the ongoing measurement that may prompt you to adjust any of the three. Collapsing them into a single concept of "limits" — as many cloud providers do — is the most common source of support tickets and quota planning mistakes on this platform.

#### Additional Concepts

| Concept | What it is |
|---|---|
| **Quota Tier** (Free, Tier 1–6) | Determines the **maximum TPM/RPM you are allowed to allocate** per model per region for your subscription. Think of it as the ceiling on your quota ceiling. Auto-upgrades over time based on consumption trends, Microsoft agreement type (EA/MCA-E starts higher), and payment history — no support ticket needed for routine growth. Tier 6 = highest allocations; Free = minimal. Approving a manual quota increase does **not** change your tier number — the tier goes up on its own schedule, but you can always request more quota within your current tier. You can opt out of auto-upgrade with the `NoAutoUpgrade` flag. |
| **Usage Tier** | A **separate**, per-tenant tier system — not the same as Quota Tier despite the similar name. Defines the throughput level above which predictable latency is no longer guaranteed: exceeding your usage tier can more than double response latency even when no 429 is returned. Measured across all subscriptions and regions for your entire Entra tenant. Applies only to Standard, GlobalStandard, and DataZoneStandard deployments — not PTU or batch. |
| **Deployment Type** | Determines how inference is routed and which quota pool is consumed. The four types are: **Standard** (single-region, shared infrastructure), **GlobalStandard** (globally load-balanced across Azure regions), **DataZoneStandard** (data-zone routing for data-residency requirements), and **Provisioned / PTU** (dedicated capacity, separate quota pool, hourly billing). Standard quota cannot be applied to a Provisioned deployment — they draw from entirely separate pools. |
| **PTU (Provisioned Throughput Unit)** | The billing unit for Provisioned deployments. One PTU reserves a fixed amount of model compute; you are billed per PTU-hour regardless of actual token consumption. PTU deployments return 429 immediately when utilisation exceeds 100% (by design, not as an error) — configure fallback routing to standard deployments on PTU 429s. |
| **Rate Limit vs. Quota Exhaustion** | Two distinct throttling mechanisms with different error codes and reset timelines. A **429 Too Many Requests** means the TPM or RPM ceiling was exceeded within the current rolling window — it resets within seconds to a minute. A **403 Forbidden** from APIM means the fixed-window cumulative token *budget* is fully consumed and will not reset until the window (e.g., monthly) rolls over. 429 = temporary spike; 403 = budget gone for the period. |
| **Shared Quota Pool** | A temporary pool of quota Azure provides for testing new models without opening a support ticket. Usage-billed, shared across all Azure customers, and subject to availability. Unsuitable for production workloads — use only for initial model evaluation before requesting dedicated quota. |

### Two-Layer Quota System

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
| Foundry resources per region per Azure subscription | **30** |
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

## Deployment Type Reference

How inference traffic is routed — and which quota pool is consumed — depends entirely on the deployment type chosen for a Foundry resource. Standard quota cannot be converted to, or applied toward, a Provisioned deployment; the pools are completely separate.

### The four deployment types

| Type | Routing | Quota pool | Data residency | Best for |
|---|---|---|---|---|
| **Standard** | Single Azure region (where the Foundry resource is deployed) | Regional shared pool — separate per region | Data stays in the declared region | Predictable routing, data-residency requirements, default choice |
| **GlobalStandard** | Azure routes globally — you declare a "home" region but traffic may be served from any Azure region | Global shared pool — separate from all Standard pools | Data **may** be processed outside the declared region | Maximum throughput without managing multi-region failover yourself |
| **DataZoneStandard** | Constrained to a geographic data zone (e.g., `EuropeanUnion`, `UnitedStates`) | Data-zone shared pool — separate from regional Standard | Data stays within declared zone boundary | Compliance requirements banning cross-zone data movement while still wanting better availability than single-region Standard |
| **Provisioned / PTU** | Single region, dedicated capacity | Dedicated PTU pool — completely separate from all token-based pools | Data stays in declared region | Predictable low latency, high-volume steady-state workloads |

> **Quota pools are completely independent.** A Standard deployment's TPM allocation cannot be applied to a GlobalStandard deployment, and vice versa. When requesting quota increases, specify the deployment type explicitly — a quota increase for Standard does not add headroom to your GlobalStandard pool.

### Standard vs. GlobalStandard — the key tradeoff for this platform

This platform uses **Standard** deployments for all current Foundry resources. The implications:

| Consideration | Standard (current) | GlobalStandard |
|---|---|---|
| **Multi-region failover** | You manage it — APIM circuit-breaker policy routes to West US secondary on 429/5xx | Azure manages it automatically — no circuit-breaker policy needed |
| **Quota pool** | Regional — East US and West US have separate quota allocations that you manage independently | Single global pool — no region-to-region allocation split |
| **Data residency** | Guaranteed — data does not leave the declared region | Not guaranteed — requests may be served from any Azure region |
| **PCI DSS / data sovereignty** | Compatible — deterministic in-region processing | Requires compliance review before adoption — data residency not guaranteed |
| **Regional capacity competition** | Competes with other Azure customers in East US for Standard capacity | Spread globally — regional capacity exhaustion less likely to affect you |

**Why this platform chose Standard:** The circuit-breaker pattern in [`policies/apim/circuit-breaker-multi-region.xml`](../../policies/apim/circuit-breaker-multi-region.xml) is already implemented, and the PCI DSS audit logging requirements in [`policies/apim/pci-dss-audit-logging.xml`](../../policies/apim/pci-dss-audit-logging.xml) benefit from deterministic in-region processing. GlobalStandard would eliminate the need for the West US secondary Foundry account — but requires a full compliance review to confirm data-residency acceptability before any migration.

### DataZoneStandard and PCI DSS

If your compliance requirements mandate that data does not leave a defined geographic zone but you want more resilience than a single-region Standard deployment:

- **DataZoneStandard** routes within the declared zone (e.g., `EuropeanUnion`, `UnitedStates`)
- This platform is currently US-only with Standard. If expanding to EU regions, DataZoneStandard in the `EuropeanUnion` zone is the correct type — not Standard in a single EU region
- Quota increases for DataZoneStandard are requested separately from Standard quota; they draw from a different pool

### Checking which deployment type each resource uses

```bash
# List all deployments with their SKU (deployment type) and capacity
az cognitiveservices account deployment list \
  --name <foundry-account-name> \
  --resource-group <rg> \
  --query "[].{Name:name, SKU:sku.name, Capacity:sku.capacity}" \
  -o table
```

Or inspect `infrastructure/bicep/foundry-hub-project.bicep` — the `sku.name` field on each deployment resource is the deployment type (`Standard`, `GlobalStandard`, `DataZoneStandard`, `ProvisionedManaged`).

---

## Quota Tier System (Microsoft Foundry — April 2026)

### Why Quota Tiers Exist

Before Quota Tiers, Azure Foundry offered only two quota levels for pay-as-you-go subscriptions: **Default** and **Enterprise**. The gap between them was large, the process to move between them was slow (requiring a support engagement), and there was no automatic growth path as a customer's usage matured. This created significant friction for workloads scaling from prototype to production.

Microsoft introduced the Quota Tier system to fix this:

> *"Quotas will now increase automatically with usage, helping avoid rate limit errors while also creating a fairer environment for all users."* — Microsoft Foundry documentation

Key improvements over the old model:
- **Seven tiers** (Free + Tiers 1–6) replace two fixed levels
- **Automatic upgrades** as usage grows — no support ticket required for routine scaling
- All existing subscriptions were migrated at tier levels **equal to or higher** than their previous allocation. No previously approved increases were reduced.
- Manual increase requests are still available at any tier if you need to grow faster than the auto-upgrade schedule

### How Tiers Are Assigned

Your **initial tier** is determined at the subscription level based on two factors:

| Factor | What it considers |
|---|---|
| **Consumption trends** | Your historical token usage across Foundry Models — how much you are actually using today |
| **Microsoft relationship** | Enterprise Agreement (EA) or Microsoft Customer Agreement — Enterprise (MCA-E) customers are assigned higher initial tiers |

Your **ongoing tier** is further influenced by:
- **Payment history** — consistent, timely payment is a factor in upgrade eligibility
- **Usage growth** — if your current tier is constraining your actual usage, the system will upgrade you automatically

The exact thresholds, measurement windows, and timelines for auto-upgrades are **not publicly disclosed** by Microsoft. If you cannot afford to wait for the automatic schedule, submit a manual quota increase request.

### What a Tier Does (and Does Not Do)

This is the most commonly misunderstood point:

> **A tier sets the ceiling on how much quota you are *allowed to allocate* — it does not itself allocate any quota.**

Practically:
- Moving from Tier 1 to Tier 3 expands the *maximum* you could request or assign. It does not automatically add TPM to any deployment.
- Foundry deployments still need their `capacity` parameter updated in Bicep and re-provisioned to actually use any additional quota. The tier just means you are now permitted to set higher `capacity` values.
- **Approved manual quota increases do not change your tier number.** Your tier stays where it is, but the specific model/region quota is increased above the tier's default. Both can coexist.

```
Tier 3  ← what you're allowed to allocate (ceiling)
  │
  ├─ gpt-4o-mini East US: 5,000,000 TPM  ← your current allocation (can be less than tier max)
  │     └─ Foundry deployment capacity: 30,000 TPM  ← actual Layer 1 enforcement (Bicep)
  │           └─ APIM Silver product: 5,000 TPM  ← Layer 2 per-LOB enforcement
  │
  └─ gpt-4.1 East US: [not yet allocated]  ← tier permits this model, but no deployment exists yet
```

### Tier 1 vs Tier 6 — Scale Reference

The range between tiers is dramatic. For the models most relevant to this platform:

| Model | Deployment Type | Tier 1 TPM | Tier 6 TPM | Scale factor |
|---|---|---|---|---|
| gpt-4o-mini | GlobalStandard | 2,000,000 | 1,500,000,000 | ~750× |
| gpt-4o-mini | DataZoneStandard | 1,000,000 | _(not published)_ | — |
| gpt-4o | DataZoneStandard | 300,000 | 500,000,000 | ~1,667× |
| gpt-4.1 | GlobalStandard | 1,000,000 | 5,000,000,000 | 5,000× |
| gpt-4.1-mini | GlobalStandard | 5,000,000 | 1,500,000,000 | 300× |
| o3-mini | GlobalStandard | 500,000 | 1,500,000,000 | 3,000× |
| gpt-5 | GlobalStandard | 1,000,000 | 5,000,000,000 | 5,000× |

> These values represent the quota you are **allowed to allocate**, not what is automatically assigned. Verify current tier reference values at [learn.microsoft.com/azure/foundry/openai/quotas-limits#quota-tier-reference](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits#quota-tier-reference).

### Auto-Upgrade Mechanics

Auto-upgrades operate silently in the background. What this means in practice:

| Behaviour | Detail |
|---|---|
| **Trigger** | Your usage grows to the point where the current tier is constraining your ability to use Foundry. Microsoft monitors this automatically. |
| **What changes** | Your subscription moves to the next higher tier. All default model allocations increase to the new tier's values. |
| **What does not change** | Existing `capacity` values in your Bicep files. A tier upgrade does not push changes to your deployed resources — you still need to update Bicep and run `azd provision` to consume the new headroom. |
| **Timing** | Not publicly disclosed. Do not plan releases or capacity changes around the expectation of an auto-upgrade arriving on a specific date. |
| **Notification** | No Azure portal notification or Event Grid event is emitted when your tier changes. Check via the API (below). |

### Auto-Upgrade vs Manual Request — When to Use Which

| Situation | Recommended approach |
|---|---|
| Gradual organic growth — existing workloads scaling up over weeks | Let auto-upgrade work. No action needed. |
| Planned new LOB onboarding — known capacity need in 2–4 weeks | Submit manual quota request now. Don't wait. |
| Immediate capacity need (launch tomorrow) | Submit manual quota request and contact your Microsoft account team if urgent. |
| Experimenting with a new model family for the first time | Use the **Shared Quota Pool** for initial testing, then request dedicated quota once you know the production TPM requirement. |
| You use quota limits as a cost control mechanism | **Opt out of auto-upgrade** (see below). Use Azure Cost Management for billing controls instead. |

### Platform-Specific Implications

On this APIM-fronted architecture, the Quota Tier affects Layer 1 headroom — not Layer 2 enforcement:

- **APIM product limits (Layer 2)** are set in Bicep and do not change when your tier changes. Bronze/Silver/Gold TPM limits are defined values, not tier-dependent.
- **A tier upgrade gives you room to raise the Foundry deployment `capacity` (Layer 1)** to support more concurrent LOBs or higher per-LOB limits. But you must make that Bicep change and run `azd provision` yourself.
- **The Capacity Sizing Rule still applies** regardless of tier: Foundry deployment `capacity` ≥ sum of worst-case simultaneous APIM product limits.
- **Tier upgrades are subscription-scoped** — they apply to the Azure subscription where your Foundry resources live. If your platform spans multiple Azure subscriptions (e.g., dev, staging, prod are separate subscriptions), each subscription has its own tier and upgrade schedule.

### Check Your Subscription's Current Tier

```bash
# Requires: az login + Owner or Contributor on the subscription
az account get-access-token --resource https://management.azure.com --query accessToken -o tsv | \
  xargs -I{} curl -s -H "Authorization: Bearer {}" \
  "https://management.azure.com/subscriptions/<SUB_ID>/providers/Microsoft.CognitiveServices/quotaTiers?api-version=2025-10-01-preview"
```

### Opt Out of Automatic Tier Upgrades

If you use quota ceilings as a cost-control mechanism and a silent tier upgrade would cause unintended spend, disable auto-upgrades:

```bash
az account get-access-token --resource https://management.azure.com --query accessToken -o tsv | \
  xargs -I{} curl -X PATCH \
  -H "Authorization: Bearer {}" \
  -H "Content-Type: application/json" \
  -d '{"properties":{"tierUpgradePolicy":"NoAutoUpgrade"}}' \
  "https://management.azure.com/subscriptions/<SUB_ID>/providers/Microsoft.CognitiveServices/quotaTiers/default?api-version=2025-10-01-preview"
```

> **Caution:** The opt-out API is in preview and may change or be removed. Microsoft's recommended pattern for billing control is [Azure Cost Management](https://learn.microsoft.com/en-us/azure/foundry/concepts/manage-costs) with budgets and alerts — not quota caps, which are a blunt instrument that can cause unexpected 403s for production workloads.

### Usage Tier and Latency Degradation

The **Usage Tier** is a separate, per-tenant concept (not the same as Quota Tier despite the similar name). Operating above your usage tier can degrade response latency even without triggering a hard 429:

- Response latency may increase by more than **2×** compared to operating within your tier.
- Latency variability is most pronounced for high sustained usage or bursty traffic patterns.
- Usage is measured **per Entra tenant** — across all Azure subscriptions, all regions, and all deployments for that model in your organisation. A single high-traffic LOB can push the entire tenant above its usage tier threshold, degrading response times for all other LOBs sharing the same tenant.
- Applies only to Standard, GlobalStandard, and DataZoneStandard deployments. PTU and batch deployments are not affected.

**Usage tier reference for key models (token threshold above which latency degrades):**

| Model | Usage Tier Threshold |
|---|---|
| gpt-4o | 12 billion tokens/minute |
| gpt-4o-mini | 85 billion tokens/minute |
| gpt-4.1 | 30 billion tokens/minute |
| gpt-4.1-mini | 150 billion tokens/minute |
| o3-mini | 50 billion tokens/minute |
| o4-mini | 50 billion tokens/minute |

If you observe persistent latency degradation at scale without 429s, you are likely above the usage tier. Options: request a quota increase, or migrate high-volume deployments to PTU for dedicated, guaranteed throughput.

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

## Redistributing Quota Between Deployments

Quota can be redistributed between deployments on the same Foundry resource **without opening a Microsoft support ticket**. This is one of the most useful but least-documented day-2 operations: you can move unused TPM from a low-traffic model to a high-traffic one in minutes, using only a Bicep edit and `azd provision`.

### What redistribution means

Your subscription has a regional TPM allocation for each model. Any allocated TPM not currently assigned to a deployment sits in an undeployed pool. You can:

- **Increase** a deployment's `capacity` by drawing from that undeployed pool
- **Decrease** a deployment's `capacity` to return TPM to the pool (freeing it for reallocation elsewhere)

Both operations require only a Bicep change and `azd provision` — no Microsoft approval needed.

Redistribution is **within your existing quota**. To add TPM you do not already have, you need a quota increase request to Microsoft (see [Requesting a Foundry Quota Increase](#requesting-a-foundry-quota-increase-microsoft)).

### How to redistribute via Bicep

The following example reallocates 8K TPM from `phi-4` to `gpt-4o-mini` on the primary account:

```bicep
// Before — phi-4 has unused capacity; gpt-4o-mini is at minimum
resource gpt4oMini1 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: foundry1
  name: 'gpt-4o-mini'
  sku: { name: 'Standard', capacity: 1 }   // 1K TPM
}

resource phi4_1 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: foundry1
  name: 'phi-4'
  sku: { name: 'GlobalStandard', capacity: 10 }   // 10K TPM — underutilised
  dependsOn: [gpt4oMini1]
}

// After — reallocate 8K TPM from phi-4 to gpt-4o-mini
resource gpt4oMini1 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: foundry1
  name: 'gpt-4o-mini'
  sku: { name: 'Standard', capacity: 9 }   // 9K TPM (+8K)
}

resource phi4_1 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: foundry1
  name: 'phi-4'
  sku: { name: 'GlobalStandard', capacity: 2 }   // 2K TPM (-8K returned to pool)
  dependsOn: [gpt4oMini1]
}
```

Then apply:

```bash
azd provision
```

> **`dependsOn` is required.** Multiple deployments on the same Foundry account must be updated sequentially. If `azd provision` fails with `DeploymentInProgress`, the `dependsOn` chain is missing or incomplete. Do not remove these dependencies.

### What you cannot redistribute

| Restriction | Detail |
|---|---|
| **Cross-region** | East US quota cannot be moved to West US — each region has its own independent pool |
| **Cross-deployment-type** | Standard TPM cannot be applied to a GlobalStandard deployment — separate pools |
| **Cross-model-family** | TPM allocated for `gpt-4o` cannot be applied to `Phi-4` — each model family has its own pool |
| **Cross-subscription** | Quota is subscription-scoped — cannot transfer between Azure subscriptions |
| **Portal redistribution** | The Foundry portal shows a pencil icon in the Affiliated Deployments section. **Do not use it** — portal changes are overwritten on the next `azd provision` |

### Checking available (unallocated) quota before redistributing

```python
# pip install azure-identity requests
import requests
from azure.identity import DefaultAzureCredential

subscription_id = "<SUB_ID>"
location        = "eastus"

token = DefaultAzureCredential().get_token("https://management.azure.com/.default").token
r = requests.get(
    f"https://management.azure.com/subscriptions/{subscription_id}"
    f"/providers/Microsoft.CognitiveServices/locations/{location}/usages"
    "?api-version=2023-05-01",
    headers={"Authorization": f"Bearer {token}"}
)
for usage in r.json()["value"]:
    remaining = usage["limit"] - usage["currentValue"]
    if remaining > 0:
        print(f"{usage['name']['localizedValue']:50s}  "
              f"used={usage['currentValue']} / limit={usage['limit']} / available={remaining}")
```

This shows unallocated TPM — headroom you can assign to existing deployments without requesting a quota increase.

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

### When to Use PTU vs. Standard — Decision Framework

PTU is not always the right choice. The decision depends on traffic profile, latency requirements, and cost tolerance.

| Signal | Recommendation |
|---|---|
| **Bursty or unpredictable traffic (demos, batch jobs, dev/test)** | Stay on Standard. PTUs are billed at idle — bursty workloads waste committed spend. |
| **Steady-state, high-volume traffic (> 50–60% utilisation for 16+ hours/day)** | PTU likely cheaper. Break-even vs. pay-per-token Standard typically occurs at sustained ~50% utilisation. |
| **P99 latency is a contractual requirement (LOB SLA)** | PTU — dedicated capacity gives predictable latency that Standard shared infrastructure cannot guarantee. |
| **Testing a new model or new workload** | Standard first. Gather 2+ weeks of real TPM/RPM data before sizing PTUs. |
| **Very large completions (o-series reasoning models)** | PTU requires careful sizing — o-series output tokens are weighted 8:1 vs. input toward utilisation. A 4,000-token completion counts as 32,000 input-equivalent tokens. |
| **Need to burst above a known steady-state baseline** | PTU + Standard fallback. Configure the APIM circuit-breaker to fall back to Standard on PTU 429s — the fallback absorbs burst traffic while PTU handles the baseline cost-efficiently. |

### PTU utilisation metric

The metric to monitor is **Provisioned Managed Utilization V2** in Azure Monitor under the Cognitive Services resource. Target range: **50–70%**.

| Utilisation level | Meaning | Action |
|---|---|---|
| > 100% | PTU 429s firing — clients are being shed to fallback | Add PTUs or reduce traffic |
| 80–100% | Approaching shed threshold | Review growth trend; plan PTU increase |
| 50–70% | Healthy operating range | No action needed |
| < 20% sustained | Over-provisioned — paying for idle capacity | Reduce PTUs at next reservation renewal |

### Declaring a PTU deployment in Bicep

PTU deployments use `sku.name: 'ProvisionedManaged'` and `capacity` expressed in PTUs — **not** thousands of TPM:

```bicep
resource gpt4oPtu 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: foundry1
  name: 'gpt-4o-ptu'
  sku: {
    name: 'ProvisionedManaged'
    capacity: 50   // 50 PTUs — not 50K TPM
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4o'
      version: '2024-11-20'
    }
  }
  dependsOn: [gpt4oMini1]
}
```

PTU reservations (for committed-use discounts) are purchased separately through Azure Reservations. The Bicep deployment above creates the PTU deployment; the reservation is a billing construct layered on top of it — without a reservation you are billed at the on-demand PTU hourly rate.

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

This platform emits quota-relevant signals at three levels: the APIM gateway, the Foundry backend, and deployed model metrics. Understanding which signal originates from which level is essential for accurate diagnosis — a 429 appearing in Application Insights may be from Layer 2 (APIM policy), Layer 1 (Foundry capacity), or both simultaneously.

### Observability Architecture

```
APIM Gateway
  ├─ Application Insights   ← per-call latency, 4xx/5xx rates, token counts
  │                           (token counts require azure-openai-emit-token-metric policy)
  └─ Log Analytics          ← full gateway request log (ApiManagementGatewayLogs),
                              backend response codes, routing decisions

Foundry (CognitiveServices)
  └─ Azure Monitor          ← deployment-level utilisation, PTU Utilization V2,
                              capacity headroom per region

Managed Grafana
  └─ Pre-built dashboards   ← token usage by LOB, latency distribution, failover
                              frequency (see observability/grafana/)
```

### Key Metrics to Watch

| Metric | Source | Signal | Alert threshold |
|---|---|---|---|
| Token usage per call (custom metric) | Application Insights — `azure-openai-total-token-usage` | Actual token consumption emitted by `azure-openai-emit-token-metric` policy | > 90% of product TPM limit sustained for 5 min |
| `BlockedCalls` (APIM built-in) | Application Insights | Calls rejected before reaching backend — rate limit or auth failure | Any non-zero spike |
| Backend 429 rate | `ApiManagementGatewayLogs.BackendResponseCode == 429` | Foundry returning 429 — Layer 1 capacity exhausted | > 5% of requests in any 5-min window |
| `SuccessfulCalls` drop | Application Insights | Availability degradation | > 20% drop from 7-day rolling baseline |
| PTU Utilization V2 | Azure Monitor (Cognitive Services resource) | PTU deployment utilisation — applies to PTU deployments only | > 80% sustained for 10 min |
| Quota headroom (`currentValue / limit`) | `Microsoft.CognitiveServices/locations/usages` REST API | Available vs. allocated quota — proactive capacity check | < 20% remaining (review weekly) |

> **Why `BackendResponseBody` token counts are null:** APIM diagnostic settings have response body logging disabled for PCI DSS Req 3.3 (avoid logging sensitive data in transit). `BackendResponseBody.usage.total_tokens` will be `null` for every row in `ApiManagementGatewayLogs`. For reliable token tracking without body logging, the [`azure-openai-emit-token-metric`](https://learn.microsoft.com/en-us/azure/api-management/azure-openai-emit-token-metric-policy) policy writes token counts directly to Application Insights custom metrics without capturing the response body. Confirm it is present in `apim-gateway.bicep`.

### KQL Queries for Operational Monitoring

#### Foundry backend 429 rate (Layer 1 exhausted)

```kql
// Alert: Foundry is rate-limiting APIM — Layer 1 capacity exhausted
ApiManagementGatewayLogs
| where TimeGenerated > ago(5m)
| where BackendResponseCode == 429
| summarize Count = count()
| where Count > 50
```

#### Per-subscription throttle rate (Layer 2) over 1 hour

```kql
// Which APIM subscription keys are being throttled, and how often?
ApiManagementGatewayLogs
| where TimeGenerated > ago(1h)
| where ResponseCode == 429
| summarize ThrottledRequests = count() by SubscriptionId, bin(TimeGenerated, 5m)
| order by ThrottledRequests desc
```

#### Approaching-quota early warning (requires emit-token-metric policy)

```kql
// Token consumption per subscription per minute — approaching-limit early warning
customMetrics
| where TimeGenerated > ago(1h)
| where name == "azure-openai-total-token-usage"
| summarize TotalTokens = sum(value)
    by bin(TimeGenerated, 1m), tostring(customDimensions["Subscription ID"])
| order by TimeGenerated desc
```

#### Failover event detection — circuit-breaker triggered

```kql
// Requests routed to West US backend — indicates East US failover
ApiManagementGatewayLogs
| where TimeGenerated > ago(1h)
| where BackendUrl contains "westus"
| summarize FailoverCount = count(), AvgDurationMs = avg(DurationMs)
    by bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

### Per-Product Alert Strategy

A generic 429-count alert does not distinguish between a Bronze subscriber legitimately hitting their 500-TPM ceiling (expected, by design) and a Gold subscriber at their 5,500-TPM ceiling (may indicate a real capacity problem). Alert at the product level with thresholds relative to each product's limit:

| Product | TPM limit | Alert at 90% | Interpretation |
|---|---|---|---|
| Bronze (`ai-bronze`) | 500 TPM | 450 TPM sustained | Expected at scale — Bronze is sized for limited use. Review if all Bronze keys are simultaneously at threshold. |
| Silver (`ai-silver`) | 5,000 TPM | 4,500 TPM sustained | Investigate per-LOB growth. Approaching Gold-tier volume — may need upgrade or quota increase. |
| Gold (`ai-gold`) | 5,500 TPM | 4,950 TPM sustained | **Requires immediate Layer 1 check.** Gold product limit is very close to the East US primary Foundry deployment capacity (currently 1K TPM for demo; raise before production). |

### Deploying Alert Rules via Bicep

Do not create alert rules in the portal. Define them in `infrastructure/bicep/supporting-infra.bicep` and apply via `azd provision`:

```bicep
resource foundry429Alert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'foundry-backend-429-elevated'
  location: location
  properties: {
    displayName: 'Foundry Layer 1 — Backend 429s Elevated'
    description: 'Foundry is rate-limiting APIM. Layer 1 capacity may be exhausted.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    scopes: [logAnalyticsWorkspace.id]
    criteria: {
      allOf: [{
        query: '''
          ApiManagementGatewayLogs
          | where BackendResponseCode == 429
          | summarize Count = count()
          | where Count > 50
        '''
        timeAggregation: 'Count'
        operator: 'GreaterThan'
        threshold: 0
      }]
    }
    actions: {
      actionGroups: [actionGroup.id]
    }
  }
}
```

### Managed Grafana Dashboards

Pre-built dashboards are maintained in [`observability/grafana/`](../../observability/grafana/). They surface:

- Token consumption by LOB (per APIM subscription key)
- Backend latency distribution per model
- 429 rate and circuit-breaker failover frequency
- Layer 1 vs. Layer 2 capacity headroom over time

Access via the Azure portal or the ACI jumpbox. Dashboard JSON is provisioned through Bicep in `supporting-infra.bicep` — do not edit dashboards in the Grafana UI directly, as portal changes will be overwritten on the next `azd provision`.

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

## Client Retry Strategy and the `Retry-After` Header

When a 429 is returned, both APIM and Foundry set a `Retry-After` response header indicating how many seconds the caller should wait before retrying. Ignoring this header and retrying immediately is the most common way to make throttling worse — a burst of 50 clients ignoring `Retry-After` and retrying at zero delay simply recreates the original burst.

### Where `Retry-After` originates

| Source | Set by | Typical value | Meaning |
|---|---|---|---|
| **APIM Layer 2 throttle (429)** | `azure-openai-token-limit` policy | 1–60 seconds | Seconds until the rolling per-minute window has recovered enough to allow the request |
| **Foundry Layer 1 throttle (429)** | Azure CognitiveServices | 1–60 seconds | Same semantics — Foundry passes its own `Retry-After` back through APIM |
| **APIM monthly quota exhaustion (403)** | `azure-openai-token-limit` policy (quota mode) | Often days or weeks | Seconds until the end of the fixed billing window — retrying in 30 seconds will not help |

> **Key distinction:** A Layer 2 APIM 429 has a short `Retry-After` (seconds). A 403 from monthly quota exhaustion has a `Retry-After` measuring days. The error code tells you which case you are in.

### SDK retry behaviour and APIM interaction

The `openai` Python SDK and `azure-ai-projects` SDK include built-in retry logic. How this interacts with APIM:

| SDK behaviour | APIM interaction | Risk |
|---|---|---|
| SDK retries on 429 with exponential backoff | Works if SDK honours `Retry-After` (v1.x+ does) | Low for well-configured clients |
| SDK retries on 503/502 (backend errors) | APIM circuit-breaker may already be retrying to the secondary backend | **Double-retry risk:** if both APIM and SDK retry independently, traffic can be amplified 2–4× during a failover event |
| SDK retries on 403 | APIM 403 = budget exhausted | **Always wrong** — retry won't succeed until the budget window resets |

**Recommendation for LOB developers on this platform:** disable SDK-level retries and implement application-level retry that reads `Retry-After`:

```python
import time
import openai

client = openai.AzureOpenAI(
    azure_endpoint="https://<apim-name>.azure-api.net",
    api_key="<apim-subscription-key>",
    max_retries=0,   # disable SDK auto-retry — APIM circuit-breaker handles backend failover
)

def chat_with_retry(messages, max_attempts=3):
    for attempt in range(max_attempts):
        try:
            return client.chat.completions.create(
                model="gpt-4o-mini",
                messages=messages
            )
        except openai.RateLimitError as e:
            retry_after = int(e.response.headers.get("Retry-After", 10))
            jitter = __import__("random").uniform(0, 2)
            if attempt < max_attempts - 1:
                time.sleep(retry_after + jitter)
            else:
                raise
        except openai.PermissionDeniedError:
            raise   # 403 = monthly quota exhausted — do not retry
```

### Backoff strategy rules

| Rule | Rationale |
|---|---|
| **Always prefer `Retry-After` over backoff formulas** | `Retry-After` is more accurate than any heuristic — it reflects the actual window state |
| **Use exponential backoff only as a fallback** | For network-level errors not from APIM (no `Retry-After` present) |
| **Always add jitter** | Prevents thundering herd — multiple clients throttled simultaneously will retry at exactly `Retry-After + 0ms` without jitter, recreating the burst |
| **Set `max_retries=0` in the SDK** | APIM circuit-breaker handles backend failover; stacking SDK retries on top amplifies traffic during failures |
| **Do not retry 403** | Monthly budget is gone — retry at next window reset, not immediately |

### Response headers to log

The `azure-openai-token-limit` policy sets headers that give early warning before throttling starts. Instruct LOB developers to log these:

| Header | Meaning |
|---|---|
| `X-Remaining-Tokens` | Tokens remaining in the current per-minute window for this subscription key |
| `X-Remaining-Monthly-Tokens` | Tokens remaining in the monthly budget window (if `token-quota` is configured on the product) |
| `Retry-After` | Seconds to wait — present on 429 and 403 responses |

Logging `X-Remaining-Tokens` trends allows LOBs to detect approaching-quota conditions before 429s begin, enabling graceful degradation (e.g., switching to a smaller model) rather than hard failure.

---

## Model Retirement and Version Management

Azure AI Foundry retires model versions on a published schedule. When a model version reaches its retirement date, new deployments of that version are blocked, and existing deployments are eventually migrated to a successor or removed. For a platform that pins specific model versions in Bicep, this is a recurring operational event requiring proactive management.

### What happens to quota when a model version retires

| Stage | What happens |
|---|---|
| **Retirement announced** | Microsoft publishes a retirement date. No quota change — existing deployments continue to operate. |
| **Retirement date reached** | New deployments of this version cannot be created. Existing deployments continue to function. |
| **Auto-migration (if available)** | Microsoft may migrate existing deployments to a successor version on a declared date. Quota allocation transfers to the new version automatically. |
| **No-successor case** | Deployments are removed. TPM returns to your unallocated quota pool — it is **not lost**, but you must deploy a different model to use it. |

> **Quota is not deleted when a model retires.** The TPM returns to your undeployed pool. The operational risk is a service availability gap if Bicep is not updated before the removal date.

### Checking retirement schedules

```bash
# List all deployments with their model version and deprecation dates
az cognitiveservices account deployment list \
  --name <foundry-account-name> \
  --resource-group <rg> \
  --query "[].{Name:name, Model:properties.model.name, Version:properties.model.version, RetirementDate:properties.model.deprecationDate}" \
  -o table
```

Published retirement dates are at [learn.microsoft.com/azure/ai-services/openai/concepts/model-retirements](https://learn.microsoft.com/en-us/azure/ai-services/openai/concepts/model-retirements).

> **Recommended cadence:** Run this check quarterly, or subscribe to Azure Service Health alerts for Cognitive Services model retirement notifications. Define a Service Health alert rule in `supporting-infra.bicep` to receive proactive notifications.

### Bicep migration path

When a model version is approaching retirement, update `infrastructure/bicep/foundry-hub-project.bicep` before the retirement date:

```bicep
// Before — pinned version approaching retirement
resource gpt4oMini1 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: foundry1
  name: 'gpt-4o-mini'
  sku: { name: 'Standard', capacity: 1 }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4o'
      version: '2024-11-20'   // ← check retirement schedule for this version
    }
  }
}

// After — updated to successor version
resource gpt4oMini1 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: foundry1
  name: 'gpt-4o-mini'
  sku: { name: 'Standard', capacity: 1 }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4o'
      version: '2025-02-01'   // ← successor version
    }
  }
}
```

Then apply:

```bash
azd provision
```

> **Deployment name is preserved.** LOB developers and APIM policies reference the *deployment name* (`gpt-4o-mini`), not the model version string. Updating `version` in Bicep and reprovisioning is transparent to callers — no APIM policy changes required.

### Auto-update policy — opt in

As an alternative to manual version pinning, Foundry supports an `versionUpgradeOption` property that controls automatic version migration:

```bicep
properties: {
  model: {
    format: 'OpenAI'
    name: 'gpt-4o'
    version: '2024-11-20'
  }
  // Options: 'NoAutoUpgrade' | 'OnceNewDefaultVersionAvailable' | 'OnceCurrentVersionExpired'
  versionUpgradeOption: 'OnceCurrentVersionExpired'   // migrate only at the last possible moment
}
```

| Option | Behaviour |
|---|---|
| `NoAutoUpgrade` | Version stays pinned — you control all migrations manually via Bicep |
| `OnceCurrentVersionExpired` | Auto-migrates only when the current version reaches its retirement date — last-resort safety net |
| `OnceNewDefaultVersionAvailable` | Auto-migrates whenever a new default version is released — **not recommended for production** (behaviour may change between versions) |

**Recommended production setting:** `OnceCurrentVersionExpired` combined with quarterly manual reviews. This prevents a retirement-day outage while giving you control over when to actually migrate.

### Model retirement operational checklist

When a retirement is announced (via Service Health alert or quarterly review):

1. Check [`infrastructure/bicep/foundry-hub-project.bicep`](../../infrastructure/bicep/foundry-hub-project.bicep) for the retiring version string across all model deployments (East US **and** West US).
2. Identify the successor version from the [model retirements page](https://learn.microsoft.com/en-us/azure/ai-services/openai/concepts/model-retirements).
3. Test the successor version in the Foundry playground or a staging deployment.
4. Verify LOB-specific prompt templates produce acceptable output on the successor.
5. Update `version` in Bicep for both primary and secondary accounts.
6. Run `azd provision` — zero downtime; deployment name is preserved.
7. Update the **Current Configured Values** table in this playbook.

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
