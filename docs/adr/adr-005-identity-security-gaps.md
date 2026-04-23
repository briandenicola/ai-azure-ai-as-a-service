# ADR-005: Identity Security Gaps — CAF Review Findings

**Status:** In Remediation  
**Date:** 2026-04-23  
**Authors:** Platform Engineering  
**Reviewers:** Security Architecture, AI Platform Lead  
**Review Trigger:** Azure Architecture Center — "Provide custom authentication to Azure OpenAI in Foundry Models through a gateway" + CAF AI security guidance

---

## Context

During an April 2026 security review against the Microsoft Azure Architecture Center
guidance for AI gateway patterns, four identity and security gaps were assessed.
This ADR records the findings, the remediation decision for each, and tracks
resolution status.

Reference documents consulted:
- [Azure OpenAI gateway — custom authentication guide](https://learn.microsoft.com/en-us/azure/architecture/ai-ml/guide/azure-openai-gateway-custom-authentication)
- [Azure OpenAI gateway guide](https://learn.microsoft.com/en-us/azure/architecture/ai-ml/guide/azure-openai-gateway-guide)
- [CAF AI security best practices](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/scenarios/ai/security)

---

## Findings

### Gap 1 — APIM → Foundry: Managed Identity (✅ Compliant, No Action)

**Finding:** Microsoft guidance requires the gateway to authenticate to the AI
backend using a managed identity (Entra Bearer token), not a stored API key.

**Current state:** `infrastructure/bicep/foundry-apim-rbac.bicep` grants APIM's
system-assigned managed identity `Cognitive Services User` on both Foundry accounts.
The global APIM policy strips any inbound `api-key` header and injects an Entra
Bearer token using `authentication-managed-identity`. `disableLocalAuth: true` is
set on both AIServices accounts so key-based auth is disabled at the platform level.

**Decision:** Already compliant. No action required.

---

### Gap 2 — Identity Logging at APIM (✅ Compliant, No Action)

**Finding:** Microsoft guidance requires the gateway to log the requesting client
and user identities on every call so that audit trails can be tied back to a specific
LOB, even though all traffic flows through a single MSI to Foundry.

**Current state:** `policies/apim/pci-dss-audit-logging.xml` captures:
- `pci-audit-sub-id` — APIM subscription ID (the per-LOB identity unit)
- `pci-audit-user-id` — JWT `sub` claim (Entra user or service principal OID)
- `pci-audit-appid` — JWT `appid` claim (the calling application's Entra client ID)
- `pci-audit-client-ip` — caller IP address

All events are written to Log Analytics (395-day retention) satisfying PCI DSS Req 10
and the CAF observability requirement.

**Decision:** Already compliant. No action required.

---

### Gap 3 — Per-LOB Routing to Separate Foundry Deployments (⚠️ Accepted Tradeoff)

**Finding:** Microsoft's recommended pattern for strong data isolation is to route
each LOB (or each security tier) to a dedicated Foundry project, so that model
deployments, vector stores, and agent state are never co-mingled.

**Current state:** The architecture uses a single shared Foundry instance
(Option A from [ADR-002](adr-002-foundry-integration.md)).  All LOBs share the same
model deployments and agent service namespace.  Isolation is enforced by APIM
subscription-key boundaries and RBAC at the Foundry level, not by physical project
separation.

**Tradeoff:** Per-LOB Foundry projects increase operational overhead significantly —
each new LOB requires a new AIServices account, private endpoint, DNS record, APIM
backend, and RBAC set.  The current single-hub model keeps onboarding simple and
cost-efficient.

**Mitigating controls in place:**
1. APIM subscription key is the only auth credential LOBs receive — they cannot
   reach Foundry directly.
2. APIM policies enforce model allowlists per product tier (Bronze/Silver/Gold).
3. PCI DSS Gold tier has a dedicated product with stricter policies and manual
   subscription approval.
4. All requests are logged with caller identity (see Gap 2).

**Decision:** Accepted tradeoff. Re-evaluate if a Gold LOB requires agent state
isolation (e.g., private vector stores with confidential documents). At that point,
provision a dedicated Foundry project for Gold and route via a separate APIM backend.
See ADR-002 §"Option B" for the provisioning pattern.

**Owner:** Platform Engineering  
**Revisit trigger:** First Gold LOB onboarding request with agent state / RAG data.

---

### Gap 4 — Semantic Cache Key Not Identity-Scoped (🔴 FIXED — April 2026)

**Finding:** Microsoft guidance explicitly states:

> "make sure the identity of the requestor is considered in the cache logic.
>  Do not return cached results for identities that are not authorized to
>  receive that data."

**Previous state (vulnerable):** `policies/apim/semantic-caching.xml` computed the
cache key as a SHA-256 hash of the prompt text only:

```csharp
// BEFORE — prompt hash only (no identity scope)
var hashBytes = sha.ComputeHash(System.Text.Encoding.UTF8.GetBytes(prompt));
```

This meant that if two different LOB subscribers sent the same prompt text, the second
subscriber would receive the first subscriber's cached response — including any
sensitive business context embedded in that response.

**Fix applied:** Cache key now includes `context.Subscription.Id` as a prefix before
hashing, ensuring that each subscriber's cache entries are entirely isolated:

```csharp
// AFTER — subscription-scoped prompt hash
var subscriptionId = context.Subscription.Id ?? "anonymous";
var raw = subscriptionId + "|" + prompt;
var hashBytes = sha.ComputeHash(System.Text.Encoding.UTF8.GetBytes(raw));
```

**Scoping strategy rationale:**
- `context.Subscription.Id` (chosen): Maximum isolation — each LOB has its own
  cache namespace. Cache hit rate is lower but no cross-subscriber leakage is
  possible under any scenario.
- `context.Product.Id` (alternative): Tier-level isolation — all Bronze subscribers
  share a cache, all Silver subscribers share a cache. Higher hit rate, but relies
  on the assumption that tier-mates never have confidential prompts that should not
  be seen by other tier-mates. Rejected as too weak a default.

**PCI DSS note:** The existing `pci-dss-cardholder-data-protection.xml` policy
already instructs: "Do NOT apply semantic-caching.xml to any PCI-scoped API
operation." This instruction is unchanged. Gold/PCI endpoints must not have
the semantic caching policy applied at all.

**Status:** ✅ Fixed in `policies/apim/semantic-caching.xml`  
**Deploy command:** `azd provision` (APIM policies are deployed via Bicep)

---

### Gap 5 — Entra Agent ID Inventory for Gold/PCI (🟡 Open — Governance)

**Finding:** Microsoft CAF AI security guidance recommends maintaining an inventory
of all agents using [Entra Agent ID](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/workload-id-agent-id-overview).
This provides visibility into which agents exist, which users/apps are running them,
and enables conditional access policies to restrict which agents can be registered.

**Current state:** Foundry agents can be created by any developer with the Foundry
`Azure AI Developer` role (granted via `developerObjectIds` in
`infrastructure/bicep/foundry-hub-project.bicep`).  There is no Entra Agent ID
registration requirement, no catalog of running agents, and no conditional access
policy restricting agent creation.

**Risk:** Without an agent inventory, a compromised developer credential could be
used to create a rogue agent that exfiltrates data through tool calls, with no
platform-level detection.

**Recommended remediation:**
1. Enable Entra Agent ID in the Foundry project settings (requires Entra P2).
2. Add a Conditional Access policy that requires agent registrations to be approved
   by the Security team for Gold-tier users.
3. Export the agent inventory monthly to Log Analytics for PCI DSS Req 12 artifact.

**Priority:** Medium — required before the first Gold LOB goes to production with
autonomous agents making tool calls against payment systems.

**Owner:** Identity & Access Management team  
**Target:** Gold tier GA date

---

## Summary Table

| Gap | Severity | Status | File(s) Affected |
|-----|----------|--------|-----------------|
| 1 — APIM MSI to Foundry | ✅ Compliant | No action | `foundry-apim-rbac.bicep` |
| 2 — Identity logging | ✅ Compliant | No action | `pci-dss-audit-logging.xml` |
| 3 — Per-LOB Foundry routing | ⚠️ Accepted | Revisit at Gold GA | `adr-002-foundry-integration.md` |
| 4 — Semantic cache identity scope | 🔴 Security | **Fixed** | `semantic-caching.xml` |
| 5 — Entra Agent ID inventory | 🟡 Governance | Open | Entra + Foundry config |

---

## Consequences

- Gap 4 fix reduces semantic cache hit rate (cache is no longer shared across
  subscribers with identical prompts). Token cost savings may decrease from the
  projected 20–40% to a lower baseline depending on per-LOB prompt diversity.
  This is an acceptable cost for eliminating data leakage risk.
  
- If cache efficiency becomes a measurable concern after deployment, the scoping
  strategy can be relaxed to `context.Product.Id` (tier-level) through a controlled
  change with Security Architecture sign-off.
