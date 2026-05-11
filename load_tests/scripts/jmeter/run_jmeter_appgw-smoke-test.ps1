#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Run the App Gateway WAF smoke test locally via JMeter.

.DESCRIPTION
  Runs appgw-load-test.jmx through the App Gateway public endpoint and writes
  results to load_tests/scripts/jmeter/output/appgw-smoke-test/<timestamp>/.

  Traffic path:
    JMeter (local) → App Gateway WAF v2 (public FQDN) → APIM Internal VNet → AI Foundry

  Baseline comparison:
    Direct APIM (apim-smoke-test):  median ~390 ms, error ~22 %
    App Gateway path (this test):   expect +10-30 ms WAF inspection overhead

  TLS:
    If load_tests/config/appgw-truststore.p12 exists (created by
    scripts/create-appgw-cert.ps1), the test uses cert-validating TLS.
    Otherwise, trust-all TLS is used (javax.net.ssl.trustStore=NONE).

.NOTES
  Prerequisites:
    - JMeter 5.6+ on PATH ('jmeter' binary)
    - az login completed
    - azd provision completed (App Gateway deployed and Running)
    - Optional: scripts/create-appgw-cert.ps1 run for cert-validating TLS
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TEST_NAME = 'appgw-smoke-test'

# ── Paths ────────────────────────────────────────────────────────────────────────
$repoRoot    = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$jmxPath     = Join-Path $repoRoot 'load_tests' 'definitions' 'appgw-load-test.jmx'
$configDir   = Join-Path $repoRoot 'load_tests' 'config'
$truststorePath = Join-Path $configDir 'appgw-truststore.p12'
$outputDir   = Join-Path $PSScriptRoot 'output' $TEST_NAME (Get-Date -Format 'yyyyMMdd-HHmmss')

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

# ── Step 3: Verify App Gateway is Running ────────────────────────────────────────
Write-Host ""
Write-Host "=== Step 3: Verify App Gateway is deployed ===" -ForegroundColor Cyan

$appgw = az network application-gateway list -g $RG `
    --query "[0].{name:name,state:operationalState}" `
    -o json 2>$null | ConvertFrom-Json

if (-not $appgw) {
    Write-Error "No App Gateway found in '$RG'.`nRun: azd provision"
}
Write-Host "  App Gateway: $($appgw.name) — state: $($appgw.state)" -ForegroundColor Green
if ($appgw.state -ne 'Running') {
    Write-Host "  WARNING: App Gateway is '$($appgw.state)'. Test traffic may fail." -ForegroundColor Yellow
}

# ── Step 4: Fetch APIM subscription keys ────────────────────────────────────────
Write-Host ""
Write-Host "=== Step 4: Fetch APIM subscription keys ===" -ForegroundColor Cyan

$BRONZE_KEY = (az rest --method POST `
    --uri "https://management.azure.com/subscriptions/$SUB_ID/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$APIM_NAME/subscriptions/app-branch-advisor/listSecrets?api-version=2022-08-01" `
    2>$null | ConvertFrom-Json).primaryKey

$SILVER_KEY = (az rest --method POST `
    --uri "https://management.azure.com/subscriptions/$SUB_ID/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$APIM_NAME/subscriptions/app-aml-screening/listSecrets?api-version=2022-08-01" `
    2>$null | ConvertFrom-Json).primaryKey

if (-not $BRONZE_KEY) { Write-Error "Failed to fetch Bronze key for 'app-branch-advisor'." }
if (-not $SILVER_KEY) { Write-Error "Failed to fetch Silver key for 'app-aml-screening'." }

Write-Host "  Bronze key (app-branch-advisor) : $($BRONZE_KEY.Substring(0,8))..." -ForegroundColor Green
Write-Host "  Silver key (app-aml-screening)  : $($SILVER_KEY.Substring(0,8))..." -ForegroundColor Green

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
$userPropsPath = Join-Path $env:TEMP 'jmeter-appgw-smoke-user.properties'
@"
# JMeter user properties for appgw-smoke-test
# Generated by run_jmeter_appgw-smoke-test.ps1 — DO NOT COMMIT
APIM_HOSTNAME=$APPGW_FQDN
API_VERSION=2024-10-21
BRONZE_KEY=$BRONZE_KEY
SILVER_KEY=$SILVER_KEY
"@ | Set-Content -Path $userPropsPath -Encoding utf8

# ── Step 8: Run JMeter ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Step 7: Run JMeter ===" -ForegroundColor Cyan
Write-Host "  JMX    : $jmxPath"
Write-Host "  Target : https://$APPGW_FQDN"
Write-Host "  Output : $outputDir"
Write-Host ""

jmeter -n `
    -t $jmxPath `
    -q $userPropsPath `
    -Jsummariser.interval=10 `
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
