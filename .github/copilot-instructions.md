# GitHub Copilot Instructions

## Solution Overview

This repo is **Azure AI as a Managed Service** — an enterprise platform that exposes Azure AI (LLMs, Agents) to internal lines-of-business (LOBs) through **Azure API Management (APIM)** as a governed gateway in front of **Azure AI Foundry**.

### Architecture in one sentence
> Developers call a single APIM endpoint with a subscription key. APIM enforces quotas, logs every request, applies semantic caching, and forwards traffic to Foundry over private endpoints using managed identity. No model keys are ever distributed.

### Key components

| Component | What it does |
|---|---|
| **APIM Premium (Internal VNet)** | AI gateway — rate limiting, caching, failover, audit logging, PCI DSS controls |
| **Azure AI Foundry × 2** | Primary (East US) + Secondary (West US); gpt-4o-mini, gpt-4o, Phi-4, Llama-3-70b |
| **Private Endpoints × 2** | Foundry reachable only inside the VNet — no public access |
| **Function App (Flex Consumption)** | APIM subscription event handler — triggered by Event Grid when subscriptions are created/updated |
| **Event Grid** | Publishes APIM subscription lifecycle events to the Function App |
| **Log Analytics (395-day)** | All APIM gateway logs + metrics for audit and PCI DSS Req 10 |
| **Application Insights** | Latency, token counts, HTTP status per request |
| **Managed Grafana** | Token usage and performance dashboards |
| **App Gateway / WAF** | Public ingress in front of APIM for production traffic |
| **ACI Jumpbox** | VNet-internal container for dev/test access to APIM |
| **Key Vault** | CMK for APIM, TLS cert; managed identity access only |

### Subscription tiers (APIM products)

| Tier | APIM product ID | Models | TPM | RPM |
|---|---|---|---|---|
| **Bronze** | `ai-bronze` | gpt-4o-mini, Phi-4 | 500 | 60 |
| **Silver** | `ai-silver` | + gpt-4o, Llama-3-70b, Agents API | 5,000 | 300 |
| **Gold** | `ai-gold` | All models incl. o1; Agents API | 100 M | Unlimited |

### Auth model
- **Client → APIM**: `Ocp-Apim-Subscription-Key` header (one key per LOB/app)
- **APIM → Foundry**: System-assigned managed identity (Entra Bearer token) — no keys stored anywhere
- **Function App → Azure**: `DefaultAzureCredential` (managed identity in production, `az login` locally)

### Developer SDK usage
Developers use the standard OpenAI SDK or `azure-ai-projects` — just swap the endpoint to the APIM URL:
```python
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential
client = AIProjectClient(
    credential=DefaultAzureCredential(),
    endpoint="https://<apim-name>.azure-api.net"
)
```

### Key policies (in `policies/apim/`)
- `circuit-breaker-multi-region.xml` — auto-failover to West US on 429/5xx
- `token-quota-by-department.xml` — per-LOB TPM limits
- `semantic-caching.xml` — cache similar prompts to reduce token spend
- `pci-dss-audit-logging.xml` — PCI DSS Req 10 request logging
- `pci-dss-cardholder-data-protection.xml` — CHD detection/masking

### Code examples (in `examples/`)
- `python/1-simple-chat-via-apim.py` — basic chat through APIM
- `python/2-agent-with-tools.py` — Foundry agent with tool use
- `python/6-foundry-agent-via-apim.py` — Foundry agent routed through APIM
- `csharp/` — equivalent C# examples

### Automation Function App (`automation/functions/apim-subscription-handler/`)
Triggered by Event Grid on APIM subscription lifecycle events. Handles: App Insights resource creation per LOB, Foundry project linking, ServiceNow CMDB updates, developer welcome email.

---

## Infrastructure-as-Code: No Manual Azure Changes

**ALL changes to Azure resources MUST go through `azd deploy` or `azd provision`.**

This project uses Azure Developer CLI (`azd`) with Bicep (`infrastructure/bicep/`) as the single source of truth for all Azure infrastructure and application deployments. Manual one-off changes made directly in the Azure Portal, via `az` CLI resource mutations, or any other out-of-band method will drift from the declared state and will be overwritten on the next provision.

### Rules

1. **Never suggest `az resource update`, `az storage account update`, `az functionapp config`, or similar mutating `az` commands as a fix.** If a resource is misconfigured, find the correct Bicep file in `infrastructure/bicep/` and fix it there, then run `azd provision`.

2. **Never suggest Portal changes.** If a setting needs changing, it goes in Bicep.

3. **Application code changes** → `azd deploy` (re-packages and deploys the Function App zip)

4. **Infrastructure changes** (APIM policies, networking, storage, RBAC, app settings) → edit the relevant Bicep file, then `azd provision`.

5. **Policy changes** (APIM XML policies in `policies/apim/`) → Bicep references them; run `azd provision` to push updates.

6. **RBAC assignments** → defined in `infrastructure/bicep/foundry-apim-rbac.bicep` or `event-grid-automation.bicep`. Do not assign roles ad hoc with `az role assignment create` as a permanent fix.

### Key files

| What to change | File |
|---|---|
| Function App, storage, Event Grid | `infrastructure/bicep/event-grid-automation.bicep` |
| APIM gateway, products, subscriptions | `infrastructure/bicep/apim-gateway.bicep` |
| Networking, private endpoints | `infrastructure/bicep/networking.bicep` |
| RBAC for Foundry / APIM | `infrastructure/bicep/foundry-apim-rbac.bicep` |
| Key Vault, supporting resources | `infrastructure/bicep/supporting-infra.bicep` |
| Top-level wiring | `infrastructure/bicep/main.bicep` |

### Deploy commands

```bash
# Deploy application code only (fast)
azd deploy

# Provision infrastructure (Bicep) + deploy code
azd provision && azd deploy

# Full up (provision + deploy in one command)
azd up
```

### When diagnosing a broken deployment

Before suggesting an `az` CLI mutation as a fix:
1. Check whether the Bicep already declares the correct value.
2. If yes → the Azure resource has drifted. Run `azd provision` to reconcile — do not patch Azure directly.
3. If no → update the Bicep, commit, then run `azd provision`.

> **Example of what NOT to do**: `az storage account update --public-network-access Enabled`  
> **Correct approach**: Verify `event-grid-automation.bicep` has `publicNetworkAccess: 'Enabled'`, commit if needed, run `azd provision`.
