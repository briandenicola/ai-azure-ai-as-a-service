# run-load-test.ps1
#
# Interactive launcher — choose which load test to run from a numbered menu.
# Delegates to the appropriate run-*.ps1 script once a test is selected.
#
# Usage:
#   pwsh scripts/run-load-test.ps1
#
# Exit codes mirror the delegated script:
#   0 — test run completed and all pass/fail criteria met
#   1 — test run failed, timed out, or server-side error

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$tests = @(
    [pscustomobject]@{
        Number      = 1
        Script      = 'run_azure_load_test_apim-smoke-test.ps1'
        TestId      = 'apim-smoke-test'
        Duration    = '~2 min'
        Recommended = $true
        Description = 'APIM smoke — direct internal VNet path (no App Gateway)'
        WhenToUse   = @(
            'Run this FIRST after every azd provision && azd deploy.',
            'Confirms gpt-4o-mini is reachable and Bronze/Silver keys are valid.',
            'Fastest sanity check — no App Gateway required.'
        )
    }
    [pscustomobject]@{
        Number      = 2
        Script      = 'run_azure_load_test_appgw-smoke-test.ps1'
        TestId      = 'appgw-smoke-test'
        Duration    = '~5 min'
        Recommended = $false
        Description = 'App Gateway smoke — measures WAF inspection overhead'
        WhenToUse   = @(
            'Compares AppGW-path latency against the direct-APIM baseline.',
            'Run after updating WAF rules or upgrading the App Gateway SKU.',
            'Expect ~10-30 ms overhead from WAF inspection.'
        )
    }
    [pscustomobject]@{
        Number      = 3
        Script      = 'run_azure_load_test_appgw-failover-test.ps1'
        TestId      = 'appgw-failover-test'
        Duration    = '~2 min'
        Recommended = $false
        Description = 'Failover — validates circuit-breaker policy end-to-end'
        WhenToUse   = @(
            'Deliberately exhausts primary Foundry TPM and confirms every',
            'request still returns HTTP 200 via the West US secondary.',
            'Run after any change to the circuit-breaker or failover policy.'
        )
    }
    [pscustomobject]@{
        Number      = 4
        Script      = 'run_azure_load_test_multi-sub-failover-test.ps1'
        TestId      = 'multi-sub-failover-test'
        Duration    = '~2 min'
        Recommended = $false
        Description = 'Multi-LOB failover — Bronze + Silver in concurrent blast suites'
        WhenToUse   = @(
            'Runs Bronze and Silver suites concurrently under shared TPM pressure.',
            "Proves one tenant's burst cannot black out another tenant's subscription.",
            'Use when you need to demonstrate multi-LOB isolation to stakeholders.'
        )
    }
    [pscustomobject]@{
        Number      = 5
        Script      = 'run_azure_load_test_steady-state-test.ps1'
        TestId      = 'steady-state-test'
        Duration    = '1 hour'
        Recommended = $false
        Description = 'Steady state — baseline traffic for dashboards and alerting'
        WhenToUse   = @(
            'Sends ~160 TPM across all four LOB subscriptions for one hour.',
            'Run overnight to populate Grafana dashboards and App Insights workbooks.',
            'Can run concurrently with multi-sub-failover-test (different ALT test ID).'
        )
    }
)

# ── Print menu ───────────────────────────────────────────────────────────────────
Clear-Host
Write-Host ""
Write-Host " Azure AI Platform — Load Test Launcher" -ForegroundColor Cyan
Write-Host " ═══════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

foreach ($t in $tests) {
    $rec = if ($t.Recommended) { " ◄ recommended after azd provision" } else { "" }
    Write-Host ("  [{0}]  {1}{2}" -f $t.Number, $t.Description, $rec) -ForegroundColor $(if ($t.Recommended) { 'Green' } else { 'White' })
    Write-Host ("         ALT test ID : {0}   Duration: {1}" -f $t.TestId, $t.Duration) -ForegroundColor DarkGray
    foreach ($line in $t.WhenToUse) {
        Write-Host ("         $line") -ForegroundColor DarkGray
    }
    Write-Host ""
}

Write-Host " ═══════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ── Prompt ───────────────────────────────────────────────────────────────────────
do {
    $input = Read-Host "  Select a test [1-5] (or Q to quit)"
    if ($input -match '^[Qq]$') {
        Write-Host "  Aborted." -ForegroundColor Yellow
        exit 0
    }
    $choice = $input -as [int]
} while ($choice -lt 1 -or $choice -gt $tests.Count)

$selected = $tests | Where-Object { $_.Number -eq $choice }

Write-Host ""
Write-Host "  Running: $($selected.Description)" -ForegroundColor Cyan
Write-Host "  Script : load_tests/scripts/azure_load_test/$($selected.Script)" -ForegroundColor DarkGray
Write-Host ""

# ── Delegate ─────────────────────────────────────────────────────────────────────
$scriptPath = Join-Path $PSScriptRoot $selected.Script
& $scriptPath
exit $LASTEXITCODE
