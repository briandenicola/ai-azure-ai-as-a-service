Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAll2 : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAll2
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

Write-Host "Sending 10 rapid calls at $(Get-Date -Format 'HH:mm:ss')..."
for ($i = 1; $i -le 10; $i++) {
    try {
        $resp = Invoke-WebRequest -Method Post -Uri $url -Headers $headers -Body $body -UseBasicParsing
        $backend = $resp.Headers['X-Backend-Region-Used']
        Write-Host "  Call $i HTTP $($resp.StatusCode) $backend"
    } catch {
        $r = $_.Exception.Response
        if ($r) { Write-Host "  Call $i HTTP $([int]$r.StatusCode)" }
        else { Write-Host "  Call $i Error $($_.Exception.Message)" }
    }
}
Write-Host "Done at $(Get-Date -Format 'HH:mm:ss')"
