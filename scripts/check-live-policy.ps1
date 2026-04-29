. "$PSScriptRoot/_resolve-env.ps1"
$url = "$base/apis/openai-inference/policies/policy?api-version=2023-05-01-preview&format=rawxml"
Invoke-RestMethod -Method Get -Uri $url -Headers @{Authorization="Bearer $t"} -OutFile "$env:TEMP\apim-policy-live.xml"
Write-Host "=== Backend section ==="
Get-Content "$env:TEMP\apim-policy-live.xml" | Select-String "retry|choose|selectedBackend|forward-request|context" | ForEach-Object { $_.Line.Trim() }
