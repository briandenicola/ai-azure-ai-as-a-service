// Bicep: Deploy Azure AI Foundry Hub Project
//
// This template creates:
// - AI Foundry project
// - Azure AI Search index (for RAG)
// - Connections to Azure OpenAI, Foundry models
// - Role assignments for developers

@description('Project name')
param projectName string = 'ai-hub-project'

@description('Hub resource group name')
param hubResourceGroup string

@description('Hub subscription ID')
param hubSubscriptionId string

@description('Location')
param location string = resourceGroup().location

@description('List of developer object IDs who need access')
param developerObjectIds array = []

@description('AI Search resource name')
param aiSearchName string = 'your-ai-search'

@description('AI Search SKU')
param aiSearchSku string = 'standard'

// ==========================================
// Resource: AI Search (for knowledge bases / RAG)
// ==========================================
resource aiSearch 'Microsoft.Search/searchServices@2021-04-01-preview' = {
  name: aiSearchName
  location: location
  sku: {
    name: aiSearchSku
  }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    publicNetworkAccess: 'disabled'  // Force traffic through private endpoints only
  }
}

// ==========================================
// Resource: AI Foundry Project
// ==========================================
resource foundryProject 'Microsoft.MachineLearningServices/workspaces@2023-04-01' = {
  name: projectName
  location: location
  kind: 'Project'
  properties: {
    friendlyName: 'AI Hub Project'
    description: 'Centralized project for all AI models and agents'
    keyVaultId: resourceId('Microsoft.KeyVault/vaults', 'your-keyvault')
    storageAccount: resourceId('Microsoft.Storage/storageAccounts', 'your-storage')
    publicNetworkAccess: 'Disabled'  // Force all access through APIM/private endpoints
  }
  identity: {
    type: 'SystemAssigned'
  }
}

// ==========================================
// Resource: Grant developers access
// ==========================================

// Cognitive Services User role for Foundry Project
resource cognitiveServicesUserRole 'Microsoft.Authorization/roleAssignments@2021-04-01-preview' = [for objectId in developerObjectIds: {
  scope: foundryProject
  name: guid(foundryProject.id, objectId, 'cognitiveServicesUserRole')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a97b65f3-24da-4784-ab6f-2a44b4d6d3be') // Cognitive Services User
    principalId: objectId
  }
}]

// ==========================================
// Outputs
// ==========================================
output projectId string = foundryProject.id
output projectName string = foundryProject.name
output aiSearchResourceId string = aiSearch.id
output aiSearchEndpoint string = 'https://${aiSearch.name}.search.windows.net'

@description('Next steps:')
output nextSteps string = '''
1. In Foundry Portal, go to your project
2. Go to Management > Models
3. Deploy models you want (GPT-4o, Llama, etc.)
4. In Management > Connections, connect to Azure OpenAI
5. Connection endpoint will be available to developers via APIM gateway
'''
