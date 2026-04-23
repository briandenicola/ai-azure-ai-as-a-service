# Playbook: Azure AI Gateway — Setup and Operations

**Audience:** Platform Engineers, IT Managers  
**Complexity:** Intermediate

> **All infrastructure is managed via `azd provision`.** This repo uses Azure Developer CLI + Bicep as the single source of truth. Do not create or modify Azure resources through the Portal or ad-hoc `az` commands — they will be overwritten on the next provision. See the [repo README](../../README.md#deploying-the-platform) for the full deploy workflow.

---

## Overview

After `azd provision`, your platform includes:

✅ APIM Premium (Internal VNet) with Bronze / Silver / Gold products  
✅ Token quota enforcement per department  
✅ Semantic caching (reduces costs by ~20–40%)  
✅ Audit logging to Log Analytics (395-day retention)  
✅ Circuit-breaker failover (East US → West US on 429/5xx)  
✅ Managed Identity auth to Foundry — no API keys distributed  

---

## Prerequisites

- [ ] Azure subscription with **Owner** or **User Access Administrator** role
- [ ] [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) installed
- [ ] [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) installed
- [ ] Azure AI Foundry accounts provisioned (see [`infrastructure/bicep/foundry-hub-project.bicep`](../../infrastructure/bicep/foundry-hub-project.bicep))

---

## Step 1: Provision the Platform

All APIM configuration — instance, products, policies, backends, logger, subscriptions — is declared in Bicep and applied with a single command:

```powershell
# Authenticate
az login
azd auth login

# Create your environment (first time only)
azd env new <env-name>

# Configure required flags
azd env set AZURE_DEPLOY_RBAC true
azd env set AZURE_RESOURCE_GROUP rg-contoso-ai-platform

# Provision all infrastructure (~6 minutes)
azd provision --no-prompt
```

**What gets created:**

| Bicep file | What it provisions |
|---|---|
| `infrastructure/bicep/apim-gateway.bicep` | APIM instance, Bronze/Silver/Gold products, global policy, backends, logger |
| `infrastructure/bicep/foundry-hub-project.bicep` | Foundry accounts (East + West), model deployments, AI Search |
| `infrastructure/bicep/foundry-apim-rbac.bicep` | `Cognitive Services User` role for APIM MSI on both Foundry accounts |
| `infrastructure/bicep/networking.bicep` | VNet, subnets, private endpoints, DNS zones |
| `infrastructure/bicep/event-grid-automation.bicep` | Function App, Event Grid topic for subscription lifecycle events |

---

## Step 2: Grant Developer Access (Subscriptions)

APIM subscriptions are created automatically via Event Grid when a developer onboards. The Function App at `automation/functions/apim-subscription-handler/` handles:
- Creating the APIM subscription
- Sending the developer their gateway URL and subscription key
- Updating the ServiceNow CMDB

For manual subscription creation, use the [APIM REST API](https://learn.microsoft.com/en-us/rest/api/apimanagement/subscription/create-or-update) or the `scripts/check-subscriptions.ps1` helper (read-only view) to inspect existing subscriptions.

---

## Step 3: Test the Gateway

Connect to the ACI jumpbox (VNet-internal):

```powershell
az container exec -g rg-contoso-ai-platform -n aci-contoso-jumpbox --exec-command /bin/sh
```

From inside the container:

```bash
# Verify Bronze tier works
curl -s -X POST \
  "https://<apim-name>.azure-api.net/openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-02-01" \
  -H "Content-Type: application/json" \
  -H "Ocp-Apim-Subscription-Key: <bronze-key>" \
  -d '{"messages":[{"role":"user","content":"Hello"}],"max_tokens":50}'
```

Or use the smoke test script from your local machine (requires VPN or App Gateway):

```powershell
.\scripts\smoke-test.ps1
```

---

## Step 4: Verify Audit Logging

All gateway requests are logged to Log Analytics. Check they are flowing:

```bash
az monitor log-analytics query \
  --workspace <workspace-id> \
  --analytics-query "ApiManagementGatewayLogs | limit 10"
```

Or via the Application Insights KQL queries:

```kusto
-- Token usage by department (daily)
customEvents
| where name == "token_consumption"
| summarize TotalTokens = sum(todouble(customDimensions["tokens"]))
    by customDimensions["department"], bin(timestamp, 1d)
| render timechart

-- Latency by model
customEvents
| summarize AvgLatencyMs = avg(todouble(customDimensions["latency"]))
    by customDimensions["model"]
| render columnchart

-- Error rate by department
customEvents
| where customDimensions["status"] == "error"
| summarize ErrorCount = count() by customDimensions["department"]
| render piechart
```

---

## Step 5: Communicate to Developers

When a developer is onboarded, the automation Function App sends a welcome email automatically. The template:

```
Subject: AI Platform Access Granted

Hi [Developer],

Your managed AI platform access is ready.

Gateway URL:      https://<apim-name>.azure-api.net
Subscription Key: [stored in Key Vault — see link below]
App Insights:     [link to your LOB dashboard in Managed Grafana]

Quick start:
  pip install azure-ai-projects azure-identity

  from azure.ai.projects import AIProjectClient
  from azure.identity import DefaultAzureCredential

  client = AIProjectClient(
      credential=DefaultAzureCredential(),
      endpoint="https://<apim-name>.azure-api.net"
  )

All requests are governed by quota, cached for cost reduction,
and logged for audit. No Foundry keys are distributed.

Full guide: https://<internal-wiki>/ai-platform/developer-quickstart
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| 401 on all requests | Missing or wrong subscription key | Check key in Key Vault; re-provision with `azd provision` if missing |
| 403 on a specific model | Model not allowed on your tier | Upgrade APIM product via ServiceNow |
| 429 on inference | TPM quota hit | Check `token-quota-by-department.xml`; adjust capacity in Bicep |
| Foundry returns 503 | Private endpoint not resolved | Verify DNS zone link: `networking.bicep` → `azd provision` |
| No App Insights data | Logger misconfigured | Verify `apim-gateway.bicep` logger resource → `azd provision` |

---

## Related

- [Architecture Decision Record — Why APIM](../adr/adr-001-why-apim.md)
- [Circuit Breaker Policy Guide](../../policies/apim/circuit-breaker-guide.md)
- [Mock Responses for Load Testing](../../policies/apim/mock-responses.md)
- [PCI DSS Configuration](pci-dss-configuration.md)
- [Developer Quick Start](../developer-quickstart.md)
