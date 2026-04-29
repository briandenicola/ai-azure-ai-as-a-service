. "$PSScriptRoot/_resolve-env.ps1"

Write-Host "=== All subscriptions and their products ==="
$subs = Invoke-RestMethod -Method Get -Uri "$base/subscriptions?api-version=2023-05-01-preview" -Headers @{Authorization="Bearer $t"}
$subs.value | Where-Object { $_.properties.scope -notmatch "^/subscriptions" } | ForEach-Object {
    $scope = $_.properties.scope -replace ".*/products/", "" -replace "/.*", ""
    Write-Host "Sub: $($_.properties.displayName) | Key1: $($_.properties.primaryKey.Substring(0,8))... | Product: $scope"
}
