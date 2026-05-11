# run_jmeter.ps1
#
# Interactive launcher — choose which load test to run locally via JMeter.
# Delegates to the appropriate run_jmeter_*.ps1 script once a test is selected.
#
# Usage:
#   pwsh load_tests/scripts/jmeter/run_jmeter.ps1
#
# Prerequisites:
#   • JMeter 5.6+ on PATH (jmeter binary)
#   • az login completed
#   • azd provision completed
#   • For AppGW tests: App Gateway deployed and running
#
# Exit codes mirror the delegated script:
#   0 — test completed (check HTML report for pass/fail analysis)
#   1 — script-level error before or after JMeter execution

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$tests = @(
    [pscustomobject]@{
        Number      = 1
        Script      = 'run_jmeter_apim-smoke-test.ps1'
        JmxFile     = 'apim-load-test.jmx'
        Duration    = '~2 min'
        Recommended = $true
        Description = 'APIM smoke — direct internal VNet path (no App Gateway)'
        WhenToUse   = @(
            'Run after azd provision to confirm gpt-4o-mini and APIM keys are valid.',
            'NOTE: APIM is Internal VNet — requires VPN or ACI jumpbox access.',
            'Fastest sanity check; no App Gateway required.'
        )
    }
    [pscustomobject]@{
        Number      = 2
        Script      = 'run_jmeter_appgw-smoke-test.ps1'
        JmxFile     = 'appgw-load-test.jmx'
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
        Script      = 'run_jmeter_appgw-failover-test.ps1'
        JmxFile     = 'failover-load-test.jmx'
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
        Script      = 'run_jmeter_multi-sub-failover-test.ps1'
        JmxFile     = 'multi-sub-failover-test.jmx'
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
        Script      = 'run_jmeter_steady-state-test.ps1'
        JmxFile     = 'steady-state-test.jmx'
        Duration    = '1 hour'
        Recommended = $false
        Description = 'Steady state — baseline traffic for dashboards and alerting'
        WhenToUse   = @(
            'Sends ~160 TPM across all four LOB subscriptions for one hour.',
            'Run overnight to populate Grafana dashboards and App Insights workbooks.',
            'Output saved locally to load_tests/scripts/jmeter/output/.'
        )
    }
)

# ── Print menu ───────────────────────────────────────────────────────────────────
Clear-Host
Write-Host ""
Write-Host " Azure AI Platform — Local JMeter Test Launcher" -ForegroundColor Cyan
Write-Host " ═══════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

foreach ($t in $tests) {
    $rec = if ($t.Recommended) { " ◄ recommended first test" } else { "" }
    Write-Host ("  [{0}]  {1}{2}" -f $t.Number, $t.Description, $rec) -ForegroundColor $(if ($t.Recommended) { 'Green' } else { 'White' })
    Write-Host ("         JMX file : {0}   Duration: {1}" -f $t.JmxFile, $t.Duration) -ForegroundColor DarkGray
    foreach ($line in $t.WhenToUse) {
        Write-Host ("         $line") -ForegroundColor DarkGray
    }
    Write-Host ""
}

Write-Host " ═══════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ── Prompt ───────────────────────────────────────────────────────────────────────
do {
    $userInput = Read-Host "  Select a test [1-5] (or Q to quit)"
    if ($userInput -match '^[Qq]$') {
        Write-Host "  Aborted." -ForegroundColor Yellow
        exit 0
    }
    $choice = $userInput -as [int]
} while ($choice -lt 1 -or $choice -gt $tests.Count)

$selected = $tests | Where-Object { $_.Number -eq $choice }

Write-Host ""
Write-Host "  Running: $($selected.Description)" -ForegroundColor Cyan
Write-Host "  Script : load_tests/scripts/jmeter/$($selected.Script)" -ForegroundColor DarkGray
Write-Host ""

# ── Delegate ─────────────────────────────────────────────────────────────────────
$scriptPath = Join-Path $PSScriptRoot $selected.Script
& $scriptPath
exit $LASTEXITCODE
