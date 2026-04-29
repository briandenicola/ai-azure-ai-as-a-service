# _resolve-env.ps1 — dot-source this at the top of scripts that need Azure env vars.
# Usage: . "$PSScriptRoot/_resolve-env.ps1"
#
# Resolves common variables from the active azd environment and live Azure resources.
# Falls back to environment variables, then az CLI defaults.
#
# Variables set in the caller's scope:
#   $SUB_ID            — Azure subscription ID
#   $RG                — Resource group name
#   $PRIMARY_LOCATION  — Primary Azure region (from azd env, default 'eastus')
#   $companyPrefix     — Company name prefix (from azd env, default 'contoso')
#   $APIM_NAME         — APIM instance name (resolved from resource group)
#   $base              — ARM management base URL for APIM
#   $t / $tok          — ARM bearer token (both aliases set)
#   $FOUNDRY_PRIMARY   — Primary Foundry AIServices account name
#   $FOUNDRY_SECONDARY — Secondary Foundry AIServices account name
#   $APPGW_NAME        — App Gateway name ('' if not deployed)
#   $APPGW_FQDN        — App Gateway public FQDN ('' if not deployed)
#   $KV_NAME           — Key Vault name ('' if not found)

function _Resolve-AzdEnv {
    param([string]$VarName)
    $line = azd env get-values 2>$null | Select-String "^$VarName="
    if (-not $line) { return '' }
    return ($line.ToString() -replace "^$VarName=`"?|`"?$", '').Trim()
}

# ── Subscription & resource group ────────────────────────────────────────────
$SUB_ID = $env:AZURE_SUBSCRIPTION_ID
if (-not $SUB_ID) { $SUB_ID = _Resolve-AzdEnv 'AZURE_SUBSCRIPTION_ID' }
if (-not $SUB_ID) { $SUB_ID = az account show --query id -o tsv 2>$null }
if (-not $SUB_ID) { Write-Error "Cannot determine Azure subscription ID. Run 'az login'."; exit 1 }

$RG = $env:AZURE_RESOURCE_GROUP
if (-not $RG) { $RG = _Resolve-AzdEnv 'AZURE_RESOURCE_GROUP' }
if (-not $RG) { Write-Error "AZURE_RESOURCE_GROUP is not set. Run 'azd env get-values' or set the environment variable."; exit 1 }

# ── Location & company prefix ────────────────────────────────────────────────
$PRIMARY_LOCATION = $env:AZURE_LOCATION
if (-not $PRIMARY_LOCATION) { $PRIMARY_LOCATION = _Resolve-AzdEnv 'AZURE_LOCATION' }
if (-not $PRIMARY_LOCATION) { $PRIMARY_LOCATION = 'eastus' }

$companyPrefix = $env:AZURE_COMPANY_PREFIX
if (-not $companyPrefix) { $companyPrefix = _Resolve-AzdEnv 'AZURE_COMPANY_PREFIX' }
if (-not $companyPrefix) { $companyPrefix = 'contoso' }

# ── APIM ─────────────────────────────────────────────────────────────────────
$APIM_NAME = az apim list -g $RG --query "[0].name" -o tsv 2>$null
if (-not $APIM_NAME) {
    Write-Warning "No APIM instance found in resource group '$RG'. Some operations may fail."
    $APIM_NAME = ''
    $base      = ''
} else {
    $base = "https://management.azure.com/subscriptions/$SUB_ID/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$APIM_NAME"
}

# ── ARM bearer token ─────────────────────────────────────────────────────────
$t   = az account get-access-token --query accessToken -o tsv 2>$null
$tok = $t   # alias: some scripts use $tok, others $t

# ── Foundry AIServices accounts ──────────────────────────────────────────────
$_foundryJson = az cognitiveservices account list -g $RG `
    --query "[?kind=='AIServices'].{name:name,location:location}" -o json 2>$null
$_foundryAccounts  = if ($_foundryJson) { $_foundryJson | ConvertFrom-Json } else { @() }
$FOUNDRY_PRIMARY   = ($_foundryAccounts | Where-Object { $_.location -eq $PRIMARY_LOCATION } | Select-Object -First 1).name
$FOUNDRY_SECONDARY = ($_foundryAccounts | Where-Object { $_.location -ne $PRIMARY_LOCATION } | Select-Object -First 1).name

# ── App Gateway (optional — may not be deployed) ─────────────────────────────
$APPGW_NAME = az network application-gateway list -g $RG --query "[0].name" -o tsv 2>$null
$APPGW_FQDN = ''
if ($APPGW_NAME) {
    $APPGW_FQDN = az network public-ip list -g $RG `
        --query "[?contains(name,'agw')].dnsSettings.fqdn | [0]" -o tsv 2>$null
}
# Fallback: if App Gateway not yet deployed, derive the expected FQDN from the APIM name.
# DNS label in Bicep = toLower('${companyPrefix}-ai-gw-${apimNameSuffix}').
if (-not $APPGW_FQDN -and $APIM_NAME) {
    $_apimSuffix   = ($APIM_NAME -replace "^apim-$companyPrefix-", '')
    $_appGwDnsLabel = "$($companyPrefix.ToLower())-ai-gw-$_apimSuffix"
    $APPGW_FQDN    = "$_appGwDnsLabel.$PRIMARY_LOCATION.cloudapp.azure.com"
}

# ── Key Vault ────────────────────────────────────────────────────────────────
$KV_NAME = az keyvault list -g $RG --query "[0].name" -o tsv 2>$null
