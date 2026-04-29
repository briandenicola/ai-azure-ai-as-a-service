# smoke-test.ps1 — quick end-to-end check through APIM
# Reads all values from the azd environment — no hardcoded secrets.
#
# Prerequisites: azd provision completed, az CLI logged in.
# Usage: pwsh scripts/smoke-test.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolve environment from azd
# ---------------------------------------------------------------------------
function Get-AzdEnv {
    param([string]$Name)
    $line = azd env get-values 2>$null | Select-String "^$Name="
    return ($line -replace "^$Name=`"?|`"?$", '').Trim()
}

$RG          = $env:AZURE_RESOURCE_GROUP ?? (Get-AzdEnv 'AZURE_RESOURCE_GROUP')
$SUB_ID      = $env:AZURE_SUBSCRIPTION_ID ?? (Get-AzdEnv 'AZURE_SUBSCRIPTION_ID')
$envName     = $env:AZURE_ENV_NAME ?? (Get-AzdEnv 'AZURE_ENV_NAME') ?? 'dev'
$apimName    = "apim-contoso-$($(az account show --query id -o tsv 2>$null) | ForEach-Object { $_.Substring(0,8) })"

if (-not $RG -or -not $SUB_ID) {
    Write-Error "AZURE_RESOURCE_GROUP and AZURE_SUBSCRIPTION_ID must be set. Run 'azd env get-values'."
}

# ---------------------------------------------------------------------------
# Fetch Bronze key live from APIM
# ---------------------------------------------------------------------------
Write-Host "Fetching Bronze subscription key from APIM..." -ForegroundColor Cyan
$apimList = az apim list -g $RG --query "[].name" -o tsv 2>$null
$apimName  = ($apimList -split "`n")[0].Trim()
if (-not $apimName) { Write-Error "No APIM instance found in resource group '$RG'." }

$bronzeKey = (az rest --method POST `
    --uri "https://management.azure.com/subscriptions/$SUB_ID/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$apimName/subscriptions/bronze-test/listSecrets?api-version=2022-08-01" `
    2>$null | ConvertFrom-Json).primaryKey

if (-not $bronzeKey) { Write-Error "Could not retrieve Bronze subscription key from APIM '$apimName'." }
Write-Host "  Key: $($bronzeKey.Substring(0,8))..." -ForegroundColor Green

# ---------------------------------------------------------------------------
# Resolve APIM endpoint — use App Gateway FQDN if available, else APIM direct
# ---------------------------------------------------------------------------
$appgwFqdn = az network public-ip list -g $RG `
    --query "[?contains(name,'agw')].dnsSettings.fqdn" -o tsv 2>$null |
    Select-Object -First 1

$endpoint = if ($appgwFqdn) {
    Write-Host "  Via App Gateway: $appgwFqdn" -ForegroundColor Green
    "https://$appgwFqdn"
} else {
    Write-Host "  App Gateway not deployed — calling APIM directly." -ForegroundColor Yellow
    "https://$apimName.azure-api.net"
}

# ---------------------------------------------------------------------------
# Send test request
# ---------------------------------------------------------------------------
$headers = @{
    "Ocp-Apim-Subscription-Key" = $bronzeKey
    "Content-Type"               = "application/json"
}
$body = '{"messages":[{"role":"user","content":"Reply with exactly one word: Hello"}],"max_tokens":5}'

Write-Host ""
Write-Host "Sending smoke test request to $endpoint ..." -ForegroundColor Cyan
$r = Invoke-WebRequest -Uri "$endpoint/openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-02-01" `
    -Method POST -Headers $headers -Body $body -UseBasicParsing

Write-Host "Status:           $($r.StatusCode)"
Write-Host "Backend region:   $($r.Headers['X-Backend-Region-Used'])"
Write-Host "Tokens remaining: $($r.Headers['X-Token-Remaining'])"
if ($r.Content.Length -gt 0) {
    $json = $r.Content | ConvertFrom-Json
    Write-Host "Finish reason:    $($json.choices[0].finish_reason)"
    Write-Host "Answer:           $($json.choices[0].message.content)"
    Write-Host "Tokens used:      prompt=$($json.usage.prompt_tokens) completion=$($json.usage.completion_tokens)"
} else {
    Write-Warning "Empty response body!"
}
