// Grant APIM managed identity 'Cognitive Services User' on both Foundry accounts.
// Deployed as a separate module after foundryAccounts and apimGateway to avoid
// circular dependency (foundryAccounts feeds endpoints to apimGateway; APIM
// outputs its principalId which this module then uses for RBAC).

targetScope = 'resourceGroup'

@description('Resource ID of the primary Foundry AIServices account')
param foundry1ResourceId string

@description('Resource ID of the secondary Foundry AIServices account')
param foundry2ResourceId string

@description('System-assigned principal ID of the APIM managed identity')
param apimPrincipalId string

@description('Set to true to create role assignments (requires Owner or User Access Administrator)')
param deployRbac bool = false

// Cognitive Services User — read/infer access; no management plane permissions
var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

resource foundry1 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: last(split(foundry1ResourceId, '/'))
}

resource foundry2 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: last(split(foundry2ResourceId, '/'))
}

resource apimRoleFoundry1 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRbac) {
  scope: foundry1
  name: guid(foundry1ResourceId, apimPrincipalId, cognitiveServicesUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource apimRoleFoundry2 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRbac) {
  scope: foundry2
  name: guid(foundry2ResourceId, apimPrincipalId, cognitiveServicesUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
  }
}
