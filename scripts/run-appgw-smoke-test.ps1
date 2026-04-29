#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Run the App Gateway WAF smoke test (appgw-smoke-test).

.DESCRIPTION
  Traffic path for this test:
    ALT agent (snet-loadtest) → AppGW WAF v2 public IP → APIM Internal VNet → AI Foundry

  Prerequisites:
    • scripts/create-appgw-cert.ps1  has been run
    • azd provision                  has completed (App Gateway deployed)

.NOTES
  Compare output with 'smoke-getenv' baseline:
    Baseline (direct APIM):  median ~390ms, error ~22%
    AppGW path (this test):  expect +10-30ms WAF inspection overhead
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Constants ───────────────────────────────────────────────────────────────────
. "$PSScriptRoot/_resolve-env.ps1"

$ALT_RG   = $RG
$TEST_ID  = 'appgw-smoke-test'

$ALT_RESOURCE = az load list -g $RG --query '[0].name' -o tsv 2>$null
if (-not $ALT_RESOURCE) { Write-Error "No Azure Load Testing resource found in '$RG'. Run: azd provision" }

$repoRoot = Split-Path -Parent $PSScriptRoot

# ── Step 1: Verify App Gateway is deployed and healthy ──────────────────────────
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

$subId = $SUB_ID
$BRONZE_KEY = (az rest --method POST `
    --uri "https://management.azure.com/subscriptions/$subId/resourceGroups/$ALT_RG/providers/Microsoft.ApiManagement/service/$APIM_NAME/subscriptions/app-branch-advisor/listSecrets?api-version=2022-08-01" `
    2>$null | ConvertFrom-Json).primaryKey
$SILVER_KEY = (az rest --method POST `
    --uri "https://management.azure.com/subscriptions/$subId/resourceGroups/$ALT_RG/providers/Microsoft.ApiManagement/service/$APIM_NAME/subscriptions/app-aml-screening/listSecrets?api-version=2022-08-01" `
    2>$null | ConvertFrom-Json).primaryKey

Write-Host "  Bronze key: $($BRONZE_KEY.Substring(0,8))..." -ForegroundColor Green
Write-Host "  Silver key: $($SILVER_KEY.Substring(0,8))..." -ForegroundColor Green

# ── Step 3: Create or update ALT test definition ────────────────────────────────
Write-Host ""
Write-Host "=== Step 3: Create / update ALT test '$TEST_ID' ===" -ForegroundColor Cyan

$subnetId = az network vnet subnet show `
    --vnet-name "vnet-$($ALT_RG -replace 'rg-','')" `
    -g $ALT_RG -n snet-loadtest --query id -o tsv 2>$null

# Try to get subnet from existing load test resource config
if (-not $subnetId) {
    $subnetId = az load show --name $ALT_RESOURCE -g $ALT_RG `
        --query "properties.subnetId" -o tsv 2>$null
}

# Check if test already exists
$testExists = az load test show `
    --load-test-resource $ALT_RESOURCE -g $ALT_RG `
    --test-id $TEST_ID -o json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue

if (-not $testExists) {
    Write-Host "  Creating new test..."
    $createArgs = @(
        "load", "test", "create",
        "--load-test-resource", $ALT_RESOURCE,
        "-g", $ALT_RG,
        "--test-id", $TEST_ID,
        "--display-name", "AppGW WAF v2 Smoke Test",
        "--description", "Measures latency through App Gateway WAF v2 vs direct APIM baseline",
        "--test-plan", "$repoRoot\tests\appgw-load-test.jmx",
        "--env", "APIM_HOSTNAME=$APPGW_FQDN",
        "--env", "API_VERSION=2024-10-21",
        "--env", "BRONZE_KEY=$BRONZE_KEY",
        "--env", "SILVER_KEY=$SILVER_KEY",
        "-o", "none"
    )
    if ($subnetId) { $createArgs += @("--subnet-id", $subnetId) }
    & az @createArgs
    if ($LASTEXITCODE -ne 0) { throw "az load test create failed (exit $LASTEXITCODE)" }
    Write-Host "  Test '$TEST_ID' created." -ForegroundColor Green
} else {
    Write-Host "  Test already exists — updating JMX..."
    az load test update `
        --load-test-resource $ALT_RESOURCE -g $ALT_RG `
        --test-id $TEST_ID `
        --test-plan "$repoRoot\tests\appgw-load-test.jmx" `
        -o none
    Write-Host "  Test plan updated." -ForegroundColor Green

    # az load test update drops all but the last two --env flags when multiple
    # are combined with --test-plan in the same call (Azure CLI preview bug).
    # Work-around: set each environment variable with its own update call.
    Write-Host "  Setting env vars (individual calls to avoid CLI multi-env bug)..."
    foreach ($kv in @(
        "APIM_HOSTNAME=$APPGW_FQDN",
        "API_VERSION=2024-10-21",
        "BRONZE_KEY=$BRONZE_KEY",
        "SILVER_KEY=$SILVER_KEY"
    )) {
        az load test update `
            --load-test-resource $ALT_RESOURCE -g $ALT_RG `
            --test-id $TEST_ID `
            --env $kv `
            -o none
    }
    Write-Host "  Env vars set." -ForegroundColor Green
}

# ── Step 4: Upload additional test files ─────────────────────────────────────────
Write-Host ""
Write-Host "=== Step 4: Upload AppGW truststore and system.properties ===" -ForegroundColor Cyan

$truststore = "$repoRoot\tests\appgw-truststore.p12"
$sysprops   = "$repoRoot\tests\appgw-system.properties"
$sysProps2  = "$repoRoot\tests\system.properties"

if (-not (Test-Path $truststore)) {
    Write-Error "Truststore not found: $truststore`nRun: scripts/create-appgw-cert.ps1 first"
}

az load test file upload `
    --load-test-resource $ALT_RESOURCE -g $ALT_RG `
    --test-id $TEST_ID `
    --path $truststore `
    --file-type ADDITIONAL_ARTIFACTS -o none
Write-Host "  Uploaded appgw-truststore.p12" -ForegroundColor Green

az load test file upload `
    --load-test-resource $ALT_RESOURCE -g $ALT_RG `
    --test-id $TEST_ID `
    --path $sysprops `
    --file-type ADDITIONAL_ARTIFACTS -o none
Write-Host "  Uploaded appgw-system.properties" -ForegroundColor Green

# Upload system.properties (exact name JMeter auto-reads at startup for trustStore=NONE bypass)
az load test file upload `
    --load-test-resource $ALT_RESOURCE -g $ALT_RG `
    --test-id $TEST_ID `
    --path $sysProps2 `
    --file-type ADDITIONAL_ARTIFACTS -o none
Write-Host "  Uploaded system.properties (trustStore=NONE for SSL bypass)" -ForegroundColor Green

# ── Generate + upload user.properties so JMeter reads keys at startup ─────────
# ALT's --env → -J flag injection is unreliable in the preview CLI.
# user.properties loaded via JMeter's -q flag at startup is the authoritative path.
# File is generated in $TEMP (never committed to git — contains live API keys).
$userPropsPath = "$env:TEMP\appgw-user.properties"
@"
# JMeter user properties for appgw-smoke-test
# Generated by run-appgw-smoke-test.ps1 — DO NOT COMMIT
APIM_HOSTNAME=$APPGW_FQDN
API_VERSION=2024-10-21
BRONZE_KEY=$BRONZE_KEY
SILVER_KEY=$SILVER_KEY
"@ | Set-Content -Path $userPropsPath -Encoding utf8
az load test file upload `
    --load-test-resource $ALT_RESOURCE -g $ALT_RG `
    --test-id $TEST_ID `
    --path $userPropsPath `
    --file-type USER_PROPERTIES -o none
Write-Host "  Uploaded user.properties (BRONZE_KEY / SILVER_KEY via -q flag)" -ForegroundColor Green

# ── Step 5: Fire the test run ────────────────────────────────────────────────────
$runId = "appgw-smoke-$(Get-Date -Format 'yyyyMMddHHmmss')"
Write-Host ""
Write-Host "=== Step 5: Start test run '$runId' ===" -ForegroundColor Cyan

az load test-run create `
    --load-test-resource $ALT_RESOURCE -g $ALT_RG `
    --test-id $TEST_ID `
    --test-run-id $runId `
    --display-name "AppGW WAF v2 Smoke — WAF overhead vs baseline" `
    --no-wait -o none

Write-Host "  Run started: $runId" -ForegroundColor Green

# Poll until done (max 10 min)
Write-Host "  Polling for completion (max 10 min)..." -ForegroundColor Yellow
$deadline = (Get-Date).AddMinutes(10)
do {
    Start-Sleep 30
    $runStatus = az load test-run show `
        --load-test-resource $ALT_RESOURCE -g $ALT_RG `
        --test-run-id $runId --query status -o tsv 2>$null
    Write-Host "    $([datetime]::UtcNow.ToString('HH:mm:ss'))Z  status: $runStatus"
} while ($runStatus -notin @('DONE','FAILED','CANCELLED','SERVER_METRIC_NOT_APPLICABLE') -and (Get-Date) -lt $deadline)

# ── Step 6: Fetch and display results ────────────────────────────────────────────
Write-Host ""
Write-Host "=== Step 6: Results ===" -ForegroundColor Cyan

$result = az load test-run show `
    --load-test-resource $ALT_RESOURCE -g $ALT_RG `
    --test-run-id $runId `
    -o json 2>$null | ConvertFrom-Json

Write-Host "  Status     : $($result.status)"
Write-Host "  Test result: $($result.testResult)"
Write-Host ""

# Fetch metrics via the metrics API (testRunStatistics not available in newer API)
$metricsBase = @("load", "test-run", "metrics", "list",
    "--load-test-resource", $ALT_RESOURCE, "-g", $ALT_RG,
    "--test-run-id", $runId,
    "--metric-namespace", "LoadTestRunMetrics")

$respTimeData   = & az @($metricsBase + @("--metric-name","ResponseTime","--aggregation","Percentile90")) 2>$null | ConvertFrom-Json
$respAvgData    = & az @($metricsBase + @("--metric-name","ResponseTime","--aggregation","Average"))      2>$null | ConvertFrom-Json
$errorData      = & az @($metricsBase + @("--metric-name","Errors","--aggregation","Total"))              2>$null | ConvertFrom-Json
$requestsData   = & az @($metricsBase + @("--metric-name","VirtualUsers","--aggregation","Total"))        2>$null | ConvertFrom-Json

function Get-MetricAvg($series) {
    $vals = @(@($series) | ForEach-Object { $_.data } | Where-Object { $_.value -ne $null } | Select-Object -ExpandProperty value)
    if ($vals.Count -gt 0) { [math]::Round(($vals | Measure-Object -Average).Average, 0) } else { 'n/a' }
}
function Get-MetricTotal($series) {
    $vals = @(@($series) | ForEach-Object { $_.data } | Where-Object { $_.value -ne $null } | Select-Object -ExpandProperty value)
    if ($vals.Count -gt 0) { [math]::Round(($vals | Measure-Object -Sum).Sum, 0) } else { 'n/a' }
}

$p90ms  = Get-MetricAvg  $respTimeData
$avgMs  = Get-MetricAvg  $respAvgData
$errors = Get-MetricTotal $errorData
$vus    = Get-MetricAvg  $requestsData

Write-Host "  ┌─────────────────────────────────────────────────────┐"
Write-Host "  │  AppGW WAF v2 Smoke Test  ($runId)"
Write-Host "  ├─────────────────────────────────────────────────────┤"
Write-Host "  │  Avg Response Time  : $avgMs ms"
Write-Host "  │  p90 Response Time  : $p90ms ms"
Write-Host "  │  Errors (total)     : $errors"
Write-Host "  │  Avg Virtual Users  : $vus"
Write-Host "  ├─────────────────────────────────────────────────────┤"
Write-Host "  │  Baseline (direct APIM, smoke-getenv run):"
Write-Host "  │    median ~390ms,  22% errors (429s + quota)"
Write-Host "  │    Model-block suite: 100% 403s at ~4ms"
Write-Host "  ├─────────────────────────────────────────────────────┤"
if ($avgMs -ne 'n/a') {
    $delta = [int]$avgMs - 390
    Write-Host "  │  WAF overhead (avg - 390ms baseline) : +${delta}ms"
}
Write-Host "  └─────────────────────────────────────────────────────┘"
Write-Host ""
Write-Host "  Portal: $($result.portalUrl)" -ForegroundColor DarkGray
