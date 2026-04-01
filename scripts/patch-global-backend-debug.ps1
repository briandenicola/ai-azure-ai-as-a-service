$ErrorActionPreference = "Stop"

$t = az account get-access-token --query accessToken -o tsv
$base = "https://management.azure.com/subscriptions/d201ebeb-c470-4a6f-82d5-c2f95bb0dc1e/resourceGroups/rg-contoso-ai-platform-dev/providers/Microsoft.ApiManagement/service/apim-contoso-vdls2xyq"

# Debug global policy — adds X-Global-Backend-Ran header to track if/when global backend fires
$debugGlobalPolicy = '<policies><inbound><set-variable name="correlationId" value="@(context.Request.Headers.ContainsKey(&quot;X-Correlation-Id&quot;) ? context.Request.Headers[&quot;X-Correlation-Id&quot;][0] : context.RequestId.ToString())" /><set-header name="X-Correlation-Id" exists-action="override"><value>@((string)context.Variables[&quot;correlationId&quot;])</value></set-header><set-header name="api-key" exists-action="delete" /><authentication-managed-identity resource="https://cognitiveservices.azure.com" output-token-variable-name="msi-access-token" ignore-error="false" /><set-header name="Authorization" exists-action="override"><value>@("Bearer " + (string)context.Variables[&quot;msi-access-token&quot;])</value></set-header></inbound><backend><set-variable name="globalBackendRan" value="true" /><forward-request /></backend><outbound><set-header name="X-Correlation-Id" exists-action="override"><value>@((string)context.Variables[&quot;correlationId&quot;])</value></set-header><set-header name="X-Global-Backend-Ran" exists-action="override"><value>@(context.Variables.ContainsKey(&quot;globalBackendRan&quot;) ? &quot;YES&quot; : &quot;NO&quot;)</value></set-header></outbound><on-error /></policies>'

$body = @{ properties = @{ format = "rawxml"; value = $debugGlobalPolicy } } | ConvertTo-Json -Depth 5
Invoke-RestMethod -Method Put -Uri "$base/policies/policy?api-version=2023-05-01-preview" -Headers @{Authorization="Bearer $t"; "Content-Type"="application/json"} -Body $body | Out-Null
Write-Host "Debug global policy applied. Waiting 8 seconds..."
Start-Sleep 8

Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllGB {
    public static void Trust() {
        ServicePointManager.ServerCertificateValidationCallback = delegate { return true; };
    }
}
"@
[TrustAllGB]::Trust()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$h = @{"Ocp-Apim-Subscription-Key"="5cfd513601124b8f8335eb14e251c2cd";"Content-Type"="application/json"}
$body2 = '{"messages":[{"role":"user","content":"Hi"}],"max_tokens":5}'
$resp = Invoke-WebRequest -Method Post "https://agw-contoso-ai-primary.eastus.cloudapp.azure.com/openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-02-01" -Headers $h -Body $body2 -UseBasicParsing
Write-Host "Status:           $($resp.StatusCode)"
Write-Host "Backend:          $($resp.Headers['X-Backend-Region-Used'])"
Write-Host "GlobalBackendRan: $($resp.Headers['X-Global-Backend-Ran'])"
Write-Host "Iterations:       $($resp.Headers['X-Retry-Iterations'])"
