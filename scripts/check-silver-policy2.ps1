. "$PSScriptRoot/_resolve-env.ps1"

Write-Host "=== Silver product policies ==="
try {
    $r = Invoke-RestMethod -Method Get -Uri "$base/products/ai-silver/policies?api-version=2023-05-01-preview" -Headers @{Authorization="Bearer $t"}
    $r | ConvertTo-Json -Depth 5
} catch {
    Write-Host "Error: $($_.Exception.Message)"
    Write-Host "StatusCode: $($_.Exception.Response.StatusCode)"
}
