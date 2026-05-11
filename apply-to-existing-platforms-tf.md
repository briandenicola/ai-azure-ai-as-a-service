# Applying This Pattern to an Existing APIM + Foundry Platform (Terraform)

This repo is a **greenfield reference deployment** — everything is provisioned from scratch via `azd provision`. If your team already has APIM and Azure AI Foundry running in production, you do not need to redeploy anything. You apply the pattern incrementally, one piece at a time.

This guide is the **Terraform edition** — every snippet uses the `azurerm` (and `azapi`) providers. See `apply-to-existing-platforms-bicep.md` for the equivalent Bicep version. Terraform files for this repo live in `infrastructure/terraform/`.

This guide walks through each layer in order of risk (read-only first, configuration last) with the exact changes required for each.

### Provider requirements

All snippets below assume your root module declares:

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.75"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 1.9"
    }
  }
}

provider "azurerm" {
  features {}
}
```

`azapi` is needed for two resources where `azurerm` does not yet expose the required properties natively (APIM logger with managed identity auth, and workbooks). It is already a dependency in `infrastructure/terraform/apim-gateway/main.tf`.

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

### Working with existing resources in Terraform

Most steps below add resources that target infrastructure already in Azure. Use `data` sources to reference existing resources without managing them, and `terraform import` to bring any resource into state that you want Terraform to own going forward. If you are only adding incremental pieces (e.g. a new diagnostic setting on an existing APIM), a `data` source is sufficient — no import needed.

---

## Step 1 — Enable `ApiManagementGatewayLogs` in Log Analytics

This is the **most important step** — it populates the tables that both workbooks depend on.

### Check whether it is already enabled

```powershell
$apimId = az apim show -n <your-apim-name> -g <your-rg> --query id -o tsv
az monitor diagnostic-settings list --resource $apimId --query "[].logs[?enabled].category" -o tsv
```

Look for `GatewayLogs` in the output. If it is missing, add it.

### Add the diagnostic setting (Terraform)

Reference your existing APIM with a `data` source, then create the diagnostic setting:

```hcl
data "azurerm_api_management" "apim" {
  name                = var.apim_name
  resource_group_name = var.resource_group_name
}

data "azurerm_log_analytics_workspace" "law" {
  name                = var.log_analytics_workspace_name
  resource_group_name = var.resource_group_name
}

resource "azurerm_monitor_diagnostic_setting" "apim_gateway_logs" {
  name                           = "gateway-logs-to-law"
  target_resource_id             = data.azurerm_api_management.apim.id
  log_analytics_workspace_id     = data.azurerm_log_analytics_workspace.law.id
  log_analytics_destination_type = "Dedicated"  # creates ApiManagementGatewayLogs table
                                                 # NOT the generic AzureDiagnostics table

  enabled_log { category = "GatewayLogs" }
  enabled_log { category = "DeveloperPortalAuditLogs" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
```

> **Important:** `log_analytics_destination_type = "Dedicated"` creates the resource-specific table `ApiManagementGatewayLogs`. If you omit this (or leave it as `AzureDiagnostics`), the workbook KQL queries will not find data because they query the dedicated table by name.

If you have an existing diagnostic setting that sends to `AzureDiagnostics`, you can create a second setting alongside it pointing to dedicated tables — both can coexist. Give the second setting a distinct `name`.

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

```hcl
data "azurerm_application_gateway" "appgw" {
  name                = var.app_gateway_name
  resource_group_name = var.resource_group_name
}

resource "azurerm_monitor_diagnostic_setting" "appgw_logs" {
  name                           = "appgw-logs-to-law"
  target_resource_id             = data.azurerm_application_gateway.appgw.id
  log_analytics_workspace_id     = data.azurerm_log_analytics_workspace.law.id
  log_analytics_destination_type = "Dedicated"  # creates AGWAccessLogs table

  enabled_log { category = "ApplicationGatewayAccessLog" }
  enabled_log { category = "ApplicationGatewayFirewallLog" }

  metric {
    category = "AllMetrics"
    enabled  = true
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

```hcl
resource "azurerm_application_insights" "apim_ai" {
  name                = "apim-ai-telemetry"
  location            = var.location
  resource_group_name = var.resource_group_name
  application_type    = "web"
  workspace_id        = data.azurerm_log_analytics_workspace.law.id  # same LAW as Step 1
  retention_in_days   = 365
  tags                = var.tags
}
```

### 3b — Create an APIM logger pointing to App Insights

The `azurerm` provider's `azurerm_api_management_logger` resource only exposes `instrumentation_key` authentication. To use the recommended **connection string + managed identity** path (required when `DisableLocalAuth = true` on the App Insights resource), use `azapi_resource` which exposes the full ARM API:

```hcl
resource "azapi_resource" "apim_ai_logger" {
  type      = "Microsoft.ApiManagement/service/loggers@2023-05-01-preview"
  name      = "ai-logger"
  parent_id = data.azurerm_api_management.apim.id

  body = jsonencode({
    properties = {
      loggerType  = "applicationInsights"
      description = "Application Insights logger for AI gateway telemetry"
      isBuffered  = true
      resourceId  = azurerm_application_insights.apim_ai.id
      credentials = {
        # Use connection string + managed identity, NOT instrumentationKey.
        # If DisableLocalAuth is true on the App Insights resource (recommended),
        # key-based auth is rejected — APIM must authenticate via its system-assigned
        # managed identity. 'SystemAssigned' is a literal string, not a variable.
        connectionString  = azurerm_application_insights.apim_ai.connection_string
        identityClientId  = "SystemAssigned"
      }
    }
  })
}
```

> **Note:** If your App Insights instance has `DisableLocalAuth = false` (the default in older deployments), you can use `azurerm_api_management_logger` with `instrumentation_key = azurerm_application_insights.apim_ai.instrumentation_key`. However, enabling `DisableLocalAuth` and switching to managed identity is the recommended production posture — it eliminates a static credential from your configuration.

### 3c — Create the APIM diagnostics resource

This is the most important part — it tells APIM which headers to capture so the workbook join works:

```hcl
resource "azurerm_api_management_diagnostic" "app_insights" {
  identifier               = "applicationinsights"  # must be exactly this string
  resource_group_name      = var.resource_group_name
  api_management_name      = data.azurerm_api_management.apim.name
  api_management_logger_id = azapi_resource.apim_ai_logger.id

  sampling_percentage       = 100    # lower to 10 on high-volume production
  always_log_errors         = true
  log_client_ip             = true
  verbosity                 = "information"  # never "verbose" — logs body content
  http_correlation_protocol = "W3C"
  operation_name_format     = "Url"

  frontend_request {
    headers_to_log = ["X-Correlation-Id"]
    body_bytes     = 0
  }

  frontend_response {
    # These four headers drive the workbook panels:
    #   X-Backend-Region-Used → which Foundry region served the request
    #   X-Correlation-Id      → join key between AGWAccessLogs and AppRequests
    #   X-Tokens-Used         → token quota utilization panel
    #   X-Cache               → semantic cache hit rate panel
    headers_to_log = ["X-Backend-Region-Used", "X-Correlation-Id", "X-Tokens-Used", "X-Cache"]
    body_bytes     = 0
  }

  backend_request {
    headers_to_log = ["X-Correlation-Id"]
    body_bytes     = 0
  }

  backend_response {
    headers_to_log = ["X-Backend-Region-Used", "X-Correlation-Id"]
    body_bytes     = 0
  }
}
```

**The `identifier = "applicationinsights"` value is a reserved keyword in APIM** — this is what links the logger to all API calls automatically. There can only be one resource with this identifier per APIM instance.

If a diagnostics resource already exists with `identifier = "applicationinsights"`, import it into Terraform state and update it with the additional headers rather than creating a new one:

```bash
terraform import azurerm_api_management_diagnostic.app_insights \
  "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ApiManagement/service/<apim>/diagnostics/applicationinsights"
```

---

## Step 4 — Add the `X-Correlation-Id` Header (App Gateway)

The E2E Trace workbook joins `AGWAccessLogs` to `AppRequests` using the `X-Correlation-Id` header. App Gateway needs a rewrite rule to stamp this header on every forwarded request.

Add a `rewrite_rule_set` block to your `azurerm_application_gateway` resource. If the gateway is not yet in Terraform state, import it first:

```bash
terraform import azurerm_application_gateway.appgw \
  "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/applicationGateways/<appgw-name>"
```

Then add the rewrite rule set and wire it to each routing rule:

```hcl
resource "azurerm_application_gateway" "appgw" {
  # ... your existing configuration ...

  rewrite_rule_set {
    name = "inject-correlation-id"

    rewrite_rule {
      name          = "add-x-correlation-id"
      rule_sequence = 100

      request_header_configuration {
        header_name  = "X-Correlation-Id"
        # Combines client IP + source port — unique for every active connection
        header_value = "{var_client_ip}-{var_client_port}"
      }

      response_header_configuration {
        header_name  = "X-Correlation-Id"
        header_value = "{var_client_ip}-{var_client_port}"
      }
    }
  }

  # Attach the rewrite rule set to each request routing rule:
  request_routing_rule {
    # ... your existing routing rule properties ...
    rewrite_rule_set_name = "inject-correlation-id"
  }
}
```

**This change is safe to deploy live.** Rewrite rules only add headers — they never block traffic or change routing. If a request already carries `X-Correlation-Id` from the client, the override replaces it with the App Gateway value (preventing client-controlled correlation injection).

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

### Option A — Terraform (recommended, idempotent)

The `azurerm` provider does not yet support Azure Monitor Workbooks directly. Use `azapi_resource`, which exposes the full ARM API. Copy both workbook JSON files from `observability/workbooks/` into your Terraform module directory under a `workbooks/` subfolder.

```hcl
locals {
  # Replace the placeholder workspace ID (written into the workbook JSON by this repo)
  # with your actual Log Analytics workspace resource ID at deploy time.
  placeholder_law_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-contoso-ai-platform-dev/providers/Microsoft.OperationalInsights/workspaces/law-contoso-ai-dev"
}

resource "azapi_resource" "workbook_backend_routing" {
  type      = "Microsoft.Insights/workbooks@2023-06-01"
  name      = "backend-routing-report"
  location  = var.location
  parent_id = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}"

  body = jsonencode({
    kind = "shared"
    properties = {
      displayName  = "AppGW \u2192 APIM \u2192 Foundry Backend Routing Report"
      serializedData = replace(
        file("${path.module}/workbooks/backend-routing-report.workbook.json"),
        local.placeholder_law_id,
        data.azurerm_log_analytics_workspace.law.id
      )
      sourceId   = data.azurerm_log_analytics_workspace.law.id
      category   = "workbook"
      version    = "1.0"
    }
  })

  tags = var.tags
}

resource "azapi_resource" "workbook_e2e_trace" {
  type      = "Microsoft.Insights/workbooks@2023-06-01"
  name      = "e2e-trace"
  location  = var.location
  parent_id = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}"

  body = jsonencode({
    kind = "shared"
    properties = {
      displayName  = "AppGW \u2192 APIM \u2192 Foundry End-to-End Trace"
      serializedData = replace(
        file("${path.module}/workbooks/e2e-trace.workbook.json"),
        local.placeholder_law_id,
        data.azurerm_log_analytics_workspace.law.id
      )
      sourceId   = data.azurerm_log_analytics_workspace.law.id
      category   = "workbook"
      version    = "1.0"
    }
  })

  tags = var.tags
}
```

> The `replace()` call substitutes the placeholder workspace ID (hard-coded in the workbook JSONs for use by the `azd`/Bicep path) with your real LAW resource ID. The workbook JSONs do not need to be modified on disk.

### Option B — Azure Portal (one-time, no Terraform required)

1. Open **Azure Monitor → Workbooks → New**
2. Click the `</>` (Advanced Editor) button
3. Paste the contents of `observability/workbooks/backend-routing-report.workbook.json`
4. Replace every occurrence of the placeholder workspace resource ID with your own LAW resource ID (find/replace on the subscription GUID)
5. Save and pin to a dashboard

Repeat for `e2e-trace.workbook.json`. Note: workbooks created via the portal are not tracked in Terraform state and will drift when the repo JSON files are updated.

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

APIM must have **Cognitive Services User** role on both Foundry accounts. Add these role assignments to your Terraform module (see `infrastructure/terraform/` for examples):

```hcl
data "azurerm_cognitive_account" "foundry_primary" {
  name                = var.foundry_primary_name
  resource_group_name = var.resource_group_name
}

data "azurerm_cognitive_account" "foundry_secondary" {
  name                = var.foundry_secondary_name
  resource_group_name = var.resource_group_name
}

resource "azurerm_role_assignment" "apim_foundry_primary" {
  scope              = data.azurerm_cognitive_account.foundry_primary.id
  role_definition_id = "/providers/Microsoft.Authorization/roleDefinitions/a97b65f3-24c7-4388-baec-2e87135dc908"
  principal_id       = data.azurerm_api_management.apim.identity[0].principal_id
}

resource "azurerm_role_assignment" "apim_foundry_secondary" {
  scope              = data.azurerm_cognitive_account.foundry_secondary.id
  role_definition_id = "/providers/Microsoft.Authorization/roleDefinitions/a97b65f3-24c7-4388-baec-2e87135dc908"
  principal_id       = data.azurerm_api_management.apim.identity[0].principal_id
}
```

You can also apply the APIM policy XML via Terraform to keep everything in state:

```hcl
resource "azurerm_api_management_api_policy" "inference_policy" {
  api_name            = var.inference_api_name
  api_management_name = data.azurerm_api_management.apim.name
  resource_group_name = var.resource_group_name
  xml_content         = file("${path.module}/policies/circuit-breaker-multi-region.xml")
}
```

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
- [ ] Terraform state access + Owner or Contributor + User Access Administrator on the resource group
- [ ] APIM system-assigned managed identity enabled

Check managed identity:

```powershell
az apim show -n <apim-name> -g <rg> --query identity -o json
```

If `principalId` is null, the system-assigned identity is not enabled. Add the `identity` block to your `azurerm_api_management` resource and run `terraform apply`:

```hcl
resource "azurerm_api_management" "apim" {
  # ... your existing configuration ...

  identity {
    type = "SystemAssigned"
  }
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
