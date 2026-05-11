#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Run the App Gateway failover test locally via JMeter.

.DESCRIPTION
  Runs failover-load-test.jmx through the App Gateway public endpoint and writes
  results to load_tests/scripts/jmeter/output/appgw-failover-test/<timestamp>/.

  Traffic path:
    JMeter (local) → App Gateway WAF v2 (public FQDN) → APIM openai-inference
      → primary 429 (1K TPM exhausted) → APIM circuit-breaker retries
      → secondary Foundry (West US) → 200 (X-Backend-Region-Used: secondary-failover)

  The primary gpt-4o-mini deployment is permanently set to 1K TPM so every
  run produces genuine 429s without any additional setup.

  The failover-retry policy is provisioned by 'azd provision'
  (infrastructure/bicep/apim-gateway.bicep) — no manual policy deployment needed.

.NOTES
  Prerequisites:
    - JMeter 5.6+ on PATH ('jmeter' binary)
    - az login completed
    - azd provision completed (App Gateway + APIM + Foundry primary at 1K TPM)
    - Optional: scripts/create-appgw-cert.ps1 run for cert-validating TLS
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TEST_NAME = 'appgw-failover-test'

# ── Paths ────────────────────────────────────────────────────────────────────────
$repoRoot       = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$jmxPath        = Join-Path $repoRoot 'load_tests' 'definitions' 'failover-load-test.jmx'
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
    Write-Host "  WARNING: App Gateway is '$($appgw.state)'. Starting it now..." -ForegroundColor Yellow
    az network application-gateway start -g $RG -n $appgw.name 2>&1 | Out-Null
    Write-Host "  App Gateway start initiated (~2-3 min). Waiting 30 s..." -ForegroundColor Yellow
    Start-Sleep 30
}

# ── Step 4: Fetch APIM subscription key ─────────────────────────────────────────
Write-Host ""
Write-Host "=== Step 4: Fetch APIM subscription key ===" -ForegroundColor Cyan

# Silver key: 300 RPM limit — stays within APIM rate limits while still
# generating enough TPM to saturate the 1K TPM Foundry primary cap.
$SILVER_KEY = (az rest --method POST `
    --uri "https://management.azure.com/subscriptions/$SUB_ID/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$APIM_NAME/subscriptions/app-aml-screening/listSecrets?api-version=2022-08-01" `
    2>$null | ConvertFrom-Json).primaryKey

if (-not $SILVER_KEY) { Write-Error "Failed to fetch Silver key for 'app-aml-screening'." }
Write-Host "  Silver key (app-aml-screening) : $($SILVER_KEY.Substring(0,8))... (300 RPM limit)" -ForegroundColor Green

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
$userPropsPath = Join-Path $env:TEMP 'jmeter-appgw-failover-user.properties'
@"
# JMeter user properties for appgw-failover-test
# Generated by run_jmeter_appgw-failover-test.ps1 — DO NOT COMMIT
APIM_HOSTNAME=$APPGW_FQDN
API_VERSION=2024-10-21
SILVER_KEY=$SILVER_KEY
"@ | Set-Content -Path $userPropsPath -Encoding utf8

# ── Step 8: Run JMeter ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Step 7: Run JMeter ===" -ForegroundColor Cyan
Write-Host "  JMX    : $jmxPath"
Write-Host "  Target : https://$APPGW_FQDN"
Write-Host "  Output : $outputDir"
Write-Host "  Note   : 20 threads x 5s think time — primary TPM exhausts quickly"
Write-Host "           Look for X-Backend-Region-Used: secondary-failover in tearDown sampler"
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
