Add-Type -TypeDefinition @"
using System.Net; using System.Security.Cryptography.X509Certificates;
public class TrustAll2 : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int err) { return true; }
}
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAll2

1..3 | ForEach-Object {
    $n = $_
    $r = Invoke-WebRequest -Uri "https://agw-contoso-ai-primary.eastus.cloudapp.azure.com/openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-02-01" `
        -Method POST `
        -Headers @{"Ocp-Apim-Subscription-Key"="430804acc2304546974817cb85b355ad";"Content-Type"="application/json"} `
        -Body '{"messages":[{"role":"user","content":"Say hello"}],"max_tokens":10}' `
        -UseBasicParsing
    $answer = if ($r.Content.Length -gt 0) { ($r.Content | ConvertFrom-Json).choices[0].message.content } else { "(empty)" }
    Write-Host ($n.ToString() + ": status=" + $r.StatusCode + " body=" + $r.Content.Length + "b backend=" + $r.Headers['X-Backend-Region-Used'] + " answer=" + $answer)
}
