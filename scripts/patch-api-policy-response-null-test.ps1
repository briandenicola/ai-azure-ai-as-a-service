$ErrorActionPreference = "Stop"

$t = az account get-access-token --query accessToken -o tsv
$base = "https://management.azure.com/subscriptions/d201ebeb-c470-4a6f-82d5-c2f95bb0dc1e/resourceGroups/rg-contoso-ai-platform-dev/providers/Microsoft.ApiManagement/service/apim-contoso-vdls2xyq"

# Debug policy: capture whether context.Response is null at start of retry body
# and expose via response header
$policy = @'
<policies>
  <inbound>
    <base />
    <set-variable name="selectedBackend" value="primary" />
    <set-variable name="iteration" value="@(0)" />
    <set-variable name="responseNullOnEntry" value="true" />
    <set-backend-service base-url="{{foundry-primary-endpoint}}/openai" />
  </inbound>
  <backend>
    <retry condition="@(context.Response != null &amp;&amp; (context.Response.StatusCode == 429 || context.Response.StatusCode >= 500))" count="1" interval="1" first-fast-retry="true">
      <set-variable name="iteration" value="@((int)context.Variables[&quot;iteration&quot;] + 1)" />
      <set-variable name="responseNullOnEntry" value="@(context.Response == null)" />
      <choose>
        <when condition="@(context.Response != null &amp;&amp; (string)context.Variables[&quot;selectedBackend&quot;] == &quot;primary&quot;)">
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
    <set-header name="X-Retry-Iterations" exists-action="override">
      <value>@(context.Variables.ContainsKey("iteration") ? ((int)context.Variables["iteration"]).ToString() : "0")</value>
    </set-header>
    <set-header name="X-ResponseNullOnEntry" exists-action="override">
      <value>@(context.Variables.ContainsKey("responseNullOnEntry") ? ((bool)context.Variables["responseNullOnEntry"]).ToString() : "unset")</value>
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

$body = @{ properties = @{ format = "rawxml"; value = $policy } } | ConvertTo-Json -Depth 5
$result = Invoke-RestMethod -Method Put -Uri "$base/apis/openai-inference/policies/policy?api-version=2023-05-01-preview" -Headers @{Authorization="Bearer $t"; "Content-Type"="application/json"} -Body $body
Write-Host "Debug API policy applied. Waiting 8 seconds..."
Start-Sleep 8

Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllRN {
    public static void Trust() {
        ServicePointManager.ServerCertificateValidationCallback = delegate { return true; };
    }
}
"@
[TrustAllRN]::Trust()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$h = @{"Ocp-Apim-Subscription-Key"="5cfd513601124b8f8335eb14e251c2cd";"Content-Type"="application/json"}
$reqBody = '{"messages":[{"role":"user","content":"Hi"}],"max_tokens":5}'
$resp = Invoke-WebRequest -Method Post "https://agw-contoso-ai-primary.eastus.cloudapp.azure.com/openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-02-01" -Headers $h -Body $reqBody -UseBasicParsing
Write-Host "Status:                $($resp.StatusCode)"
Write-Host "Backend:               $($resp.Headers['X-Backend-Region-Used'])"
Write-Host "Iterations:            $($resp.Headers['X-Retry-Iterations'])"
Write-Host "ResponseNullOnEntry:   $($resp.Headers['X-ResponseNullOnEntry'])"
Write-Host ""
Write-Host "--- INTERPRETATION ---"
if ($resp.Headers['X-ResponseNullOnEntry'] -eq 'True') {
    Write-Host "context.Response WAS null at retry body entry → choose correctly skipped on iter 1"
    Write-Host "If Backend=secondary-failover, the retry ran TWICE (2nd iter context.Response was set)"
} else {
    Write-Host "context.Response was NOT null at retry body entry → global backend ran BEFORE API backend!"
    Write-Host "ROOT CAUSE CONFIRMED: Execution order is global-first, not innermost-first."
}
