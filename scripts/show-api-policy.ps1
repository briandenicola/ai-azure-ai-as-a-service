. "$PSScriptRoot/_resolve-env.ps1"
$t = $tok

Write-Host "=== API policy ==="
$r = Invoke-RestMethod -Method Get -Uri "$base/apis/openai-inference/policies/policy?api-version=2023-05-01-preview&format=rawxml" -Headers @{Authorization="Bearer $t"}
$r.value
