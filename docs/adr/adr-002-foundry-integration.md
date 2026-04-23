# ADR-002: Azure AI Foundry as the Hub for Models & Agents

**Status:** Accepted  
**Date:** February 2026  
**Supersedes:** N/A

## Context

Organizations need a **single control plane** for:
- Exploring models (1900+ options: OpenAI, Meta, Llama, Claude, etc.)
- Creating and managing agents
- Evaluating model performance
- Managing knowledge bases (RAG)
- Audit logging and compliance

## Decision

**Use Azure AI Foundry as the central hub** for all AI model and agent lifecycle management. Route Foundry traffic through APIM (ADR-001).

This gives developers a consistent API contract whether they're using:
- GPT-4o (Microsoft-hosted)
- Llama (partner-hosted)
- Custom fine-tuned models

## Architecture

```
Developer App
    ↓
AIProjectClient (Foundry SDK)
    ↓
APIM Gateway (Cost Control, Caching, Auth)
    ↓
Azure AI Foundry Project
    ├─ Models (inference endpoint)
    ├─ Agent Service
    ├─ Knowledge Base (Azure AI Search)
    └─ Evaluations
    ↓
    Logs → Application Insights → Grafana
```

## Why Foundry Instead of Direct Azure OpenAI?

| Feature | Direct Azure OpenAI | Azure AI Foundry |
|---------|-------------------|-------------------|
| Model catalog access | ❌ GPT-4/3.5 only | ✅ 1900+ models |
| Agent Service | ❌ | ✅ Assistants API compatible |
| Fine-tuning UI | ❌ | ✅ Built-in |
| Evaluations | ❌ | ✅ Evaluate agent quality |
| Knowledge bases | ❌ | ✅ RAG built-in |
| Project isolation | ❌ | ✅ Multi-tenant safe |

**Bottom line:** Foundry is Azure's comprehensive AI platform; Azure OpenAI is just a component within it.

## Implementation Pattern: Single Shared Foundry Instance

Create **one shared Foundry instance** (`Microsoft.CognitiveServices/accounts`) that all developers access through APIM:

```
Azure AI Foundry (Shared Instance)
├─ Models Available
│  ├─ gpt-4o (Microsoft-hosted)
│  ├─ meta-llama-3-70b (partner)
│  ├─ claude-opus-4 (partner)
│  └─ custom-fine-tuned (your org)
├─ Shared Tools & Integrations
│  ├─ Function tools (your APIs)
│  ├─ Azure AI Search (knowledge)
│  └─ Azure Logic Apps (workflows)
└─ Evaluation & Testing
   ├─ Model comparison
   ├─ Agent performance metrics
   └─ Cost analysis per model
```

**All traffic routed through APIM** for cost control and audit.

## Developer Experience

### Simple Chat
```python
from azure.ai.projects import AIProjectClient
client = AIProjectClient(
    credential=DefaultAzureCredential(),
    project_id="shared-foundry",
    endpoint="https://my-org-ai.azure-api.net"
)

# Use any Foundry model
response = client.inference.get_chat_completions_client().complete(
    model="gpt-4o",  # or "meta-llama-3-70b", "claude-opus-4", etc.
    messages=[{"role": "user", "content": "Hello"}]
)
```

### Create & Run Agents
```python
# IT team deploys model → Foundry → APIM
# Developer uses unified API regardless of backend
agent = client.agents.create_agent(
    name="my-agent",
    model="gpt-4o"  # Foundry abstracts the actual backend
)
```

## Foundry Project Isolation vs. Hub

**Two deployment models:**

### Option A: Single Shared Foundry Instance (Current — implemented)

All LOBs share one pair of `Microsoft.CognitiveServices/accounts` (East US + West US).
Isolation is enforced exclusively at the APIM layer: each LOB gets a unique subscription
key, and APIM policies enforce model allowlists, TPM/RPM quotas, and audit logging per
subscription.

**Advantages**
- ✅ Single set of model deployments — TPM quota pooled across all LOBs (higher burst tolerance)
- ✅ One private endpoint pair → lower networking cost and DNS complexity
- ✅ New LOB onboarding = create an APIM subscription only (minutes, not hours)
- ✅ APIM policies are the single enforcement point — easier to audit
- ✅ Centrally managed model versions — one upgrade rolls out to all LOBs
- ✅ Shared AI Search index for org-wide RAG knowledge bases

**Disadvantages / Risks**
- ❌ Agent state (threads, files, vector stores) is in a shared namespace — a leaked
  agent ID from one LOB could be used to poll another LOB's thread if APIM auth is
  bypassed (defence: APIM is the only network path; direct Foundry access is blocked
  by private endpoint + `disableLocalAuth: true`)
- ❌ A noisy LOB can consume disproportionate TPM headroom under burst conditions,
  degrading other LOBs (mitigation: `token-quota-by-department.xml`)
- ❌ No physical data boundary between LOBs — relies on APIM subscription key as the
  sole segregation control. Does not satisfy regulators who require physical separation
  (e.g., FedRAMP High, HIPAA BAA with strict data residency requirements)
- ❌ Fine-tuned model deployments are visible to all LOBs that share the account
  (mitigation: APIM product allowlist blocks access; but the deployment exists in the
  shared namespace)

---

### Option B: Per-LOB Foundry Instance (not yet implemented)

Each LOB gets a dedicated `Microsoft.CognitiveServices/accounts` resource (and
optionally a dedicated AI Search instance). APIM routes to the correct backend based
on the caller's subscription product.

**Advantages**
- ✅ Physical data boundary — agent threads, vector stores, fine-tuned models and
  uploaded files are isolated at the Azure resource level, not just the APIM policy level
- ✅ Per-LOB TPM quota is independent — one LOB cannot exhaust another's capacity
  even without APIM quota enforcement
- ✅ LOB-specific model deployments (custom fine-tunes, private model versions) are
  not visible to other LOBs at all
- ✅ Satisfies strict compliance regimes (FedRAMP High, HIPAA with data residency,
  internal audit requirements mandating physical separation)
- ✅ Per-LOB cost allocation is exact — Foundry billing maps directly to one resource
  per LOB without tag-based apportionment

**Disadvantages / Costs**
- ❌ **Infrastructure multiplication** — each LOB requires:
  - 2× `Microsoft.CognitiveServices/accounts` (primary + secondary regions)
  - 2× private endpoints (one per account)
  - 2× private DNS A-records
  - 2× APIM backends + 1 APIM backend pool
  - 2× RBAC assignments (`Cognitive Services User` → APIM MSI)
  - Model deployments duplicated on every account (identical SKU/capacity per LOB)
- ❌ **TPM quota fragmentation** — Azure allocates TPM per deployment per account.
  Splitting 50K TPM across 5 LOBs gives 10K each; burst that hits one LOB cannot
  borrow from others (no pooling). Requires careful capacity planning per LOB.
- ❌ **Operational overhead** — model version upgrades, capacity changes, and policy
  updates must be applied to every LOB account individually (or via Bicep loops,
  but drift is harder to detect)
- ❌ **APIM routing complexity** — the global policy must inspect the subscription
  product and select the correct backend pool. A mis-routing bug sends LOB A's traffic
  to LOB B's Foundry account.
- ❌ **Cost** — each additional AIServices account adds private endpoint hours,
  DNS zone link costs, and (if AI Search is per-LOB) Search index costs.
  Rough estimate: ~$150–300/month per LOB at low usage vs. ~$50/month shared.

---

### Decision Matrix: When to Choose Each Option

| Requirement | Option A (Shared Instance) | Option B (Per-LOB Instance) |
|-------------|:--------------:|:------------------:|
| Standard Bronze/Silver LOBs | ✅ Sufficient | Overkill |
| Gold LOB — inference only | ✅ Sufficient | Acceptable |
| Gold LOB — agent state isolation needed | ⚠️ Risky | ✅ Required |
| Gold LOB — private RAG index (confidential docs) | ⚠️ Risky | ✅ Required |
| Gold LOB — custom fine-tuned model (IP sensitive) | ⚠️ Risky | ✅ Required |
| FedRAMP High / HIPAA with physical separation clause | ❌ Non-compliant | ✅ Compliant |
| Cost-optimised onboarding (<5 LOBs) | ✅ Best | Expensive |
| Scale to 20+ LOBs | ✅ Scales well | Complex to manage |

---

### Migration Path: Hub → Per-LOB

If a LOB later needs Option B, no developer code changes are required:

1. Provision a new `Microsoft.CognitiveServices/accounts` pair for the LOB (Bicep).
2. Add private endpoints and DNS records for the new accounts.
3. Add a new APIM backend and backend pool pointing to the LOB-specific accounts.
4. Update the APIM product policy for that LOB to route to the new backend pool.
5. Grant the LOB's APIM subscription key access to the new product.
6. Revoke access to the shared Foundry product for that subscription.

The developer's APIM URL (`https://<apim>.azure-api.net/ai/...`) and subscription
key are unchanged. The re-routing is invisible at the SDK level.

**See ADR-005 §Gap 3 for the current accepted-tradeoff decision and the trigger
conditions that would require migration to Option B.**

---

**Current recommendation:** Use **Option A (Single Shared Foundry Instance)** for all Bronze and Silver LOBs.
Evaluate Option B individually for Gold LOBs based on their agent state and RAG
data sensitivity requirements.

## Integration with ServiceNow

When developers request a new model or increase quota:

1. Ticket filed in ServiceNow
2. IT approves (via ADR-003 workflow)
3. Model deployed to shared Foundry instance
4. APIM endpoint automatically updated
5. Developers get it without code changes

## Consequences

### Positive 🟢

1. **Model Flexibility** - Swap models without code changes
2. **Centralized Experiments** - All teams use same evaluation framework
3. **Cost Optimization** - Easy to identify cheapest model for a use case
4. **Knowledge Sharing** - Common knowledge bases (RAG) across teams
5. **Compliance** - Audit trail through Foundry + APIM + App Insights

### Negative 🔴

1. **Complexity** - Another platform to learn (vs. direct Azure OpenAI)
2. **Slower Iteration** - Changes to Foundry require IT approval
3. **Additional Costs** - Shared Foundry instance costs (~$50/month)

## Related Decisions

- [ADR-001: APIM as Gateway](adr-001-why-apim.md)
- [ADR-003: ServiceNow Workflow](adr-003-servicenow-workflow.md)
- [ADR-005: Identity Security Gaps — includes Gap 3 (per-LOB routing accepted tradeoff)](adr-005-identity-security-gaps.md)

---

## Revision History

| Version | Date | Author | Change |
|---------|------|--------|--------|
| 1.0 | Feb 2026 | Platform Team | Initial version |
| 1.1 | Apr 2026 | Platform Engineering | Expanded Option A (Shared Instance) vs Option B (Per-LOB Instance) tradeoff analysis with decision matrix and migration path |
