// Azure Managed Grafana with LOB Folder Isolation
// Provides portal-less access to telemetry for developers

param location string = resourceGroup().location
param grafanaName string = 'grafana-ai-gateway'
param tags object = {
  environment: 'production'
  purpose: 'developer-observability'
}

// Managed Grafana Instance
resource managedGrafana 'Microsoft.Dashboard/grafana@2023-09-01' = {
  name: grafanaName
  location: location
  tags: tags
  sku: {
    name: 'Standard'  // Supports Entra ID SSO, folder permissions
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
    zoneRedundancy: 'Enabled'
    apiKey: 'Enabled'
    deterministicOutboundIP: 'Enabled'
    grafanaIntegrations: {
      azureMonitorWorkspaceIntegrations: []
    }
  }
}

// RBAC: Grafana Admin role to IT team — only when deployRbac=true and itTeamObjectId is provided
param deployRbac bool = false
param itTeamObjectId string

resource itAdminRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRbac && !empty(itTeamObjectId)) {
  name: guid(managedGrafana.id, itTeamObjectId, 'Admin')
  scope: managedGrafana
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '22926164-76b3-42b3-bc55-97df8dab3e41') // Grafana Admin
    principalId: itTeamObjectId
    principalType: 'Group'
  }
}

// Grafana connects to Azure Monitor via its system-assigned managed identity using
// the Monitoring Reader role (assigned at subscription scope in main.bicep).
// No managed private endpoint needed for the basic dev deployment.
// For private network access in production: create an AzureMonitorWorkspace or
// AzureMonitorPrivateLinkScope and target that resource instead.

// Outputs
output grafanaEndpoint string = managedGrafana.properties.endpoint
output grafanaId string = managedGrafana.id
output grafanaPrincipalId string = managedGrafana.identity.principalId

// Instructions for folder-based LOB isolation
output setupInstructions string = '''
Next Steps:
1. Log in to Grafana: ${managedGrafana.properties.endpoint}
2. Create folders for each LOB:
   - Settings → Folders → New Folder
   - Create: "Marketing", "Sales", "Engineering", etc.
3. Set folder permissions:
   - Marketing folder → Add permission → Entra ID group "AI-Project-marketing-*" → Viewer
   - Sales folder → Add permission → Entra ID group "AI-Project-sales-*" → Viewer
4. Import dashboards:
   - Upload observability/grafana/dashboards/*.json
   - Assign to appropriate LOB folders
5. Developers access via:
   - Direct URL: ${managedGrafana.properties.endpoint}
   - VS Code: Install Grafana extension
'''
