// Grant 'Key Vault Certificate User' to an App Gateway UAMI on a Key Vault.
//
// Called from main.bicep (subscription scope) with:
//   scope: resourceGroup(resolvedKvRg)
//
// This must be a separate module because waf-appgw.bicep is resourceGroup-scoped
// and cannot create RBAC on a Key Vault in a *different* resource group (BCP139).
// main.bicep is subscription-scoped and can target any resource group.

targetScope = 'resourceGroup'

@description('Name of the Key Vault that holds the SSL certificate')
param keyVaultName string

@description('Principal ID of the App Gateway user-assigned managed identity')
param principalId string

@description('Set to true to create role assignments (requires Owner or User Access Administrator)')
param deployRbac bool = false

// Key Vault Certificate User — read-only access to certificates/secrets
var kvCertUserRoleId = 'db79e9a7-68ee-4b58-9aeb-b90e7c24fcba'

resource kv 'Microsoft.KeyVault/vaults@2023-02-01' existing = {
  name: keyVaultName
}

resource kvCertRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRbac) {
  scope: kv
  name: guid(kv.id, principalId, kvCertUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvCertUserRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
