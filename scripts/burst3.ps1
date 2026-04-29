. "$PSScriptRoot/_resolve-env.ps1"

# Fetch Bronze subscription key dynamically
$BRONZE_KEY = (az rest --method POST `
    --uri "$base/subscriptions/bronze-test/listSecrets?api-version=2022-08-01" `
    2>$null | ConvertFrom-Json).primaryKey
if (-not $BRONZE_KEY) { Write-Error "Could not retrieve Bronze subscription key from APIM '$APIM_NAME'."; exit 1 }

# Use App Gateway FQDN if deployed, fall back to APIM direct endpoint
$endpoint = if ($APPGW_FQDN) {
    "https://$APPGW_FQDN/openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-02-01"
} else {
    "https://$APIM_NAME.azure-api.net/openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-02-01"
}
Write-Host "Endpoint: $endpoint" -ForegroundColor Cyan

Add-Type -TypeDefinition @"
using System.Net; using System.Security.Cryptography.X509Certificates;
public class TrustAll2 : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int err) { return true; }
}
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAll2

1..3 | ForEach-Object {
    $n = $_
    $r = Invoke-WebRequest -Uri $endpoint `
        -Method POST `
        -Headers @{"Ocp-Apim-Subscription-Key"=$BRONZE_KEY;"Content-Type"="application/json"} `
        -Body '{"messages":[{"role":"user","content":"Say hello"}],"max_tokens":10}' `
        -UseBasicParsing
    $answer = if ($r.Content.Length -gt 0) { ($r.Content | ConvertFrom-Json).choices[0].message.content } else { "(empty)" }
    Write-Host ($n.ToString() + ": status=" + $r.StatusCode + " body=" + $r.Content.Length + "b backend=" + $r.Headers['X-Backend-Region-Used'] + " answer=" + $answer)
}
