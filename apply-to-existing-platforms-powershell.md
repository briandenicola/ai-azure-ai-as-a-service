# Applying This Pattern to an Existing APIM + Foundry Platform (PowerShell)

This repo is a **greenfield reference deployment** — everything is provisioned from scratch via `azd provision`. If your team already has APIM and Azure AI Foundry running in production, you do not need to redeploy anything. You apply the pattern incrementally, one piece at a time.

This guide is the **PowerShell edition** — every change is applied via ARM REST API calls using `Invoke-RestMethod` and the Azure CLI. No IaC toolchain required. See `apply-to-existing-platforms-bicep.md` or `apply-to-existing-platforms-tf.md` if you want idempotent infrastructure-as-code alternatives.

---

## Two Ways to Use This Guide

### Option A — Run the interactive script (recommended)

`scripts/apply-observability.ps1` automates all five changes in this guide. It checks current state before applying each change, skips anything already configured, and prompts for confirmation before making any modifications.

```powershell
# Interactive menu — choose which changes to apply
pwsh scripts/apply-observability.ps1

# Apply a specific change non-interactively
pwsh scripts/apply-observability.ps1 -Change 1

# Apply changes 1–3 in sequence (zero + low risk only)
pwsh scripts/apply-observability.ps1 -Change All

# Skip confirmation prompts (CI/CD or scripted runs)
pwsh scripts/apply-observability.ps1 -Change All -Force
```

The script auto-discovers your APIM, App Gateway, Log Analytics workspace, and App Insights instance from the resource group. If it cannot find them, it prompts interactively.

### Option B — Manual PowerShell (surgical, one change at a time)

Each step below includes the raw ARM REST API call you can run directly without the script. Use this when you want to apply a single change to a specific environment without running the full script.

---

## Prerequisites

Before running either option:

```powershell
# 1. Log in
az login
az account set --subscription <your-subscription-id>

# 2. Confirm you can reach your resources
az apim show -n <your-apim> -g <your-rg> --query name -o tsv
az network application-gateway show -n <your-appgw> -g <your-rg> --query name -o tsv
az monitor log-analytics workspace show -g <your-rg> -n <your-law> --query customerId -o tsv

# 3. Get an ARM bearer token (used in manual steps below)
$t = az account get-access-token --query accessToken -o tsv
```

### Optional: set values once in `scripts/platform.env`

Copy `scripts/platform.env.example` to `scripts/platform.env` and fill in your values. All scripts that dot-source `scripts/_resolve-env.ps1` (including `apply-observability.ps1`) will pick them up automatically — no `-ResourceGroup` flags needed on every run.

```powershell
# scripts/platform.env
AZURE_SUBSCRIPTION_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
AZURE_RESOURCE_GROUP=rg-your-platform
APIM_NAME=apim-your-instance           # optional — auto-discovered if blank
```

This file is gitignored and will never be committed.

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
| `X-Model-Name` header + model latency workbook | APIM policy (both inference APIs) + APIM diagnostics | Low — adds a response header |
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
$apimId = az apim show -n <your-apim> -g <your-rg> --query id -o tsv
az monitor diagnostic-settings list --resource $apimId `
    --query "[].logs[?enabled].category" -o tsv
```

Look for `GatewayLogs` in the output. If it is missing, apply this change.

### Apply via script

```powershell
pwsh scripts/apply-observability.ps1 -Change 1
```

The script checks for an existing setting first and skips if `GatewayLogs` is already flowing to your LAW.

### Apply manually (ARM REST API)

```powershell
$SUB_ID  = az account show --query id -o tsv
$RG      = "rg-your-platform"
$apimId  = az apim show -n <your-apim> -g $RG --query id -o tsv
$lawId   = az monitor log-analytics workspace show -g $RG -n <your-law> --query id -o tsv
$t       = az account get-access-token --query accessToken -o tsv

$uri  = "https://management.azure.com$apimId/providers/Microsoft.Insights/diagnosticSettings/gateway-logs-to-law?api-version=2021-05-01-preview"
$body = @{
    properties = @{
        workspaceId                 = $lawId
        logAnalyticsDestinationType = "Dedicated"   # creates ApiManagementGatewayLogs table
                                                     # NOT the generic AzureDiagnostics table
        logs = @(
            @{ category = "GatewayLogs";              enabled = $true }
            @{ category = "DeveloperPortalAuditLogs"; enabled = $true }
        )
        metrics = @(@{ category = "AllMetrics"; enabled = $true })
    }
} | ConvertTo-Json -Depth 10

Invoke-RestMethod -Method PUT -Uri $uri -Body $body `
    -Headers @{ Authorization = "Bearer $t"; "Content-Type" = "application/json" }
```

> **Important:** `logAnalyticsDestinationType = "Dedicated"` creates the resource-specific table `ApiManagementGatewayLogs`. If you omit this, the workbook KQL queries will not find data — they query the dedicated table by name, not `AzureDiagnostics`.

If you have an existing diagnostic setting that sends to `AzureDiagnostics`, you can create a second setting alongside it with a distinct name pointing to dedicated tables — both coexist safely.

### Verify (after ~5 minutes of traffic)

```kql
ApiManagementGatewayLogs
| take 5
```

---

## Step 2 — Enable `AGWAccessLogs` in Log Analytics

Required for the **E2E Trace workbook** to show the App Gateway layer. Skip this step if you do not have App Gateway in front of APIM.

### Check whether it is already enabled

```powershell
$appgwId = az network application-gateway show -n <your-appgw> -g <your-rg> --query id -o tsv
az monitor diagnostic-settings list --resource $appgwId `
    --query "[].logs[?enabled].category" -o tsv
```

### Apply via script

```powershell
pwsh scripts/apply-observability.ps1 -Change 2
```

### Apply manually

```powershell
$appgwId = az network application-gateway show -n <your-appgw> -g $RG --query id -o tsv

$uri  = "https://management.azure.com$appgwId/providers/Microsoft.Insights/diagnosticSettings/appgw-logs-to-law?api-version=2021-05-01-preview"
$body = @{
    properties = @{
        workspaceId                 = $lawId
        logAnalyticsDestinationType = "Dedicated"   # creates AGWAccessLogs table
        logs = @(
            @{ category = "ApplicationGatewayAccessLog";    enabled = $true }
            @{ category = "ApplicationGatewayFirewallLog";  enabled = $true }
            @{ category = "ApplicationGatewayPerformanceLog"; enabled = $true }
        )
        metrics = @(@{ category = "AllMetrics"; enabled = $true })
    }
} | ConvertTo-Json -Depth 10

Invoke-RestMethod -Method PUT -Uri $uri -Body $body `
    -Headers @{ Authorization = "Bearer $t"; "Content-Type" = "application/json" }
```

### Verify

```kql
AGWAccessLogs
| take 5
```

---

## Step 3 — Wire App Insights to APIM

This populates `AppRequests` and `AppDependencies` — the tables used for per-request latency breakdown and the E2E Trace workbook.

### 3a — Confirm your App Insights instance is workspace-based

```powershell
az monitor app-insights component show -a <your-ai> -g <your-rg> `
    --query workspaceResourceId -o tsv
```

If this returns empty, the instance is Classic (deprecated). The workbook tables (`AppRequests`, `AppDependencies`) are only populated by workspace-based instances. Migrate to workspace-based or create a new one before continuing — see Step 3a in `apply-to-existing-platforms-bicep.md` for the resource definition.

### 3b — Create the APIM logger (`ai-logger`)

The script uses connection string + system-assigned managed identity authentication (recommended). If `DisableLocalAuth` is `false` on your App Insights instance, it falls back to instrumentation key automatically.

#### Apply via script

```powershell
pwsh scripts/apply-observability.ps1 -Change 3
```

#### Apply manually

```powershell
$apimName     = "<your-apim>"
$aiName       = "<your-ai>"
$apimRid      = "/subscriptions/$SUB_ID/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$apimName"
$aiId         = az monitor app-insights component show -a $aiName -g $RG --query id -o tsv
$aiConnStr    = az monitor app-insights component show -a $aiName -g $RG --query connectionString -o tsv

$loggerUri  = "https://management.azure.com$apimRid/loggers/ai-logger?api-version=2022-12-01"
$loggerBody = @{
    properties = @{
        loggerType  = "applicationInsights"
        description = "Application Insights logger for AI gateway telemetry"
        resourceId  = $aiId
        isBuffered  = $true
        credentials = @{
            # Use connection string + managed identity — NOT instrumentationKey.
            # If DisableLocalAuth is true (recommended), key-based auth is rejected.
            # 'SystemAssigned' is a literal string, not a variable.
            connectionString = $aiConnStr
            identityClientId = "SystemAssigned"
        }
    }
} | ConvertTo-Json -Depth 10

Invoke-RestMethod -Method PUT -Uri $loggerUri -Body $loggerBody `
    -Headers @{ Authorization = "Bearer $t"; "Content-Type" = "application/json" }
```

> If this fails with a 400 (DisableLocalAuth=false), fall back to instrumentation key:
> ```powershell
> $iKey = az monitor app-insights component show -a $aiName -g $RG --query instrumentationKey -o tsv
> # Replace credentials block above with: @{ instrumentationKey = $iKey }
> ```
> Then enable `DisableLocalAuth=true` on the App Insights resource and re-run to upgrade to MSI auth.

### 3c — Create the APIM diagnostics resource

This is the most important part — it tells APIM which response headers to capture so the workbook joins work:

```powershell
$loggerRid = "$apimRid/loggers/ai-logger"
$diagUri   = "https://management.azure.com$apimRid/diagnostics/applicationinsights?api-version=2022-12-01"
$diagBody  = @{
    properties = @{
        loggerId    = $loggerRid
        alwaysLog   = "allErrors"
        sampling    = @{ samplingType = "fixed"; percentage = 100 }  # lower to 10 on high volume
        verbosity   = "information"   # never "verbose" — logs request body content
        httpCorrelationProtocol = "W3C"
        operationNameFormat     = "Url"
        frontend = @{
            request  = @{ headers = @("X-Correlation-Id"); body = @{ bytes = 0 } }
            response = @{
                # These five headers drive the workbook panels:
                #   X-Backend-Region-Used → which Foundry region served the request
                #   X-Correlation-Id      → join key between AGWAccessLogs and AppRequests
                #   X-Tokens-Used         → token quota utilization panel
                #   X-Cache               → semantic cache hit rate panel
                #   X-Model-Name          → model name for the model latency workbook
                headers = @("X-Backend-Region-Used","X-Correlation-Id","X-Tokens-Used","X-Cache","X-Model-Name")
                body    = @{ bytes = 0 }
            }
        }
        backend = @{
            request  = @{ headers = @("X-Correlation-Id"); body = @{ bytes = 0 } }
            response = @{ headers = @("X-Backend-Region-Used","X-Correlation-Id"); body = @{ bytes = 0 } }
        }
    }
} | ConvertTo-Json -Depth 10

Invoke-RestMethod -Method PUT -Uri $diagUri -Body $diagBody `
    -Headers @{ Authorization = "Bearer $t"; "Content-Type" = "application/json" }
```

**The name `applicationinsights` is a reserved APIM keyword** — this is what automatically links the logger to all API traffic. There can only be one resource with this name per APIM instance. If one already exists, the `PUT` updates it in-place with the additional headers.

### Verify

```kql
AppRequests
| take 5

AppDependencies
| take 5
```

---

## Step 4 — Add the `X-Correlation-Id` Header (App Gateway) — Optional

The E2E Trace workbook joins `AGWAccessLogs` to `AppRequests` using the `X-Correlation-Id` header. App Gateway needs a rewrite rule to stamp this header on every forwarded request.

> **Preferred approach:** Add `rewriteRuleSets` to your Bicep or Terraform and run `azd provision`. App Gateway rewrite rule changes require a full resource redeployment — the ARM GET→PUT pattern is safe but means a brief reconfiguration cycle. See `apply-to-existing-platforms-bicep.md` Step 4 for the Bicep snippet.

### Apply via script (ARM GET→mutate→PUT)

```powershell
pwsh scripts/apply-observability.ps1 -Change 4
```

The script fetches the current App Gateway configuration, appends the rewrite rule set, attaches it to all routing rules, and PUTs the full configuration back. It checks for an existing `inject-correlation-id` rule set and skips if already present.

### Apply manually

```powershell
$appgwId  = az network application-gateway show -n <your-appgw> -g $RG --query id -o tsv
$appgwUri = "https://management.azure.com$appgwId`?api-version=2023-05-01"

# GET current configuration
$appgw = Invoke-RestMethod -Method GET -Uri $appgwUri `
    -Headers @{ Authorization = "Bearer $t" }

# Build rewrite rule set
$newRuleSet = @{
    name       = "inject-correlation-id"
    properties = @{
        rewriteRules = @(@{
            name         = "add-x-correlation-id"
            ruleSequence = 100
            conditions   = @()
            actionSet    = @{
                requestHeaderConfigurations  = @(@{
                    headerName  = "X-Correlation-Id"
                    # Combines client IP + source port — unique for every active connection
                    headerValue = "{var_client_ip}-{var_client_port}"
                })
                responseHeaderConfigurations = @(@{
                    headerName  = "X-Correlation-Id"
                    headerValue = "{var_client_ip}-{var_client_port}"
                })
            }
        })
    }
}

# Append rule set to existing array
if (-not $appgw.properties.rewriteRuleSets) {
    $appgw.properties | Add-Member -NotePropertyName rewriteRuleSets -NotePropertyValue @($newRuleSet)
} else {
    $appgw.properties.rewriteRuleSets += $newRuleSet
}

# Attach rule set to all routing rules
$ruleSetRef = @{ id = "$appgwId/rewriteRuleSets/inject-correlation-id" }
foreach ($rule in $appgw.properties.requestRoutingRules) {
    if (-not $rule.properties.rewriteRuleSet) {
        $rule.properties | Add-Member -NotePropertyName rewriteRuleSet -NotePropertyValue $ruleSetRef
    }
}

# PUT the full configuration back
$putBody = $appgw | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable | ConvertTo-Json -Depth 30
Invoke-RestMethod -Method PUT -Uri $appgwUri -Body $putBody `
    -Headers @{ Authorization = "Bearer $t"; "Content-Type" = "application/json" }
```

**This change is safe to deploy live.** Rewrite rules only add headers — they never block traffic or change routing. If a request already carries `X-Correlation-Id` from the client, the override replaces it with the App Gateway value (preventing client-controlled correlation injection).

---

## Step 5 — Add `X-Backend-Region-Used` to Your APIM Policy — Optional

The Backend Routing Report workbook splits traffic by `primary` vs `secondary` using this response header. Add it to your API-level outbound policy wherever you route between Foundry endpoints.

### Apply via script

```powershell
pwsh scripts/apply-observability.ps1 -Change 5
```

The script reads your current API-level policy XML, injects the `set-header` element into the `<outbound>` section if it is not already present, and PUTs the updated XML back.

### Apply manually (policy XML inject)

```powershell
$apimName    = "<your-apim>"
$apiName     = "<your-inference-api-name>"   # e.g. "model-inference"
$apimRid     = "/subscriptions/$SUB_ID/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$apimName"
$policyUri   = "https://management.azure.com$apimRid/apis/$apiName/policies/policy?api-version=2022-12-01"

# Get current policy XML
$current = Invoke-RestMethod -Method GET -Uri $policyUri `
    -Headers @{ Authorization = "Bearer $t" }
$xml = $current.properties.value

# Add X-Backend-Region-Used to the outbound section if not already present
if ($xml -notmatch 'X-Backend-Region-Used') {
    $inject = @'
  <set-header name="X-Backend-Region-Used" exists-action="override">
    <value>@(context.Variables.GetValueOrDefault("selectedBackend", "primary"))</value>
  </set-header>
'@
    $xml = $xml -replace '(<outbound>[^<]*<base\s*/>)', "`$1`n$inject"
}

$putBody = @{
    properties = @{ format = "rawxml"; value = $xml }
} | ConvertTo-Json -Depth 5

Invoke-RestMethod -Method PUT -Uri $policyUri -Body $putBody `
    -Headers @{ Authorization = "Bearer $t"; "Content-Type" = "application/json" }
```

In your inbound section you should already have a `<set-variable name="selectedBackend" ...>` that tracks which Foundry endpoint was chosen. If you are routing via a simple `<set-backend-service>` without a named variable, add the variable alongside it:

```xml
<inbound>
  <base />
  <!-- your existing routing logic -->
  <set-backend-service base-url="https://<your-foundry>.services.ai.azure.com/openai" />
  <set-variable name="selectedBackend" value="primary" />
</inbound>
<on-error>
  <base />
  <set-header name="X-Backend-Region-Used" exists-action="override">
    <value>@(context.Variables.GetValueOrDefault("selectedBackend", "unknown"))</value>
  </set-header>
</on-error>
```

The workbook will still work with a static `"primary"` value — the Backend Switch Events table just will not show any failover rows.

---

## Step 6 — Deploy the Workbooks

The workbooks are Azure Monitor Workbooks (JSON files). They can be deployed independently of all other steps — they are purely read-only dashboards.

### Option A — PowerShell (ARM REST, idempotent)

Copy both workbook JSON files from `observability/workbooks/` and deploy them via ARM:

```powershell
$lawId        = az monitor log-analytics workspace show -g $RG -n <your-law> --query id -o tsv
$placeholderId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-contoso-ai-platform-dev/providers/Microsoft.OperationalInsights/workspaces/law-contoso-ai-dev"

foreach ($wb in @("backend-routing-report","e2e-trace","model-latency")) {
    $json     = Get-Content "observability/workbooks/$wb.workbook.json" -Raw
    $json     = $json.Replace($placeholderId, $lawId)
    $wbUri    = "https://management.azure.com/subscriptions/$SUB_ID/resourceGroups/$RG/providers/Microsoft.Insights/workbooks/$wb`?api-version=2023-06-01"
    $wbBody   = @{
        location   = (az group show -n $RG --query location -o tsv)
        kind       = "shared"
        properties = @{
            displayName    = $wb
            serializedData = $json
            sourceId       = $lawId
            category       = "workbook"
            version        = "1.0"
        }
    } | ConvertTo-Json -Depth 5

    Invoke-RestMethod -Method PUT -Uri $wbUri -Body $wbBody `
        -Headers @{ Authorization = "Bearer $t"; "Content-Type" = "application/json" }
    Write-Host "Deployed workbook: $wb"
}
```

The `Replace()` call substitutes the placeholder workspace ID (written into the workbook JSON by this repo) with your real LAW resource ID. The workbook JSON files do not need to be modified on disk.

### Option B — Azure Portal (one-time, no scripting required)

1. Open **Azure Monitor → Workbooks → New**
2. Click the `</>` (Advanced Editor) button
3. Paste the contents of `observability/workbooks/backend-routing-report.workbook.json`
4. Replace every occurrence of the placeholder workspace resource ID with your own LAW resource ID (find/replace on the subscription GUID)
5. Save and pin to a dashboard

Repeat for `e2e-trace.workbook.json` and `model-latency.workbook.json`.

### What you will see immediately

After deploying workbooks against an existing APIM that already had `GatewayLogs` flowing:

- **Backend Routing Report panels 1–5, 7, and 8** — populated immediately (data is in `ApiManagementGatewayLogs`)
- **Panel 6 (Full Chain Latency — joined with AGWAccessLogs)** — populated once Step 2 is done
- **E2E Trace panels 1–5** — populated once Step 3 is done (App Insights wired up)
- **E2E Trace panel 10 (waterfall per request)** — needs both Step 3 and Step 4 (`X-Correlation-Id` header)
- **E2E Trace panel 12 (cache hit rate)** — needs `X-Cache` header in your APIM policy (Step 7b below)
- **E2E Trace panel 13 (token quota)** — needs `X-Tokens-Used` header (Step 7c below)
- **Model Latency workbook (all panels)** — needs Step 3 (App Insights) plus `X-Model-Name` header from Step 7e below

---

## Step 7 — Optional: Circuit Breaker, Caching, and Token Policies

These are the operational policies in `policies/apim/`. They are **independent of the workbooks** — the dashboards work without them. Apply them only if you want the corresponding capability.

### 7a — Circuit Breaker Failover (`circuit-breaker-multi-region.xml`)

Automatically fails over to a secondary Foundry endpoint when the primary returns 429 or 5xx. Requires two Foundry deployments.

Apply at the API scope on your OpenAI inference API. See `policies/apim/circuit-breaker-multi-region.xml` for the full policy. You need two APIM Named Values:

```powershell
$apimName = "<your-apim>"
$apiVer   = "2022-12-01"
$apimRid  = "/subscriptions/$SUB_ID/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$apimName"

# Create named values for Foundry endpoints
foreach ($nv in @(
    @{ name = "foundry-primary-endpoint";   value = "https://<primary-foundry>.services.ai.azure.com" }
    @{ name = "foundry-secondary-endpoint"; value = "https://<secondary-foundry>.services.ai.azure.com" }
)) {
    $nvUri  = "https://management.azure.com$apimRid/namedValues/$($nv.name)?api-version=$apiVer"
    $nvBody = @{ properties = @{ displayName = $nv.name; value = $nv.value; secret = $false } } | ConvertTo-Json
    Invoke-RestMethod -Method PUT -Uri $nvUri -Body $nvBody `
        -Headers @{ Authorization = "Bearer $t"; "Content-Type" = "application/json" }
}
```

APIM must also have **Cognitive Services User** role on both Foundry accounts. In production, add these role assignments to Bicep — see `infrastructure/bicep/foundry-apim-rbac.bicep`. For a one-off check only (diagnostics, not permanent configuration):

```powershell
$apimPid = az apim show -n $apimName -g $RG --query identity.principalId -o tsv

# Cognitive Services User = a97b65f3-24c7-4388-baec-2e87135dc908
foreach ($foundry in @("<primary-foundry-resource-id>","<secondary-foundry-resource-id>")) {
    az role assignment create `
        --role "a97b65f3-24c7-4388-baec-2e87135dc908" `
        --assignee $apimPid `
        --scope $foundry
}
```

> **IaC rule:** Do not run `az role assignment create` as a permanent fix. Put the role assignments in `infrastructure/bicep/foundry-apim-rbac.bicep` and run `azd provision`.

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

See `policies/apim/pci-dss-audit-logging.xml` and `docs/playbooks/pci-dss-configuration.md`. Apply only if your API gateway is in PCI DSS scope.

### 7e — Emit `X-Model-Name` for the Model Latency Workbook

Adds the model name as a response header on both inference API paths. Required for the **Model Latency workbook** to break down P50/P90/P99 latency per model.

**OpenAI-compatible path** (`/openai/deployments/{model}/chat/completions`) — read model name from the response body `"model"` field:

```xml
<!-- In the outbound policy of your OpenAI inference API, inside the existing status-200 block: -->
<set-variable name="modelName" value="@{
  try { return context.Response.Body.As<JObject>(preserveContent: true)?["model"]?.ToString() ?? ""; }
  catch { return ""; }
}" />
<set-header name="X-Model-Name" exists-action="override">
  <value>@((string)context.Variables.GetValueOrDefault("modelName", ""))</value>
</set-header>
```

**Native Foundry inference SDK path** (`/models/chat/completions`) — the model name is in the **request** body, not the URL. Read it inbound with `preserveContent: true` before forwarding:

```xml
<!-- Inbound policy of your native inference API: -->
<set-variable name="requestedModel" value="@{
  try { return context.Request.Body.As<JObject>(preserveContent: true)?["model"]?.ToString() ?? ""; }
  catch { return ""; }
}" />
<!-- Outbound policy: -->
<set-header name="X-Model-Name" exists-action="override">
  <value>@((string)context.Variables.GetValueOrDefault("requestedModel", ""))</value>
</set-header>
```

> **`preserveContent: true` is critical** — omitting it consumes the body, leaving the backend or caller with an empty payload. Always pass `preserveContent: true` when reading `JObject` in APIM policies.

Apply each policy fragment via ARM REST API PUT to the corresponding APIM API policy resource. Also ensure `"X-Model-Name"` is in the `frontend.response.headers` list in your APIM diagnostics resource (Step 3c) so it flows through to `AppRequests.Properties["Response-Header-X-Model-Name"]` in Log Analytics.

---

## Prerequisites Checklist

Before starting, confirm you have:

- [ ] APIM instance (any SKU except Consumption for VNet scenarios; Premium for internal VNet)
- [ ] Log Analytics Workspace (PerGB2018 SKU; 395-day retention for PCI, 90-day minimum otherwise)
- [ ] App Insights instance linked to the same LAW (workspace-based, not Classic)
- [ ] App Gateway v2 (WAF_v2 SKU) if you want the E2E Trace workbook AppGW layer
- [ ] Azure CLI installed and authenticated (`az login`)
- [ ] PowerShell 7+ (`pwsh`) — the script uses `ConvertFrom-Json -AsHashtable` (PS 6+) and null-coalescing `??` (PS 7+)
- [ ] APIM system-assigned managed identity enabled

Check managed identity:

```powershell
az apim show -n <apim-name> -g <rg> --query identity -o json
```

If `principalId` is null, the system-assigned identity is not enabled. Enable it via a Bicep change in `infrastructure/bicep/apim-gateway.bicep` and run `azd provision` — do not use `az apim update` as a permanent fix.

---

## Verify All Resources Before Starting

```powershell
# Run _resolve-env.ps1 to see what the scripts will auto-discover
. scripts/_resolve-env.ps1
Write-Host "SUB:   $SUB_ID"
Write-Host "RG:    $RG"
Write-Host "APIM:  $APIM_NAME"
Write-Host "AppGW: $APPGW_NAME"
Write-Host "KV:    $KV_NAME"
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

All tables land in the same Log Analytics workspace. Verify any table exists:

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
| Step 7e (X-Model-Name header) | Model Latency workbook shows no data. |
