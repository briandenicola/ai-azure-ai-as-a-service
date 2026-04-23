$runId = (az load test-run list --load-test-resource lt-contoso-ai-dev --resource-group rg-contoso-ai-platform-dev --test-id steady-state-test --query '[0].testRunId' -o tsv 2>$null).Trim()
Write-Host "Run ID: $runId"
$detail = az load test-run show --load-test-resource lt-contoso-ai-dev --resource-group rg-contoso-ai-platform-dev --test-run-id $runId 2>&1 | Out-String
Write-Host $detail
