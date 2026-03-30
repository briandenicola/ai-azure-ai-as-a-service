// Bicep: Deploy 2 Azure AI Foundry Accounts (non-hub architecture)
//
// NOTE: The ML Workspace Hub resource type is deprecated.
//       The current Foundry resource is Microsoft.CognitiveServices/accounts
//       with kind: 'AIServices' (S0 SKU — only supported tier).
//
// This template creates:
//   - 2 Foundry accounts (East US primary, West US secondary)
//     aligned with the circuit-breaker-multi-region.xml APIM policy
//   - Model deployments on each account:
//       • gpt-4o-mini  (OpenAI format, primary=1K TPM, secondary=30K TPM — pay-as-you-go, lowest-cost chat model)
//       • Phi-4        (Microsoft format, 1K TPM — open-weight, very low cost)
//   - Azure AI Search (shared, for RAG across both accounts)
//   - Cognitive Services User RBAC for each developer

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Prefix for resource names (e.g. "contoso")')
param accountPrefix string = 'foundry'

@description('Primary region — must match APIM circuit breaker primaryBackend')
param primaryLocation string = 'eastus'

@description('Secondary region — must match APIM circuit breaker secondaryBackend')
param secondaryLocation string = 'westus'

@description('Object IDs of developers who should get Cognitive Services User access')
param developerObjectIds array = []

@description('Set to true to create role assignments (requires Owner or User Access Administrator)')
param deployRbac bool = false

@description('Resource ID of the VNet to link the private DNS zone to. Required when privateEndpointSubnetId is set.')
param vnetResourceId string = ''

@description('Resource ID of the private endpoint subnet (snet-private-endpoints). Leave empty to skip private endpoint creation.')
param privateEndpointSubnetId string = ''

// ---------------------------------------------------------------------------
// Foundry Account 1 — Primary (East US)
// ---------------------------------------------------------------------------

resource foundry1 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: '${accountPrefix}-primary'
  location: primaryLocation
  kind: 'AIServices'
  sku: {
    name: 'S0'  // Only supported tier for AIServices
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publicNetworkAccess: 'Disabled'  // Traffic via APIM / private endpoints only
    disableLocalAuth: true           // Entra ID / managed identity auth only
    customSubDomainName: '${accountPrefix}-primary'
  }
}

// gpt-4o-mini on primary — cheapest OpenAI chat model
// capacity=2 (2K TPM, 20 RPM) intentionally low: saturates under the failover
// blast test (20 threads × 5 s think ≈ 208 req/min >> 20 RPM) so APIM retries
// to secondary.  Increase to 10+ for non-demo workloads.
resource gpt4oMini1 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: foundry1
  name: 'gpt-4o-mini'
  sku: {
    name: 'Standard'
    capacity: 2  // 2K TPM, 20 RPM — intentionally low for failover demo
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4o-mini'
      version: '2024-07-18'
    }
    versionUpgradeOption: 'OnceCurrentVersionExpired'
  }
}

// Phi-4 on primary — Microsoft open-weight model, very low cost
resource phi4_1 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: foundry1
  name: 'phi-4'
  dependsOn: [gpt4oMini1]  // Deployments must be created sequentially per account
  sku: {
    name: 'GlobalStandard'  // Phi-4 v2 requires GlobalStandard; Standard is not supported
    capacity: 1  // 1K TPM — Phi-4 is highly efficient; increase if needed
  }
  properties: {
    model: {
      format: 'Microsoft'
      name: 'Phi-4'
      version: '2'
    }
    versionUpgradeOption: 'OnceCurrentVersionExpired'
  }
}

// ---------------------------------------------------------------------------
// Foundry Account 2 — Secondary (West US)
// ---------------------------------------------------------------------------

resource foundry2 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: '${accountPrefix}-secondary'
  location: secondaryLocation
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publicNetworkAccess: 'Disabled'
    disableLocalAuth: true
    customSubDomainName: '${accountPrefix}-secondary'
  }
}

// Same model set on secondary for failover consistency
// capacity=30 (30K TPM, 300 RPM) — must absorb 100% of primary overflow
// during failover test: primary is capped at 10 RPM so secondary receives
// up to ~210 req/min; 300 RPM gives comfortable headroom.
resource gpt4oMini2 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: foundry2
  name: 'gpt-4o-mini'
  sku: {
    name: 'Standard'
    capacity: 30  // 30K TPM, 300 RPM — handles full failover overflow from primary
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4o-mini'
      version: '2024-07-18'
    }
    versionUpgradeOption: 'OnceCurrentVersionExpired'
  }
}

resource phi4_2 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: foundry2
  name: 'phi-4'
  dependsOn: [gpt4oMini2]
  sku: {
    name: 'GlobalStandard'  // Phi-4 v2 requires GlobalStandard; Standard is not supported
    capacity: 1
  }
  properties: {
    model: {
      format: 'Microsoft'
      name: 'Phi-4'
      version: '2'
    }
    versionUpgradeOption: 'OnceCurrentVersionExpired'
  }
}

// ---------------------------------------------------------------------------
// Private Endpoints + Private DNS
//
// Both Foundry accounts have publicNetworkAccess: 'Disabled'.
// Private endpoints give APIM (VNet-internal) a private IP for each account.
//
// DNS resolution chain:
//   contoso-foundry-primary.cognitiveservices.azure.com
//     → CNAME → contoso-foundry-primary.privatelink.cognitiveservices.azure.com
//     → A     → 10.100.5.x (private endpoint NIC in snet-private-endpoints)
//
// Cross-region PE: pe-secondary PE NIC is in EastUS VNet but routes to WestUS
// Foundry account via Azure backbone — fully supported for Cognitive Services.
// ---------------------------------------------------------------------------

var deployPrivateEndpoints = !empty(privateEndpointSubnetId)

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (deployPrivateEndpoints) {
  name: 'privatelink.cognitiveservices.azure.com'
  location: 'global'
  properties: {}
}

resource privateDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (deployPrivateEndpoints) {
  parent: privateDnsZone
  name: 'link-foundry-dns-to-vnet'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnetResourceId
    }
    registrationEnabled: false
  }
}

// Private endpoint for primary Foundry (EastUS)
resource pe1 'Microsoft.Network/privateEndpoints@2023-05-01' = if (deployPrivateEndpoints) {
  name: 'pe-${accountPrefix}-primary'
  location: primaryLocation
  // Must wait for ALL model deployments to complete before creating the PE.
  // Model deployments put the account in 'Accepted' state; PE creation fails if
  // the account is not in 'Succeeded' state.
  dependsOn: [gpt4oMini1, phi4_1]
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'plsc-${accountPrefix}-primary'
        properties: {
          privateLinkServiceId: foundry1.id
          groupIds: ['account']
        }
      }
    ]
  }
}

resource pe1DnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = if (deployPrivateEndpoints) {
  parent: pe1
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-cognitiveservices'
        properties: {
          privateDnsZoneId: deployPrivateEndpoints ? privateDnsZone.id : ''
        }
      }
    ]
  }
}

// Private endpoint for secondary Foundry (WestUS resource, PE NIC in primary VNet / EastUS)
// Cross-region private endpoints are supported for Cognitive Services.
resource pe2 'Microsoft.Network/privateEndpoints@2023-05-01' = if (deployPrivateEndpoints) {
  name: 'pe-${accountPrefix}-secondary'
  location: primaryLocation  // PE location = VNet region, not the target resource region
  dependsOn: [gpt4oMini2, phi4_2]
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'plsc-${accountPrefix}-secondary'
        properties: {
          privateLinkServiceId: foundry2.id
          groupIds: ['account']
        }
      }
    ]
  }
}

resource pe2DnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = if (deployPrivateEndpoints) {
  parent: pe2
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-cognitiveservices'
        properties: {
          privateDnsZoneId: deployPrivateEndpoints ? privateDnsZone.id : ''
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// RBAC: Cognitive Services User on both Foundry accounts for each developer
// ---------------------------------------------------------------------------

var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

resource devRoleFoundry1 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for objectId in (deployRbac ? developerObjectIds : []): {
  scope: foundry1
  name: guid(foundry1.id, objectId, cognitiveServicesUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: objectId
    principalType: 'User'
  }
}]

resource devRoleFoundry2 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for objectId in (deployRbac ? developerObjectIds : []): {
  scope: foundry2
  name: guid(foundry2.id, objectId, cognitiveServicesUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: objectId
    principalType: 'User'
  }
}]

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output foundry1Endpoint string = foundry1.properties.endpoint
output foundry1ResourceId string = foundry1.id
output foundry1PrincipalId string = foundry1.identity.principalId

output foundry2Endpoint string = foundry2.properties.endpoint
output foundry2ResourceId string = foundry2.id
output foundry2PrincipalId string = foundry2.identity.principalId
