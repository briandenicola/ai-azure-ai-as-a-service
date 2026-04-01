$headers = @{
    "Ocp-Apim-Subscription-Key" = "430804acc2304546974817cb85b355ad"
    "Content-Type" = "application/json"
}
$body = '{"messages":[{"role":"user","content":"Reply with exactly one word: Hello"}],"max_tokens":5}'
$r = Invoke-WebRequest -Uri "https://agw-contoso-ai-primary.eastus.cloudapp.azure.com/openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-02-01" -Method POST -Headers $headers -Body $body -UseBasicParsing
Write-Host "Status: $($r.StatusCode)"
Write-Host "Backend: $($r.Headers['X-Backend-Region-Used'])"
Write-Host "Remaining: $($r.Headers['X-Token-Remaining'])"
Write-Host "Content-Length: $($r.Headers['Content-Length'])"
Write-Host "Body length: $($r.Content.Length)"
if ($r.Content.Length -gt 0) {
    $json = $r.Content | ConvertFrom-Json
    Write-Host "Finish reason: $($json.choices[0].finish_reason)"
    Write-Host "Answer: $($json.choices[0].message.content)"
    Write-Host "Tokens used: prompt=$($json.usage.prompt_tokens) completion=$($json.usage.completion_tokens)"
} else {
    Write-Host "WARNING: Empty response body!"
}
