// Azure AI Agent Starter Infrastructure
// Deploys Container Apps, Container Registry, and supporting resources

@description('Environment name (dev, staging, production)')
param environment string = 'dev'

@description('Azure region for resources')
param location string = resourceGroup().location

@description('Azure AI Project Endpoint')
@secure()
param azureProjectEndpoint string

@description('Model Deployment Name')
param modelDeploymentName string = 'gpt-4'

@description('Container App name')
param containerAppName string = 'ai-agent-starter-${environment}'

@description('Container Registry name (must be globally unique)')
param containerRegistryName string = 'aiagentstarter${environment}${uniqueString(resourceGroup().id)}'

@description('Log Analytics workspace name')
param logAnalyticsWorkspaceName string = 'ai-agent-starter-${environment}-logs'

@description('Container Apps environment name')
param containerAppsEnvironmentName string = 'ai-agent-starter-${environment}-env'

@description('Enable Application Insights')
param enableAppInsights bool = true

@description('CPU cores for container app')
param cpuCore string = '1.0'

@description('Memory for container app')
param memorySize string = '2Gi'

@description('Min replicas')
param minReplicas int = 1

@description('Max replicas')
param maxReplicas int = environment == 'production' ? 10 : 3

// Variables
var tags = {
  Environment: environment
  Project: 'ai-agent-starter'
  ManagedBy: 'Bicep'
}

// Log Analytics Workspace
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: environment == 'production' ? 90 : 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

// Application Insights (optional)
resource appInsights 'Microsoft.Insights/components@2020-02-02' = if (enableAppInsights) {
  name: '${containerAppName}-insights'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    IngestionMode: 'LogAnalytics'
  }
}

// Container Registry
resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: containerRegistryName
  location: location
  tags: tags
  sku: {
    name: environment == 'production' ? 'Standard' : 'Basic'
  }
  properties: {
    adminUserEnabled: true
    publicNetworkAccess: 'Enabled'
  }
}

// Container Apps Environment
resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: containerAppsEnvironmentName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
    zoneRedundant: environment == 'production' ? true : false
  }
}

// Managed Identity for Container App
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${containerAppName}-identity'
  location: location
  tags: tags
}

// Role assignment for Container Registry
resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerRegistry.id, managedIdentity.id, 'acrpull')
  scope: containerRegistry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d') // AcrPull role
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Container App
resource containerApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: containerAppName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerAppsEnvironment.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8989
        transport: 'http'
        allowInsecure: false
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      registries: [
        {
          server: containerRegistry.properties.loginServer
          identity: managedIdentity.id
        }
      ]
      secrets: [
        {
          name: 'azure-project-endpoint'
          value: azureProjectEndpoint
        }
        {
          name: 'model-deployment-name'
          value: modelDeploymentName
        }
        {
          name: 'app-insights-connection-string'
          value: enableAppInsights ? appInsights!.properties.ConnectionString : ''
        }
      ]
    }
    template: {
      containers: [
        {
          name: containerAppName
          image: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest' // Placeholder until first deployment
          resources: {
            cpu: json(cpuCore)
            memory: memorySize
          }
          env: [
            {
              name: 'AZURE_PROJECT_ENDPOINT'
              secretRef: 'azure-project-endpoint'
            }
            {
              name: 'MODEL_DEPLOYMENT_NAME'
              secretRef: 'model-deployment-name'
            }
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              secretRef: 'app-insights-connection-string'
            }
            {
              name: 'ENVIRONMENT'
              value: environment
            }
          ]
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/health'
                port: 8989
              }
              initialDelaySeconds: 15
              periodSeconds: 30
              timeoutSeconds: 5
              failureThreshold: 3
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/health'
                port: 8989
              }
              initialDelaySeconds: 10
              periodSeconds: 10
              timeoutSeconds: 3
              failureThreshold: 3
            }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http-scale'
            http: {
              metadata: {
                concurrentRequests: '10'
              }
            }
          }
        ]
      }
    }
  }
  dependsOn: [
    acrPullRole
  ]
}

// Outputs
@description('Container App URL')
output containerAppUrl string = 'https://${containerApp.properties.configuration.ingress.fqdn}'

@description('Container App FQDN')
output containerAppFqdn string = containerApp.properties.configuration.ingress.fqdn

@description('Container Registry name')
output containerRegistryName string = containerRegistry.name

@description('Container Registry login server')
output containerRegistryLoginServer string = containerRegistry.properties.loginServer

@description('Managed Identity ID')
output managedIdentityId string = managedIdentity.id

@description('Managed Identity Client ID')
output managedIdentityClientId string = managedIdentity.properties.clientId

@description('Log Analytics Workspace ID')
output logAnalyticsWorkspaceId string = logAnalytics.id

@description('Application Insights Connection String')
output appInsightsConnectionString string = enableAppInsights ? appInsights!.properties.ConnectionString : ''

@description('Container Apps Environment ID')
output containerAppsEnvironmentId string = containerAppsEnvironment.id
