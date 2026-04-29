#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Run the steady-state load test — 1 hour, all four LOB subscriptions, low TPM.

.DESCRIPTION
  Simulates realistic baseline traffic across all four LOB subscriptions
  (Bronze + Silver x2 + Gold) for 1 hour.  Designed to produce smooth,
  gap-free graphs in Azure Monitor without throttling or failover.

  Test suites (all run in parallel — 3600s / 1 hour total):
    Suite 1  [Bronze]  Branch Advisor       — 2 threads, 30s think → ~4 RPM,  ~40 TPM
    Suite 2  [Silver]  AML Screening        — 2 threads, 30s think → ~4 RPM,  ~40 TPM
    Suite 3  [Silver]  Credit Underwriting  — 2 threads, 30s think → ~4 RPM,  ~40 TPM
    Suite 4  [Gold]    Investment Platform  — 2 threads, 30s think → ~4 RPM,  ~40 TPM

  Combined: ~160 TPM << Foundry 1K TPM primary cap — no throttling expected.
  Graph coverage: ~19 data points per 5-minute bin per subscription — no gaps.

  Can run CONCURRENTLY with multi-sub-failover-test (different ALT test ID).

  JMX:   tests/steady-state-test.jmx
  ALT test ID: steady-state-test

.NOTES
  Prerequisites:
    azd provision completed (App Gateway + APIM + Foundry deployed)
    App Gateway and APIM operational

  To run both tests concurrently:
    Start-Process pwsh -ArgumentList '-File', 'scripts/run-steady-state-test.ps1'
    Start-Process pwsh -ArgumentList '-File', 'scripts/run-multi-sub-failover-test.ps1'
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Constants ───────────────────────────────────────────────────────────────────
. "$PSScriptRoot/_resolve-env.ps1"

$ALT_RG   = $RG
$TEST_ID  = 'steady-state-test'

$ALT_RESOURCE = az load list -g $RG --query '[0].name' -o tsv 2>$null
if (-not $ALT_RESOURCE) { Write-Error "No Azure Load Testing resource found in '$RG'. Run: azd provision" }

$repoRoot = Split-Path -Parent $PSScriptRoot

# ── Step 1: Verify App Gateway is running ───────────────────────────────────────
Write-Host ""
Write-Host "=== Step 1: Verify App Gateway is running ===" -ForegroundColor Cyan

$appgw = az network application-gateway list -g $ALT_RG `
    --query "[0].{name:name,state:operationalState}" `
    -o json 2>$null | ConvertFrom-Json

if (-not $appgw) {
    Write-Error "App Gateway not found in '$ALT_RG'. Run: azd provision"
}
$appgwState = $appgw.state
Write-Host "  App Gateway: $($appgw.name) — state: $appgwState" -ForegroundColor Green
if ($appgwState -ne 'Running') {
    Write-Host "  WARNING: App Gateway is '$appgwState' — starting it now..." -ForegroundColor Yellow
    az network application-gateway start -g $ALT_RG -n $appgw.name 2>&1 | Out-Null
    Write-Host "  App Gateway start initiated (takes ~2-3 min)." -ForegroundColor Yellow
    Start-Sleep 30
}

# ── Step 2: Fetch APIM subscription keys ────────────────────────────────────────
Write-Host ""
Write-Host "=== Step 2: Fetch APIM subscription keys ===" -ForegroundColor Cyan

function Invoke-ApimListSecrets([string]$subName) {
    for ($i = 1; $i -le 10; $i++) {
        try {
            $result = az rest --method POST `
                --uri "https://management.azure.com/subscriptions/$SUB_ID/resourceGroups/$ALT_RG/providers/Microsoft.ApiManagement/service/$APIM_NAME/subscriptions/$subName/listSecrets?api-version=2022-08-01" `
                2>&1
            Set-StrictMode -Off
            $json = $result | Where-Object { $_ -notmatch '^WARNING' } | Out-String | ConvertFrom-Json -ErrorAction SilentlyContinue
            $key  = $json.primaryKey
            Set-StrictMode -Version Latest
            if ($key) { return $key }
        } catch {
            # SSL / network transient error — fall through to retry
        }
        Write-Host "  Key fetch attempt $i/10 for '$subName' failed (SSL/network) — retrying in 10s..." -ForegroundColor Yellow
        Start-Sleep 10
    }
    Write-Error "Failed to fetch APIM key for subscription '$subName' after 10 attempts."
}

$BRONZE_KEY   = Invoke-ApimListSecrets 'app-branch-advisor'
$SILVER_KEY   = Invoke-ApimListSecrets 'app-aml-screening'
$SILVER_KEY_2 = Invoke-ApimListSecrets 'app-credit-underwriting'
$GOLD_KEY     = Invoke-ApimListSecrets 'app-investment-platform'

Write-Host "  Bronze key (Branch Advisor):        $($BRONZE_KEY.Substring(0,8))..." -ForegroundColor Green
Write-Host "  Silver key (AML Screening):         $($SILVER_KEY.Substring(0,8))..." -ForegroundColor Green
Write-Host "  Silver key 2 (Credit Underwriting): $($SILVER_KEY_2.Substring(0,8))..." -ForegroundColor Green
Write-Host "  Gold key (Investment Platform):     $($GOLD_KEY.Substring(0,8))..." -ForegroundColor Green

# ── Step 3: Create / update ALT test definition ─────────────────────────────────
Write-Host ""
Write-Host "=== Step 3: Create / update ALT test '$TEST_ID' ===" -ForegroundColor Cyan

$jmxPath = "$repoRoot\tests\steady-state-test.jmx"
if (-not (Test-Path $jmxPath)) {
    Write-Error "JMX not found: $jmxPath"
}

$subnetId = az load show --name $ALT_RESOURCE -g $ALT_RG `
    --query "properties.subnetId" -o tsv 2>$null

$ErrorActionPreference = 'Continue'
$testExists = az load test show `
    --load-test-resource $ALT_RESOURCE -g $ALT_RG `
    --test-id $TEST_ID -o json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
$ErrorActionPreference = 'Stop'

if (-not $testExists) {
    Write-Host "  Creating new ALT test '$TEST_ID'..." -ForegroundColor Yellow
    $createArgs = @(
        "load", "test", "create",
        "--load-test-resource", $ALT_RESOURCE,
        "-g", $ALT_RG,
        "--test-id", $TEST_ID,
        "--display-name", "Steady State: All Subscriptions (1h)",
        "--description", "Baseline steady-state traffic — 4 subs, 2 threads each, 30s think, 3600s; ~160 TPM combined, no failover expected",
        "--test-plan", $jmxPath,
        "--env", "APIM_HOSTNAME=$APPGW_FQDN",
        "--env", "API_VERSION=2024-10-21",
        "--env", "BRONZE_KEY=$BRONZE_KEY",
        "--env", "SILVER_KEY=$SILVER_KEY",
        "--env", "SILVER_KEY_2=$SILVER_KEY_2",
        "--env", "GOLD_KEY=$GOLD_KEY",
        "-o", "none"
    )
    if ($subnetId) { $createArgs += @("--subnet-id", $subnetId) }
    & az @createArgs
    if ($LASTEXITCODE -ne 0) { throw "az load test create failed (exit $LASTEXITCODE)" }
    Write-Host "  Test '$TEST_ID' created." -ForegroundColor Green
} else {
    Write-Host "  Updating existing test plan and env vars..."
    az load test update `
        --load-test-resource $ALT_RESOURCE -g $ALT_RG `
        --test-id $TEST_ID `
        --test-plan $jmxPath `
        -o none

    foreach ($kv in @(
        "APIM_HOSTNAME=$APPGW_FQDN",
        "API_VERSION=2024-10-21",
        "BRONZE_KEY=$BRONZE_KEY",
        "SILVER_KEY=$SILVER_KEY",
        "SILVER_KEY_2=$SILVER_KEY_2",
        "GOLD_KEY=$GOLD_KEY"
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

$sysPropsPath = "$repoRoot\tests\appgw-system.properties"
if (Test-Path $sysPropsPath) {
    az load test file upload `
        --load-test-resource $ALT_RESOURCE -g $ALT_RG `
        --test-id $TEST_ID `
        --path $sysPropsPath `
        --file-type ADDITIONAL_ARTIFACTS -o none
    Write-Host "  Uploaded appgw-system.properties" -ForegroundColor Green
}

# system.properties — JMeter auto-reads this at startup; trustStore=NONE trusts the
# App Gateway self-signed cert without needing the PKCS12 truststore file.
$sysPropsPath2 = "$repoRoot\tests\system.properties"
if (Test-Path $sysPropsPath2) {
    az load test file upload `
        --load-test-resource $ALT_RESOURCE -g $ALT_RG `
        --test-id $TEST_ID `
        --path $sysPropsPath2 `
        --file-type ADDITIONAL_ARTIFACTS -o none
    Write-Host "  Uploaded system.properties (trustStore=NONE)" -ForegroundColor Green
}

$userPropsPath = "$env:TEMP\steady-state-user.properties"
@"
# JMeter user properties for steady-state-test
# Generated by run-steady-state-test.ps1 — DO NOT COMMIT (contains live API keys)
APIM_HOSTNAME=$APPGW_FQDN
API_VERSION=2024-10-21
BRONZE_KEY=$BRONZE_KEY
SILVER_KEY=$SILVER_KEY
SILVER_KEY_2=$SILVER_KEY_2
GOLD_KEY=$GOLD_KEY
"@ | Set-Content -Path $userPropsPath -Encoding utf8

az load test file upload `
    --load-test-resource $ALT_RESOURCE -g $ALT_RG `
    --test-id $TEST_ID `
    --path $userPropsPath `
    --file-type USER_PROPERTIES -o none
Write-Host "  Uploaded user.properties" -ForegroundColor Green

Remove-Item $userPropsPath -Force -ErrorAction SilentlyContinue

# ── Step 5: Fire the test run ────────────────────────────────────────────────────
$runId = "steady-state-$(Get-Date -Format 'yyyyMMddHHmmss')"
Write-Host ""
Write-Host "=== Step 5: Start test run '$runId' ===" -ForegroundColor Cyan
Write-Host "  Suites: 4 subscriptions x 2 threads x 30s think time"
Write-Host "  Duration: 3600s (1 hour)"
Write-Host "  Combined TPM: ~160 — no throttling or failover expected"
Write-Host "  Graph coverage: ~19 data points / 5-min bin / subscription"
Write-Host ""

$createOk = $false
for ($attempt = 1; $attempt -le 3; $attempt++) {
    $ErrorActionPreference = 'Continue'
    az load test-run create `
        --load-test-resource $ALT_RESOURCE -g $ALT_RG `
        --test-id $TEST_ID `
        --test-run-id $runId `
        --display-name "Steady state $(Get-Date -Format 'yyyy-MM-dd HH:mm')" `
        --no-wait -o none 2>&1 | Out-Null
    $ErrorActionPreference = 'Stop'
    $ErrorActionPreference = 'Continue'
    $checkJson = az load test-run show --load-test-resource $ALT_RESOURCE -g $ALT_RG `
        --test-run-id $runId -o json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    $ErrorActionPreference = 'Stop'
    if ($checkJson -and $checkJson.testRunId) {
        $createOk = $true
        Write-Host "  Run verified: $runId (attempt $attempt)" -ForegroundColor Green
        break
    }
    Write-Host "  Create attempt $attempt failed (SSL/network) — retrying in 10s..." -ForegroundColor Yellow
    Start-Sleep 10
}
if (-not $createOk) {
    Write-Error "Failed to create test run '$runId' after 3 attempts. Check 'az load test-run list' to confirm and retry."
    exit 1
}

# ── Step 6: Poll until done (max 90 min — 3600s test + ALT engine overhead) ─────
Write-Host "  Polling every 30s for completion (max 90 min)..." -ForegroundColor Yellow
$deadline   = (Get-Date).AddMinutes(90)
$doneStates = @('DONE','FAILED','CANCELLED','SERVER_METRIC_NOT_APPLICABLE')
$runStatus  = ''
do {
    Start-Sleep 30
    $ts = [datetime]::UtcNow.ToString('HH:mm:ss')
    $runJson = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $ErrorActionPreference = 'Continue'
        $rawJson = az load test-run show `
            --load-test-resource $ALT_RESOURCE -g $ALT_RG `
            --test-run-id $runId `
            -o json 2>$null
        $ErrorActionPreference = 'Stop'
        if ($rawJson) {
            $runJson = $rawJson | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($runJson) { break }
        }
        if ($attempt -lt 3) { Start-Sleep 5 }
    }
    if (-not $runJson) {
        Write-Host "    ${ts}Z  (poll failed — SSL/network error, retrying next cycle)" -ForegroundColor Yellow
        continue
    }
    Set-StrictMode -Off
    $runStatus = $runJson.status            ?? ''
    $vus       = $runJson.virtualUsers      ?? ''
    $rps       = $runJson.requestsPerSecond ?? ''
    $errs      = $runJson.errorPercentage   ?? ''
    Set-StrictMode -Version Latest
    Write-Host "    ${ts}Z  $runStatus  VUs=$vus  RPS=$rps  Err%=$errs"
} while ($runStatus -notin $doneStates -and (Get-Date) -lt $deadline)

# ── Step 7: Display results ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Step 7: Results ===" -ForegroundColor Cyan

$ErrorActionPreference = 'Continue'
$result = az load test-run show `
    --load-test-resource $ALT_RESOURCE -g $ALT_RG `
    --test-run-id $runId `
    -o json 2>$null | ConvertFrom-Json

function Get-MetricAvg($series) {
    Set-StrictMode -Off
    $vals = @(@($series) | ForEach-Object { $_.data } | Where-Object { $_ -ne $null -and $_.value -ne $null } | Select-Object -ExpandProperty value)
    Set-StrictMode -Version Latest
    if ($vals.Count -gt 0) { [math]::Round(($vals | Measure-Object -Average).Average, 0) } else { 'n/a' }
}
function Get-MetricTotal($series) {
    Set-StrictMode -Off
    $vals = @(@($series) | ForEach-Object { $_.data } | Where-Object { $_ -ne $null -and $_.value -ne $null } | Select-Object -ExpandProperty value)
    Set-StrictMode -Version Latest
    if ($vals.Count -gt 0) { [math]::Round(($vals | Measure-Object -Sum).Sum, 0) } else { 0 }
}

$metricsBase = @("load", "test-run", "metrics", "list",
    "--load-test-resource", $ALT_RESOURCE, "-g", $ALT_RG,
    "--test-run-id", $runId,
    "--metric-namespace", "LoadTestRunMetrics")

$respAvg = Get-MetricAvg  (& az @($metricsBase + @("--metric-name","ResponseTime","--aggregation","Average"))       2>$null | ConvertFrom-Json)
$respP90 = Get-MetricAvg  (& az @($metricsBase + @("--metric-name","ResponseTime","--aggregation","Percentile90"))  2>$null | ConvertFrom-Json)
$errors  = Get-MetricTotal(& az @($metricsBase + @("--metric-name","Errors",       "--aggregation","Total"))        2>$null | ConvertFrom-Json)
$ErrorActionPreference = 'Stop'

Write-Host "  +------------------------------------------------------------+"
Write-Host "  |  Steady State Test  ($runId)"
Write-Host "  +------------------------------------------------------------+"
Write-Host "  |  Status            : $($result.status)"
Write-Host "  |  Test result       : $($result.testResult)"
Write-Host "  |  Avg response time : $respAvg ms"
Write-Host "  |  p90 response time : $respP90 ms"
Write-Host "  |  Client errors     : $errors  (0 = expected)"
Write-Host "  +------------------------------------------------------------+"
Write-Host "  |  See '[Summary] Per-subscription baseline statistics'"
Write-Host "  |  sampler in ALT results for per-subscription counts."
Write-Host "  +------------------------------------------------------------+"
Write-Host "  |  Log Analytics — verify primary routing:"
Write-Host "  |    AppRequests"
Write-Host "  |    | where TimeGenerated > ago(65m)"
Write-Host "  |    | summarize"
Write-Host "  |        Requests=count(),"
Write-Host "  |        Primary=countif(tostring(Properties['Response-X-Backend-Region-Used']) == 'primary'),"
Write-Host "  |        Failover=countif(tostring(Properties['Response-X-Backend-Region-Used']) contains 'secondary')"
Write-Host "  |      by SubName=tostring(Properties['Subscription Name'])"
Write-Host "  |    | order by SubName asc"
Write-Host "  +------------------------------------------------------------+"
