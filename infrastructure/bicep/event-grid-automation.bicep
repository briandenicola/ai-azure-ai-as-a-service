// Event Grid Topic for APIM Subscription Events
// Triggered when APIM subscriptions are created/updated/deleted

param location string = resourceGroup().location
param eventGridTopicName string = 'evt-apim-subscriptions'
param tags object = {
  environment: 'production'
  purpose: 'apim-automation'
}

@description('Object ID of the principal running azd deploy (e.g. the CI service principal or developer UPN). Granted Storage Blob Data Contributor so azd can upload the function zip to the deployments container. Set with: azd env set AZURE_DEPLOYING_USER_OBJECT_ID $(az ad signed-in-user show --query id -o tsv)')
param deployingUserObjectId string = ''

// Event Grid Topic
resource eventGridTopic 'Microsoft.EventGrid/topics@2023-06-01-preview' = {
  name: eventGridTopicName
  location: location
  tags: tags
  properties: {
    inputSchema: 'EventGridSchema'
    publicNetworkAccess: 'Enabled'
  }
}

// Event Grid System Topic for APIM (captures subscription events)
// Note: Requires APIM resource ID
param apimResourceId string

resource apimSystemTopic 'Microsoft.EventGrid/systemTopics@2023-06-01-preview' = {
  name: 'systopic-apim-events'
  location: location
  tags: tags
  properties: {
    source: apimResourceId
    topicType: 'Microsoft.ApiManagement.Service'
  }
}

// Storage Account for Function App
param storageAccountName string

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    // allowSharedKeyAccess defaults to false (subscription policy enforces this).
    // All access is via managed identity — see RBAC assignments below.
  }
}

// App Service Plan — Flex Consumption (FC1)
// Uses separate quota from Consumption (Y1/Dynamic).
// No Dynamic VM quota required — avoids InternalSubscriptionIsOverQuotaForSku errors.
resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'asp-apim-automation'
  location: location
  tags: tags
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true  // Linux required for FC1
  }
}

// Function App for automation
param functionAppName string
param applicationInsightsConnectionString string

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  // azd discovers this function app via the azd-service-name tag
  tags: union(tags, { 'azd-service-name': 'apim-subscription-handler' })
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageAccount.properties.primaryEndpoints.blob}deployments'
          authentication: {
            // Use managed identity — subscription policy blocks shared key access.
            // The Function App's system-assigned identity needs Storage Blob Data Owner
            // on the storage account (see storageBlobOwnerForFuncApp below).
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 100
        instanceMemoryMB: 2048
      }
      runtime: {
        name: 'python'
        version: '3.11'
      }
    }
    siteConfig: {
      appSettings: [
        {
          // Managed identity connection — uses system-assigned MSI instead of a key.
          // Format: AzureWebJobsStorage__accountName tells the Functions host to auth via MSI.
          name: 'AzureWebJobsStorage__accountName'
          value: storageAccount.name
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: applicationInsightsConnectionString
        }
        {
          name: 'EventGridTopicEndpoint'
          value: eventGridTopic.properties.endpoint
        }
        {
          name: 'EventGridTopicKey'
          value: eventGridTopic.listKeys().key1
        }
      ]
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
    }
    httpsOnly: true
  }
}

// ---------------------------------------------------------------------------
// RBAC: Function App managed identity → Storage Account
//
// Required roles for Flex Consumption (FC1) with managed identity storage:
//   Storage Blob Data Owner   — read/write/delete deployment blobs + runtime blobs
//   Storage Queue Data Contributor — AzureWebJobsStorage queue triggers / locks
//   Storage Table Data Contributor — AzureWebJobsStorage durable functions / state
// ---------------------------------------------------------------------------

var storageBlobOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageQueueContributorRoleId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageTableContributorRoleId = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource storageBlobOwnerForFuncApp 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, storageBlobOwnerRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobOwnerRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageQueueContributorForFuncApp 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, storageQueueContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueContributorRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageTableContributorForFuncApp 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, storageTableContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageTableContributorRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Storage: deployments blob container
// Required by Flex Consumption (FC1) before azd deploy can upload the function
// zip. Created here so a fresh provision is all that's needed — no manual step.
// ---------------------------------------------------------------------------
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource deploymentsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'deployments'
  properties: {
    publicAccess: 'None'
  }
}

// ---------------------------------------------------------------------------
// RBAC: deploying user / CI principal → Storage Blob Data Contributor
// Needed so azd deploy can upload the function zip to the deployments container.
// Set deployingUserObjectId = $(az ad signed-in-user show --query id -o tsv)
// or the service principal object ID used in CI.
// ---------------------------------------------------------------------------
resource storageBlobContributorForDeployer 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployingUserObjectId)) {
  name: guid(storageAccount.id, deployingUserObjectId, storageBlobDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: deployingUserObjectId
    principalType: 'User'
  }
}

// Event Grid Subscription (APIM events → Function App)
// IMPORTANT: deployEventSubscription must be false on first provision — the
// Function code must be deployed (azd deploy) before Event Grid can validate
// the function endpoint. Set to true after running azd deploy.
param deployEventSubscription bool = false

resource eventSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2023-06-01-preview' = if (deployEventSubscription) {
  parent: apimSystemTopic
  name: 'apim-subscription-created'
  properties: {
    destination: {
      endpointType: 'AzureFunction'
      properties: {
        resourceId: '${functionApp.id}/functions/ApimSubscriptionHandler'
        maxEventsPerBatch: 1
        preferredBatchSizeInKilobytes: 64
      }
    }
    filter: {
      includedEventTypes: [
        'Microsoft.ApiManagement.SubscriptionCreated'
        'Microsoft.ApiManagement.SubscriptionUpdated'
      ]
    }
    retryPolicy: {
      maxDeliveryAttempts: 30
      eventTimeToLiveInMinutes: 1440
    }
  }
}

// RBAC: Function App managed identity → APIM Contributor
resource functionToApimRBAC 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(functionApp.id, apimResourceId, 'Contributor')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c') // Contributor
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Outputs
output eventGridTopicEndpoint string = eventGridTopic.properties.endpoint
output functionAppName string = functionApp.name
output functionAppPrincipalId string = functionApp.identity.principalId
output eventSubscriptionId string = deployEventSubscription ? eventSubscription.id : ''
