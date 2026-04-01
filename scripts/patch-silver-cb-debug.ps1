$t = az account get-access-token --query accessToken -o tsv
$base = "https://management.azure.com/subscriptions/d201ebeb-c470-4a6f-82d5-c2f95bb0dc1e/resourceGroups/rg-contoso-ai-platform-dev/providers/Microsoft.ApiManagement/service/apim-contoso-vdls2xyq"

# Replace Silver product policy with one that reads and ECHOES the primaryFailureCount
$debugPolicy = @"
<policies>
  <inbound>
    <base />
    <!-- Circuit-breaker failover -->
    <set-variable name="primaryBackend" value="{{foundry-primary-endpoint}}" />
    <set-variable name="secondaryBackend" value="{{foundry-secondary-endpoint}}" />
    <cache-lookup-value key="@(&quot;circuit-breaker-&quot; + context.Variables[&quot;primaryBackend&quot;])" variable-name="primaryFailureCount" />
    <choose>
      <when condition="@(context.Variables.ContainsKey(&quot;primaryFailureCount&quot;) == false)">
        <set-variable name="primaryFailureCount" value="0" />
      </when>
    </choose>
    <!-- Expose the counter in a response header for diagnosis -->
    <set-variable name="cbState" value="@(&quot;count=&quot; + (string)context.Variables[&quot;primaryFailureCount&quot;])" />
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
    <set-header name="X-CB-State" exists-action="override">
      <value>@((string)context.Variables["cbState"])</value>
    </set-header>
  </outbound>
  <on-error><base /></on-error>
</policies>
"@

$body = @{
    properties = @{
        format = "rawxml"
        value = $debugPolicy
    }
} | ConvertTo-Json -Depth 5

Write-Host "Patching Silver product policy to expose circuit-breaker counter..."
$r = Invoke-RestMethod -Method Put -Uri "$base/products/ai-silver/policies/policy?api-version=2023-05-01-preview" -Headers @{Authorization="Bearer $t"; "Content-Type"="application/json"} -Body $body
Write-Host "Done."
