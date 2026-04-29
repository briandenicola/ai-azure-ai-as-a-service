Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAll : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAll
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

. "$PSScriptRoot/_resolve-env.ps1"
$silverKey = (az rest --method POST `
    --uri "$base/subscriptions/app-aml-screening/listSecrets?api-version=2022-08-01" `
    2>$null | ConvertFrom-Json).primaryKey
$url = "https://$APPGW_FQDN/openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-02-01"
$body = '{"messages":[{"role":"user","content":"Hi"}],"max_tokens":5}'
$headers = @{
    "Ocp-Apim-Subscription-Key" = $silverKey
    "Content-Type" = "application/json"
}

Write-Host "Sending test request at $(Get-Date -Format 'HH:mm:ss')..."
try {
    $resp = Invoke-WebRequest -Method Post -Uri $url -Headers $headers -Body $body -UseBasicParsing
    Write-Host "HTTP Status: $($resp.StatusCode)"
    Write-Host "X-Backend-Region-Used: $($resp.Headers['X-Backend-Region-Used'])"
    Write-Host "X-Correlation-Id: $($resp.Headers['X-Correlation-Id'])"
} catch {
    $resp = $_.Exception.Response
    if ($resp) {
        Write-Host "HTTP Status: $([int]$resp.StatusCode)"
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        Write-Host "Body: $($reader.ReadToEnd())"
    } else {
        Write-Host "Error: $($_.Exception.Message)"
    }
}
