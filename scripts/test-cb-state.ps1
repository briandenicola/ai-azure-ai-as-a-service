Add-Type -TypeDefinition "using System.Net;using System.Security.Cryptography.X509Certificates;public class TA6:ICertificatePolicy{public bool CheckValidationResult(ServicePoint s,X509Certificate c,WebRequest r,int p){return true;}}" -ErrorAction SilentlyContinue
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TA6
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$silverKey = "5cfd513601124b8f8335eb14e251c2cd"
$url = "https://agw-contoso-ai-primary.eastus.cloudapp.azure.com/openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-02-01"
$b = '{"messages":[{"role":"user","content":"Hi"}],"max_tokens":5}'
$h = @{"Ocp-Apim-Subscription-Key"=$silverKey;"Content-Type"="application/json"}
$resp = Invoke-WebRequest -Method Post -Uri $url -Headers $h -Body $b -UseBasicParsing
Write-Host "Backend=$($resp.Headers['X-Backend-Region-Used']) CB=$($resp.Headers['X-CB-State'])"
