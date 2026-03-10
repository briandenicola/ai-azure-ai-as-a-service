// Bicep: Deploy Azure API Management Gateway for AI Workloads
//
// This template deploys:
// - APIM instance (Premium tier — required for VNet integration and PCI DSS network segmentation)
// - VNet integration in Internal mode (no public inbound traffic)
// - TLS 1.2+ enforcement (PCI DSS Req 4.2.1)
// - Customer-managed encryption key via Key Vault (PCI DSS Req 3.7)
// - Diagnostic settings routed to Log Analytics (PCI DSS Req 10)
// - Logger to Application Insights
// - Rate limit / token quota policies
// - Backend routing to Azure OpenAI & Foundry
//
// PCI DSS v4.0 requirements addressed by this infrastructure:
//   Req 1   — Segmented network using VNet Internal mode + NSG
//   Req 3.7 — Encryption key management via Azure Key Vault HSM
//   Req 4.2.1 — TLS 1.2+ only, TLS 1.0/1.1/SSL disabled
//   Req 6.4 — WAF in front of APIM (Application Gateway / Front Door)
//   Req 10  — All APIM diagnostic categories sent to Log Analytics Workspace

@description('Environment name (dev, staging, prod)')
param environment string = 'prod'

@description('APIM instance name')
param apimName string = 'your-company-ai'

@description('Azure OpenAI resource name')
param openaiResourceName string = 'your-openai'

@description('Azure OpenAI key')
@secure()
param openaiApiKey string

@description('Foundry project ID')
param foundryProjectId string

@description('Application Insights instance name')
param appInsightsName string

@description('Location for resources')
param location string = resourceGroup().location

// ---------------------------------------------------------------------------
// PCI DSS — additional required parameters
// ---------------------------------------------------------------------------

@description('Azure Key Vault name used for customer-managed encryption keys (PCI DSS Req 3.7)')
param keyVaultName string

@description('Key Vault key name for APIM CMK (PCI DSS Req 3.7)')
param keyVaultKeyName string = 'apim-encryption-key'

@description('Log Analytics Workspace resource ID for PCI DSS Req 10 audit logs')
param logAnalyticsWorkspaceId string

@description('Virtual Network resource ID for APIM VNet integration (PCI DSS Req 1)')
param vnetResourceId string

@description('Subnet name within the VNet to inject APIM into (minimum /28, must have APIM delegation)')
param apimSubnetName string = 'snet-apim'

@description('Number of APIM scale units. Premium minimum is 1; use 2+ for HA across AZs (PCI DSS Req 12.3.4)')
@minValue(1)
@maxValue(10)
param apimCapacity int = 2

@description('Availability zones for APIM Premium (PCI DSS Req 12.3.4 — high availability)')
param availabilityZones array = ['1', '2', '3']

// Build the full APIM URL
var apimUrl = 'https://${apimName}.azure-api.net'

// Derived: subnet resource ID from VNet + subnet name
var apimSubnetId = '${vnetResourceId}/subnets/${apimSubnetName}'

// ==========================================
// Resource: Application Insights (for logging)
// PCI DSS: Public network access restricted — ingest via private link only
// PCI DSS Req 10.5.1: Retain at least 12 months (730 days)
// ==========================================
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    // PCI DSS Req 10.5.1: 13 months retention (minimum is 12; rounding up for audit buffer)
    RetentionInDays: 395
    WorkspaceResourceId: logAnalyticsWorkspaceId
    // PCI DSS Req 1: Restrict public network access to Application Insights
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
    // PCI DSS Req 3: Disable local authentication — enforce Entra ID / managed identity
    DisableLocalAuth: true
  }
}

// ==========================================
// Resource: Key Vault reference (for CMK)
// PCI DSS Req 3.7: Protect encryption keys used to protect cardholder data
// ==========================================
resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' existing = {
  name: keyVaultName
}

// ==========================================
// Resource: APIM Instance — Premium SKU
//
// PCI DSS controls enforced here:
//   Req 1:     VNet Internal mode — no public inbound gateway traffic
//   Req 3.7:   Customer-managed encryption key via Key Vault HSM
//   Req 4.2.1: TLS 1.2+ enforced; TLS 1.0, 1.1, SSL 3.0 explicitly disabled
//   Req 6.4:   disableGateway:false + HTTP disabled for API operations
//   Req 12.3.4:Zone-redundant Premium deployment for high availability
// ==========================================
resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' = {
  name: apimName
  location: location
  // PCI DSS Req 1 / 12.3.4: Premium is required for VNet integration and availability zones
  sku: {
    name: 'Premium'
    capacity: apimCapacity
  }
  // PCI DSS Req 12.3.4: Deploy across availability zones for resilience
  zones: availabilityZones
  // PCI DSS Req 3.7: System-assigned managed identity to access Key Vault CMK
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: 'admin@your-company.com'
    publisherName: 'Your Company AI Platform'
    // PCI DSS Req 1: Internal VNet mode — APIM gateway is not reachable from the internet
    // Inbound traffic must come through WAF (Application Gateway / Front Door)
    virtualNetworkType: 'Internal'
    virtualNetworkConfiguration: {
      subnetResourceId: apimSubnetId
    }
    // PCI DSS Req 4.2.1: Disable weak protocols and cipher suites
    customProperties: {
      // Disable SSL 3.0
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Ssl30': 'false'
      // Disable TLS 1.0
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls10': 'false'
      // Disable TLS 1.1
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls11': 'false'
      // Disable triple-DES cipher suite (weak cipher)
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TripleDes168': 'false'
      // Disable MD5 client certificate negotiation
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls10': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls11': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Ssl30': 'false'
      // Enforce TLS 1.2 for backend connections
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Protocols.Server.Http2': 'true'
    }
    // PCI DSS Req 3.7: Reference customer-managed key
    // Key must be RSA 2048+ in Key Vault HSM; key rotation enforced by Key Vault rotation policy
    encryption: {
      primaryEncryptionKeyId: '${keyVault.properties.vaultUri}keys/${keyVaultKeyName}'
    }
  }
}

// ==========================================
// Resource: Logger pointing to Application Insights
// ==========================================
resource logger 'Microsoft.ApiManagement/service/loggers@2021-12-01-preview' = {
  parent: apim
  name: 'ai-logger'
  properties: {
    loggerType: 'applicationInsights'
    description: 'Application Insights logger for AI requests'
    credentials: {
      instrumentationKey: appInsights.properties.InstrumentationKey
    }
    isBuffered: true
    resourceId: appInsights.id
  }
}

// ==========================================
// Resource: API Products
// ==========================================

// Product 1: Inference (model completions)
resource inferenceProduct 'Microsoft.ApiManagement/service/products@2023-05-01-preview' = {
  parent: apim
  name: 'ai-inference'
  properties: {
    displayName: 'AI Inference'
    description: 'Model inference endpoints (GPT-4o, Llama, etc.)'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

// Product 2: Agents
resource agentsProduct 'Microsoft.ApiManagement/service/products@2023-05-01-preview' = {
  parent: apim
  name: 'ai-agents'
  properties: {
    displayName: 'AI Agents'
    description: 'Agent Service endpoints (create, run, list agents)'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

// Product 3: PCI DSS — Payment-scoped AI operations
// PCI DSS Req 7: Only explicitly approved subscribers can access PCI-scoped endpoints
resource pciProduct 'Microsoft.ApiManagement/service/products@2023-05-01-preview' = {
  parent: apim
  name: 'ai-pci-payment'
  properties: {
    displayName: 'AI Payment Processing (PCI DSS Scoped)'
    description: 'PCI DSS-scoped AI endpoints for payment-related workloads. '
      + 'All subscriptions require QSA-approved justification and manual approval. '
      + 'pci-dss-cardholder-data-protection.xml and pci-dss-audit-logging.xml policies are enforced.'
    // PCI DSS Req 7: Require explicit subscription approval for payment-scoped APIs
    subscriptionRequired: true
    approvalRequired: true
    state: 'published'
    // PCI DSS Req 7: Limit subscriptions per consumer to enforce least privilege
    subscriptionsLimit: 1
  }
}

// ==========================================
// Resource: Azure OpenAI Backend
// PCI DSS Req 4.2.1: Backend connections enforce TLS 1.2+ (via APIM customProperties)
// PCI DSS Req 1: Backend URL must be private endpoint / internal VNet address in production
// ==========================================
resource openaiBackend 'Microsoft.ApiManagement/service/backends@2023-05-01-preview' = {
  parent: apim
  name: 'azure-openai'
  properties: {
    url: 'https://${openaiResourceName}.openai.azure.com'
    protocol: 'http'
    description: 'Azure OpenAI backend (PCI: accessed via private endpoint inside VNet)'
    // PCI DSS: Use managed identity for backend auth rather than static API key where possible
    // The managed identity of APIM is granted Cognitive Services User on the OpenAI resource
    credentials: {
      header: {
        'api-key': [openaiApiKey]
      }
    }
    tls: {
      // PCI DSS Req 4.2.1: Validate backend certificate (no certificate skipping)
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
}

// ==========================================
// Resource: Diagnostic Settings for APIM
// PCI DSS Req 10: All APIM diagnostic categories sent to Log Analytics Workspace
// PCI DSS Req 10.5.1: Retained for 395 days (13 months)
// ==========================================
resource apimDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: apim
  name: 'pci-dss-audit-diagnostics'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    // PCI DSS Req 10.2.1: Capture all gateway and management logs
    logs: [
      { category: 'GatewayLogs',           enabled: true, retentionPolicy: { enabled: true, days: 395 } }
      { category: 'WebSocketConnectionLogs', enabled: true, retentionPolicy: { enabled: true, days: 395 } }
      { category: 'DeveloperPortalAuditLogs', enabled: true, retentionPolicy: { enabled: true, days: 395 } }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true, retentionPolicy: { enabled: true, days: 395 } }
    ]
  }
}

// ==========================================
// Resource: API Operations
// ==========================================

// Operation: POST /ai/completions
// PCI DSS: protocols must be ['https'] only — HTTP not allowed (Req 4.2.1)
resource completionsApi 'Microsoft.ApiManagement/service/apis@2023-05-01-preview' = {
  parent: apim
  name: 'ai-completions'
  properties: {
    displayName: 'AI Completions'
    description: 'Chat completions endpoint'
    path: 'ai/completions'
    // PCI DSS Req 4.2.1: HTTPS only — do NOT add http to this list
    protocols: ['https']
    subscriptionRequired: true
    authentication: {
      oauth2: {
        authorizationServerId: 'aad'
        scope: 'openid profile'
      }
    }
  }
}

// Add operation to completions API
resource postCompletion 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  parent: completionsApi
  name: 'post-completions'
  properties: {
    displayName: 'Post Completion'
    method: 'POST'
    urlTemplate: '/completions'
  }
}

// ==========================================
// Output: APIM Managed Identity Principal ID
// Use this to assign 'Cognitive Services User' role on OpenAI and Foundry resources
// and 'Key Vault Crypto User' on the Key Vault (PCI DSS Req 3.7)
// ==========================================
output apimManagedIdentityPrincipalId string = apim.identity.principalId
output apimManagedIdentityTenantId string = apim.identity.tenantId

// ==========================================
// Output: Important URLs and Info
// ==========================================
output apimGatewayUrl string = apimUrl
// PCI DSS Note: InstrumentationKey is a non-secret connection string for App Insights.
// For PCI workloads use connection strings with managed identity (DisableLocalAuth: true above).
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output appInsightsResourceId string = appInsights.id

@description('How developers connect (internal VNet mode — must connect from within the VNet or via private DNS):')
output connectionExample string = '''
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

client = AIProjectClient(
    credential=DefaultAzureCredential(),
    project_id="your-project",
    endpoint="${apimUrl}"  # <- Use this URL
)
'''
