# run-load-test.ps1
#
# Creates and monitors an Azure Load Testing test run against the APIM gateway.
#
# Usage:
#   pwsh scripts/run-load-test.ps1
#   pwsh scripts/run-load-test.ps1 -TestId apim-smoke-test -Engines 2 -Description "Pre-release smoke"
#
# Prerequisites:
#   azd provision (with AZURE_DEPLOY_LOAD_TEST=true) must have run successfully.
#   configure-load-test.ps1 must have run (test definition must exist).
#
# Exit codes:
#   0 — test run completed and all pass/fail criteria met (or no criteria set)
#   1 — test run failed, timed out, or server-side error

[CmdletBinding()]
param(
    [string] $TestId     = 'apim-smoke-test',
    [int]    $Engines    = 1,
    [string] $Description = '',
    [int]    $TimeoutMinutes = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 1. Resolve environment
# ---------------------------------------------------------------------------
function Get-AzdEnv {
    param([string]$Name)
    $val = (azd env get-values 2>$null | Select-String "^$Name=").ToString() -replace "^$Name=`"?|`"?$", ''
    return $val.Trim()
}

$RG          = $env:AZURE_RESOURCE_GROUP
$envName     = $env:AZURE_ENV_NAME ?? 'dev'
$companyPrefix = 'contoso'
$altName     = "lt-$companyPrefix-ai-$envName"

# Prefer env vars set by azd; fall back to azd env get-values
if (-not $RG) {
    $RG = Get-AzdEnv 'AZURE_RESOURCE_GROUP'
}

if (-not $RG) {
    Write-Error "AZURE_RESOURCE_GROUP is not set. Run 'azd env get-values' or set the variable."
}

# ---------------------------------------------------------------------------
# 2. Ensure az load extension is present
# ---------------------------------------------------------------------------
$ext = az extension list --query "[?name=='load'].name" -o tsv 2>$null
if ($ext -ne 'load') {
    Write-Host "Installing az load extension..."
    az extension add --name load --yes
}

# ---------------------------------------------------------------------------
# 3. Verify the test definition exists
# ---------------------------------------------------------------------------
Write-Host "Verifying test definition '$TestId' in '$altName'..."
$testExists = az load test show `
    --load-test-resource $altName `
    --resource-group $RG `
    --test-id $TestId `
    --query testId -o tsv 2>$null

if ($testExists -ne $TestId) {
    Write-Error @"
Test definition '$TestId' not found in '$altName'.
Run the following to create it first:
  pwsh scripts/configure-load-test.ps1
"@
}

# ---------------------------------------------------------------------------
# 4. Optionally update engine count (allows scaling up for a specific run)
# ---------------------------------------------------------------------------
if ($Engines -gt 1) {
    Write-Host "Updating engine instance count to $Engines..."
    az load test update `
        --load-test-resource $altName `
        --resource-group $RG `
        --test-id $TestId `
        --engine-instances $Engines | Out-Null
}

# ---------------------------------------------------------------------------
# 5. Create the test run
# ---------------------------------------------------------------------------
$runId      = "run-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$displayName = if ($Description) { $Description } else { "Smoke test $(Get-Date -Format 'yyyy-MM-dd HH:mm')" }

Write-Host ""
Write-Host "Starting load test run:"
Write-Host "  Resource : $altName"
Write-Host "  Test ID  : $TestId"
Write-Host "  Run ID   : $runId"
Write-Host "  Engines  : $Engines"
Write-Host "  Timeout  : $TimeoutMinutes min"
Write-Host ""

az load test-run create `
    --load-test-resource $altName `
    --resource-group $RG `
    --test-id $TestId `
    --test-run-id $runId `
    --display-name $displayName | Out-Null

Write-Host "Test run created. Polling for completion..."

# ---------------------------------------------------------------------------
# 6. Poll until terminal state
# ---------------------------------------------------------------------------
$terminalStates = @('DONE', 'FAILED', 'CANCELLED', 'VALIDATION_FAILURE')
$pollInterval   = 15   # seconds
$maxPolls       = [math]::Ceiling($TimeoutMinutes * 60 / $pollInterval)
$spinChars      = @('|', '/', '-', '\')
$spin           = 0

for ($i = 0; $i -lt $maxPolls; $i++) {
    Start-Sleep -Seconds $pollInterval

    $run = az load test-run show `
        --load-test-resource $altName `
        --resource-group $RG `
        --test-run-id $runId `
        -o json 2>$null | ConvertFrom-Json

    $status   = $run.status
    # duration (ms) only populated once the run has a startDateTime; guard with null check
    $elapsed  = if ($run.PSObject.Properties['duration'] -and $run.duration) { "$([math]::Round($run.duration / 1000))s" } else { '…' }

    $spinChar = $spinChars[$spin % $spinChars.Count]; $spin++
    Write-Host -NoNewline "`r  $spinChar  Status: $($status.PadRight(20)) Elapsed: $elapsed    "

    if ($terminalStates -contains $status) {
        Write-Host ""
        break
    }
}

Write-Host ""

# ---------------------------------------------------------------------------
# 7. Report results — stats are computed async after DONE; retry until populated
# ---------------------------------------------------------------------------
$run = $null
for ($r = 0; $r -lt 24; $r++) {
    $run = az load test-run show `
        --load-test-resource $altName `
        --resource-group $RG `
        --test-run-id $runId `
        -o json 2>$null | ConvertFrom-Json
    if ($run.PSObject.Properties['testRunStatistics'] -and
        $run.testRunStatistics -and
        ($run.testRunStatistics.PSObject.Properties | Measure-Object).Count -gt 0) { break }
    if ($r -lt 23) {
        Write-Host -NoNewline "`r  Waiting for statistics... ($([math]::Round(($r+1)*5))s elapsed)   "
        Start-Sleep -Seconds 5
    }
}
Write-Host ""

$status    = $run.status
$passOrFail = $run.testResult   # 'PASSED' | 'FAILED' | 'NOT_APPLICABLE'

Write-Host "────────────────────────────────────────────────────"
Write-Host " Run ID   : $runId"
Write-Host " Status   : $status"
Write-Host " Result   : $passOrFail"

# testRunStatistics is a PSCustomObject keyed by transaction name.
# Print the 'Total' row plus one row per sampler.
if ($run.PSObject.Properties['testRunStatistics'] -and $run.testRunStatistics) {
    $stats = $run.testRunStatistics

    # Helper: safely read a numeric property, round to integer
    function Fmt($val) { if ($null -eq $val) { '—' } else { [math]::Round($val) } }

    Write-Host ""
    Write-Host " Per-sampler results:"
    $fmt = "{0,-55} {1,8} {2,8} {3,8} {4,8} {5,8} {6,8} {7,8}"
    Write-Host ($fmt -f 'Transaction', 'Samples', 'Errors', 'Err%', 'p50ms', 'p90ms', 'p99ms', 'RPS')
    Write-Host ($fmt -f ('-' * 55), ('-' * 8), ('-' * 8), ('-' * 8), ('-' * 8), ('-' * 8), ('-' * 8), ('-' * 8))

    # Print Total last for emphasis
    $txNames = $stats.PSObject.Properties.Name | Where-Object { $_ -ne 'Total' }
    foreach ($tx in ($txNames + @('Total'))) {
        $s = $stats.$tx
        if (-not $s) { continue }
        $label = if ($tx.Length -gt 55) { $tx.Substring(0, 52) + '...' } else { $tx }
        $line  = $fmt -f $label,
                            (Fmt $s.sampleCount),
                            (Fmt $s.errorCount),
                            "$(Fmt $s.errorPct)%",
                            (Fmt $s.medianResTime),
                            (Fmt $s.pct2ResTime),
                            (Fmt $s.pct3ResTime),
                            ([math]::Round($s.throughput, 1))
        if ($tx -eq 'Total') { Write-Host $line -ForegroundColor Cyan } else { Write-Host $line }
    }
} else {
    Write-Host " (No testRunStatistics returned — run may have been too short or all requests failed.)"
}

$portalUrl = if ($run.PSObject.Properties['portalUrl'] -and $run.portalUrl) { $run.portalUrl } else { "https://portal.azure.com (search load test run $runId)" }
Write-Host " Portal   : $portalUrl"
Write-Host "────────────────────────────────────────────────────"

# ---------------------------------------------------------------------------
# 8. Exit with appropriate code
# ---------------------------------------------------------------------------
if ($status -eq 'DONE' -and $passOrFail -ne 'FAILED') {
    Write-Host "PASSED" -ForegroundColor Green
    exit 0
} elseif ($status -notin $terminalStates) {
    Write-Warning "Timed out waiting for run to complete. Check the portal for current status."
    exit 1
} else {
    Write-Host "FAILED — status: $status  result: $passOrFail" -ForegroundColor Red
    exit 1
}
