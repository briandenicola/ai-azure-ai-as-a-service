$ErrorActionPreference = "Stop"

$t = az account get-access-token --query accessToken -o tsv
$base = "https://management.azure.com/subscriptions/d201ebeb-c470-4a6f-82d5-c2f95bb0dc1e/resourceGroups/rg-contoso-ai-platform-dev/providers/Microsoft.ApiManagement/service/apim-contoso-vdls2xyq"
$hdr = @{Authorization = "Bearer $t"; "Content-Type" = "application/json"}
$wd = Split-Path $MyInvocation.MyCommand.Path

function Apply-Policy($url, $xmlFile, $label) {
    $xml = [System.IO.File]::ReadAllText("$wd\$xmlFile", [System.Text.Encoding]::UTF8)
    if ($xml[0] -eq [char]0xFEFF) { $xml = $xml.Substring(1) }  # strip BOM
    $body = @{ properties = @{ format = "rawxml"; value = $xml } } | ConvertTo-Json -Depth 5 -Compress
    Invoke-RestMethod -Method Put -Uri $url -Headers $hdr -Body $body | Out-Null
    Write-Host "Applied: $label"
}

# Only openai-inference needs the retry condition fix.
# Global stays as-is (<forward-request />), foundry-agents and model-inference unchanged.
Apply-Policy "$base/apis/openai-inference/policies/policy?api-version=2023-05-01-preview" "policy-openai-inference.xml" "openai-inference (retry failover - status-code condition)"

Write-Host ""
Write-Host "Policy applied. Waiting 12s for propagation..."
Start-Sleep 12

# Test
Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllFix2 {
    public static void Trust() {
        ServicePointManager.ServerCertificateValidationCallback = delegate { return true; };
    }
}
"@
[TrustAllFix2]::Trust()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$h = @{"Ocp-Apim-Subscription-Key" = "5cfd513601124b8f8335eb14e251c2cd"; "Content-Type" = "application/json"}
$reqBody = '{"messages":[{"role":"user","content":"Hi"}],"max_tokens":5}'
$resp = Invoke-WebRequest -Method Post "https://agw-contoso-ai-primary.eastus.cloudapp.azure.com/openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-02-01" -Headers $h -Body $reqBody -UseBasicParsing
Write-Host "Status:   $($resp.StatusCode)"
Write-Host "Backend:  $($resp.Headers['X-Backend-Region-Used'])"
if ($resp.Headers['X-Backend-Region-Used'] -eq 'primary') {
    Write-Host ""
    Write-Host "SUCCESS! Primary routing works correctly."
} else {
    Write-Host ""
    Write-Host "Still routing to secondary."
}
