. "$PSScriptRoot/_resolve-env.ps1"

Write-Host "=== Silver product policy ==="
$r = Invoke-RestMethod -Method Get -Uri "$base/products/ai-silver/policies/policy?api-version=2023-05-01-preview&format=rawxml" -Headers @{Authorization="Bearer $t"}
$r.value

Write-Host ""
Write-Host "=== Bronze product policy ==="
$r2 = Invoke-RestMethod -Method Get -Uri "$base/products/ai-bronze/policies/policy?api-version=2023-05-01-preview&format=rawxml" -Headers @{Authorization="Bearer $t"}
$r2.value
