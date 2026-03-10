# ADR-004: PCI DSS Compliance for AI Models and Foundry Agents via APIM

**Status:** Accepted  
**Date:** 2026-03-10  
**Authors:** Platform Engineering  
**Reviewers:** QSA Engagement Lead, Security Architecture, Payments Engineering Lead

---

## Context

The customer requires PCI DSS v4.0 compliance so that credit card data can be
processed within AI-powered workflows.  Foundry agents and Azure OpenAI models
are central to those workflows and currently route all traffic through Azure API
Management (APIM) — as established in [ADR-001](adr-001-why-apim.md) and
[ADR-002](adr-002-foundry-integration.md).

**The core tension:** AI model backends (Azure OpenAI, Azure AI Foundry) are
managed, multi-tenant services operated by Microsoft.  They are **not** within
a customer's PCI DSS Cardholder Data Environment (CDE) and must **never**
receive raw Primary Account Numbers (PANs), card security codes (CVV/CVC), or
other Sensitive Authentication Data (SAD).

---

## Decision

We extend the APIM gateway to act as a PCI DSS enforcement boundary between
callers (which may possess CHD) and AI model backends (which are outside the CDE).

The architecture follows a **tokenize-then-infer** pattern:

```
Caller (in CDE)
  │  Raw payment data
  ▼
Tokenization Service (PCI-scoped, customer-managed)
  │  Opaque token (e.g., "tok_411111_xxxx_1111")
  ▼
APIM Gateway  ◄── PCI DSS enforcement boundary
  │  PCI policy applied: PAN/CVV detected → request blocked
  │  Audit event emitted to Log Analytics / Event Hub
  ▼
Azure AI Foundry Agent / Azure OpenAI model
  │  Receives token only — never raw CHD
  ▼
APIM Gateway  ◄── Response masked (defense-in-depth)
  │  Any leaked PAN in response → first 6 + last 4 visible, rest masked
  ▼
Caller
```

---

## Consequences

### What changes

| Area | Before | After |
|---|---|---|
| APIM SKU | Standard | **Premium** (required for VNet, availability zones) |
| Network topology | Public APIM endpoint | **Internal VNet mode** — no public gateway traffic |
| Inbound path | Direct to APIM | WAF (App Gateway / Front Door) → APIM internal VNet |
| TLS | TLS 1.2 default | TLS 1.0, 1.1, SSL 3.0 **explicitly disabled**; TLS 1.2+ enforced |
| Encryption at rest | Platform-managed key | **Customer-managed key (CMK)** in Key Vault HSM |
| App Insights | Public ingestion | **Private link** only, local auth disabled |
| Audit retention | 90 days | **395 days** (~13 months; PCI DSS Req 10.5.1) |
| PCI-scoped API product | None | `ai-pci-payment` product with manual approval gate |
| Caching (semantic) | Allowed on all APIs | **Prohibited on PCI-scoped APIs** |
| Tokenization | None | Required by callers before calling PCI-scoped APIs |

### New APIM policies applied to the `ai-pci-payment` product

| Policy file | Purpose | PCI DSS requirements |
|---|---|---|
| `pci-dss-cardholder-data-protection.xml` | PAN/CVV detection + blocking; response masking; no-cache headers; security headers | Req 3.3, 3.4, 3.5, 4.2.1, 6.4, 7 |
| `pci-dss-audit-logging.xml` | Structured audit events for every request (success, failure, error); CHD-free log fields | Req 10.2.1.1–10.2.1.7, 10.3.1, 10.3.2, 10.5.1, 10.7 |

> **Policy chaining order** (always inbound, then base):
> 1. `pci-dss-cardholder-data-protection.xml` — blocks CHD before any other processing
> 2. `pci-dss-audit-logging.xml` — logs clean metadata (never the body)
> 3. `auth-header-validation.xml` — JWT + subscription key validation
> 4. `token-quota-by-department.xml` — rate limiting (body logging must be disabled)
> 5. _Do NOT apply_ `semantic-caching.xml` to PCI-scoped operations

---

## PCI DSS v4.0 Requirement Mapping

### Requirement 1 — Install and maintain network security controls

| Sub-req | Control |
|---|---|
| 1.3 | APIM in **Internal VNet mode** — gateway not reachable from internet. Inbound goes through WAF. |
| 1.3.2 | NSG on APIM subnet: allow inbound from WAF subnet only (port 443), Management port 3443 from internet for Azure Portal. |
| 1.4.1 | No direct path from internet to AI model endpoints — must traverse APIM in VNet. |

**Required NSG rules for APIM subnet:**
```
Priority 100: Allow HTTPS (443)      from WAF subnet         → APIM subnet
Priority 110: Allow Mgmt  (3443)     from ApiManagement tag  → APIM subnet
Priority 200: Allow Azure LB         from AzureLoadBalancer  → APIM subnet
Priority 4096: Deny All              *                       → APIM subnet
```

### Requirement 3 — Protect stored account data

| Sub-req | Control |
|---|---|
| 3.3.1 | APIM policy blocks any request containing a CVV/CVC pattern |
| 3.3.2 | APIM policy blocks any request containing a raw PAN (16-digit card number) |
| 3.4.1 | APIM outbound policy masks any PAN leaked in AI model response (BIN + last 4 visible) |
| 3.5 | `Cache-Control: no-store` enforced on all PCI-scoped API responses |
| 3.7 | APIM encrypted with customer-managed RSA 2048+ key in Key Vault HSM; 90-day rotation via Key Vault rotation policy |

**What the AI model receives in a compliant call:**
```json
// ✅ Correct — token only, no CHD
{
  "messages": [{
    "role": "user",
    "content": "The customer's card tok_411111_xxxx_1111 was declined. What should I do?"
  }]
}

// ❌ Blocked by APIM — raw PAN
{
  "messages": [{
    "role": "user",
    "content": "The customer's card 4111111111111111 was declined. What should I do?"
  }]
}
```

### Requirement 4 — Protect cardholder data with strong cryptography during transmission

| Sub-req | Control |
|---|---|
| 4.2.1 | APIM `customProperties` disable TLS 1.0, TLS 1.1, SSL 3.0. Only TLS 1.2+ accepted. |
| 4.2.1 | APIM-to-backend TLS: `validateCertificateChain: true`, `validateCertificateName: true` |
| 4.2.1 | Triple-DES cipher suite disabled in APIM `customProperties` |

### Requirement 6 — Develop and maintain secure systems and software

| Sub-req | Control |
|---|---|
| 6.4 | Response headers: `Strict-Transport-Security`, `X-Content-Type-Options`, `X-Frame-Options`, `Content-Security-Policy`, `Referrer-Policy` added by APIM policy |
| 6.4 | Infrastructure headers (`Server`, `X-Powered-By`, `X-AspNet-Version`) stripped by policy |
| 6.5.4 | WAF (Application Gateway WAF v2 or Front Door WAF in Prevention mode) in front of APIM |

### Requirement 7 — Restrict access to system components and cardholder data

| Sub-req | Control |
|---|---|
| 7.2 | `ai-pci-payment` APIM product requires **manual approval** and QSA-approved justification |
| 7.2 | `subscriptionsLimit: 1` on the PCI product limits blast radius per subscriber |
| 7.3 | JWT validated by `auth-header-validation.xml`; callers need Entra ID token with correct audience |

### Requirement 8 — Identify and authenticate access to system components

| Sub-req | Control |
|---|---|
| 8.2 | All callers must have an Entra ID identity (`validate-jwt` in auth policy) |
| 8.3 | MFA enforced at Entra ID for developer portal access (Conditional Access policy — Entra side) |
| 8.6 | APIM managed identity used for Key Vault and App Insights — no shared static secrets |

### Requirement 10 — Log and monitor all access to network resources and cardholder data

| Sub-req | Control |
|---|---|
| 10.2.1.1 | Every API call logged: user, IP, resource, outcome |
| 10.2.1.4 | Auth failures (401, 403) emit `AUTH_FAILURE` / `AUTHZ_FAILURE` events with `alert_on_repeat: true` |
| 10.3.1 | Log fields: user ID, event type, timestamp (UTC ISO-8601), outcome, IP, API path, correlation ID |
| 10.3.2 | Logs sent to Log Analytics Workspace; access controlled by RBAC (read-only for most, write for APIM system identity only) |
| 10.5.1 | Diagnostic settings retention: 395 days; App Insights retention: 395 days |
| 10.7 | SIEM alert recommended: ≥ 5 `AUTH_FAILURE` events from same IP/user in 5 min → PagerDuty / Sentinel alert |

### Requirement 12 — Support information security with organizational policies and programs

| Sub-req | Control |
|---|---|
| 12.3.2 | PCI-scoped API product requires annual re-approval of subscriptions |
| 12.3.4 | APIM Premium with availability zones (zone-redundant) for resilience |

---

## What is NOT in scope / Remaining responsibilities

> These items are **caller responsibilities** — they are not enforced by APIM itself.

1. **Tokenization service**: The customer must operate a PCI DSS-scoped tokenization vault (e.g., Braintree, Stripe, or a custom HSM-backed vault). APIM blocks raw PANs but does not perform tokenization.

2. **Foundry agent conversation history**: AI Foundry stores thread history. Verify that no CHD ever appears in thread content by relying on APIM's inbound PAN-blocking policy.  Review Foundry data retention settings.

3. **RAG index / Knowledge Base**: Ensure that no payment data files are indexed in the AI Search instance used by Foundry agents.  Document the ingestion pipeline as out-of-scope for CHD.

4. **Caller application CDE**: The system calling APIM (web app, backend service) is itself a PCI-scoped system if it handles raw CHD before tokenization.  Scope that system with your QSA.

5. **Fine-tuning data**: If any model is fine-tuned, training data must be reviewed for CHD before upload.

6. **WAF configuration**: Application Gateway WAF v2 (or Front Door WAF) must be deployed in Prevention mode with OWASP CRS 3.2+ and custom rules that complement APIM policies.

7. **Key rotation**: Key Vault rotation policy must rotate the APIM CMK at least every 90 days (PCI DSS Req 3.7.1). Configure via Key Vault rotation policy or automate with Event Grid.

8. **Penetration testing**: PCI DSS Req 11.4 requires annual external penetration testing of the CDE boundary (including APIM as a boundary device).

---

## Alternatives Considered

### Alternative A: Standard SKU APIM with PCI policies only
Rejected. Standard SKU does not support VNet injection, which is required for
PCI DSS network segmentation (Req 1.3).  Without VNet, the APIM gateway is
publicly reachable, expanding the CDE attack surface.

### Alternative B: Dedicated APIM instance for PCI workloads
Under consideration for Phase 2 if PCI traffic volume warrants isolation.
For now, the `ai-pci-payment` product within the existing Premium APIM instance
provides sufficient tenant isolation via subscription-level enforcement.

### Alternative C: Azure API Center for PCI governance
Azure API Center can catalog PCI-scoped APIs and enforce governance metadata, but
does not implement runtime policies.  Complementary, not a replacement.

---

## References

- [PCI DSS v4.0 Standard](https://www.pcisecuritystandards.org/document_library/)
- [APIM VNet integration (Internal mode)](https://learn.microsoft.com/azure/api-management/api-management-using-with-internal-vnet)
- [APIM Premium SKU](https://learn.microsoft.com/azure/api-management/api-management-features)
- [APIM Customer-managed keys](https://learn.microsoft.com/azure/api-management/customer-managed-key)
- [Azure AI Foundry data privacy](https://learn.microsoft.com/azure/ai-foundry/concepts/data-privacy)
- ADR-001: [Why APIM](adr-001-why-apim.md)
- ADR-002: [Foundry Integration](adr-002-foundry-integration.md)
- Playbook: [PCI DSS Configuration](../playbooks/pci-dss-configuration.md)
