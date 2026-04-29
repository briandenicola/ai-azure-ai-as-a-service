. "$PSScriptRoot/_resolve-env.ps1"
$ALT_RESOURCE = az load list -g $RG --query '[0].name' -o tsv 2>$null
$runId = (az load test-run list --load-test-resource $ALT_RESOURCE --resource-group $RG --test-id steady-state-test --query '[0].testRunId' -o tsv 2>$null).Trim()
Write-Host "Run ID: $runId"
$detail = az load test-run show --load-test-resource $ALT_RESOURCE --resource-group $RG --test-run-id $runId 2>&1 | Out-String
Write-Host $detail
