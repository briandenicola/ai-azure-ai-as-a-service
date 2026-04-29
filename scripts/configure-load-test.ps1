# configure-load-test.ps1
#
# azd postprovision hook — creates ALL Azure Load Testing test definitions.
#
# Runs automatically on every `azd provision`. No flags or gates — load tests
# are mandatory. Can also be run manually: pwsh scripts/configure-load-test.ps1
#
# Creates / updates all 5 load test definitions:
#   apim-smoke-test         tests/apim-load-test.jmx          app-branch-advisor + app-aml-screening (direct APIM, no AppGW)
#   appgw-failover-test     tests/failover-load-test.jmx      app-branch-advisor + app-aml-screening (circuit-breaker blast)
#   appgw-smoke-test        tests/appgw-load-test.jmx         app-branch-advisor + app-aml-screening (WAF overhead measurement)
#   multi-sub-failover-test tests/multi-sub-failover-test.jmx all 4 LOB subscriptions (concurrent failover)
#   steady-state-test       tests/steady-state-test.jmx       all 4 LOB subscriptions (1-hour baseline)
#
# Prerequisites:
#   azd provision   ← must run first (creates ALT resource, APIM, App Gateway)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Wrap so postprovision hook always exits 0 (best-effort step)
trap {
    Write-Warning "configure-load-test.ps1: non-fatal error — $($_.Exception.Message)"
    Write-Warning "Re-run 'pwsh scripts/configure-load-test.ps1' manually after fixing the issue."
    exit 0
}

# ---------------------------------------------------------------------------
# 1. Resolve environment
# ---------------------------------------------------------------------------
. "$PSScriptRoot/_resolve-env.ps1"

if (-not $APIM_NAME) {
    Write-Error "No APIM instance found in '$RG'. Ensure 'azd provision' completed successfully."
}
if (-not $APPGW_FQDN) {
    Write-Warning "APPGW_FQDN is empty — App Gateway may not be deployed yet. AppGW tests will target an unresolvable FQDN until App Gateway is provisioned."
}

# Internal APIM hostname — used only by apim-smoke-test (direct VNet baseline, no App Gateway).
# All other tests target $APPGW_FQDN (App Gateway → APIM → Foundry).
$apimHostname = "$APIM_NAME.azure-api.net"

# Locate the ALT resource in this resource group
$ALT_RESOURCE = az load list -g $RG --query '[0].name' -o tsv 2>$null
if (-not $ALT_RESOURCE) {
    Write-Error "No Azure Load Testing resource found in '$RG'. Re-run 'azd provision' to create it."
}

# Subnet ID for VNet injection (so ALT agents run inside the VNet)
$subnetId = az load show --name $ALT_RESOURCE -g $RG --query "properties.subnetId" -o tsv 2>$null

$testsDir = Join-Path $PSScriptRoot '..' 'tests'
$tempDir  = $env:TEMP

Write-Host ""
Write-Host "ALT resource : $ALT_RESOURCE"
Write-Host "APIM         : $APIM_NAME  (internal: $apimHostname)"
Write-Host "AppGW FQDN   : $APPGW_FQDN"
Write-Host "Subnet ID    : $subnetId"
Write-Host ""

# ---------------------------------------------------------------------------
# 2. Install az load extension if not present
# ---------------------------------------------------------------------------
Write-Host "Checking az load extension..."
$ext = az extension list --query "[?name=='load'].name" -o tsv 2>$null
if ($ext -ne 'load') {
    Write-Host "  Installing az load extension..."
    az extension add --name load --yes
}

# ---------------------------------------------------------------------------
# 3. Fetch all APIM subscription keys
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Fetching APIM subscription keys ===" -ForegroundColor Cyan

function Get-ApimKey([string]$subId) {
    $key = az rest --method POST `
        --uri "https://management.azure.com/subscriptions/$SUB_ID/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$APIM_NAME/subscriptions/$subId/listSecrets?api-version=2022-08-01" `
        --query primaryKey -o tsv 2>$null
    if (-not $key) {
        Write-Warning "  Could not fetch key for subscription '$subId' — it will be empty in the test."
    }
    return $key
}

# LOB subscriptions — all 5 test definitions use LOB-named subscription IDs
$branchAdvisorKey      = Get-ApimKey 'app-branch-advisor'     # Bronze — BRONZE_KEY in generic load tests
$amlScreeningKey       = Get-ApimKey 'app-aml-screening'      # Silver — SILVER_KEY in generic load tests
$creditUnderwritingKey = Get-ApimKey 'app-credit-underwriting'
$investmentPlatformKey = Get-ApimKey 'app-investment-platform'

# Aliases used as BRONZE_KEY / SILVER_KEY env vars in apim-smoke-test, appgw-failover-test, appgw-smoke-test
$bronzeTestKey = $branchAdvisorKey
$silverTestKey = $amlScreeningKey
Write-Host "  app-branch-advisor:      $(if ($branchAdvisorKey)      { $branchAdvisorKey.Substring(0,8)+'...' }      else { 'MISSING' })  (BRONZE_KEY)"
Write-Host "  app-aml-screening:       $(if ($amlScreeningKey)       { $amlScreeningKey.Substring(0,8)+'...' }       else { 'MISSING' })  (SILVER_KEY)"
Write-Host "  app-credit-underwriting: $(if ($creditUnderwritingKey) { $creditUnderwritingKey.Substring(0,8)+'...' } else { 'MISSING' })"
Write-Host "  app-investment-platform: $(if ($investmentPlatformKey) { $investmentPlatformKey.Substring(0,8)+'...' } else { 'MISSING' })"

# ---------------------------------------------------------------------------
# 4. Helper — create or update one ALT test definition
# ---------------------------------------------------------------------------
function Register-AltTest {
    param(
        [string]   $TestId,
        [string]   $DisplayName,
        [string]   $Description,
        [string]   $JmxPath,
        [string[]] $EnvKvPairs,       # @("KEY=value", ...) — stored on the test definition
        [string[]] $AdditionalFiles,  # paths uploaded as ADDITIONAL_ARTIFACTS (system.properties, truststore)
        [string[]] $UserPropsPairs,   # @("KEY=value", ...) — written to user.properties and uploaded
        [string]   $TempFileName      # unique filename for temp user.properties in $TEMP
    )

    Write-Host ""
    Write-Host "─── $TestId ─────────────────────────────────────────────────" -ForegroundColor Cyan

    if (-not (Test-Path $JmxPath)) {
        Write-Warning "  JMX not found: $JmxPath — skipping $TestId"
        return
    }

    # Create or update the test definition
    $ErrorActionPreference = 'Continue'
    $exists = az load test show `
        --load-test-resource $ALT_RESOURCE -g $RG `
        --test-id $TestId --query testId -o tsv 2>$null
    $ErrorActionPreference = 'Stop'

    if ($exists -eq $TestId) {
        Write-Host "  Test exists — updating JMX and env vars..."
        az load test update `
            --load-test-resource $ALT_RESOURCE -g $RG `
            --test-id $TestId `
            --test-plan $JmxPath `
            -o none

        # Individual update calls per env var — avoids az load CLI preview bug
        # where multiple --env flags combined with --test-plan drops all but the last two.
        foreach ($kv in $EnvKvPairs) {
            az load test update `
                --load-test-resource $ALT_RESOURCE -g $RG `
                --test-id $TestId `
                --env $kv `
                -o none
        }
        Write-Host "  Updated." -ForegroundColor Green
    } else {
        Write-Host "  Creating test '$TestId'..."
        $createArgs = @(
            "load", "test", "create",
            "--load-test-resource", $ALT_RESOURCE,
            "-g", $RG,
            "--test-id", $TestId,
            "--display-name", $DisplayName,
            "--description", $Description,
            "--test-plan", $JmxPath,
            "-o", "none"
        )
        foreach ($kv in $EnvKvPairs) { $createArgs += @("--env", $kv) }
        if ($subnetId) { $createArgs += @("--subnet-id", $subnetId) }
        & az @createArgs
        if ($LASTEXITCODE -ne 0) { throw "az load test create failed for '$TestId' (exit $LASTEXITCODE)" }
        Write-Host "  Created '$TestId'." -ForegroundColor Green
    }

    # Upload static support files (system.properties, appgw-system.properties, truststore)
    foreach ($filePath in $AdditionalFiles) {
        if (Test-Path $filePath) {
            az load test file upload `
                --load-test-resource $ALT_RESOURCE -g $RG `
                --test-id $TestId `
                --path $filePath `
                --file-type ADDITIONAL_ARTIFACTS -o none
            Write-Host "  Uploaded $(Split-Path $filePath -Leaf)" -ForegroundColor Green
        } else {
            Write-Warning "  File not found (skipped): $(Split-Path $filePath -Leaf)"
        }
    }

    # Write user.properties to $TEMP, upload, then delete (contains live API keys)
    if ($UserPropsPairs -and $TempFileName) {
        $tmpPath = Join-Path $tempDir $TempFileName
        @(
            "# JMeter user properties for $TestId",
            "# Auto-generated by configure-load-test.ps1 — DO NOT COMMIT (contains live API keys)"
        ) + $UserPropsPairs | Set-Content -Path $tmpPath -Encoding utf8

        az load test file upload `
            --load-test-resource $ALT_RESOURCE -g $RG `
            --test-id $TestId `
            --path $tmpPath `
            --file-type USER_PROPERTIES -o none

        Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
        Write-Host "  Uploaded user.properties (keys injected; temp file deleted)" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# 5. Register all 5 load test definitions
# ---------------------------------------------------------------------------

# ── Test 1: apim-smoke-test ──────────────────────────────────────────────────
# Direct APIM baseline — ALT agent is inside the VNet (snet-loadtest) so it
# can reach APIM's internal hostname without going through App Gateway.
# Provides the reference latency for App Gateway overhead calculations.
Register-AltTest `
    -TestId       'apim-smoke-test' `
    -DisplayName  'APIM Smoke Test (direct VNet baseline)' `
    -Description  'Bronze/Silver direct to APIM (no AppGW); latency baseline for WAF overhead calculations' `
    -JmxPath      (Join-Path $testsDir 'apim-load-test.jmx') `
    -EnvKvPairs   @(
        "APIM_HOSTNAME=$apimHostname",
        "API_VERSION=2024-10-21",
        "BRONZE_KEY=$bronzeTestKey",
        "SILVER_KEY=$silverTestKey"
    ) `
    -AdditionalFiles @(
        (Join-Path $testsDir 'system.properties')
    ) `
    -UserPropsPairs @(
        "APIM_HOSTNAME=$apimHostname",
        "API_VERSION=2024-10-21",
        "BRONZE_KEY=$bronzeTestKey",
        "SILVER_KEY=$silverTestKey"
    ) `
    -TempFileName 'apim-smoke-user.properties'

# ── Test 2: appgw-failover-test ─────────────────────────────────────────────
# Saturates primary Foundry gpt-4o-mini TPM cap (1K TPM permanently).
# Verifies APIM circuit-breaker retries on secondary Foundry endpoint.
# Client sees HTTP 200; X-Backend-Region-Used: secondary-failover in responses.
Register-AltTest `
    -TestId       'appgw-failover-test' `
    -DisplayName  'AppGW Failover Blast — primary→secondary retry' `
    -Description  'Saturates primary Foundry TPM cap; verifies APIM circuit-breaker failover to secondary' `
    -JmxPath      (Join-Path $testsDir 'failover-load-test.jmx') `
    -EnvKvPairs   @(
        "APIM_HOSTNAME=$APPGW_FQDN",
        "API_VERSION=2024-10-21",
        "SILVER_KEY=$silverTestKey"
    ) `
    -AdditionalFiles @(
        (Join-Path $testsDir 'system.properties'),
        (Join-Path $testsDir 'appgw-system.properties')
    ) `
    -UserPropsPairs @(
        "APIM_HOSTNAME=$APPGW_FQDN",
        "API_VERSION=2024-10-21",
        "SILVER_KEY=$silverTestKey"
    ) `
    -TempFileName 'appgw-failover-user.properties'

# ── Test 3: appgw-smoke-test ─────────────────────────────────────────────────
# Measures WAF inspection latency overhead vs direct APIM baseline.
# appgw-truststore.p12 is generated by scripts/create-appgw-cert.ps1 and is
# uploaded when present. system.properties (trustStore=NONE) provides a fallback
# SSL bypass so the test still runs even without the truststore file.
$appgwTruststore = Join-Path $testsDir 'appgw-truststore.p12'
$appgwExtraFiles = [System.Collections.Generic.List[string]]::new()
if (Test-Path $appgwTruststore) {
    $appgwExtraFiles.Add($appgwTruststore)
} else {
    Write-Warning "appgw-truststore.p12 not found — run scripts/create-appgw-cert.ps1 then re-run this script to upload it."
    Write-Warning "The appgw-smoke-test will use system.properties (trustStore=NONE) as a fallback."
}
$appgwExtraFiles.Add((Join-Path $testsDir 'system.properties'))
$appgwExtraFiles.Add((Join-Path $testsDir 'appgw-system.properties'))

Register-AltTest `
    -TestId       'appgw-smoke-test' `
    -DisplayName  'AppGW WAF v2 Smoke Test' `
    -Description  'Measures latency through App Gateway WAF v2 vs direct APIM baseline (~10-30ms overhead expected)' `
    -JmxPath      (Join-Path $testsDir 'appgw-load-test.jmx') `
    -EnvKvPairs   @(
        "APIM_HOSTNAME=$APPGW_FQDN",
        "API_VERSION=2024-10-21",
        "BRONZE_KEY=$bronzeTestKey",
        "SILVER_KEY=$silverTestKey"
    ) `
    -AdditionalFiles $appgwExtraFiles.ToArray() `
    -UserPropsPairs @(
        "APIM_HOSTNAME=$APPGW_FQDN",
        "API_VERSION=2024-10-21",
        "BRONZE_KEY=$bronzeTestKey",
        "SILVER_KEY=$silverTestKey"
    ) `
    -TempFileName 'appgw-smoke-user.properties'

# ── Test 4: multi-sub-failover-test ─────────────────────────────────────────
# All four LOB subscriptions run sustained + blast suites simultaneously.
# Proves one tenant's TPM burst does not black out other subscriptions.
Register-AltTest `
    -TestId       'multi-sub-failover-test' `
    -DisplayName  'Multi-Sub Failover: Bronze+Silver+Gold' `
    -Description  'All LOB subs concurrent; triggers APIM circuit-breaker; proves per-tenant isolation' `
    -JmxPath      (Join-Path $testsDir 'multi-sub-failover-test.jmx') `
    -EnvKvPairs   @(
        "APIM_HOSTNAME=$APPGW_FQDN",
        "API_VERSION=2024-10-21",
        "BRONZE_KEY=$branchAdvisorKey",
        "SILVER_KEY=$amlScreeningKey",
        "SILVER_KEY_2=$creditUnderwritingKey",
        "GOLD_KEY=$investmentPlatformKey"
    ) `
    -AdditionalFiles @(
        (Join-Path $testsDir 'system.properties'),
        (Join-Path $testsDir 'appgw-system.properties')
    ) `
    -UserPropsPairs @(
        "APIM_HOSTNAME=$APPGW_FQDN",
        "API_VERSION=2024-10-21",
        "BRONZE_KEY=$branchAdvisorKey",
        "SILVER_KEY=$amlScreeningKey",
        "SILVER_KEY_2=$creditUnderwritingKey",
        "GOLD_KEY=$investmentPlatformKey"
    ) `
    -TempFileName 'multi-sub-failover-user.properties'

# ── Test 5: steady-state-test ────────────────────────────────────────────────
# 1-hour baseline — all four LOB subscriptions at ~160 TPM combined.
# No throttling or failover expected. Use to populate Grafana / App Insights dashboards.
# Can run concurrently with multi-sub-failover-test (different ALT test ID).
Register-AltTest `
    -TestId       'steady-state-test' `
    -DisplayName  'Steady State: All Subscriptions (1h)' `
    -Description  '4 LOB subs, ~160 TPM combined, 3600s; no failover expected; populates monitoring dashboards' `
    -JmxPath      (Join-Path $testsDir 'steady-state-test.jmx') `
    -EnvKvPairs   @(
        "APIM_HOSTNAME=$APPGW_FQDN",
        "API_VERSION=2024-10-21",
        "BRONZE_KEY=$branchAdvisorKey",
        "SILVER_KEY=$amlScreeningKey",
        "SILVER_KEY_2=$creditUnderwritingKey",
        "GOLD_KEY=$investmentPlatformKey"
    ) `
    -AdditionalFiles @(
        (Join-Path $testsDir 'system.properties'),
        (Join-Path $testsDir 'appgw-system.properties')
    ) `
    -UserPropsPairs @(
        "APIM_HOSTNAME=$APPGW_FQDN",
        "API_VERSION=2024-10-21",
        "BRONZE_KEY=$branchAdvisorKey",
        "SILVER_KEY=$amlScreeningKey",
        "SILVER_KEY_2=$creditUnderwritingKey",
        "GOLD_KEY=$investmentPlatformKey"
    ) `
    -TempFileName 'steady-state-user.properties'

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "All 5 load test definitions configured in '$ALT_RESOURCE'." -ForegroundColor Green
Write-Host ""
Write-Host "Run a test:"
Write-Host "  pwsh scripts/run-load-test.ps1               # interactive launcher — pick from all 5 tests"
Write-Host "  pwsh scripts/run-apim-smoke-test.ps1         # apim-smoke-test       (direct APIM baseline)"
Write-Host "  pwsh scripts/run-appgw-failover-test.ps1     # appgw-failover-test   (circuit-breaker blast)"
Write-Host "  pwsh scripts/run-appgw-smoke-test.ps1        # appgw-smoke-test      (WAF overhead ~5 min)"
Write-Host "  pwsh scripts/run-multi-sub-failover-test.ps1 # multi-sub-failover-test  (~2 min)"
Write-Host "  pwsh scripts/run-steady-state-test.ps1       # steady-state-test     (1 hour)"
Write-Host ""
Write-Host "Note: scripts/create-appgw-cert.ps1 generates tests/appgw-truststore.p12."
Write-Host "      Run it once after provision, then re-run this script to upload the truststore to appgw-smoke-test."
