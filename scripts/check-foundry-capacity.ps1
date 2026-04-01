$t = az account get-access-token --query accessToken -o tsv
$sub = "d201ebeb-c470-4a6f-82d5-c2f95bb0dc1e"
$rg = "rg-contoso-ai-platform-dev"

# Find the primary AI Services account name
$accounts = az cognitiveservices account list --resource-group $rg --query "[].{name:name,location:location,kind:kind}" --output json | ConvertFrom-Json
$accounts | Format-Table

# Check primary deployment capacity
$primary = $accounts | Where-Object { $_.location -eq "eastus" -and $_.kind -eq "AIServices" } | Select-Object -First 1
if ($primary) {
    Write-Host "Primary account: $($primary.name)"
    $deployments = az cognitiveservices account deployment list --name $primary.name --resource-group $rg --query "[].{name:name,capacity:sku.capacity,model:properties.model.name,version:properties.model.version}" --output json | ConvertFrom-Json
    $deployments | Format-Table
}
