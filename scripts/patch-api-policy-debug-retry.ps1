$ErrorActionPreference = "Stop"

$t = az account get-access-token --query accessToken -o tsv
$base = "https://management.azure.com/subscriptions/d201ebeb-c470-4a6f-82d5-c2f95bb0dc1e/resourceGroups/rg-contoso-ai-platform-dev/providers/Microsoft.ApiManagement/service/apim-contoso-vdls2xyq"

# Debug policy: exposes iteration count, selectedBackend value, and response status in headers
# so we can see exactly what happens at each step of the retry
$policy = @'
<policies>
  <inbound>
    <base />
    <set-variable name="selectedBackend" value="primary" />
    <set-variable name="iteration" value="@(0)" />
    <set-backend-service base-url="{{foundry-primary-endpoint}}/openai" />
  </inbound>
  <backend>
    <retry condition="@(context.Response != null &amp;&amp; (context.Response.StatusCode == 429 || context.Response.StatusCode >= 500))" count="1" interval="1" first-fast-retry="true">
      <set-variable name="iteration" value="@((int)context.Variables[&quot;iteration&quot;] + 1)" />
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
  </outbound>
  <on-error>
    <base />
    <set-header name="X-Backend-Region-Used" exists-action="override">
      <value>@(context.Variables.GetValueOrDefault("selectedBackend", "unknown"))</value>
    </set-header>
    <set-header name="X-Retry-Iterations" exists-action="override">
      <value>@(context.Variables.ContainsKey("iteration") ? ((int)context.Variables["iteration"]).ToString() : "0")</value>
    </set-header>
  </on-error>
</policies>
'@

$body = @{ properties = @{ format = "rawxml"; value = $policy } } | ConvertTo-Json -Depth 5

Invoke-RestMethod -Method Put `
  -Uri "$base/apis/openai-inference/policies/policy?api-version=2023-05-01-preview" `
  -Headers @{ Authorization = "Bearer $t"; "Content-Type" = "application/json" } `
  -Body $body | Out-Null

Write-Host "Debug retry policy applied. Testing in 5 seconds..."
Start-Sleep 5

# Trust self-signed certs (App Gateway uses a cert that may not be in the dev machine's store)
Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllDebug : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllDebug
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Test
$silverKey = "5cfd513601124b8f8335eb14e251c2cd"
$requestBody = '{"messages":[{"role":"user","content":"Say one word only."}],"max_tokens":5}'
$h = @{ "Ocp-Apim-Subscription-Key" = $silverKey; "Content-Type" = "application/json" }
$uri = "https://agw-contoso-ai-primary.eastus.cloudapp.azure.com/openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-02-01"

try {
    $resp = Invoke-WebRequest -Method Post -Uri $uri -Headers $h -Body $requestBody -UseBasicParsing
    Write-Host "Status:       $($resp.StatusCode)"
    Write-Host "Backend:      $($resp.Headers['X-Backend-Region-Used'])"
    Write-Host "Iterations:   $($resp.Headers['X-Retry-Iterations'])"
} catch {
    $errResp = $_.Exception.Response
    if ($errResp) {
        Write-Host "HTTP Error: $([int]$errResp.StatusCode)"
        $reader = New-Object System.IO.StreamReader($errResp.GetResponseStream())
        Write-Host "Body: $($reader.ReadToEnd())"
    } else {
        Write-Host "Error: $($_.Exception.Message)"
    }
}
