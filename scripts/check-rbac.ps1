$sub = "d201ebeb-c470-4a6f-82d5-c2f95bb0dc1e"
$apimMsiId = (az apim show --name apim-contoso-vdls2xyq --resource-group rg-contoso-ai-platform-dev --query "identity.principalId" -o tsv 2>&1 | Where-Object { $_ -notmatch "WARNING" -and $_ -notmatch "UserWarning" -and $_ -notmatch "pkg_resources" })
Write-Host "APIM MSI principal: $apimMsiId"

Write-Host ""
Write-Host "=== Roles on contoso-foundry-secondary ==="
az role assignment list --scope "/subscriptions/$sub/resourceGroups/rg-contoso-ai-platform-dev/providers/Microsoft.CognitiveServices/accounts/contoso-foundry-secondary" --query "[].{role:roleDefinitionName,principal:principalName,principalId:principalId}" -o table 2>&1 | Where-Object { $_ -notmatch "WARNING|UserWarning|pkg_resources" }

Write-Host ""
Write-Host "=== Roles on contoso-foundry-primary ==="
az role assignment list --scope "/subscriptions/$sub/resourceGroups/rg-contoso-ai-platform-dev/providers/Microsoft.CognitiveServices/accounts/contoso-foundry-primary" --query "[].{role:roleDefinitionName,principal:principalName,principalId:principalId}" -o table 2>&1 | Where-Object { $_ -notmatch "WARNING|UserWarning|pkg_resources" }
