# analyze-appinsights.ps1
# Queries App Insights (workspace-based) for the three key views that show traffic flow:
#   1. Requests by status code + operation (what APIM received / returned)
#   2. Dependency calls (APIM → Foundry backend breakdown)
#   3. Error details (failed requests with response codes)
#
# Queries via Log Analytics workspace API — the authoritative endpoint for
# workspace-based App Insights. All App Insights tables (AppRequests, AppDependencies,
# etc.) are available directly in the linked LAW.
#
# Usage:
#   pwsh scripts/analyze-appinsights.ps1
#   pwsh scripts/analyze-appinsights.ps1 -StartTime "2026-03-24T17:49:00Z" -EndTime "2026-03-24T17:58:00Z"

param(
    [string] $WorkspaceId = ($env:AZURE_LAW_CUSTOMER_ID ?? (az monitor log-analytics workspace list -g ($env:AZURE_RESOURCE_GROUP ?? (azd env get-values 2>$null | Select-String '^AZURE_RESOURCE_GROUP=' | ForEach-Object { $_ -replace '^AZURE_RESOURCE_GROUP="?|"?$','' })) --query '[0].customerId' -o tsv 2>$null)),
    [string] $StartTime   = ((Get-Date).ToUniversalTime().AddHours(-1).ToString("yyyy-MM-ddTHH:mm:ssZ")),
    [string] $EndTime     = ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Auth — acquire bearer token for the Log Analytics REST API
# ---------------------------------------------------------------------------
$token = az account get-access-token --resource "https://api.loganalytics.io" --query accessToken -o tsv 2>$null
if (-not $token) { Write-Error "Could not acquire access token. Run 'az login' first." }

function Invoke-AppInsightsQuery([string]$kql) {
    $body = ConvertTo-Json @{ query = $kql } -Compress
    $resp = Invoke-RestMethod `
        -Uri     "https://api.loganalytics.io/v1/workspaces/$WorkspaceId/query" `
        -Method  POST `
        -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
        -Body    $body
    $cols = $resp.tables[0].columns.name
    $resp.tables[0].rows | ForEach-Object {
        $row = $_; $i = 0; $h = [ordered]@{}
        $cols | ForEach-Object { $h[$_] = $row[$i++] }
        [PSCustomObject]$h
    }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════"
Write-Host "  App Insights Traffic Analysis"
Write-Host "  Window : $StartTime  →  $EndTime"
Write-Host "═══════════════════════════════════════════════════════════════════════"

# Workspace-based App Insights schema (migrated from Classic):
#   AppRequests   — APIM incoming requests   (was: requests)
#   AppDependencies — APIM → Foundry calls  (was: dependencies)
#   TimeGenerated — event timestamp         (was: timestamp)
#   DurationMs    — latency in ms           (was: duration)
#   Success       — bool                    (was: success)
#   ResultCode    — HTTP status string      (was: resultCode)
#   OperationId   — W3C trace id           (was: operation_Id)
#   Properties    — custom dimensions       (was: customDimensions)

# ---------------------------------------------------------------------------
# 1. APIM request breakdown — by operation + HTTP status code
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "── 1. APIM INCOMING REQUESTS (by operation + status) ─────────────────"
$q1 = @"
AppRequests
| where TimeGenerated between(datetime('$StartTime') .. datetime('$EndTime'))
| summarize
    Requests = count(),
    Errors   = countif(Success == false),
    AvgMs    = round(avg(DurationMs), 0),
    P50      = round(percentile(DurationMs, 50), 0),
    P90      = round(percentile(DurationMs, 90), 0),
    P99      = round(percentile(DurationMs, 99), 0)
  by Status=ResultCode, Operation=Name
| sort by Requests desc
"@
$r1 = Invoke-AppInsightsQuery $q1
if ($r1) { $r1 | Format-Table -AutoSize } else { Write-Host "  (no data in window)" }

# ---------------------------------------------------------------------------
# 2. APIM → Foundry dependency calls — backend traffic
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "── 2. APIM → FOUNDRY BACKEND CALLS (dependencies) ───────────────────"
$q2 = @"
AppDependencies
| where TimeGenerated between(datetime('$StartTime') .. datetime('$EndTime'))
| where Type == "HTTP"
| summarize
    Calls    = count(),
    Failures = countif(Success == false),
    AvgMs    = round(avg(DurationMs), 0),
    P50      = round(percentile(DurationMs, 50), 0),
    P90      = round(percentile(DurationMs, 90), 0),
    P99      = round(percentile(DurationMs, 99), 0)
  by Target=Target, Status=ResultCode, Operation=Name
| sort by Calls desc
"@
$r2 = Invoke-AppInsightsQuery $q2
if ($r2) { $r2 | Format-Table -AutoSize } else { Write-Host "  (no data — APIM diagnostics may not yet be emitting dependencies)" }

# ---------------------------------------------------------------------------
# 3. Layer latency split — APIM overhead vs Foundry inference
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "── 3. LAYER LATENCY SPLIT (APIM overhead vs Foundry inference) ──────"
$q3 = @"
let apim = AppRequests
    | where TimeGenerated between(datetime('$StartTime') .. datetime('$EndTime'))
    | project opId=OperationId, apimMs=DurationMs, ok=Success, status=ResultCode;
let foundry = AppDependencies
    | where TimeGenerated between(datetime('$StartTime') .. datetime('$EndTime'))
    | where Type == "HTTP"
    | summarize foundryMs = avg(DurationMs) by opId=OperationId;
apim
| join kind=leftouter foundry on opId
| extend foundryMs      = iff(isnotempty(foundryMs), foundryMs, 0.0)
| extend apimOverheadMs = max_of(apimMs - foundryMs, 0.0)
| summarize
    Requests      = count(),
    AvgTotalMs    = round(avg(apimMs), 0),
    AvgFoundryMs  = round(avg(foundryMs), 0),
    AvgApimOvhd   = round(avg(apimOverheadMs), 0),
    P99TotalMs    = round(percentile(apimMs, 99), 0),
    P99FoundryMs  = round(percentile(foundryMs, 99), 0),
    SuccessRate   = round(100.0 * countif(ok == true) / count(), 1)
  by Status=tostring(status)
| sort by Requests desc
"@
$r3 = Invoke-AppInsightsQuery $q3
if ($r3) { $r3 | Format-Table -AutoSize } else { Write-Host "  (no data)" }

# ---------------------------------------------------------------------------
# 4. Error breakdown — what went wrong and what codes
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "── 4. ERROR DETAIL ───────────────────────────────────────────────────"
$q4 = @"
AppRequests
| where TimeGenerated between(datetime('$StartTime') .. datetime('$EndTime'))
| where Success == false
| summarize
    Count  = count(),
    AvgMs  = round(avg(DurationMs), 0),
    Sample = any(Id)
  by Status=ResultCode, Operation=Name
| sort by Count desc
"@
$r4 = Invoke-AppInsightsQuery $q4
if ($r4) { $r4 | Format-Table -AutoSize } else { Write-Host "  (no errors in window)" -ForegroundColor Green }

# ---------------------------------------------------------------------------
# 5. Per-minute request + error rate — shows rate limiter engagement
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "── 5. PER-MINUTE REQUEST + ERROR RATE ────────────────────────────────"
$q5 = @"
AppRequests
| where TimeGenerated between(datetime('$StartTime') .. datetime('$EndTime'))
| summarize
    Requests = count(),
    Errors   = countif(Success == false),
    ErrPct   = round(100.0 * countif(Success == false) / count(), 1)
  by bin(TimeGenerated, 1m)
| sort by TimeGenerated asc
"@
$r5 = Invoke-AppInsightsQuery $q5
if ($r5) { $r5 | Format-Table -AutoSize } else { Write-Host "  (no data)" }

# ---------------------------------------------------------------------------
# 6. X-Correlation-Id coverage — AppGW → APIM header propagation check
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "── 6. X-CORRELATION-ID COVERAGE (AppGW→APIM header propagation) ─────"
$q6 = @"
AppRequests
| where TimeGenerated between(datetime('$StartTime') .. datetime('$EndTime'))
| extend corrId = tostring(Properties["Request-Header-X-Correlation-Id"])
| summarize
    Total         = count(),
    WithCorrId    = countif(isnotempty(corrId)),
    WithoutCorrId = countif(isempty(corrId)),
    CoveragePct   = round(100.0 * countif(isnotempty(corrId)) / count(), 1)
"@
$r6 = Invoke-AppInsightsQuery $q6
if ($r6) { $r6 | Format-Table -AutoSize } else { Write-Host "  (no data)" }

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════"
Write-Host "  Transaction Search (Portal drilldown):"
$_sub = $env:AZURE_SUBSCRIPTION_ID ?? (az account show --query id -o tsv 2>$null)
$_rg  = $env:AZURE_RESOURCE_GROUP  ?? (azd env get-values 2>$null | Select-String '^AZURE_RESOURCE_GROUP=' | ForEach-Object { $_ -replace '^AZURE_RESOURCE_GROUP="?|"?$','' })
$_appInsights = az monitor app-insights component list -g $_rg --query '[0].name' -o tsv 2>$null
Write-Host "  https://portal.azure.com/#resource/subscriptions/$_sub/resourceGroups/$_rg/providers/microsoft.insights/components/$_appInsights/searchV1"
Write-Host "═══════════════════════════════════════════════════════════════════════"
