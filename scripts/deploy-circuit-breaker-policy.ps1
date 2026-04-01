$tok = (az account get-access-token --query accessToken -o tsv)
$sub = "d201ebeb-c470-4a6f-82d5-c2f95bb0dc1e"
$base = "https://management.azure.com/subscriptions/$sub/resourceGroups/rg-contoso-ai-platform-dev/providers/Microsoft.ApiManagement/service/apim-contoso-vdls2xyq"

# Cache-based circuit breaker: avoids Content-Length mismatch from retry pattern.
#
# Pattern:
#   INBOUND:  Check "primary-circuit-open" cache key.
#             If set => route directly to secondary (circuit open).
#             Else   => route to primary (circuit closed, default path).
#
#   BACKEND:  Single <forward-request /> — NO retry, no Content-Length issues.
#             global <forward-request /> runs via <base />.
#             NOTE: API-level backend must NOT exist, so global runs directly.
#
#   OUTBOUND: If primary returned 429 => open circuit for 30s (set cache key).
#             If primary returned 200 => ensure circuit is closed (cache remove).
#             Always stamp X-Backend-Region-Used for observability.
#
# Failover visibility in App Insights:
#   The ~1-2 circuit-trip requests return 429 with backend=primary.
#   All subsequent ~30s of requests return 200 with backend=secondary-failover.
#   After 30s, traffic returns to primary automatically (TTL expires).

$policy = @'
<policies>
    <inbound>
        <base />
        <!-- Check if the primary circuit breaker is open (tripped by a recent 429). -->
        <cache-lookup-value key="primary-circuit-open" variable-name="primaryCircuitOpen" />
        <choose>
            <when condition="@(context.Variables.ContainsKey(&quot;primaryCircuitOpen&quot;))">
                <!-- Circuit open: route directly to secondary, skip primary entirely. -->
                <set-backend-service base-url="{{foundry-secondary-endpoint}}/openai" />
                <set-variable name="selectedBackend" value="secondary-failover" />
            </when>
            <otherwise>
                <!-- Circuit closed (normal path): route to primary. -->
                <set-backend-service base-url="{{foundry-primary-endpoint}}/openai" />
                <set-variable name="selectedBackend" value="primary" />
            </otherwise>
        </choose>
    </inbound>
    <backend>
        <!-- Single <base /> — delegates to global <forward-request />.
             No retry loop; no Content-Length mismatch risk. -->
        <base />
    </backend>
    <outbound>
        <base />
        <!-- Primary returned 429: open circuit for 30 seconds.
             Primary returned 200: ensure circuit is reset (remove stale key). -->
        <choose>
            <when condition="@(context.Response.StatusCode == 429 &amp;&amp; (string)context.Variables.GetValueOrDefault(&quot;selectedBackend&quot;, &quot;primary&quot;) == &quot;primary&quot;)">
                <cache-store-value key="primary-circuit-open" value="true" duration="30" />
            </when>
            <when condition="@(context.Response.StatusCode == 200 &amp;&amp; (string)context.Variables.GetValueOrDefault(&quot;selectedBackend&quot;, &quot;primary&quot;) == &quot;primary&quot;)">
                <cache-remove-value key="primary-circuit-open" />
            </when>
        </choose>
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

# Verify — show backend section
Write-Host "`n--- Verification (backend+outbound) ---"
$v = Invoke-RestMethod -Uri "$base/apis/openai-inference/policies/policy?api-version=2024-05-01&format=rawxml" -Headers @{Authorization="Bearer $tok"}
[System.Net.WebUtility]::HtmlDecode($v.properties.value)
