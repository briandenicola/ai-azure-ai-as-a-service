# migrate-appinsights-to-workspace.ps1
# One-time migration: convert Classic App Insights → workspace-based.
# In-place: no data loss, no resource recreation. Takes ~10 seconds.
#
# Workspace-based is required for:
#   - Cross-source KQL joins (AGWAccessLogs + AppRequests in same LAW)
#   - E2E trace workbook
#   - Full audit trail per PCI DSS Req 10
#
# Usage:
#   pwsh scripts/migrate-appinsights-to-workspace.ps1

[CmdletBinding()]
param(
    [string] $SubscriptionId    = ($env:AZURE_SUBSCRIPTION_ID ?? (az account show --query id -o tsv 2>$null)),
    [string] $ResourceGroup     = ($env:AZURE_RESOURCE_GROUP   ?? (azd env get-values 2>$null | Select-String '^AZURE_RESOURCE_GROUP=' | ForEach-Object { $_ -replace '^AZURE_RESOURCE_GROUP="?|"?$','' })),
    [string] $AppInsightsName   = "appi-$((azd env get-values 2>$null | Select-String '^AZURE_ENV_NAME=' | ForEach-Object { $_ -replace '^AZURE_ENV_NAME="?|"?$','' }) ?? 'contoso-ai-dev')",
    [string] $WorkspaceName     = "law-$((azd env get-values 2>$null | Select-String '^AZURE_ENV_NAME=' | ForEach-Object { $_ -replace '^AZURE_ENV_NAME="?|"?$','' }) ?? 'contoso-ai-dev')",
    [string] $Location          = ($env:AZURE_LOCATION ?? (azd env get-values 2>$null | Select-String '^AZURE_LOCATION=' | ForEach-Object { $_ -replace '^AZURE_LOCATION="?|"?$','' }) ?? 'eastus')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Auth ──────────────────────────────────────────────────────────────────────
Write-Host "Acquiring ARM access token..."
$token = az account get-access-token --query accessToken -o tsv 2>$null
if (-not $token) { throw "Could not get access token. Run 'az login' first." }

# ── Build resource IDs ────────────────────────────────────────────────────────
$wsId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName"
$aiUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/microsoft.insights/components/${AppInsightsName}?api-version=2020-02-02"

# ── Show current state ────────────────────────────────────────────────────────
Write-Host "`nCurrent state:"
$current = Invoke-RestMethod -Uri $aiUri -Method GET -Headers @{ Authorization = "Bearer $token" }
Write-Host "  IngestionMode      : $($current.properties.IngestionMode)"
Write-Host "  WorkspaceResourceId: $($current.properties.WorkspaceResourceId)"

if ($current.properties.WorkspaceResourceId) {
    Write-Host "`nAlready workspace-based. No action needed." -ForegroundColor Green
    exit 0
}

# ── Perform migration ─────────────────────────────────────────────────────────
Write-Host "`nMigrating to workspace-based App Insights..."

$body = @{
    location   = $Location
    kind       = "web"
    properties = @{
        Application_Type                = "web"
        WorkspaceResourceId             = $wsId
        IngestionMode                   = "LogAnalytics"
        RetentionInDays                 = 365
        publicNetworkAccessForIngestion = "Enabled"
        publicNetworkAccessForQuery     = "Enabled"
    }
} | ConvertTo-Json -Depth 5

$resp = Invoke-RestMethod `
    -Uri     $aiUri `
    -Method  PUT `
    -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
    -Body    $body

# ── Verify ────────────────────────────────────────────────────────────────────
Write-Host "`nResult:"
Write-Host "  name               : $($resp.name)"
Write-Host "  IngestionMode      : $($resp.properties.IngestionMode)"
Write-Host "  WorkspaceResourceId: $($resp.properties.WorkspaceResourceId)"

if ($resp.properties.WorkspaceResourceId) {
    Write-Host "`nMigration successful! App Insights is now workspace-based." -ForegroundColor Green
    Write-Host "  Telemetry tables: AppRequests, AppDependencies, AppExceptions, AppTraces" -ForegroundColor Cyan
    Write-Host "  New data arrives in LAW within ~2-3 minutes." -ForegroundColor Cyan
} else {
    Write-Error "Migration may not have applied — WorkspaceResourceId is still null."
}
