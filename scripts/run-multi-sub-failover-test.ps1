#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Run the multi-subscription failover load test (Bronze + Silver, both trigger failover).

.DESCRIPTION
  Combined test that exercises both Bronze and Silver subscriptions while generating
  enough traffic to saturate the primary Foundry gpt-4o-mini TPM cap (1K TPM)
  and trigger genuine APIM failover retries to the secondary endpoint.

  Test suites (all run in parallel — 120s total):
    Suite 1  [Bronze] Sustained  — 3 threads, 8s think → steady normal traffic
    Suite 2  [Bronze] Blast      — 8 threads, 3s think, max_tokens=1 → TPM saturation
    Suite 3  [Silver] Sustained  — 3 threads, 8s think → steady normal traffic
    Suite 4  [Silver] Blast      — 8 threads, 3s think, max_tokens=1 → TPM saturation

  Expected outcome:
    • Blast suites generate ~5400 combined TPM > 1K primary cap → 429s
    • APIM failover-retry policy retries on secondary endpoint
    • Both subscriptions see HTTP 200 (client-transparent retry)
    • X-Backend-Region-Used: secondary-failover appears in both sub's responses
    • tearDown sampler reports Bronze failover% and Silver failover% separately

  JMX:   tests/multi-sub-failover-test.jmx
  ALT test ID: multi-sub-failover-test

.NOTES
  Prerequisites:
    • azd provision completed (App Gateway + APIM + Foundry deployed)
    • Primary gpt-4o-mini permanently at 1K TPM (see run-failover-test.ps1 notes)
    • failover-retry.xml policy active on openai-inference API (provisioned by azd)
    • App Gateway operational state: Running

  To check App Gateway state:
    az network application-gateway list -g <RG> --query '[0].{name:name,state:operationalState}' -o table
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Constants ───────────────────────────────────────────────────────────────────
. "$PSScriptRoot/_resolve-env.ps1"

$ALT_RG   = $RG
$TEST_ID  = 'multi-sub-failover-test'

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

# ── Step 2: Get APIM keys for both Bronze and Silver ────────────────────────────
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
$GOLD_KEY     = Invoke-ApimListSecrets 'Investment-Platform'

Write-Host "  Bronze key (Branch Advisor):        $($BRONZE_KEY.Substring(0,8))... (60 RPM — sustained only)" -ForegroundColor Green
Write-Host "  Silver key (AML Screening):         $($SILVER_KEY.Substring(0,8))... (300 RPM — blast safe)" -ForegroundColor Green
Write-Host "  Silver key 2 (Credit Underwriting): $($SILVER_KEY_2.Substring(0,8))... (300 RPM — blast safe)" -ForegroundColor Green
Write-Host "  Gold key (Investment Platform):     $($GOLD_KEY.Substring(0,8))... (5,500 TPM / 330 RPM — Gold tier)" -ForegroundColor Green

# ── Step 3: Create / update ALT test definition ─────────────────────────────────
Write-Host ""
Write-Host "=== Step 3: Create / update ALT test '$TEST_ID' ===" -ForegroundColor Cyan

$jmxPath = "$repoRoot\tests\multi-sub-failover-test.jmx"
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
        "--display-name", "Multi-Sub Failover: Bronze+Silver+Gold",
        "--description", "Bronze + Silver + Gold sustained + blast suites; all trigger APIM failover-retry policy",
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

# system.properties — trustStore=NONE for AppGW self-signed cert
$sysPropsPath = "$repoRoot\tests\appgw-system.properties"
if (Test-Path $sysPropsPath) {
    az load test file upload `
        --load-test-resource $ALT_RESOURCE -g $ALT_RG `
        --test-id $TEST_ID `
        --path $sysPropsPath `
        --file-type ADDITIONAL_ARTIFACTS -o none
    Write-Host "  Uploaded appgw-system.properties" -ForegroundColor Green
}

# user.properties — both keys injected as USER_PROPERTIES so JMeter resolves
# ${__P(BRONZE_KEY,)} / ${__P(SILVER_KEY,)} at startup before TestPlan evaluation.
$userPropsPath = "$env:TEMP\multi-sub-failover-user.properties"
@"
# JMeter user properties for multi-sub-failover-test
# Generated by run-multi-sub-failover-test.ps1 — DO NOT COMMIT (contains live API keys)
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
Write-Host "  Uploaded user.properties (BRONZE_KEY + SILVER_KEY via -q flag at JMeter startup)" -ForegroundColor Green

# Remove temp file immediately — keys are now in ALT, not needed locally
Remove-Item $userPropsPath -Force -ErrorAction SilentlyContinue

# ── Step 5: Fire the test run ────────────────────────────────────────────────────
$runId = "multi-sub-failover-$(Get-Date -Format 'yyyyMMddHHmmss')"
Write-Host ""
Write-Host "=== Step 5: Start test run '$runId' ===" -ForegroundColor Cyan
Write-Host "  Suites: Bronze-sustained(3t/8s) + Bronze-blast(8t/3s) + Silver-sustained(3t/8s) + Silver-blast(8t/3s)"
Write-Host "  Duration: 600s (10 min) — blast suites generate ~5400 combined TPM > 1K primary cap"
Write-Host "  Expected: primary 429s → APIM retries secondary → client sees 200 for both subs"
Write-Host ""

$createOk = $false
for ($attempt = 1; $attempt -le 3; $attempt++) {
    $ErrorActionPreference = 'Continue'
    az load test-run create `
        --load-test-resource $ALT_RESOURCE -g $ALT_RG `
        --test-id $TEST_ID `
        --test-run-id $runId `
        --display-name "Multi-sub failover $(Get-Date -Format 'yyyy-MM-dd HH:mm')" `
        --no-wait -o none 2>&1 | Out-Null
    $ErrorActionPreference = 'Stop'
    # Verify the run actually exists in ALT before proceeding
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

# ── Step 6: Poll until done ──────────────────────────────────────────────────────
Write-Host "  Polling for completion (max 10 min — 120s test + ALT engine overhead)..." -ForegroundColor Yellow
$deadline  = (Get-Date).AddMinutes(18)
$doneStates = @('DONE','FAILED','CANCELLED','SERVER_METRIC_NOT_APPLICABLE')
$runStatus  = ''
do {
    Start-Sleep 20
    $ts = [datetime]::UtcNow.ToString('HH:mm:ss')
    # Retry up to 3 times per poll cycle to handle transient SSL/network errors
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
    # StrictMode is on globally — use PSObject.Properties to safely read fields
    # that may be absent during ramp-up (virtualUsers, requestsPerSecond, etc.)
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

$respAvg = Get-MetricAvg  (& az @($metricsBase + @("--metric-name","ResponseTime","--aggregation","Average"))    2>$null | ConvertFrom-Json)
$respP90 = Get-MetricAvg  (& az @($metricsBase + @("--metric-name","ResponseTime","--aggregation","Percentile90")) 2>$null | ConvertFrom-Json)
$errors  = Get-MetricTotal(& az @($metricsBase + @("--metric-name","Errors","--aggregation","Total"))             2>$null | ConvertFrom-Json)
$ErrorActionPreference = 'Stop'

Write-Host "  +----------------------------------------------------------+"
Write-Host "  |  Multi-Subscription Failover Test  ($runId)"
Write-Host "  +----------------------------------------------------------+"
Write-Host "  |  Status            : $($result.status)"
Write-Host "  |  Test result       : $($result.testResult)"
Write-Host "  |  Avg response time : $respAvg ms"
Write-Host "  |  p90 response time : $respP90 ms"
Write-Host "  |  Client errors     : $errors  (0 = APIM retry transparent)"
Write-Host "  +----------------------------------------------------------+"
Write-Host "  |  See '[Summary] Per-subscription failover statistics'"
Write-Host "  |  sampler in ALT results for Bronze% and Silver% failover."
Write-Host "  +----------------------------------------------------------+"
Write-Host "  |  Log Analytics — verify per-subscription failover:"
Write-Host "  |    AppRequests"
Write-Host "  |    | where TimeGenerated > ago(5m)"
Write-Host "  |    | summarize"
Write-Host "  |        Requests=count(),"
Write-Host "  |        Failover=countif(tostring(Properties['X-Backend-Region-Used']) contains 'secondary')"
Write-Host "  |      by SubName=tostring(Properties['Subscription Name'])"
Write-Host "  |    | extend FailoverPct = round(100.0 * Failover / Requests, 1)"
Write-Host "  |    | order by SubName asc"
Write-Host "  +----------------------------------------------------------+"
