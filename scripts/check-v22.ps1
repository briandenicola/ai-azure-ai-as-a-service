$tok = (az account get-access-token --query accessToken -o tsv)
$appId = "aa5915a0-951d-4f0c-9857-876ae1a2ef8e"
$q = @'
requests
| where timestamp > ago(20m)
| where isnotempty(customDimensions["Ocp-Apim-Subscription-Name"])
| extend backend=tostring(customDimensions["X-Backend-Region-Used"]),
         sub=tostring(customDimensions["Ocp-Apim-Subscription-Name"])
| summarize n=count(), avg_ms=round(avg(duration)) by backend, sub, resultCode
| order by backend asc, sub asc
'@
$body = @{ query = $q } | ConvertTo-Json
$r = Invoke-RestMethod -Uri "https://api.applicationinsights.io/v1/apps/$appId/query" `
    -Method POST `
    -Headers @{Authorization="Bearer $tok"; "Content-Type"="application/json"} `
    -Body $body
$r.tables[0].rows | ForEach-Object {
    "backend=$($_[0])  sub=$($_[1])  rc=$($_[2])  n=$($_[3])  avg_ms=$($_[4])"
}
