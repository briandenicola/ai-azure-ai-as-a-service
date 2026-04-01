$t = az account get-access-token --query accessToken -o tsv
$base = "https://management.azure.com/subscriptions/d201ebeb-c470-4a6f-82d5-c2f95bb0dc1e/resourceGroups/rg-contoso-ai-platform-dev/providers/Microsoft.ApiManagement/service/apim-contoso-vdls2xyq"

Write-Host "=== All subscriptions ==="
$subs = Invoke-RestMethod -Method Get -Uri "$base/subscriptions?api-version=2023-05-01-preview" -Headers @{Authorization="Bearer $t"}
$subs.value | ForEach-Object {
    Write-Host "Name: $($_.properties.displayName) | State: $($_.properties.state) | Scope: $($_.properties.scope)"
}
