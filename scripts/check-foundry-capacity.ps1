. "$PSScriptRoot/_resolve-env.ps1"
$rg = $RG     # alias used in this script

# Find the primary AI Services account name
$accounts = az cognitiveservices account list --resource-group $rg --query "[].{name:name,location:location,kind:kind}" --output json | ConvertFrom-Json
$accounts | Format-Table

# Check primary deployment capacity
$primary = $accounts | Where-Object { $_.location -eq $PRIMARY_LOCATION -and $_.kind -eq "AIServices" } | Select-Object -First 1
if ($primary) {
    Write-Host "Primary account: $($primary.name)"
    $deployments = az cognitiveservices account deployment list --name $primary.name --resource-group $rg --query "[].{name:name,capacity:sku.capacity,model:properties.model.name,version:properties.model.version}" --output json | ConvertFrom-Json
    $deployments | Format-Table
}
