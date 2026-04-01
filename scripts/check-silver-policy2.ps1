$t = az account get-access-token --query accessToken -o tsv
$base = "https://management.azure.com/subscriptions/d201ebeb-c470-4a6f-82d5-c2f95bb0dc1e/resourceGroups/rg-contoso-ai-platform-dev/providers/Microsoft.ApiManagement/service/apim-contoso-vdls2xyq"

Write-Host "=== Silver product policies ==="
try {
    $r = Invoke-RestMethod -Method Get -Uri "$base/products/ai-silver/policies?api-version=2023-05-01-preview" -Headers @{Authorization="Bearer $t"}
    $r | ConvertTo-Json -Depth 5
} catch {
    Write-Host "Error: $($_.Exception.Message)"
    Write-Host "StatusCode: $($_.Exception.Response.StatusCode)"
}
