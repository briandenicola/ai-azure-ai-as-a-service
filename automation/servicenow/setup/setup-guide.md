# ServiceNow Integration Setup Guide

This guide walks you through connecting your ServiceNow PDI instance to the Azure AI as a Service platform so that model access requests, quota increases, and tool integrations flow through ServiceNow for governance and approval.

---

## Architecture overview

```
Developer submits request
        │
        ▼
ServiceNow (intake + approval)
        │  approval
        ▼
Azure Function App ──► APIM subscription provisioned
        │
        ▼
ServiceNow CMDB updated + welcome email sent
```

**Inbound** (Azure → ServiceNow): The Function App POSTs subscription lifecycle events to a Scripted REST API endpoint on your ServiceNow instance.

**Outbound** (ServiceNow → Azure): When a governance ticket is approved, a Business Rule calls the outbound REST Message to notify the Function App.

---

## Prerequisites

| Requirement | Details |
|---|---|
| Python 3.10+ | `python --version` |
| `requests` library | `pip install requests` |
| ServiceNow PDI admin password | Set on first login at `<instance>.service-now.com` |
| Azure Function App URL | From the Azure Portal read-only view or `azd env get-values` |
| Azure Function App host key | From the Azure Portal read-only view or Key Vault |

> **Finding the Function App URL and host key**: Run `azd env get-values` in the repo root to list all environment outputs, including `AZURE_FUNCTION_URL`. The host key is stored in Key Vault — look for a secret named `function-host-key` in the Key Vault output from `azd provision`.

---

## Step 1 — Note your instance URL and credentials

Your ServiceNow PDI instance URL is shown after login, for example:
```
https://dev389009.service-now.com
```

On a fresh PDI, ServiceNow forces a password change on first login. Complete that before running the scripts.

---

## Step 2 — Install the Python dependency

```bash
pip install requests
```

---

## Step 3 — Run bootstrap.py

`bootstrap.py` provisions all required ServiceNow resources in a single run. It is **idempotent** — safe to re-run if interrupted.

```bash
cd automation/servicenow/setup

python bootstrap.py \
  --instance https://dev389009.service-now.com \
  --username admin \
  --password <your-admin-password> \
  --function-app-url https://<funcapp>.azurewebsites.net/api/apim-subscription-handler \
  --function-app-key <host-key>
```

Alternatively, export environment variables and omit the flags:

```bash
export SN_INSTANCE=https://dev389009.service-now.com
export SN_USERNAME=admin
export SN_PASSWORD=<password>
export AZURE_FUNCTION_URL=https://<funcapp>.azurewebsites.net/api/apim-subscription-handler
export AZURE_FUNCTION_KEY=<host-key>

python bootstrap.py
```

### What bootstrap.py creates

| # | Resource | Type |
|---|---|---|
| 1 | `u_ai_model_requests` | Custom table (extends task) |
| 1 | `u_ai_quota_requests` | Custom table (extends task) |
| 1 | `u_ai_tool_requests` | Custom table (extends task) |
| 2 | AI Governance | Assignment group (`sys_user_group`) |
| 3 | `AzureAIServiceEvents` | Inbound Scripted REST API (`sys_ws_definition`) |
| 4 | `AzureFunctionApp_APIMHandler` | Outbound REST Message (`sys_rest_message`) |

Expected output (first run):

```
ServiceNow Bootstrap — https://dev389009.service-now.com
=================================================================
[1/5] Creating custom tables...
  ✅ Created table: u_ai_model_requests
       → 7 columns added
  ✅ Created table: u_ai_quota_requests
       → 8 columns added
  ✅ Created table: u_ai_tool_requests
       → 10 columns added

[2/5] Creating AI Governance assignment group...
  ✅ Created group: AI Governance

[3/5] Creating inbound Scripted REST API (Azure → ServiceNow)...
  ✅ Created API: AzureAIServiceEvents
  ✅ Resource: POST /api/x_<scope>/azure_ai_service_events/subscription

[4/5] Creating outbound REST Message (ServiceNow → Azure)...
  ✅ Created: AzureFunctionApp_APIMHandler
  ✅ HTTP function 'notifyApproval' created with x-functions-key header

[5/5] Verifying all resources...
  ✅ Table  u_ai_model_requests
  ✅ Table  u_ai_quota_requests
  ✅ Table  u_ai_tool_requests
  ✅ Group  AI Governance
  ✅ Inbound webhook API
  ✅ Outbound REST Message
=================================================================
✅ Bootstrap complete — ServiceNow integration is ready.
```

---

## Step 4 — Run verify.py

`verify.py` confirms every resource exists and discovers the application scope prefix for the webhook URL.

```bash
python verify.py \
  --instance https://dev389009.service-now.com \
  --username admin \
  --password <password>
```

Note the webhook URL printed at the end, for example:
```
✅ Inbound webhook URL:
   https://dev389009.service-now.com/api/x_12345_azureai/azure_ai_service_events/subscription
```

Copy this URL — you need it in Step 5.

---

## Step 5 — Configure the Azure Function App environment variables

The Function App needs the ServiceNow instance and webhook URL to call back after processing events.

Edit `infrastructure/bicep/event-grid-automation.bicep` and add these values to the `appSettings` block:

```bicep
{
  name: 'SN_INSTANCE'
  value: 'https://dev389009.service-now.com'
}
{
  name: 'SN_WEBHOOK_URL'
  value: 'https://dev389009.service-now.com/api/x_<scope>/azure_ai_service_events/subscription'
}
```

Replace `x_<scope>` with the scope prefix from `verify.py`.

Then provision:

```bash
azd provision
```

> **IaC policy**: All Function App configuration must go through Bicep + `azd provision`. Do not set app settings in the Azure Portal or via `az functionapp config appsettings set`.

---

## Step 6 — Add a ServiceNow credential to the Function App (optional)

If you want the Function App to create records directly in ServiceNow (not just receive webhooks), add credentials to Key Vault and reference them from Bicep. Do not store passwords in app settings plain text.

Suggested Key Vault secrets (create via `az keyvault secret set` locally, then reference from Bicep):

```
sn-username   → admin
sn-password   → <your-admin-password>
```

Reference from Bicep:

```bicep
{
  name: 'SN_USERNAME'
  value: '@Microsoft.KeyVault(SecretUri=${keyVault.properties.vaultUri}secrets/sn-username/)'
}
```

---

## How the end-to-end flow works

### Model access request flow

1. Developer submits a model access request using `automation/servicenow/model_request_workflow.py:ServiceNowClient.create_model_request()`.
2. A record is created in `u_ai_model_requests` with state = Open.
3. The AI Governance group receives the assignment.
4. Approver reviews and approves. The approval triggers the outbound REST Message (`notifyApproval`).
5. The Azure Function App receives the event, provisions the APIM subscription, and updates the ServiceNow record with the subscription key.
6. Developer receives a welcome email (implemented in `automation/functions/apim-subscription-handler/__init__.py`).

### Quota increase flow

Uses the `u_ai_quota_requests` table and `automation/servicenow/quota_increase_workflow.py:QuotaManager`. Urgency routing:

| Est. monthly cost increase | Urgency | Approver |
|---|---|---|
| > $1,000 | High | VP |
| > $100 | Medium | Manager |
| ≤ $100 | Low | Auto-approved |

### Tool integration flow

Uses `u_ai_tool_requests` and `automation/servicenow/tool_integration_workflow.py:ToolIntegrationManager`. Security review is required for tools accessing cardholder data (flagged via `u_security_review_required`).

---

## Troubleshooting

### 401 Unauthorized from bootstrap.py or verify.py

- Confirm the password was changed from the PDI default on first login.
- PDIs reset every 10 days — if the instance was recycled, the password may have reverted.
- Check: `curl -u admin:<password> https://<instance>.service-now.com/api/now/table/sys_user?sysparm_limit=1`

### 404 on a table (e.g. `u_ai_model_requests`)

The table DDL may not have committed before the column records were written. Re-run `bootstrap.py` — it is idempotent and will skip existing resources.

### Webhook returns 404 after setup

The scope prefix may differ from what `verify.py` detected. Check the exact URL by navigating to:
```
<instance>.service-now.com/nav_to.do?uri=sys_ws_definition_list.do
```
Click the `AzureAIServiceEvents` record and note the **REST endpoint** field.

### PDI recycled (instance reset every 10 days)

Personal Developer Instances are recycled after 10 days of inactivity. All custom tables and scripts are lost. Re-run `bootstrap.py` after the instance is restored.

To prevent recycling: log in to developer.servicenow.com at least once every 10 days and click "Wake Instance".

### Function App not receiving events

1. Confirm Event Grid subscription is pointing to the correct Function App URL (`azd env get-values`).
2. Check Event Grid delivery failures in the Azure Portal (read-only) or via Log Analytics.
3. Confirm the Function App host key in the outbound REST Message header matches the current key (`verify.py` does not test the outbound call end-to-end — check Function App logs in Application Insights).

---

## Reference

| File | Purpose |
|---|---|
| `automation/servicenow/setup/bootstrap.py` | One-shot provisioning script |
| `automation/servicenow/setup/verify.py` | Post-setup verification script |
| `automation/servicenow/model_request_workflow.py` | Model access request client |
| `automation/servicenow/quota_increase_workflow.py` | Quota increase workflow |
| `automation/servicenow/tool_integration_workflow.py` | Tool integration workflow |
| `automation/functions/apim-subscription-handler/` | Azure Function App (Event Grid trigger) |
| `infrastructure/bicep/event-grid-automation.bicep` | Function App + Event Grid Bicep |
| `docs/adr/adr-003-servicenow-workflow.md` | Architecture Decision Record |
