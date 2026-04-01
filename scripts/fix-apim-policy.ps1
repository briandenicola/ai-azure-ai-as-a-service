$tok = (az account get-access-token --query accessToken -o tsv)
$sub = "d201ebeb-c470-4a6f-82d5-c2f95bb0dc1e"
$base = "https://management.azure.com/subscriptions/$sub/resourceGroups/rg-contoso-ai-platform-dev/providers/Microsoft.ApiManagement/service/apim-contoso-vdls2xyq"

# Correct APIM failover policy:
# - <retry> is the SINGLE top-level element in <backend> (required by APIM validation)
# - First attempt: context.Response is null, choose does nothing, forward-request calls primary
# - If primary 429/5xx: retry fires; choose switches backend to secondary; forward-request calls secondary
$policy = @'
<policies>
    <inbound>
        <base />
        <set-variable name="selectedBackend" value="primary" />
        <set-backend-service base-url="{{foundry-primary-endpoint}}/openai" />
    </inbound>
    <backend>
        <retry condition="@(context.Response != null &amp;&amp; (context.Response.StatusCode == 429 || context.Response.StatusCode >= 500))" count="1" interval="0" first-fast-retry="true">
            <choose>
                <when condition="@(context.Response != null &amp;&amp; (context.Response.StatusCode == 429 || context.Response.StatusCode >= 500) &amp;&amp; (string)context.Variables.GetValueOrDefault(&quot;selectedBackend&quot;, &quot;primary&quot;) == &quot;primary&quot;)">
                    <set-backend-service base-url="{{foundry-secondary-endpoint}}/openai" />
                    <set-variable name="selectedBackend" value="secondary-failover" />
                </when>
            </choose>
            <forward-request timeout="60" />
        </retry>
    </backend>
    <outbound>
        <base />
        <set-header name="X-Backend-Region-Used" exists-action="override">
            <value>@(context.Variables.GetValueOrDefault("selectedBackend", "primary"))</value>
        </set-header>
    </outbound>
    <on-error>
        <base />
        <set-header name="X-Backend-Region-Used" exists-action="override">
            <value>@(context.Variables.GetValueOrDefault("selectedBackend", "unknown"))</value>
        </set-header>
    </on-error>
</policies>
'@

$body = @{ properties = @{ format = "rawxml"; value = $policy } } | ConvertTo-Json -Depth 3
$r = Invoke-RestMethod -Uri "$base/apis/openai-inference/policies/policy?api-version=2024-05-01" `
  -Method PUT -Headers @{Authorization="Bearer $tok"; "Content-Type"="application/json"} `
  -Body $body
Write-Host "Policy updated: format=$($r.properties.format)"

# Verify round-trip
Write-Host "`n--- Verification (backend section) ---"
$v = Invoke-RestMethod -Uri "$base/apis/openai-inference/policies/policy?api-version=2024-05-01&format=rawxml" -Headers @{Authorization="Bearer $tok"}
[System.Net.WebUtility]::HtmlDecode($v.properties.value) | Select-String -Pattern '<backend>' -Context 0,8
