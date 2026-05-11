#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Run the 1-hour steady-state baseline test locally via JMeter.

.DESCRIPTION
  Runs steady-state-test.jmx through the App Gateway public endpoint and writes
  results to load_tests/scripts/jmeter/output/steady-state-test/<timestamp>/.

  Sends ~160 TPM across all four LOB subscriptions for one hour:
    • Bronze (app-branch-advisor)     — 2 threads, 30s think
    • Silver (app-aml-screening)      — 2 threads, 30s think
    • Silver (app-credit-underwriting)— 2 threads, 30s think
    • Gold   (app-investment-platform)— 2 threads, 30s think

  No throttling or failover is expected. Use this test to:
    • Populate Grafana dashboards and App Insights workbooks with real traffic
    • Validate per-LOB token tracking and App Insights separation
    • Establish a latency baseline before making infrastructure changes

.NOTES
  Prerequisites:
    - JMeter 5.6+ on PATH ('jmeter' binary)
    - az login completed
    - azd provision completed (App Gateway + APIM + all 4 LOB subscriptions active)
    - Optional: scripts/create-appgw-cert.ps1 run for cert-validating TLS

  The HTML report is written incrementally — open index.html after the test
  completes for the full dashboard including latency percentiles and throughput.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TEST_NAME = 'steady-state-test'

# ── Paths ────────────────────────────────────────────────────────────────────────
$repoRoot       = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$jmxPath        = Join-Path $repoRoot 'load_tests' 'definitions' 'steady-state-test.jmx'
$configDir      = Join-Path $repoRoot 'load_tests' 'config'
$truststorePath = Join-Path $configDir 'appgw-truststore.p12'
$outputDir      = Join-Path $PSScriptRoot 'output' $TEST_NAME (Get-Date -Format 'yyyyMMdd-HHmmss')

# ── Step 1: Verify JMeter is on PATH ────────────────────────────────────────────
Write-Host ""
Write-Host "=== Step 1: Verify JMeter is available ===" -ForegroundColor Cyan

$jmeterCmd = Get-Command jmeter -ErrorAction SilentlyContinue
if (-not $jmeterCmd) {
    Write-Error "JMeter not found on PATH.`nInstall JMeter 5.6+ and ensure 'jmeter' (or 'jmeter.bat' on Windows) is on your PATH."
}
Write-Host "  JMeter: $($jmeterCmd.Source)" -ForegroundColor Green

# ── Step 2: Resolve environment ──────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Step 2: Resolve environment ===" -ForegroundColor Cyan

. "$PSScriptRoot/../../../scripts/_resolve-env.ps1"

if (-not $APPGW_FQDN) {
    Write-Error "App Gateway FQDN could not be resolved. Run: azd provision"
}
Write-Host "  Resource group : $RG" -ForegroundColor Green
Write-Host "  App Gateway    : $APPGW_FQDN" -ForegroundColor Green

# ── Step 3: Verify App Gateway is Running (start if Stopped) ────────────────────
Write-Host ""
Write-Host "=== Step 3: Verify App Gateway is running ===" -ForegroundColor Cyan

$appgw = az network application-gateway list -g $RG `
    --query "[0].{name:name,state:operationalState}" `
    -o json 2>$null | ConvertFrom-Json

if (-not $appgw) {
    Write-Error "App Gateway not found in '$RG'. Run: azd provision"
}
Write-Host "  App Gateway: $($appgw.name) — state: $($appgw.state)" -ForegroundColor Green
if ($appgw.state -ne 'Running') {
    Write-Host "  WARNING: App Gateway is '$($appgw.state)'. Starting it now..." -ForegroundColor Yellow
    az network application-gateway start -g $RG -n $appgw.name 2>&1 | Out-Null
    Write-Host "  App Gateway start initiated (~2-3 min). Waiting 30 s before proceeding..." -ForegroundColor Yellow
    Start-Sleep 30
}

# ── Step 4: Fetch APIM subscription keys for all four LOBs ──────────────────────
Write-Host ""
Write-Host "=== Step 4: Fetch APIM subscription keys ===" -ForegroundColor Cyan

function Invoke-ApimListSecrets([string]$subName) {
    for ($i = 1; $i -le 10; $i++) {
        try {
            $result = az rest --method POST `
                --uri "https://management.azure.com/subscriptions/$SUB_ID/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$APIM_NAME/subscriptions/$subName/listSecrets?api-version=2022-08-01" `
                2>&1
            Set-StrictMode -Off
            $json = $result | Where-Object { $_ -notmatch '^WARNING' } | Out-String | ConvertFrom-Json -ErrorAction SilentlyContinue
            $key  = $json.primaryKey
            Set-StrictMode -Version Latest
            if ($key) { return $key }
        } catch {
            # SSL / network transient error — fall through to retry
        }
        Write-Host "  Key fetch attempt $i/10 for '$subName' failed — retrying in 10 s..." -ForegroundColor Yellow
        Start-Sleep 10
    }
    Write-Error "Failed to fetch APIM key for subscription '$subName' after 10 attempts."
}

$BRONZE_KEY   = Invoke-ApimListSecrets 'app-branch-advisor'
$SILVER_KEY   = Invoke-ApimListSecrets 'app-aml-screening'
$SILVER_KEY_2 = Invoke-ApimListSecrets 'app-credit-underwriting'
$GOLD_KEY     = Invoke-ApimListSecrets 'app-investment-platform'

Write-Host "  Bronze (app-branch-advisor)     : $($BRONZE_KEY.Substring(0,8))..." -ForegroundColor Green
Write-Host "  Silver (app-aml-screening)      : $($SILVER_KEY.Substring(0,8))..." -ForegroundColor Green
Write-Host "  Silver (app-credit-underwriting) : $($SILVER_KEY_2.Substring(0,8))..." -ForegroundColor Green
Write-Host "  Gold   (app-investment-platform) : $($GOLD_KEY.Substring(0,8))..." -ForegroundColor Green

# ── Step 5: Configure TLS ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Step 5: Configure TLS ===" -ForegroundColor Cyan

if (Test-Path $truststorePath) {
    Write-Host "  Truststore found — using cert-validating TLS (PKCS12)" -ForegroundColor Green
    Write-Host "  Truststore: $truststorePath"
    $env:JVM_ARGS = "-Djavax.net.ssl.trustStore=$truststorePath -Djavax.net.ssl.trustStorePassword=changeit -Djavax.net.ssl.trustStoreType=PKCS12 -Dhttps.use.cached.ssl.context=false"
} else {
    Write-Host "  Truststore not found — using trust-all TLS (javax.net.ssl.trustStore=NONE)" -ForegroundColor Yellow
    Write-Host "  To enable cert validation, run: scripts/create-appgw-cert.ps1"
    $env:JVM_ARGS = '-Djavax.net.ssl.trustStore=NONE -Dhttps.use.cached.ssl.context=false'
}

# ── Step 6: Prepare output directory ────────────────────────────────────────────
Write-Host ""
Write-Host "=== Step 6: Prepare output directory ===" -ForegroundColor Cyan

New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$jtlPath   = Join-Path $outputDir 'results.jtl'
$reportDir = Join-Path $outputDir 'html-report'

Write-Host "  Output: $outputDir" -ForegroundColor Green

# ── Step 7: Write user.properties (never committed — contains live keys) ─────────
$userPropsPath = Join-Path $env:TEMP 'jmeter-steady-state-user.properties'
@"
# JMeter user properties for steady-state-test
# Generated by run_jmeter_steady-state-test.ps1 — DO NOT COMMIT (contains live API keys)
APIM_HOSTNAME=$APPGW_FQDN
API_VERSION=2024-10-21
BRONZE_KEY=$BRONZE_KEY
SILVER_KEY=$SILVER_KEY
SILVER_KEY_2=$SILVER_KEY_2
GOLD_KEY=$GOLD_KEY
"@ | Set-Content -Path $userPropsPath -Encoding utf8

# ── Step 8: Run JMeter ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Step 7: Run JMeter (1-hour test) ===" -ForegroundColor Cyan
Write-Host "  JMX      : $jmxPath"
Write-Host "  Target   : https://$APPGW_FQDN"
Write-Host "  Output   : $outputDir"
Write-Host "  Suites   : 4 LOBs x 2 threads x 30s think time"
Write-Host "  Duration : 3600 s (1 hour)"
Write-Host "  TPM      : ~160 — no throttling or failover expected"
Write-Host ""
Write-Host "  This test runs for 1 hour. Leave it running and check the report when done." -ForegroundColor Yellow
Write-Host "  Press Ctrl+C to abort early (partial results will still be available)." -ForegroundColor Yellow
Write-Host ""

jmeter -n `
    -t $jmxPath `
    -q $userPropsPath `
    -Jsummariser.interval=30 `
    -l $jtlPath `
    -e -o $reportDir

$exitCode = $LASTEXITCODE
$env:JVM_ARGS = ''
Remove-Item $userPropsPath -Force -ErrorAction SilentlyContinue

# ── Step 9: Report output location ───────────────────────────────────────────────
Write-Host ""
if ($exitCode -eq 0) {
    Write-Host "=== Test complete ===" -ForegroundColor Green
} else {
    Write-Host "=== JMeter exited with code $exitCode ===" -ForegroundColor Yellow
}
Write-Host "  Results  : $jtlPath"
Write-Host "  Report   : $reportDir\index.html"
Write-Host ""
Write-Host "  Open report:"
Write-Host "    Start-Process '$reportDir\index.html'"
Write-Host ""

exit $exitCode
