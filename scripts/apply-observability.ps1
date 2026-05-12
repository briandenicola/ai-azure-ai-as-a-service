# apply-observability.ps1
# Incrementally applies observability changes to an existing APIM + App Gateway platform.
# Menu-driven — run each change independently or all at once.
#
# Usage:
#   pwsh scripts/apply-observability.ps1
#   pwsh scripts/apply-observability.ps1 -Change 1        # non-interactive
#   pwsh scripts/apply-observability.ps1 -Change All      # apply 1-3 in sequence
#
# Changes:
#   1 — APIM diagnostic settings → ApiManagementGatewayLogs (zero risk)
#   2 — App Gateway diagnostic settings → AGWAccessLogs    (zero risk)
#   3 — App Insights logger + diagnostics wired to APIM    (low risk)
#   4 — X-Correlation-Id rewrite rule on App Gateway       (optional / low risk)
#   5 — X-Backend-Region-Used header in APIM outbound      (optional / low risk)

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('','1','2','3','4','5','All')]
    [string]$Change = '',

    # Pre-supply values to skip interactive prompts
    [string]$SubscriptionId  = '',
    [string]$ResourceGroup   = '',
    [string]$ApimName        = '',
    [string]$AppInsightsName = '',

    # Skip confirmation prompts (for CI / scripted runs)
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────
function Write-Step([string]$msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Ok  ([string]$msg) { Write-Host "  ✔ $msg"      -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "  ⚠ $msg"      -ForegroundColor Yellow }
function Write-Fail([string]$msg) { Write-Host "  ✘ $msg"      -ForegroundColor Red }
function Write-Info([string]$msg) { Write-Host "  · $msg"      -ForegroundColor Gray }

function Confirm-Step([string]$prompt) {
    if ($Force) { return $true }
    $answer = Read-Host "$prompt [y/N]"
    return ($answer -match '^[yY]')
}

function Invoke-AzRest([string]$method, [string]$uri, [hashtable]$body = $null) {
    $headers = @{
        Authorization  = "Bearer $t"
        'Content-Type' = 'application/json'
    }
    $params = @{ Uri = $uri; Method = $method; Headers = $headers }
    if ($body) { $params['Body'] = ($body | ConvertTo-Json -Depth 20 -Compress) }
    return Invoke-RestMethod @params
}

# ─────────────────────────────────────────────────────────────────────────────
# Resolve environment — try auto-discovery first, then prompt for anything missing
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Resolving environment"

# Seed env vars from -Parameter values before dot-sourcing so _resolve-env.ps1 picks them up
if ($SubscriptionId) { $env:AZURE_SUBSCRIPTION_ID = $SubscriptionId }
if ($ResourceGroup)  { $env:AZURE_RESOURCE_GROUP  = $ResourceGroup  }

# Attempt auto-discovery (suppressing hard-errors — we will prompt for what's missing)
try   { . "$PSScriptRoot/_resolve-env.ps1" }
catch { <# _resolve-env.ps1 called Write-Error — we handle below #> }

# ── Subscription ──────────────────────────────────────────────────────────────
if (-not $SUB_ID) { $SUB_ID = az account show --query id -o tsv 2>$null }
if (-not $SUB_ID) {
    Write-Warn "Not logged in to Azure CLI. Run 'az login' first, then re-run this script."
    exit 1
}

# ── Resource group ────────────────────────────────────────────────────────────
if (-not $RG) {
    Write-Host ""
    Write-Host "  Resource group could not be auto-detected." -ForegroundColor Yellow
    $availableRGs = az group list --query "[].name" -o tsv 2>$null
    if ($availableRGs) {
        Write-Host "  Available resource groups in subscription $SUB_ID:" -ForegroundColor Gray
        $availableRGs -split "`n" | ForEach-Object { Write-Host "    · $_" -ForegroundColor Gray }
    }
    $RG = (Read-Host "  Enter resource group name").Trim()
    if (-not $RG) { Write-Host "No resource group provided. Exiting." -ForegroundColor Red; exit 1 }
}

# ── APIM ──────────────────────────────────────────────────────────────────────
if (-not $APIM_NAME) {
    $APIM_NAME = az apim list -g $RG --query "[0].name" -o tsv 2>$null
}
if (-not $APIM_NAME) {
    Write-Host ""
    Write-Host "  No APIM instance found in '$RG'." -ForegroundColor Yellow
    $APIM_NAME = (Read-Host "  Enter APIM instance name (or leave blank to skip APIM changes)").Trim()
}

# ── App Gateway (optional) ────────────────────────────────────────────────────
if (-not $APPGW_NAME) {
    $APPGW_NAME = az network application-gateway list -g $RG --query "[0].name" -o tsv 2>$null
}

# ── ARM token ─────────────────────────────────────────────────────────────────
if (-not $t) { $t = az account get-access-token --query accessToken -o tsv 2>$null }
if (-not $t) { Write-Host "Cannot get ARM access token. Run 'az login'." -ForegroundColor Red; exit 1 }

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Ok "Subscription  : $SUB_ID"
Write-Ok "Resource group: $RG"
if ($APIM_NAME) { Write-Ok "APIM          : $APIM_NAME" } else { Write-Warn "No APIM name — changes 1, 3, 5 will be skipped." }
if ($APPGW_NAME) { Write-Ok "App Gateway   : $APPGW_NAME" } else { Write-Warn "No App Gateway found — changes 2 and 4 will be skipped." }

# ── Log Analytics Workspace ───────────────────────────────────────────────────
$_lawList  = az monitor log-analytics workspace list -g $RG -o json 2>$null | ConvertFrom-Json
$lawId     = ''
$lawCustomerId = ''
if ($_lawList -and $_lawList.Count -gt 0) {
    if ($_lawList.Count -eq 1) {
        $lawId         = $_lawList[0].id
        $lawCustomerId = $_lawList[0].customerId
        Write-Ok "Log Analytics : $_($lawList[0].name)"
    } else {
        Write-Host ""
        Write-Host "  Multiple Log Analytics workspaces found in '$RG':" -ForegroundColor Yellow
        for ($i = 0; $i -lt $_lawList.Count; $i++) {
            Write-Host "  $($i+1). $($_lawList[$i].name)" -ForegroundColor Gray
        }
        $idx = (Read-Host "  Enter number to use").Trim()
        $selected = $_lawList[[int]$idx - 1]
        $lawId         = $selected.id
        $lawCustomerId = $selected.customerId
        Write-Ok "Log Analytics : $($selected.name)"
    }
} else {
    Write-Host ""
    Write-Host "  No Log Analytics workspace found in '$RG'." -ForegroundColor Yellow
    $lawId = (Read-Host "  Enter Log Analytics workspace resource ID (or leave blank to skip logging changes)").Trim()
    if (-not $lawId) { Write-Warn "No Log Analytics workspace — changes 1 and 2 require one. They will fail." }
}

# ── App Insights (change 3 only) ──────────────────────────────────────────────
$_aiList = az monitor app-insights component list -g $RG -o json 2>$null | ConvertFrom-Json
$appInsightsId      = ''
$appInsightsConnStr = ''
$appInsightsName    = if ($ApimName) { $ApimName } else { '' }   # reset — $ApimName param is for APIM, not AI
$appInsightsName    = ''
if ($_aiList -and $_aiList.Count -gt 0) {
    if ($_aiList.Count -eq 1) {
        $appInsightsId      = $_aiList[0].id
        $appInsightsConnStr = $_aiList[0].connectionString
        $appInsightsName    = $_aiList[0].name
        Write-Ok "App Insights  : $appInsightsName"
    } else {
        Write-Host ""
        Write-Host "  Multiple App Insights instances found in '$RG':" -ForegroundColor Yellow
        for ($i = 0; $i -lt $_aiList.Count; $i++) {
            Write-Host "  $($i+1). $($_aiList[$i].name)" -ForegroundColor Gray
        }
        # Use -AppInsightsName param if supplied
        if ($AppInsightsName) {
            $selected = $_aiList | Where-Object { $_.name -eq $AppInsightsName } | Select-Object -First 1
        }
        if (-not $selected) {
            $idx = (Read-Host "  Enter number to use for Change 3 (App Insights)").Trim()
            $selected = $_aiList[[int]$idx - 1]
        }
        $appInsightsId      = $selected.id
        $appInsightsConnStr = $selected.connectionString
        $appInsightsName    = $selected.name
        Write-Ok "App Insights  : $appInsightsName"
    }
} else {
    Write-Warn "No App Insights instance found in '$RG' — Change 3 will be skipped."
}

$apimId  = if ($APIM_NAME) { az apim show -n $APIM_NAME -g $RG --query id -o tsv 2>$null } else { '' }
$apimRid = "/subscriptions/$SUB_ID/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$APIM_NAME"
$mgmt    = "https://management.azure.com"
$apiVer  = "2022-12-01"

# ─────────────────────────────────────────────────────────────────────────────
# Change definitions
# ─────────────────────────────────────────────────────────────────────────────
function Show-Menu {
    Write-Host ""
    Write-Host "┌─────────────────────────────────────────────────────────────────┐" -ForegroundColor White
    Write-Host "│  Observability Changes — Apply to Existing Platform             │" -ForegroundColor White
    Write-Host "├─────┬──────────────────────────────────────────────────────────┤" -ForegroundColor White
    Write-Host "│  #  │  Change                                         │  Risk  │" -ForegroundColor White
    Write-Host "├─────┼──────────────────────────────────────────────────────────┤" -ForegroundColor White
    Write-Host "│  1  │  APIM → ApiManagementGatewayLogs (diag settings)│  Zero  │" -ForegroundColor Green
    Write-Host "│  2  │  App Gateway → AGWAccessLogs (diag settings)    │  Zero  │" -ForegroundColor Green
    Write-Host "│  3  │  App Insights logger + diagnostics wired to APIM│  Low   │" -ForegroundColor Yellow
    Write-Host "├─────┼──────────────────────────────────────────────────────────┤" -ForegroundColor DarkGray
    Write-Host "│  4  │  X-Correlation-Id rewrite rule (App Gateway)    │  Low   │" -ForegroundColor DarkYellow
    Write-Host "│  5  │  X-Backend-Region-Used header (APIM outbound)   │  Low   │" -ForegroundColor DarkYellow
    Write-Host "├─────┼──────────────────────────────────────────────────────────┤" -ForegroundColor DarkGray
    Write-Host "│  A  │  Apply all (1-3) — zero + low risk only                  │" -ForegroundColor Cyan
    Write-Host "│  Q  │  Quit                                                     │" -ForegroundColor DarkGray
    Write-Host "└─────────────────────────────────────────────────────────────────┘" -ForegroundColor White
    Write-Host ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Change 1 — APIM diagnostic settings → ApiManagementGatewayLogs
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Change1 {
    Write-Step "Change 1 — APIM diagnostic settings → ApiManagementGatewayLogs"

    # Check current state
    Write-Info "Checking existing APIM diagnostic settings..."
    $existing = az monitor diagnostic-settings list --resource $apimId `
        --query "[?contains(workspaceId,'$lawCustomerId') || workspaceId=='$lawId']" `
        -o json 2>$null | ConvertFrom-Json

    if ($existing.Count -gt 0) {
        $hasGatewayLogs = $existing | ForEach-Object { $_.logs } | Where-Object { $_.category -eq 'GatewayLogs' -and $_.enabled }
        if ($hasGatewayLogs) {
            Write-Ok "GatewayLogs already enabled and sending to this Log Analytics workspace."
            Write-Info "Setting name: $($existing[0].name)"
            return
        }
    }

    Write-Info "GatewayLogs not found in current diagnostic settings."
    Write-Info "This will create a dedicated-table diagnostic setting on:"
    Write-Info "  Resource : $APIM_NAME"
    Write-Info "  LAW      : $lawId"
    Write-Info "  Tables   : ApiManagementGatewayLogs (dedicated)"
    Write-Info "  Risk     : Zero — read-only logging, no traffic impact"

    if (-not (Confirm-Step "Apply Change 1 (APIM diagnostic settings)?")) {
        Write-Warn "Skipped."; return
    }

    $settingName = "gateway-logs-to-law"
    $body = @{
        properties = @{
            workspaceId                    = $lawId
            logAnalyticsDestinationType    = "Dedicated"
            logs = @(
                @{ category = "GatewayLogs";             enabled = $true; retentionPolicy = @{ days = 0; enabled = $false } }
                @{ category = "DeveloperPortalAuditLogs"; enabled = $true; retentionPolicy = @{ days = 0; enabled = $false } }
            )
            metrics = @(
                @{ category = "AllMetrics"; enabled = $true; retentionPolicy = @{ days = 0; enabled = $false } }
            )
        }
    }

    $uri = "$mgmt$apimId/providers/Microsoft.Insights/diagnosticSettings/$($settingName)?api-version=2021-05-01-preview"
    try {
        Invoke-AzRest -method PUT -uri $uri -body $body | Out-Null
        Write-Ok "Diagnostic setting '$settingName' created on APIM."
        Write-Info "ApiManagementGatewayLogs will appear in LAW after ~5 minutes of traffic."
        Write-Info "Verify: ApiManagementGatewayLogs | take 5"
    } catch {
        Write-Fail "Failed to create diagnostic setting: $_"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Change 2 — App Gateway diagnostic settings → AGWAccessLogs
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Change2 {
    Write-Step "Change 2 — App Gateway diagnostic settings → AGWAccessLogs"

    if (-not $APPGW_NAME) {
        Write-Warn "No App Gateway found in '$RG'. Skipping."
        return
    }

    $appgwId = az network application-gateway show -n $APPGW_NAME -g $RG --query id -o tsv 2>$null

    Write-Info "Checking existing App Gateway diagnostic settings..."
    $existing = az monitor diagnostic-settings list --resource $appgwId `
        --query "[?workspaceId=='$lawId']" -o json 2>$null | ConvertFrom-Json

    if ($existing.Count -gt 0) {
        $hasAccessLog = $existing | ForEach-Object { $_.logs } | Where-Object { $_.category -eq 'ApplicationGatewayAccessLog' -and $_.enabled }
        if ($hasAccessLog) {
            Write-Ok "ApplicationGatewayAccessLog already enabled and sending to this Log Analytics workspace."
            return
        }
    }

    Write-Info "AGWAccessLogs not found in current diagnostic settings."
    Write-Info "This will create a dedicated-table diagnostic setting on:"
    Write-Info "  Resource : $APPGW_NAME"
    Write-Info "  LAW      : $lawId"
    Write-Info "  Tables   : AGWAccessLogs (dedicated)"
    Write-Info "  Risk     : Zero — read-only logging, no traffic impact"

    if (-not (Confirm-Step "Apply Change 2 (App Gateway diagnostic settings)?")) {
        Write-Warn "Skipped."; return
    }

    $settingName = "appgw-logs-to-law"
    $body = @{
        properties = @{
            workspaceId                    = $lawId
            logAnalyticsDestinationType    = "Dedicated"
            logs = @(
                @{ category = "ApplicationGatewayAccessLog";   enabled = $true; retentionPolicy = @{ days = 0; enabled = $false } }
                @{ category = "ApplicationGatewayFirewallLog";  enabled = $true; retentionPolicy = @{ days = 0; enabled = $false } }
                @{ category = "ApplicationGatewayPerformanceLog"; enabled = $true; retentionPolicy = @{ days = 0; enabled = $false } }
            )
            metrics = @(
                @{ category = "AllMetrics"; enabled = $true; retentionPolicy = @{ days = 0; enabled = $false } }
            )
        }
    }

    $uri = "$mgmt$appgwId/providers/Microsoft.Insights/diagnosticSettings/$($settingName)?api-version=2021-05-01-preview"
    try {
        Invoke-AzRest -method PUT -uri $uri -body $body | Out-Null
        Write-Ok "Diagnostic setting '$settingName' created on App Gateway."
        Write-Info "AGWAccessLogs will appear in LAW after ~5 minutes of traffic."
        Write-Info "Verify: AGWAccessLogs | take 5"
    } catch {
        Write-Fail "Failed to create diagnostic setting: $_"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Change 3 — App Insights logger + diagnostics wired to APIM
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Change3 {
    Write-Step "Change 3 — App Insights logger + diagnostics wired to APIM"

    if (-not $appInsightsId) {
        Write-Warn "No App Insights instance found in '$RG'."
        Write-Info "Create a workspace-based App Insights instance first, then re-run this change."
        Write-Info "See Step 3a in apply-to-existing-platforms-bicep.md"
        return
    }

    Write-Ok "App Insights : $appInsightsName ($appInsightsId)"

    # Check workspace-based
    $wsLink = az monitor app-insights component show -a $appInsightsName -g $RG `
        --query workspaceResourceId -o tsv 2>$null
    if (-not $wsLink) {
        Write-Warn "App Insights instance '$appInsightsName' is Classic (not workspace-based)."
        Write-Warn "AppRequests / AppDependencies tables will NOT be populated with a Classic instance."
        Write-Warn "Migrate to workspace-based or create a new instance linked to '$lawId'."
        Write-Warn "See Step 3a in apply-to-existing-platforms-bicep.md"
        if (-not (Confirm-Step "Continue anyway (logger will be created but tables may be missing)?")) {
            Write-Warn "Skipped."; return
        }
    } else {
        Write-Ok "App Insights is workspace-based — AppRequests/AppDependencies will populate."
    }

    Write-Info "This will:"
    Write-Info "  3b — Create/update APIM logger 'ai-logger' → App Insights (managed identity auth)"
    Write-Info "  3c — Create/update APIM diagnostics resource 'applicationinsights'"
    Write-Info "  Risk: Low — adds telemetry collection, no impact on request routing"

    if (-not (Confirm-Step "Apply Change 3 (App Insights wired to APIM)?")) {
        Write-Warn "Skipped."; return
    }

    # ── 3b: Create/update APIM logger ────────────────────────────────────────
    Write-Info "3b — Creating APIM logger 'ai-logger'..."
    $loggerUri = "$mgmt$apimRid/loggers/ai-logger?api-version=$apiVer"
    $loggerBody = @{
        properties = @{
            loggerType  = "applicationInsights"
            description = "Application Insights logger for AI gateway telemetry"
            resourceId  = $appInsightsId
            isBuffered  = $true
            credentials = @{
                connectionString = $appInsightsConnStr
                identityClientId = "SystemAssigned"
            }
        }
    }

    try {
        Invoke-AzRest -method PUT -uri $loggerUri -body $loggerBody | Out-Null
        Write-Ok "APIM logger 'ai-logger' created/updated."
    } catch {
        # May fail if DisableLocalAuth=false + connection string. Try with instrumentationKey fallback.
        Write-Warn "MSI-auth logger creation failed (App Insights may have DisableLocalAuth=false)."
        Write-Info "Retrying with instrumentation key (less secure — enable DisableLocalAuth when possible)..."
        $iKey = az monitor app-insights component show -a $appInsightsName -g $RG `
            --query instrumentationKey -o tsv 2>$null
        $loggerBody.properties.credentials = @{ instrumentationKey = $iKey }
        $loggerBody.properties.Remove('credentials') | Out-Null
        $loggerBody.properties.credentials = @{ instrumentationKey = $iKey }
        try {
            Invoke-AzRest -method PUT -uri $loggerUri -body $loggerBody | Out-Null
            Write-Ok "APIM logger 'ai-logger' created with instrumentation key."
            Write-Warn "Set DisableLocalAuth=true on App Insights and re-run to upgrade to MSI auth."
        } catch {
            Write-Fail "Could not create APIM logger: $_"; return
        }
    }

    # ── 3c: Create/update diagnostics resource ────────────────────────────────
    Write-Info "3c — Creating APIM diagnostics resource 'applicationinsights'..."
    $loggerResourceId = "$apimRid/loggers/ai-logger"
    $diagUri = "$mgmt$apimRid/diagnostics/applicationinsights?api-version=$apiVer"
    $diagBody = @{
        properties = @{
            loggerId    = $loggerResourceId
            alwaysLog   = "allErrors"
            sampling    = @{ samplingType = "fixed"; percentage = 100 }
            verbosity   = "information"
            httpCorrelationProtocol = "W3C"
            operationNameFormat     = "Url"
            frontend = @{
                request  = @{
                    headers = @("X-Correlation-Id")
                    body    = @{ bytes = 0 }
                }
                response = @{
                    headers = @("X-Backend-Region-Used","X-Correlation-Id","X-Tokens-Used","X-Cache")
                    body    = @{ bytes = 0 }
                }
            }
            backend = @{
                request  = @{ headers = @("X-Correlation-Id"); body = @{ bytes = 0 } }
                response = @{ headers = @("X-Backend-Region-Used","X-Correlation-Id"); body = @{ bytes = 0 } }
            }
        }
    }

    try {
        Invoke-AzRest -method PUT -uri $diagUri -body $diagBody | Out-Null
        Write-Ok "APIM diagnostics resource 'applicationinsights' created/updated."
        Write-Info "AppRequests and AppDependencies will populate after ~5 minutes of traffic."
        Write-Info "Verify: AppRequests | take 5"
    } catch {
        Write-Fail "Failed to create APIM diagnostics resource: $_"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Change 4 — X-Correlation-Id rewrite rule on App Gateway (optional)
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Change4 {
    Write-Step "Change 4 (optional) — X-Correlation-Id rewrite rule on App Gateway"

    if (-not $APPGW_NAME) {
        Write-Warn "No App Gateway found in '$RG'. Skipping."; return
    }

    Write-Info "This adds a rewrite rule set to App Gateway that stamps X-Correlation-Id"
    Write-Info "on every forwarded request using '{var_client_ip}-{var_client_port}'."
    Write-Info "Required for E2E Trace workbook to join AGWAccessLogs to AppRequests."
    Write-Info "Risk: Low — adds a header only, never blocks traffic."
    Write-Info ""
    Write-Warn "NOTE: This change requires a full App Gateway redeployment (no in-place patch)."
    Write-Warn "Recommended approach: add rewriteRuleSets to your Bicep/Terraform and run azd provision."
    Write-Warn "See Step 4 in apply-to-existing-platforms-bicep.md for the Bicep snippet."

    if (-not (Confirm-Step "Apply Change 4 via REST API (App Gateway rewrite rule)?")) {
        Write-Warn "Skipped."; return
    }

    # Full App Gateway GET → mutate → PUT (safest pattern for AGW)
    Write-Info "Fetching current App Gateway configuration..."
    $appgwId  = az network application-gateway show -n $APPGW_NAME -g $RG --query id -o tsv 2>$null
    $appgwUri = "$mgmt$appgwId`?api-version=2023-05-01"
    $appgw    = Invoke-AzRest -method GET -uri $appgwUri

    # Check if rule set already exists
    $existingRs = $appgw.properties.rewriteRuleSets | Where-Object { $_.name -eq 'inject-correlation-id' }
    if ($existingRs) {
        Write-Ok "Rewrite rule set 'inject-correlation-id' already exists."; return
    }

    $newRuleSet = @{
        name       = "inject-correlation-id"
        properties = @{
            rewriteRules = @(@{
                name         = "add-x-correlation-id"
                ruleSequence = 100
                conditions   = @()
                actionSet    = @{
                    requestHeaderConfigurations  = @(@{ headerName = "X-Correlation-Id"; headerValue = "{var_client_ip}-{var_client_port}" })
                    responseHeaderConfigurations = @(@{ headerName = "X-Correlation-Id"; headerValue = "{var_client_ip}-{var_client_port}" })
                }
            })
        }
    }

    # Append rule set
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

    Write-Info "Submitting updated App Gateway configuration (PUT)..."
    try {
        # Round-trip through JSON to get a plain hashtable the PUT body serializer can handle
        $appgwBody = $appgw | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        Invoke-AzRest -method PUT -uri $appgwUri -body $appgwBody | Out-Null
        Write-Ok "App Gateway rewrite rule 'inject-correlation-id' applied."
        Write-Info "Allow 2-5 minutes for the App Gateway to reprovisioning."
    } catch {
        Write-Fail "App Gateway PUT failed: $_"
        Write-Warn "Use Bicep/Terraform for this change instead. See Step 4 in apply-to-existing-platforms-bicep.md"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Change 5 — X-Backend-Region-Used header in APIM outbound policy (optional)
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Change5 {
    Write-Step "Change 5 (optional) — X-Backend-Region-Used header in APIM outbound policy"

    Write-Info "This adds a response header to the APIM API-level outbound policy."
    Write-Info "The Backend Routing Report workbook uses this header to split traffic"
    Write-Info "between Primary (East US) and Secondary (West US) Foundry regions."
    Write-Info "Risk: Low — adds a header, no routing change."
    Write-Info ""

    # Show available APIs
    Write-Info "Available APIs in APIM '$APIM_NAME':"
    $apis = az apim api list -g $RG -n $APIM_NAME --query "[].{name:name,path:path}" -o json 2>$null | ConvertFrom-Json
    $i = 1
    foreach ($api in $apis) { Write-Info "  $i. $($api.name)  ($($api.path))"; $i++ }

    $apiName = Read-Host "  Enter API name to update (or press Enter for 'model-inference')"
    if (-not $apiName) { $apiName = "model-inference" }

    # Fetch existing policy
    $policyUri = "$mgmt$apimRid/apis/$apiName/policies/policy?api-version=$apiVer&format=rawxml"
    $existingPolicy = $null
    try {
        $resp = Invoke-AzRest -method GET -uri $policyUri
        $existingPolicy = $resp.properties.value
    } catch {
        Write-Warn "Could not fetch existing policy for API '$apiName'. Starting with minimal policy."
        $existingPolicy = "<policies><inbound><base /></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>"
    }

    # Check if header already present
    if ($existingPolicy -match 'X-Backend-Region-Used') {
        Write-Ok "X-Backend-Region-Used header already present in API '$apiName' policy."; return
    }

    # Inject the set-header element before the closing </outbound> tag
    $snippet = "`n  <set-header name=`"X-Backend-Region-Used`" exists-action=`"override`">`n    <value>@(context.Variables.GetValueOrDefault(`"selectedBackend`", `"primary`"))</value>`n  </set-header>"
    $newPolicy = $existingPolicy -replace '(</outbound>)', "$snippet`$1"

    Write-Info "Updated policy outbound section will include:"
    Write-Info "  <set-header name='X-Backend-Region-Used' exists-action='override'>"
    Write-Info "    <value>@(context.Variables.GetValueOrDefault('selectedBackend', 'primary'))</value>"
    Write-Info "  </set-header>"
    Write-Info ""
    Write-Warn "This reads a policy variable 'selectedBackend'. Ensure your circuit-breaker"
    Write-Warn "policy sets: <set-variable name='selectedBackend' value='primary'/> or 'secondary'."

    if (-not (Confirm-Step "Apply Change 5 (set X-Backend-Region-Used in API '$apiName')?")) {
        Write-Warn "Skipped."; return
    }

    $policyPutUri = "$mgmt$apimRid/apis/$apiName/policies/policy?api-version=$apiVer"
    $policyBody = @{
        properties = @{
            format = "rawxml"
            value  = $newPolicy
        }
    }
    try {
        Invoke-AzRest -method PUT -uri $policyPutUri -body $policyBody | Out-Null
        Write-Ok "Policy updated for API '$apiName'."
        Write-Info "X-Backend-Region-Used header will appear in APIM responses immediately."
    } catch {
        Write-Fail "Failed to update policy: $_"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Main dispatch
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-ChangeByKey([string]$key) {
    switch ($key) {
        '1'   { Invoke-Change1 }
        '2'   { Invoke-Change2 }
        '3'   { Invoke-Change3 }
        '4'   { Invoke-Change4 }
        '5'   { Invoke-Change5 }
        'All' { Invoke-Change1; Invoke-Change2; Invoke-Change3 }
        default { Write-Warn "Unknown option: $key" }
    }
}

# Non-interactive mode
if ($Change -and $Change -ne '') {
    Invoke-ChangeByKey -key $Change
    exit 0
}

# Interactive menu loop
do {
    Show-Menu
    $selection = (Read-Host "Select change to apply [1-5 / A=All 1-3 / Q=Quit]").Trim().ToUpper()

    switch ($selection) {
        '1' { Invoke-Change1 }
        '2' { Invoke-Change2 }
        '3' { Invoke-Change3 }
        '4' { Invoke-Change4 }
        '5' { Invoke-Change5 }
        'A' { Invoke-Change1; Invoke-Change2; Invoke-Change3 }
        'Q' { Write-Host "Exiting." -ForegroundColor Cyan; exit 0 }
        default { Write-Warn "Invalid selection '$selection'. Enter 1-5, A, or Q." }
    }

    Write-Host ""
} while ($true)
