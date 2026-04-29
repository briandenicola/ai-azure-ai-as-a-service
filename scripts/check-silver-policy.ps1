. "$PSScriptRoot/_resolve-env.ps1"

Write-Host "=== Live Silver product policy ==="
$r = Invoke-RestMethod -Method Get -Uri "$base/products/ai-silver/policies/policy?api-version=2023-05-01-preview&format=rawxml" -Headers @{Authorization="Bearer $t"}
$xml = $r.value
Write-Host $xml
