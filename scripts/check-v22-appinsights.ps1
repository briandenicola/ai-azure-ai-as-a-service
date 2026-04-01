$tok = (az account get-access-token --resource "https://api.applicationinsights.io" --query accessToken -o tsv)
$appId = "aa5915a0-951d-4f0c-9857-876ae1a2ef8e"
# v22 ran 14:48-14:53 UTC
$q = @'
requests
| where timestamp between (datetime(2026-04-01T14:47:00Z) .. datetime(2026-04-01T14:55:00Z))
| where isnotempty(customDimensions["Ocp-Apim-Subscription-Name"])
| extend backend=tostring(customDimensions["X-Backend-Region-Used"]),
         sub=tostring(customDimensions["Ocp-Apim-Subscription-Name"])
| summarize n=count(), avg_ms=round(avg(duration)), p99_ms=round(percentile(duration,99)) by backend, sub, resultCode
| order by backend asc, sub asc
'@
$body = @{ query = $q } | ConvertTo-Json
$r = Invoke-RestMethod -Uri "https://api.applicationinsights.io/v1/apps/$appId/query" `
    -Method POST `
    -Headers @{Authorization="Bearer $tok"; "Content-Type"="application/json"} `
    -Body $body
Write-Host "=== v22 App Insights (14:47-14:55 UTC) ==="
$r.tables[0].rows | ForEach-Object {
    "backend=$($_[0])  sub=$($_[1])  rc=$($_[2])  n=$($_[3])  avg=$($_[4])ms  p99=$($_[5])ms"
}
