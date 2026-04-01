$t = az account get-access-token --query accessToken -o tsv
$url = "https://management.azure.com/subscriptions/d201ebeb-c470-4a6f-82d5-c2f95bb0dc1e/resourceGroups/rg-contoso-ai-platform-dev/providers/Microsoft.ApiManagement/service/apim-contoso-vdls2xyq/apis/openai-inference/policies/policy?api-version=2023-05-01-preview&format=rawxml"
Invoke-RestMethod -Method Get -Uri $url -Headers @{Authorization="Bearer $t"} -OutFile "$env:TEMP\apim-policy-live.xml"
Write-Host "=== Backend section ==="
Get-Content "$env:TEMP\apim-policy-live.xml" | Select-String "retry|choose|selectedBackend|forward-request|context" | ForEach-Object { $_.Line.Trim() }
