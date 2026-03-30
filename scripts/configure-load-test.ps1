# configure-load-test.ps1
#
# azd postprovision hook — creates the ALT test definition for the
# AI-as-a-Service APIM gateway load test.
#
# Runs automatically after `azd provision` when AZURE_DEPLOY_LOAD_TEST=true.
# Can also be run manually: pwsh scripts/configure-load-test.ps1
#
# Prerequisites:
#   azd env set AZURE_DEPLOY_LOAD_TEST true
#   azd provision   ← must run first to create the ALT resource

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Wrap the entire script so postprovision hook always exits 0 (best-effort step)
trap {
    Write-Warning "configure-load-test.ps1: non-fatal error — $($_.Exception.Message)"
    Write-Warning "Load test configuration was skipped. Re-run 'pwsh scripts/configure-load-test.ps1' manually after fixing the issue."
    exit 0
}

# ---------------------------------------------------------------------------
# 1. Check if load test deployment is enabled
# ---------------------------------------------------------------------------
$deployLoadTest = $env:AZURE_DEPLOY_LOAD_TEST
if ($deployLoadTest -ne 'true') {
    Write-Host "AZURE_DEPLOY_LOAD_TEST is not 'true' — skipping load test configuration."
    exit 0
}

# ---------------------------------------------------------------------------
# 2. Resolve values from azd env
# ---------------------------------------------------------------------------
$RG        = $env:AZURE_RESOURCE_GROUP
$prefix    = $env:AZURE_ENV_NAME ?? 'dev'
$companyPrefix = 'contoso'   # matches main.bicep companyPrefix default

# Derive the ALT resource name the same way main.bicep does
$altName   = "lt-$companyPrefix-ai-$prefix"

# APIM hostname (strip the https:// prefix from the gateway URL)
$apimUrl   = $env:APIM_GATEWAY_URL
if (-not $apimUrl) {
    Write-Error "APIM_GATEWAY_URL is not set. Run 'azd env get-values' to check outputs."
}
$apimHostname = $apimUrl -replace '^https?://', '' -replace '/$', ''

# Subnet ID for VNet injection
$subnetId  = $env:LOAD_TEST_SUBNET_ID
if (-not $subnetId) {
    Write-Error "LOAD_TEST_SUBNET_ID is not set. Run 'azd env get-values' to check outputs."
}

# ---------------------------------------------------------------------------
# 3. Install the az load extension if not present
# ---------------------------------------------------------------------------
Write-Host "Checking az load extension..."
$ext = az extension list --query "[?name=='load'].name" -o tsv 2>$null
if ($ext -ne 'load') {
    Write-Host "Installing az load extension..."
    az extension add --name load --yes
}

# ---------------------------------------------------------------------------
# 4. Fetch APIM subscription keys
# ---------------------------------------------------------------------------
Write-Host "Fetching APIM subscription keys..."

# Derive APIM name from its gateway URL (strip .azure-api.net)
$apimName  = $apimHostname -replace '\.azure-api\.net$', ''

$bronzeKey = az apim subscription show `
    --service-name $apimName `
    --resource-group $RG `
    --subscription-id bronze-test `
    --query primaryKey -o tsv 2>$null

$silverKey = az apim subscription show `
    --service-name $apimName `
    --resource-group $RG `
    --subscription-id silver-test `
    --query primaryKey -o tsv 2>$null

if (-not $bronzeKey) { Write-Warning "Could not fetch bronze-test key — BRONZE_KEY will be empty in the test." }
if (-not $silverKey) { Write-Warning "Could not fetch silver-test key — SILVER_KEY will be empty in the test." }

# ---------------------------------------------------------------------------
# 5. Update JMX User-Defined Variables with current APIM keys
# ---------------------------------------------------------------------------
# Azure Load Testing stores env vars in its test definition but does NOT inject
# them as JMeter variables or -J properties at runtime. The JMX therefore uses
# User-Defined Variables (UDVs) as the source of truth for the keys at test
# execution time. We update the UDV values here on every provision so that key
# rotation is handled automatically without manual JMX edits.

$jmxPath = Join-Path $PSScriptRoot '..' 'tests' 'apim-load-test.jmx'
if ($bronzeKey -and $silverKey) {
    Write-Host "Updating JMX UDV values with current APIM keys..."
    [xml]$jmx = Get-Content $jmxPath -Raw
    $jmx.SelectNodes("//elementProp[@name='BRONZE_KEY']/stringProp[@name='Argument.value']") |
        ForEach-Object { $_.'#text' = $bronzeKey }
    $jmx.SelectNodes("//elementProp[@name='SILVER_KEY']/stringProp[@name='Argument.value']") |
        ForEach-Object { $_.'#text' = $silverKey }
    $jmx.SelectNodes("//elementProp[@name='APIM_HOSTNAME']/stringProp[@name='Argument.value']") |
        ForEach-Object { $_.'#text' = $apimHostname }
    $jmx.Save($jmxPath)
    Write-Host "JMX UDVs updated."
} else {
    Write-Warning "Skipping JMX UDV update — one or both keys could not be fetched."
}

# ---------------------------------------------------------------------------
# 6. Write a temporary ALT config YAML
# ---------------------------------------------------------------------------
# The config YAML stores env vars on the ALT test definition for reference.
# Note: ALT does NOT inject environmentVariables as JMeter variables at
# runtime — the JMX UDVs updated above are the actual key source.
#
# testPlan path is relative to the config file's location — since we write
# the config to the repo root's tests/ folder, testPlan is just the filename.

$configPath = Join-Path $PSScriptRoot '..' 'tests' '_alt-config.yaml'
$jmxRelPath = 'apim-load-test.jmx'   # relative to tests/

$yaml = @"
version: v0.1
testId: apim-smoke-test
displayName: "APIM Smoke Test"
description: "Bronze/Silver smoke tests against /openai and /models (auto-configured by azd postprovision)"
testPlan: $jmxRelPath
engineInstances: 1
subnetId: "$subnetId"
env:
  - name: APIM_HOSTNAME
    value: "$apimHostname"
  - name: API_VERSION
    value: "2024-10-21"
  - name: BRONZE_KEY
    value: "$bronzeKey"
  - name: SILVER_KEY
    value: "$silverKey"
"@

Set-Content -Path $configPath -Value $yaml -Encoding UTF8
Write-Host "Wrote ALT config to $configPath"

# ---------------------------------------------------------------------------
# 7. Create or update the test definition
# ---------------------------------------------------------------------------
Write-Host "Checking if test 'apim-smoke-test' already exists in $altName..."
$exists = az load test show `
    --load-test-resource $altName `
    --resource-group $RG `
    --test-id apim-smoke-test `
    --query testId -o tsv 2>$null

$testsDir = Join-Path $PSScriptRoot '..' 'tests'

if ($exists -eq 'apim-smoke-test') {
    Write-Host "Test exists — updating..."
    az load test update `
        --load-test-resource $altName `
        --resource-group $RG `
        --test-id apim-smoke-test `
        --load-test-config-file $configPath `
        --test-plan (Join-Path $testsDir 'apim-load-test.jmx')
} else {
    Write-Host "Creating test..."
    az load test create `
        --load-test-resource $altName `
        --resource-group $RG `
        --test-id apim-smoke-test `
        --load-test-config-file $configPath `
        --test-plan (Join-Path $testsDir 'apim-load-test.jmx')
}

# ---------------------------------------------------------------------------
# 8. Clean up temporary config (contains subscription keys in plaintext)
# ---------------------------------------------------------------------------
Remove-Item $configPath -Force
Write-Host "Removed temporary config file."

Write-Host ""
Write-Host "Load test configured. To run it:"
Write-Host "  az load test-run create --load-test-resource $altName -g $RG --test-id apim-smoke-test --test-run-id run-$(Get-Date -Format 'yyyyMMdd-HHmm') --display-name 'Smoke test'"
Write-Host "  Portal: https://portal.azure.com/#resource$(($subnetId -split '/subnets')[0] -replace '/virtualNetworks/.*', '')/overview"
