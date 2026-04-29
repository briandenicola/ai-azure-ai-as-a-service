# Applying This Pattern to an Existing APIM + Foundry Platform

This repo is a **greenfield reference deployment** — everything is provisioned from scratch via `azd provision`. If your team already has APIM and Azure AI Foundry running in production, you do not need to redeploy anything. You apply the pattern incrementally, one piece at a time.

This guide walks through each layer in order of risk (read-only first, configuration last) with the exact changes required for each.

---

## What This Pattern Actually Adds

If you already have APIM in front of Foundry, you are likely missing some or all of these:

| Capability | Where it lives | Risk to add |
|---|---|---|
| `ApiManagementGatewayLogs` → Log Analytics | APIM diagnostic settings | Zero — read-only logging |
| `AGWAccessLogs` → Log Analytics | App Gateway diagnostic settings | Zero — read-only logging |
| App Insights wired to APIM | APIM diagnostics resource | Low — adds telemetry, no traffic impact |
| `X-Correlation-Id` header | App Gateway rewrite rule set | Low — adds a header, never blocks traffic |
| `X-Backend-Region-Used` header | APIM policy (outbound section) | Low — adds a response header |
| Circuit-breaker failover policy | APIM policy (per-API) | Medium — changes routing logic |
| Semantic caching policy | APIM policy (per-API) | Medium — new external dependency (Redis) |
| Token quota policy | APIM product policy | Medium — rate-limiting, will return 429 |
| Workbooks | Azure Monitor | Zero — read-only; just deploys dashboards |

Work top-to-bottom. The workbooks will light up incrementally as each layer is added.

---

## Step 1 — Enable `ApiManagementGatewayLogs` in Log Analytics

This is the **most important step** — it populates the tables that both workbooks depend on.

### Check whether it is already enabled

```powershell
$apimId = az apim show -n <your-apim-name> -g <your-rg> --query id -o tsv
az monitor diagnostic-settings list --resource $apimId --query "[].logs[?enabled].category" -o tsv
```

Look for `GatewayLogs` in the output. If it is missing, add it.

### Add the diagnostic setting (Bicep — preferred)

Find the Bicep file that manages your APIM instance and add:

```bicep
resource apimDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: apim                           // reference your existing APIM resource
  name: 'gateway-logs-to-law'
  properties: {
    workspaceId: logAnalyticsWorkspaceId  // your existing LAW resource ID
    logAnalyticsDestinationType: 'Dedicated'   // creates ApiManagementGatewayLogs table
                                               // NOT the generic AzureDiagnostics table
    logs: [
      { category: 'GatewayLogs',            enabled: true }
      { category: 'DeveloperPortalAuditLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}
```

> **Important:** `logAnalyticsDestinationType: 'Dedicated'` creates the resource-specific table `ApiManagementGatewayLogs`. If you omit this (or set it to `AzureDiagnostics`), the workbook KQL queries will not find data because they query the dedicated table by name.

If you have an existing diagnostic setting that sends to `AzureDiagnostics`, you can add a second setting alongside it pointing to dedicated tables — both can coexist.

### Verify tables exist (after ~5 minutes of traffic)

```kql
// In Log Analytics — run in Azure Monitor → Logs
ApiManagementGatewayLogs
| take 5
```

If this returns rows, Step 1 is complete.

---

## Step 2 — Enable `AGWAccessLogs` in Log Analytics

Required for the **E2E Trace workbook** to show the App Gateway layer. Skip this step if you do not have App Gateway in front of APIM.

```bicep
resource appGwDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: appGateway
  name: 'appgw-logs-to-law'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'   // creates AGWAccessLogs table
    logs: [
      { category: 'ApplicationGatewayAccessLog',   enabled: true }
      { category: 'ApplicationGatewayFirewallLog',  enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}
```

Verify:

```kql
AGWAccessLogs
| take 5
```

---

## Step 3 — Wire App Insights to APIM

This populates `AppRequests` and `AppDependencies` — the tables used for per-request latency breakdown and the E2E Trace workbook.

### 3a — Create a workspace-based App Insights instance

If you already have an App Insights instance, check whether it is workspace-based:

```powershell
az monitor app-insights component show -a <app-insights-name> -g <rg> --query "workspaceResourceId" -o tsv
```

If this returns empty, your instance is Classic (deprecated). Migrate it to workspace-based or create a new one:

```bicep
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'apim-ai-telemetry'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspaceId   // same LAW as Step 1
    IngestionMode: 'LogAnalytics'
    RetentionInDays: 365
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery:     'Enabled'
  }
}
```

### 3b — Create an APIM logger pointing to App Insights

```bicep
resource appInsightsLogger 'Microsoft.ApiManagement/service/loggers@2023-05-01-preview' = {
  parent: apim
  name: 'ai-logger'
  properties: {
    loggerType: 'applicationInsights'
    description: 'Application Insights logger for AI gateway telemetry'
    resourceId: appInsights.id
    isBuffered: true
    credentials: {
      // Use connection string + managed identity, NOT instrumentationKey.
      // If DisableLocalAuth is true on the App Insights resource (recommended),
      // key-based auth is rejected — APIM must authenticate via its system-assigned
      // managed identity. 'SystemAssigned' is a literal string, not a variable.
      connectionString: appInsights.properties.ConnectionString
      identityClientId: 'SystemAssigned'
    }
  }
}
```

> **Note:** If your App Insights instance has `DisableLocalAuth: false` (the default in older deployments), you can use `instrumentationKey: appInsights.properties.InstrumentationKey` instead. However, enabling `DisableLocalAuth` and switching to managed identity is the recommended production posture — it eliminates a static credential from your configuration.

### 3c — Create the APIM diagnostics resource

This is the most important part — it tells APIM which headers to capture so the workbook join works:

```bicep
resource apimAppInsightsDiagnostics 'Microsoft.ApiManagement/service/diagnostics@2023-05-01-preview' = {
  parent: apim
  name: 'applicationinsights'         // must be exactly this string
  properties: {
    loggerId: appInsightsLogger.id
    alwaysLog: 'allErrors'
    sampling: {
      samplingType: 'fixed'
      percentage: 100                  // lower to 10 on high-volume production
    }
    verbosity: 'information'           // never 'verbose' — logs body content
    httpCorrelationProtocol: 'W3C'
    operationNameFormat: 'Url'
    frontend: {
      request: {
        headers: [ 'X-Correlation-Id' ]
        body: { bytes: 0 }
      }
      response: {
        // These four headers drive the workbook panels:
        //   X-Backend-Region-Used → which Foundry region served the request
        //   X-Correlation-Id      → join key between AGWAccessLogs and AppRequests
        //   X-Tokens-Used         → token quota utilization panel
        //   X-Cache               → semantic cache hit rate panel
        headers: [ 'X-Backend-Region-Used', 'X-Correlation-Id', 'X-Tokens-Used', 'X-Cache' ]
        body: { bytes: 0 }
      }
    }
    backend: {
      request:  { headers: [ 'X-Correlation-Id' ], body: { bytes: 0 } }
      response: { headers: [ 'X-Backend-Region-Used', 'X-Correlation-Id' ], body: { bytes: 0 } }
    }
  }
}
```

**The `name: 'applicationinsights'` value is a reserved keyword in APIM** — this is what links the logger to all API calls automatically. There can only be one resource with this name per APIM instance.

If a diagnostics resource already exists with `name: 'applicationinsights'`, update it in-place with the additional headers rather than creating a new one.

---

## Step 4 — Add the `X-Correlation-Id` Header (App Gateway)

The E2E Trace workbook joins `AGWAccessLogs` to `AppRequests` using the `X-Correlation-Id` header. App Gateway needs a rewrite rule to stamp this header on every forwarded request.

Add a rewrite rule set to your App Gateway Bicep:

```bicep
// In your Application Gateway resource properties:
rewriteRuleSets: [
  {
    name: 'inject-correlation-id'
    properties: {
      rewriteRules: [
        {
          name: 'add-x-correlation-id'
          ruleSequence: 100
          conditions: []
          actionSet: {
            requestHeaderConfigurations: [
              {
                headerName: 'X-Correlation-Id'
                // Combines client IP + source port — unique for every active connection
                headerValue: '{var_client_ip}-{var_client_port}'
              }
            ]
            responseHeaderConfigurations: [
              {
                headerName: 'X-Correlation-Id'
                headerValue: '{var_client_ip}-{var_client_port}'
              }
            ]
          }
        }
      ]
    }
  }
]
```

Then attach the rewrite rule set to each routing rule:

```bicep
// In each requestRoutingRules entry:
rewriteRuleSet: {
  id: resourceId('Microsoft.Network/applicationGateways/rewriteRuleSets',
                  appGwName, 'inject-correlation-id')
}
```

**This change is safe to deploy live.** Rewrite rules only add headers — they never block traffic or change routing. If a request already carries `X-Correlation-Id` from the client, the `override` action replaces it with the App Gateway value (preventing client-controlled correlation injection).

---

## Step 5 — Add `X-Backend-Region-Used` to Your APIM Policy

The Backend Routing Report workbook splits traffic by `primary` vs `secondary` using this response header. Add it to your API-level outbound policy wherever you route between Foundry endpoints:

```xml
<!-- In your outbound policy, after the backend routing logic.
     Reads the 'selectedBackend' policy variable set in your inbound section
     when you chose which Foundry endpoint to target. -->
<outbound>
  <base />
  <set-header name="X-Backend-Region-Used" exists-action="override">
    <value>@(context.Variables.GetValueOrDefault("selectedBackend", "primary"))</value>
  </set-header>
</outbound>
<on-error>
  <base />
  <set-header name="X-Backend-Region-Used" exists-action="override">
    <value>@(context.Variables.GetValueOrDefault("selectedBackend", "unknown"))</value>
  </set-header>
</on-error>
```

In your inbound section you should already have a `<set-variable name="selectedBackend" ...>` that tracks which endpoint was chosen. If you are routing via a simple `<set-backend-service>` without a named variable, add the variable alongside it:

```xml
<inbound>
  <base />
  <!-- your existing routing logic -->
  <set-backend-service base-url="https://<your-foundry>.services.ai.azure.com/openai" />
  <set-variable name="selectedBackend" value="primary" />
</inbound>
```

The workbook will still work with a static `"primary"` value — the Backend Switch Events table just won't show any failover rows.

---

## Step 6 — Deploy the Workbooks

The workbooks are Azure Monitor Workbooks (JSON files). You can deploy them without touching your APIM or Foundry configuration — they are purely read-only dashboards.

### Option A — Bicep (recommended, idempotent)

Copy `infrastructure/bicep/workbooks.bicep` and both files from `observability/workbooks/` into your own repo. Update the `placeholderWorkspaceId` variable to match your Log Analytics workspace resource ID:

```bicep
// In workbooks.bicep — replace this value with your LAW resource ID:
var placeholderWorkspaceId = '/subscriptions/<your-sub>/resourceGroups/<your-rg>/providers/Microsoft.OperationalInsights/workspaces/<your-law-name>'
```

Then include the module in your `main.bicep`:

```bicep
module workbooks 'workbooks.bicep' = {
  name: 'workbooks'
  params: {
    location: location
    logAnalyticsWorkspaceId: law.id
    tags: tags
  }
}
```

### Option B — Azure Portal (one-time, no Bicep required)

1. Open **Azure Monitor → Workbooks → New**
2. Click the `</>` (Advanced Editor) button
3. Paste the contents of `observability/workbooks/backend-routing-report.workbook.json`
4. Replace every occurrence of the placeholder workspace resource ID with your own LAW resource ID (find/replace on the subscription GUID)
5. Save and pin to a dashboard

Repeat for `e2e-trace.workbook.json`.

### What you will see immediately

After deploying workbooks against an existing APIM that already had `GatewayLogs` flowing:

- **Backend Routing Report panels 1–5, 7, and 8** — populated immediately (data is in `ApiManagementGatewayLogs`)
- **Panel 6 (Full Chain Latency — joined with AGWAccessLogs)** — populated once Step 2 is done and App Gateway logs are flowing
- **E2E Trace panels 1–5** — populated once Step 3 is done (App Insights wired up)
- **E2E Trace panel 10 (waterfall per request)** — needs both Step 3 and Step 4 (`X-Correlation-Id` header)
- **E2E Trace panel 12 (cache hit rate)** — needs `X-Cache` header in your APIM policy (Step 7b below)
- **E2E Trace panel 13 (token quota)** — needs `X-Tokens-Used` header (Step 7c below)

---

## Step 7 — Optional: Circuit Breaker, Caching, and Token Policies

These are the operational policies in `policies/apim/`. They are **independent of the workbooks** — the dashboards work without them. Apply them only if you want the corresponding capability.

### 7a — Circuit Breaker Failover (`circuit-breaker-multi-region.xml`)

Automatically fails over to a secondary Foundry endpoint when the primary returns 429 or 5xx. Requires two Foundry deployments.

Apply at the API scope on your OpenAI inference API. See `policies/apim/circuit-breaker-multi-region.xml` for the full policy. You need two APIM Named Values:

```
foundry-primary-endpoint   = https://<primary-foundry>.services.ai.azure.com
foundry-secondary-endpoint = https://<secondary-foundry>.services.ai.azure.com
```

APIM must have **Cognitive Services User** role on both Foundry accounts:

```powershell
$apimPid = az apim show -n <apim-name> -g <rg> --query identity.principalId -o tsv

az role assignment create `
  --role "a97b65f3-24c7-4388-baec-2e87135dc908" `
  --assignee $apimPid `
  --scope /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<foundry-primary>

az role assignment create `
  --role "a97b65f3-24c7-4388-baec-2e87135dc908" `
  --assignee $apimPid `
  --scope /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<foundry-secondary>
```

In production, add these role assignments to Bicep rather than using the `az` CLI. See `infrastructure/bicep/foundry-apim-rbac.bicep` for the template.

### 7b — Semantic Caching (`semantic-caching.xml`)

Caches semantically similar prompts to reduce token spend. Requires Azure Cache for Redis with the vector search module. Adds `X-Cache: HIT|MISS` to responses, which populates the cache hit rate panel in the E2E Trace workbook.

### 7c — Token Quota by Department (`token-quota-by-department.xml`)

Enforces per-LOB token-per-minute limits. Add `X-Tokens-Used` to your outbound policy to populate the token quota panel in the E2E Trace workbook:

```xml
<outbound>
  <base />
  <!-- Emit token count from Foundry's usage response -->
  <set-header name="X-Tokens-Used" exists-action="override">
    <value>@{
      var body = context.Response.Body.As<JObject>(preserveContent: true);
      return body?["usage"]?["total_tokens"]?.ToString() ?? "0";
    }</value>
  </set-header>
</outbound>
```

### 7d — PCI DSS Audit Logging

See `policies/apim/pci-dss-audit-logging.xml` and `docs/playbooks/pci-dss-configuration.md`. This enables logging at the detail level required for PCI DSS Requirement 10. Apply only if your API gateway is in PCI DSS scope.

---

## Prerequisites Checklist

Before starting, confirm you have:

- [ ] APIM instance (any SKU except Consumption for VNet scenarios; Premium for internal VNet)
- [ ] Log Analytics Workspace (PerGB2018 SKU; 395-day retention for PCI, 90-day minimum otherwise)
- [ ] App Insights instance linked to the same LAW (workspace-based, not Classic)
- [ ] App Gateway v2 (WAF_v2 SKU) if you want the E2E Trace workbook AppGW layer
- [ ] Bicep access (Owner or Contributor + User Access Administrator on the resource group)
- [ ] APIM system-assigned managed identity enabled (`identity.type: 'SystemAssigned'` in Bicep)

Check managed identity:

```powershell
az apim show -n <apim-name> -g <rg> --query identity -o json
```

If `principalId` is null, the system-assigned identity is not enabled. Enable it in your Bicep:

```bicep
identity: {
  type: 'SystemAssigned'
}
```

---

## Log Analytics Table Reference

These are the tables queried by the workbooks. Once each step above is complete, the corresponding tables will exist:

| Table | Populated by | Step | Workbook |
|---|---|---|---|
| `ApiManagementGatewayLogs` | APIM diagnostic settings → LAW (Dedicated mode) | Step 1 | Both |
| `AGWAccessLogs` | App Gateway diagnostic settings → LAW | Step 2 | E2E Trace (AppGW layer) |
| `AGWFirewallLogs` | App Gateway diagnostic settings → LAW | Step 2 | E2E Trace (WAF panel) |
| `AppRequests` | APIM App Insights diagnostics (inbound span) | Step 3 | E2E Trace |
| `AppDependencies` | APIM App Insights diagnostics (backend call to Foundry) | Step 3 | E2E Trace |

All tables land in the same Log Analytics workspace. You can verify any table exists:

```kql
search *
| where $table in ("ApiManagementGatewayLogs", "AGWAccessLogs", "AppRequests", "AppDependencies")
| summarize count() by $table
```

---

## What Breaks If a Step Is Skipped

| Skipped step | What stops working |
|---|---|
| Step 1 (GatewayLogs) | Both workbooks show no data. Nothing else works without this. |
| Step 2 (AGWAccessLogs) | AppGW latency columns in E2E Trace are blank. WAF panel is empty. |
| Step 3 (App Insights) | All E2E Trace panels are empty. Backend Routing Report still works. |
| Step 4 (X-Correlation-Id) | E2E Trace waterfall panel (Panel 10) shows no per-request breakdown. |
| Step 5 (X-Backend-Region-Used) | Backend Routing Report shows all traffic as "primary" — failover is invisible. |
| Step 7b (X-Cache header) | E2E Trace Panel 12 (cache hit rate) is empty. |
| Step 7c (X-Tokens-Used header) | E2E Trace Panel 13 (token quota) is empty. |
