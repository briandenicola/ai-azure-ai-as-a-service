#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Run the App Gateway failover load test (appgw-failover-test).

.DESCRIPTION
  Overview of what this script does:
    1. Verify App Gateway is deployed.
    2. Fetch live APIM subscription keys.
    3. Create / update ALT test 'appgw-failover-test' with failover-load-test.jmx.
    4. Upload system.properties (trustStore=NONE) and user.properties (keys).
    5. Fire the test run and poll until complete.
    6. Display results — including failover % from the JMeter tearDown sampler.

  The failover-retry policy on the openai-inference API is provisioned by
  'azd provision' (infrastructure/bicep/apim-gateway.bicep) — no manual
  policy deployment needed from this script.

  Traffic path:
    JMeter (20 threads, 5s think time) → AppGW WAF v2 → APIM openai-inference
      → primary 429 (1K TPM exhausted) → APIM retries → secondary Foundry → 200
        X-Backend-Region-Used: secondary-failover

.NOTES
  Prerequisites:
    • scripts/create-appgw-cert.ps1 has been run (truststore exists)
    • azd provision completed (App Gateway + APIM deployed)
    • APIM has 'foundry-primary-endpoint' and 'foundry-secondary-endpoint' Named Values

  Primary gpt-4o-mini is kept at 1K TPM permanently so every run produces
  genuine 429s without any setup. To restore TPM manually if needed, run
  scripts/check-foundry-capacity.ps1 to find account names, then:
    az cognitiveservices account deployment update -g <RG> --account-name <foundry-primary> \
        --deployment-name gpt-4o-mini --sku-capacity 10
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Constants ───────────────────────────────────────────────────────────────────
. "$PSScriptRoot/_resolve-env.ps1"

$ALT_RG   = $RG
$TEST_ID  = 'appgw-failover-test'

# Discover Azure Load Testing resource name from the resource group
$ALT_RESOURCE = az load list -g $RG --query '[0].name' -o tsv 2>$null
if (-not $ALT_RESOURCE) { Write-Error "No Azure Load Testing resource found in '$RG'. Run: azd provision" }

# Primary gpt-4o-mini is permanently kept at 1K TPM — genuine 429s at test RPS.
# Failover policy is provisioned by azd (infrastructure/bicep/apim-gateway.bicep).

$repoRoot = Split-Path -Parent $PSScriptRoot

# ── Step 1: Verify App Gateway is deployed ──────────────────────────────────────
Write-Host ""
Write-Host "=== Step 1: Verify App Gateway is deployed ===" -ForegroundColor Cyan

$appgw = az network application-gateway list -g $ALT_RG `
    --query "[0].{name:name,state:operationalState}" `
    -o json 2>$null | ConvertFrom-Json

if (-not $appgw) {
    Write-Error "No App Gateway found in '$ALT_RG'.`nRun: azd provision"
}
Write-Host "  App Gateway: $($appgw.name) — state: $($appgw.state)" -ForegroundColor Green

# ── Step 2: Get APIM keys ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Step 2: Fetch APIM subscription keys ===" -ForegroundColor Cyan

$BRONZE_KEY = (az rest --method POST `
    --uri "https://management.azure.com/subscriptions/$SUB_ID/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$APIM_NAME/subscriptions/app-branch-advisor/listSecrets?api-version=2022-08-01" `
    2>$null | ConvertFrom-Json).primaryKey

# Use Silver key for load test: Silver has 300 RPM vs Bronze 60 RPM.
# At 20 threads x 5s think time = 240 req/min, Bronze saturates its own
# rate limiter before the Foundry backend can 429. Silver stays within limits.
$SILVER_KEY = (az rest --method POST `
    --uri "https://management.azure.com/subscriptions/$SUB_ID/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$APIM_NAME/subscriptions/app-aml-screening/listSecrets?api-version=2022-08-01" `
    2>$null | ConvertFrom-Json).primaryKey

Write-Host "  Bronze key: $($BRONZE_KEY.Substring(0,8))..." -ForegroundColor Green
Write-Host "  Silver key: $($SILVER_KEY.Substring(0,8))... (used for load test — 300 RPM limit)" -ForegroundColor Green

# ── Step 3: Create / update ALT test definition ────────────────────────────────
Write-Host ""
Write-Host "=== Step 3: Create / update ALT test '$TEST_ID' ===" -ForegroundColor Cyan

$subnetId = az load show --name $ALT_RESOURCE -g $ALT_RG `
    --query "properties.subnetId" -o tsv 2>$null
if ($LASTEXITCODE -ne 0) { $subnetId = $null }

$ErrorActionPreference = 'Continue'
$testExists = az load test show `
    --load-test-resource $ALT_RESOURCE -g $ALT_RG `
    --test-id $TEST_ID -o json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
$ErrorActionPreference = 'Stop'

if (-not $testExists) {
    Write-Host "  Creating new test..."
    $createArgs = @(
        "load", "test", "create",
        "--load-test-resource", $ALT_RESOURCE,
        "-g", $ALT_RG,
        "--test-id", $TEST_ID,
        "--display-name", "AppGW Failover Blast -- primary->secondary retry",
        "--description", "Saturates primary Foundry TPM cap; verifies APIM retries on secondary",
        "--test-plan", "$repoRoot\tests\failover-load-test.jmx",
        "--env", "APIM_HOSTNAME=$APPGW_FQDN",
        "--env", "API_VERSION=2024-10-21",
        "--env", "SILVER_KEY=$SILVER_KEY",
        "-o", "none"
    )
    if ($subnetId) { $createArgs += @("--subnet-id", $subnetId) }
    & az @createArgs
    if ($LASTEXITCODE -ne 0) { throw "az load test create failed (exit $LASTEXITCODE)" }
    Write-Host "  Test '$TEST_ID' created." -ForegroundColor Green
} else {
    Write-Host "  Updating existing test plan..."
    az load test update `
        --load-test-resource $ALT_RESOURCE -g $ALT_RG `
        --test-id $TEST_ID `
        --test-plan "$repoRoot\tests\failover-load-test.jmx" `
        -o none

    foreach ($kv in @(
        "APIM_HOSTNAME=$APPGW_FQDN",
        "API_VERSION=2024-10-21",
        "SILVER_KEY=$SILVER_KEY"
    )) {
        az load test update `
            --load-test-resource $ALT_RESOURCE -g $ALT_RG `
            --test-id $TEST_ID `
            --env $kv `
            -o none
    }
    Write-Host "  Test plan and env vars updated." -ForegroundColor Green
}

# ── Step 4: Upload test support files ───────────────────────────────────────────
Write-Host ""
Write-Host "=== Step 4: Upload test support files ===" -ForegroundColor Cyan

# system.properties — trustStore=NONE so JMeter trusts the AppGW self-signed cert
$sysPropsPath = "$repoRoot\tests\appgw-system.properties"
if (Test-Path $sysPropsPath) {
    az load test file upload `
        --load-test-resource $ALT_RESOURCE -g $ALT_RG `
        --test-id $TEST_ID `
        --path $sysPropsPath `
        --file-type ADDITIONAL_ARTIFACTS -o none
    Write-Host "  Uploaded appgw-system.properties" -ForegroundColor Green
}

$sysPropsPath2 = "$repoRoot\tests\system.properties"
if (Test-Path $sysPropsPath2) {
    az load test file upload `
        --load-test-resource $ALT_RESOURCE -g $ALT_RG `
        --test-id $TEST_ID `
        --path $sysPropsPath2 `
        --file-type ADDITIONAL_ARTIFACTS -o none
    Write-Host "  Uploaded system.properties (trustStore=NONE)" -ForegroundColor Green
}

# user.properties — inject live API keys via JMeter -q flag (reliable vs --env)
$userPropsPath = "$env:TEMP\failover-user.properties"
@"
# JMeter user properties for appgw-failover-test
# Generated by run-appgw-failover-test.ps1 — DO NOT COMMIT (contains live API keys)
APIM_HOSTNAME=$APPGW_FQDN
API_VERSION=2024-10-21
SILVER_KEY=$SILVER_KEY
"@ | Set-Content -Path $userPropsPath -Encoding utf8

az load test file upload `
    --load-test-resource $ALT_RESOURCE -g $ALT_RG `
    --test-id $TEST_ID `
    --path $userPropsPath `
    --file-type USER_PROPERTIES -o none
Write-Host "  Uploaded user.properties (SILVER_KEY injected via -q flag)" -ForegroundColor Green

# Remove temp file immediately — key is now in ALT, not needed locally
Remove-Item $userPropsPath -Force -ErrorAction SilentlyContinue

# ── Step 5: Fire the test run ────────────────────────────────────────────────────
$runId = "appgw-failover-$(Get-Date -Format 'yyyyMMddHHmmss')"
Write-Host ""
Write-Host "=== Step 5: Start test run '$runId' ===" -ForegroundColor Cyan
Write-Host "  Strategy: 20 threads, 5s think time, 120s — primary 2K TPM / 20 RPM exhausts in ~6s"
Write-Host "  Expected: primary 429s → APIM retries secondary → client sees 200"
Write-Host "  Watch for: X-Backend-Region-Used: secondary-failover in responses"
Write-Host ""

az load test-run create `
    --load-test-resource $ALT_RESOURCE -g $ALT_RG `
    --test-id $TEST_ID `
    --test-run-id $runId `
    --display-name "Failover Blast -- primary TPM saturation" `
    --no-wait -o none

Write-Host "  Run started: $runId" -ForegroundColor Green

# Poll until done (max 8 min -- test is only 2 min + ALT overhead)
Write-Host "  Polling for completion (max 8 min)..." -ForegroundColor Yellow
$deadline = (Get-Date).AddMinutes(8)
do {
    Start-Sleep 20
    $ErrorActionPreference = 'Continue'
    $runStatus = az load test-run show `
        --load-test-resource $ALT_RESOURCE -g $ALT_RG `
        --test-run-id $runId --query status -o tsv 2>$null
    $ErrorActionPreference = 'Stop'
    Write-Host "    $([datetime]::UtcNow.ToString('HH:mm:ss'))Z  status: $runStatus"
} while ($runStatus -notin @('DONE','FAILED','CANCELLED','SERVER_METRIC_NOT_APPLICABLE') -and (Get-Date) -lt $deadline)

# ── Step 6: Display results ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Step 6: Results ===" -ForegroundColor Cyan

$ErrorActionPreference = 'Continue'
$result = az load test-run show `
    --load-test-resource $ALT_RESOURCE -g $ALT_RG `
    --test-run-id $runId `
    -o json 2>$null | ConvertFrom-Json

$metricsBase = @("load", "test-run", "metrics", "list",
    "--load-test-resource", $ALT_RESOURCE, "-g", $ALT_RG,
    "--test-run-id", $runId,
    "--metric-namespace", "LoadTestRunMetrics")

$respAvgData  = & az @($metricsBase + @("--metric-name","ResponseTime","--aggregation","Average"))  2>$null | ConvertFrom-Json
$respP90Data  = & az @($metricsBase + @("--metric-name","ResponseTime","--aggregation","Percentile90")) 2>$null | ConvertFrom-Json
$errorData    = & az @($metricsBase + @("--metric-name","Errors","--aggregation","Total"))          2>$null | ConvertFrom-Json
$ErrorActionPreference = 'Stop'

function Get-MetricAvg($series) {
    $vals = @(@($series) | ForEach-Object { $_.data } | Where-Object { $_.value -ne $null } | Select-Object -ExpandProperty value)
    if ($vals.Count -gt 0) { [math]::Round(($vals | Measure-Object -Average).Average, 0) } else { 'n/a' }
}
function Get-MetricTotal($series) {
    $vals = @(@($series) | ForEach-Object { $_.data } | Where-Object { $_.value -ne $null } | Select-Object -ExpandProperty value)
    # Empty data array from ALT means 0 occurrences (no error data points recorded)
    if ($vals.Count -gt 0) { [math]::Round(($vals | Measure-Object -Sum).Sum, 0) } else { 0 }
}

$avgMs  = Get-MetricAvg   $respAvgData
$p90Ms  = Get-MetricAvg   $respP90Data
$errors = Get-MetricTotal  $errorData

Write-Host "  +----------------------------------------------------------+"
Write-Host "  |  Failover Blast Test  ($runId)"
Write-Host "  +----------------------------------------------------------+"
Write-Host "  |  Status           : $($result.status)"
Write-Host "  |  Test result      : $($result.testResult)"
Write-Host "  |  Avg response time: $avgMs ms"
Write-Host "  |  p90 response time: $p90Ms ms"
Write-Host "  |  Client errors    : $errors (should be 0 -- APIM retries transparently)"
Write-Host "  +----------------------------------------------------------+"
Write-Host "  |  Failover detail:"
Write-Host "  |    See '[Summary] Failover statistics' sampler in ALT results"
Write-Host "  |    for per-request primary vs secondary-failover counts."
Write-Host "  |    Expected: failover % rises as primary TPM cap is hit."
Write-Host "  +----------------------------------------------------------+"
Write-Host "  |  App Insights query (run in portal after test):"
Write-Host "  |    requests"
Write-Host "  |    | where customDimensions['X-Backend-Region-Used'] == 'secondary-failover'"
Write-Host "  |    | summarize failoverCount=count() by bin(timestamp, 10s)"
Write-Host "  |    | render timechart"
Write-Host "  +----------------------------------------------------------+"
Write-Host ""
Write-Host "  Portal: $($result.portalUrl)" -ForegroundColor DarkGray

Write-Host ""
Write-Host "Failover test complete." -ForegroundColor Green
Write-Host "  Re-run this script at any time -- policy and infrastructure are provisioned by azd."
