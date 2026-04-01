$t = az account get-access-token --query accessToken -o tsv
$base = "https://management.azure.com/subscriptions/d201ebeb-c470-4a6f-82d5-c2f95bb0dc1e/resourceGroups/rg-contoso-ai-platform-dev/providers/Microsoft.ApiManagement/service/apim-contoso-vdls2xyq"

$debugPolicy = @"
<policies>
  <inbound>
    <base />
    <!-- Debug: skip circuit-breaker, always use primary via API policy's set-backend-service -->
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>
"@

$body = @{
    properties = @{
        format = "rawxml"
        value = $debugPolicy
    }
} | ConvertTo-Json -Depth 5

Write-Host "Patching Silver product policy (debug: base only)..."
$r = Invoke-RestMethod -Method Put -Uri "$base/products/ai-silver/policies/policy?api-version=2023-05-01-preview" -Headers @{Authorization="Bearer $t"; "Content-Type"="application/json"} -Body $body
Write-Host "Done. Silver product policy replaced with base-only."
