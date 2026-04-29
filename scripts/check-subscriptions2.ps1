. "$PSScriptRoot/_resolve-env.ps1"

Write-Host "=== All subscriptions ==="
$subs = Invoke-RestMethod -Method Get -Uri "$base/subscriptions?api-version=2023-05-01-preview" -Headers @{Authorization="Bearer $t"}
$subs.value | ForEach-Object {
    Write-Host "Name: $($_.properties.displayName) | State: $($_.properties.state) | Scope: $($_.properties.scope)"
}
