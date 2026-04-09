#!/usr/bin/env pwsh
Set-StrictMode -Off
$ErrorActionPreference = "Stop"

$ALT_RESOURCE = "lt-contoso-ai-dev"
$ALT_RG       = "rg-contoso-ai-platform-dev"
$APIM_NAME    = "apim-contoso-vdls2xyq"
$APPGW_FQDN   = "agw-contoso-ai-primary.eastus.cloudapp.azure.com"
$SUB_ID       = "d201ebeb-c470-4a6f-82d5-c2f95bb0dc1e"
$repoRoot     = Split-Path -Parent $PSScriptRoot

function Get-ApimKey([string]$subName) {
    for ($i = 1; $i -le 5; $i++) {
        $ErrorActionPreference = "Continue"
        $json = az rest --method POST `
            --uri "https://management.azure.com/subscriptions/$SUB_ID/resourceGroups/$ALT_RG/providers/Microsoft.ApiManagement/service/$APIM_NAME/subscriptions/$subName/listSecrets?api-version=2022-08-01" `
            2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
        $ErrorActionPreference = "Stop"
        if ($json.primaryKey) { return $json.primaryKey }
        Write-Host "  Retry $i/5 for $subName..." -ForegroundColor Yellow
        Start-Sleep 5
    }
    throw "Failed to fetch key: $subName"
}

Write-Host "`n=== Fetching APIM keys ===" -ForegroundColor Cyan
$BRONZE_KEY   = Get-ApimKey "app-branch-advisor"
$SILVER_KEY   = Get-ApimKey "app-aml-screening"
$SILVER_KEY_2 = Get-ApimKey "app-credit-underwriting"
$GOLD_KEY     = Get-ApimKey "Investment-Platform"
Write-Host "  Branch Advisor (Bronze): $($BRONZE_KEY.Substring(0,8))..." -ForegroundColor Green
Write-Host "  AML Screening  (Silver): $($SILVER_KEY.Substring(0,8))..." -ForegroundColor Green
Write-Host "  Credit U/W     (Silver): $($SILVER_KEY_2.Substring(0,8))..." -ForegroundColor Green
Write-Host "  Inv. Platform  (Gold):   $($GOLD_KEY.Substring(0,8))..." -ForegroundColor Green

$subnetId = az load show --name $ALT_RESOURCE -g $ALT_RG --query "properties.subnetId" -o tsv 2>$null

function Deploy-AltTest([string]$testId, [string]$displayName, [string]$desc, [string]$jmxPath) {
    Write-Host "`n=== Deploying: $testId ===" -ForegroundColor Cyan
    if (-not (Test-Path $jmxPath)) { throw "JMX not found: $jmxPath" }

    $ErrorActionPreference = "Continue"
    $existing = az load test show `
        --load-test-resource $ALT_RESOURCE -g $ALT_RG `
        --test-id $testId -o json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    $ErrorActionPreference = "Stop"

    $kvs = @(
        "APIM_HOSTNAME=$APPGW_FQDN",
        "API_VERSION=2024-10-21",
        "BRONZE_KEY=$BRONZE_KEY",
        "SILVER_KEY=$SILVER_KEY",
        "SILVER_KEY_2=$SILVER_KEY_2",
        "GOLD_KEY=$GOLD_KEY"
    )

    if (-not $existing) {
        Write-Host "  Creating '$testId'..." -ForegroundColor Yellow
        $createArgs = @(
            "load", "test", "create",
            "--load-test-resource", $ALT_RESOURCE,
            "-g", $ALT_RG,
            "--test-id", $testId,
            "--display-name", $displayName,
            "--description", $desc,
            "--test-plan", $jmxPath,
            "-o", "none"
        )
        foreach ($kv in $kvs) { $createArgs += "--env"; $createArgs += $kv }
        if ($subnetId) { $createArgs += "--subnet-id"; $createArgs += $subnetId }
        & az @createArgs
        if ($LASTEXITCODE -ne 0) { throw "Create failed for $testId (exit $LASTEXITCODE)" }
        Write-Host "  Created '$testId'." -ForegroundColor Green
    } else {
        Write-Host "  Updating '$testId' (already exists)..." -ForegroundColor Yellow
        # All env vars in one call — reduces 6 separate HTTPS calls to 1,
        # which is far less likely to hit intermittent SSL proxy errors.
        $updateArgs = @(
            "load", "test", "update",
            "--load-test-resource", $ALT_RESOURCE,
            "-g", $ALT_RG,
            "--test-id", $testId,
            "--test-plan", $jmxPath,
            "-o", "none"
        )
        foreach ($kv in $kvs) { $updateArgs += "--env"; $updateArgs += $kv }
        for ($r = 1; $r -le 5; $r++) {
            $ErrorActionPreference = "Continue"
            & az @updateArgs 2>&1 | Where-Object { $_ -notmatch "preview" }
            $ErrorActionPreference = "Stop"
            if ($LASTEXITCODE -eq 0) { break }
            Write-Host "  SSL retry $r/5 for $testId..." -ForegroundColor Yellow
            Start-Sleep 5
        }
        if ($LASTEXITCODE -ne 0) { throw "Update failed for $testId after 5 retries" }
        Write-Host "  Updated '$testId'." -ForegroundColor Green
    }
}

Deploy-AltTest `
    "multi-sub-failover-test" `
    "Multi-Sub Failover: Bronze+Silver+Gold" `
    "Bronze+Silver+Gold sustained+blast suites; triggers APIM failover-retry policy" `
    "$repoRoot\tests\multi-sub-failover-test.jmx"

Deploy-AltTest `
    "steady-state-test" `
    "Steady State: All Subscriptions (1h)" `
    "Baseline 4-sub steady traffic; ~160 TPM combined; no failover expected" `
    "$repoRoot\tests\steady-state-test.jmx"

Write-Host "`n=== Both tests deployed successfully ===" -ForegroundColor Green
Write-Host "  To run failover test:  pwsh scripts/run-multi-sub-failover-test.ps1" -ForegroundColor Cyan
Write-Host "  To run steady-state:   pwsh scripts/run-steady-state-test.ps1" -ForegroundColor Cyan
Write-Host "  To run concurrently:" -ForegroundColor Cyan
Write-Host "    Start-Process pwsh -ArgumentList '-File','scripts/run-steady-state-test.ps1'" -ForegroundColor Cyan
Write-Host "    Start-Process pwsh -ArgumentList '-File','scripts/run-multi-sub-failover-test.ps1'" -ForegroundColor Cyan
