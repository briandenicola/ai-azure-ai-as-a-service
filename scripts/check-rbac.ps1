. "$PSScriptRoot/_resolve-env.ps1"
$apimMsiId = (az apim show --name $APIM_NAME --resource-group $RG --query "identity.principalId" -o tsv 2>&1 | Where-Object { $_ -notmatch "WARNING" -and $_ -notmatch "UserWarning" -and $_ -notmatch "pkg_resources" })
Write-Host "APIM MSI principal: $apimMsiId"

Write-Host ""
Write-Host "=== Roles on $FOUNDRY_SECONDARY ==="
az role assignment list --scope "/subscriptions/$SUB_ID/resourceGroups/$RG/providers/Microsoft.CognitiveServices/accounts/$FOUNDRY_SECONDARY" --query "[].{role:roleDefinitionName,principal:principalName,principalId:principalId}" -o table 2>&1 | Where-Object { $_ -notmatch "WARNING|UserWarning|pkg_resources" }

Write-Host ""
Write-Host "=== Roles on $FOUNDRY_PRIMARY ==="
az role assignment list --scope "/subscriptions/$SUB_ID/resourceGroups/$RG/providers/Microsoft.CognitiveServices/accounts/$FOUNDRY_PRIMARY" --query "[].{role:roleDefinitionName,principal:principalName,principalId:principalId}" -o table 2>&1 | Where-Object { $_ -notmatch "WARNING|UserWarning|pkg_resources" }
