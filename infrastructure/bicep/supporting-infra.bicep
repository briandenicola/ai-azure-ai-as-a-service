// Bicep: Supporting infrastructure — Log Analytics Workspace + Key Vault
//
// These are created first so that:
//   - APIM can send diagnostics to Log Analytics
//   - App Gateway can read the SSL certificate from Key Vault
//
// Key Vault name is derived from a stable uniqueString of the resource group ID,
// so it stays the same across repeated `azd provision` runs.

targetScope = 'resourceGroup'

param location string
param prefix string
param environment string
param tags object = {}

@description('Object ID (User or Group) to grant Key Vault Administrator — so you can add secrets/certs after provisioning. Leave blank to skip.')
param adminObjectId string = ''

// ---------------------------------------------------------------------------
// Log Analytics Workspace
// PCI DSS Req 10: Centralised audit log retention (minimum 12 months)
// ---------------------------------------------------------------------------

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: 'law-${prefix}-ai-${environment}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 90  // Increase to 395 for PCI DSS Req 10.5.1 production compliance
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

// ---------------------------------------------------------------------------
// Key Vault
// PCI DSS Req 3.7 / 8.6: Protect encryption keys; no static credentials
//
// Name: kv-{prefix}-{6-char stable hash} — globally unique, idempotent.
// Standard SKU is sufficient for dev; upgrade to Premium for HSM in production.
// ---------------------------------------------------------------------------

var kvName = 'kv-${prefix}-${take(uniqueString(resourceGroup().id), 6)}'

resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: kvName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenant().tenantId
    enableRbacAuthorization: true     // Use RBAC rather than access policies
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true       // Required for PCI DSS Req 3.7
    publicNetworkAccess: 'Enabled'    // Needed so ARM can manage secrets at provision time
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

@description('Set to true to assign Key Vault Administrator to adminObjectId. Requires resource-group-scoped role assignment permission.')
param deployRbac bool = false

// Key Vault Administrator — lets the deploying user upload the SSL cert and secrets
// after the deployment completes. Skipped if adminObjectId is not provided.
var kvAdminRoleId = '00482a5a-887f-4fb3-b363-3b7fe8e74483'

resource kvAdminRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRbac && !empty(adminObjectId)) {
  scope: keyVault
  name: guid(keyVault.id, adminObjectId, kvAdminRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvAdminRoleId)
    principalId: adminObjectId
    principalType: 'User'
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output logAnalyticsWorkspaceId string = logAnalytics.id
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri

// NOTE: The SSL certificate for App Gateway is NOT auto-generated here.
// ARM's Microsoft.KeyVault/vaults/certificates resource requires the deploying
// principal to already have Key Vault data-plane RBAC, which in turn requires
// roleAssignments/write — a circular permission dependency on restricted accounts.
//
// To add App Gateway WAF (recommended for PCI DSS):
//   1. Run: scripts/create-appgw-cert.ps1 -KeyVaultName <name> -CertName appgw-ssl-cert
//      (or: az keyvault certificate create --vault-name <kv> --name appgw-ssl-cert --policy @cert-policy.json)
//   2. Copy the secret URI output (e.g. https://kv-contoso-hvrukk.vault.azure.net/secrets/appgw-ssl-cert)
//   3. Run: azd env set AZURE_SSL_CERT_KV_SECRET_ID <secret-uri>
//   4. Run: azd provision
