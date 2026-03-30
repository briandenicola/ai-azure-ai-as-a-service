// load-testing.bicep — Azure Load Testing resource
//
// Creates the Azure Load Testing workspace. The actual test definition
// (JMX upload, VNet injection config, environment variables) is configured
// by scripts/configure-load-test.ps1 via azd postprovision hook, because
// ARM has no resource type for ALT test configurations — they live on the
// ALT data plane.
//
// Deployed conditionally: azd env set AZURE_DEPLOY_LOAD_TEST true

targetScope = 'resourceGroup'

param location string
param prefix string
param environment string
param tags object = {}

@description('Resource ID of the VNet that contains snet-loadtest; required for Network Contributor RBAC')
param vnetId string

@description('Set to true to create role assignments (requires Owner or User Access Administrator)')
param deployRbac bool = true

resource loadTest 'Microsoft.LoadTestService/loadTests@2022-12-01' = {
  name: 'lt-${prefix}-ai-${environment}'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    description: 'Load test workspace for AI-as-a-Service APIM gateway (${environment})'
  }
}

// Network Contributor on the VNet — required for ALT to inject test engines into snet-loadtest.
// Without this the ALT service can't create NICs in the subnet and falls back to running
// agents from the public internet, which can't reach Internal-mode APIM (no public DNS record).
// Role: Network Contributor (4d97b98b-1d4f-4787-a291-c67834d212e7)
var networkContributorRoleId = '4d97b98b-1d4f-4787-a291-c67834d212e7'

resource vnet 'Microsoft.Network/virtualNetworks@2023-04-01' existing = {
  name: last(split(vnetId, '/'))
}

resource altNetworkContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRbac) {
  // Use resource names (not .id) so the GUID seed is case-stable across ARM responses.
  name: guid(loadTest.name, vnet.name, networkContributorRoleId)
  scope: vnet
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', networkContributorRoleId)
    principalId: loadTest.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Allow ALT to inject test engines into snet-loadtest for private load testing'
  }
}

output loadTestName string = loadTest.name
output loadTestResourceId string = loadTest.id
output loadTestPrincipalId string = loadTest.identity.principalId
