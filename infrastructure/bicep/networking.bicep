// Bicep: Core networking for the AI-as-a-Service platform
//
// Creates a VNet with three subnets:
//   snet-apim          — APIM Premium Internal VNet injection (/24)
//   snet-appgw-primary — App Gateway WAF v2 (/24, no resource sharing)
//   snet-functions     — Future: Function App VNet integration (/24)
//
// The VNet address space (10.100.0.0/16) is chosen to avoid overlap with
// common corporate ranges (10.0.x.x, 192.168.x.x). Adjust if your org
// has a conflicting range by changing addressPrefix below.

targetScope = 'resourceGroup'

param location string
param prefix string
param tags object = {}

// ---------------------------------------------------------------------------
// NAT Gateway — provides stable internet egress for snet-apim
//
// APIM stv2 in Internal VNet mode has no internet egress by default
// (no Public IP on the APIM instance itself in Internal mode). Without
// explicit egress, APIM cannot send telemetry to the App Insights
// ingestion endpoint (eastus-8.in.applicationinsights.azure.com:443).
//
// A NAT Gateway gives the subnet a predictable static outbound IP, which
// also supports PCI DSS egress logging requirements.
// ---------------------------------------------------------------------------

resource natGwPip 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: 'pip-nat-${prefix}-apim'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
  }
}

resource natGateway 'Microsoft.Network/natGateways@2023-05-01' = {
  name: 'nat-${prefix}-apim'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      { id: natGwPip.id }
    ]
  }
}

// ---------------------------------------------------------------------------
// NSG for APIM subnet — required for APIM Internal VNet mode
// See: https://aka.ms/apiminternalvnet
//
// PCI DSS Req 1: Explicit allowlist; default deny-all for unlisted ports.
// ---------------------------------------------------------------------------

resource apimNsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: 'nsg-${prefix}-apim'
  location: location
  tags: tags
  properties: {
    securityRules: [
      // ── Inbound ────────────────────────────────────────────────────────────
      {
        // REQUIRED: APIM management plane (Azure portal, ARM, PowerShell, Terraform)
        name: 'AllowAPIMManagement'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3443'
          sourceAddressPrefix: 'ApiManagement'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        // REQUIRED: Azure Load Balancer health probes (port 6390 for APIM)
        name: 'AllowAzureLoadBalancer'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '6390'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      // ── Outbound ───────────────────────────────────────────────────────────
      {
        // APIM uploads policies, certificates to Azure Storage
        name: 'AllowStorageOutbound'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'Storage'
        }
      }
      {
        // APIM stores config in Azure SQL
        name: 'AllowSqlOutbound'
        properties: {
          priority: 120
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '1433'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'Sql'
        }
      }
      {
        // Health status, metrics, and diagnostics logs to Azure Monitor
        name: 'AllowMonitorOutbound'
        properties: {
          priority: 130
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRanges: ['1886', '443']
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'AzureMonitor'
        }
      }
      {
        // OAuth 2.0 / OpenID Connect / Entra ID token validation
        name: 'AllowAADOutbound'
        properties: {
          priority: 140
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'AzureActiveDirectory'
        }
      }
      {
        // Key Vault — named values, backend certs, APIM custom domain certs
        name: 'AllowKeyVaultOutbound'
        properties: {
          priority: 150
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'AzureKeyVault'
        }
      }
      {
        // Azure Load Testing VNet-injected engines — allows load test traffic into APIM
        // Engines run in snet-loadtest (10.100.6.0/24); this rule opens port 443 inbound.
        // See: https://learn.microsoft.com/azure/load-testing/how-to-test-private-endpoint
        name: 'AllowLoadTestInbound'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '10.100.6.0/24'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
    ]
  }
}

// NSG for AzureBastionSubnet — required rules per Microsoft documentation
// https://learn.microsoft.com/azure/bastion/bastion-nsg
resource bastionNsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: 'nsg-${prefix}-bastion'
  location: location
  tags: tags
  properties: {
    securityRules: [
      // ── Inbound ───────────────────────────────────────────────────────────
      {
        name: 'AllowHttpsFromInternet'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowGatewayManager'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'GatewayManager'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowAzureLoadBalancer'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowBastionHostCommunication'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRanges: ['8080', '5701']
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      // ── Outbound ──────────────────────────────────────────────────────────
      {
        name: 'AllowRdpSshToVnet'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRanges: ['3389', '22']
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'AllowAzureCloudOutbound'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'AzureCloud'
        }
      }
      {
        name: 'AllowBastionCommunicationOutbound'
        properties: {
          priority: 120
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRanges: ['8080', '5701']
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'AllowHttpOutbound'
        properties: {
          priority: 130
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'Internet'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// NSG for App Gateway subnet — required rules for WAF v2 public listener
//
// AppGW v2 NSG requirements (https://aka.ms/agv2nsg):
//   Inbound  port 443          from Internet       — client HTTPS traffic
//   Inbound  port 65200-65535  from GatewayManager — AppGW v2 management plane
//   All other inbound denied by default (implicit deny-all)
//
// PCI DSS Req 1.3: No direct internet access to APIM; all inbound goes
//   via AppGW WAF, which is allowed here at port 443 only.
// ---------------------------------------------------------------------------
resource appgwNsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: 'nsg-${prefix}-appgw-primary'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        // Client HTTPS — must be explicitly allowed; AppGW does not expose HTTP.
        // PCI DSS Req 4.2.1: TLS-only inbound; HTTP (80) is intentionally absent.
        name: 'AllowHttpsInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
      {
        // REQUIRED: AppGW v2 management plane communication from Azure infrastructure.
        // Without this rule the AppGW will fail to provision or update.
        // See https://aka.ms/agv2nsg for full documentation.
        name: 'AllowGatewayManagerInbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '65200-65535'
          sourceAddressPrefix: 'GatewayManager'
          destinationAddressPrefix: '*'
        }
      }
      {
        // Azure Load Balancer health checks into the AppGW instances.
        name: 'AllowAzureLoadBalancerInbound'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: 'vnet-${prefix}-ai'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: ['10.100.0.0/16']
    }
    subnets: [
      {
        // APIM Premium Internal mode — minimum /28, /24 gives room to grow
        name: 'snet-apim'
        properties: {
          addressPrefix: '10.100.0.0/24'
          // REQUIRED: APIM Internal VNet deployment requires an NSG.
          // See https://aka.ms/apiminternalvnet for rule requirements.
          networkSecurityGroup: {
            id: apimNsg.id
          }
          // NAT Gateway provides stable internet egress for APIM.
          // Required so APIM can send telemetry to App Insights ingestion endpoint
          // (eastus-8.in.applicationinsights.azure.com) in Internal VNet mode.
          natGateway: {
            id: natGateway.id
          }
        }
      }
      {
        // App Gateway WAF v2 — dedicated subnet, minimum /26 per Microsoft requirement.
        // NSG is required with two explicit rules (see appgwNsg above):
        //   • port 443 from Internet (client traffic)
        //   • port 65200-65535 from GatewayManager (AppGW v2 management)
        name: 'snet-appgw-primary'
        properties: {
          addressPrefix: '10.100.1.0/24'
          networkSecurityGroup: {
            id: appgwNsg.id
          }
        }
      }
      {
        // Reserved for Function App VNet integration (future)
        name: 'snet-functions'
        properties: {
          addressPrefix: '10.100.2.0/24'
          delegations: [
            {
              name: 'functions-delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      {
        // Azure Bastion — must be named exactly 'AzureBastionSubnet'; minimum /26
        // Provides browser-based and native RDP to jumpbox without exposing port 3389
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: '10.100.3.0/26'
          networkSecurityGroup: {
            id: bastionNsg.id
          }
        }
      }
      {
        // Jumpbox — ACI container for VNet-internal APIM testing
        // Delegation required by Microsoft.ContainerInstance/containerGroups
        name: 'snet-jumpbox'
        properties: {
          addressPrefix: '10.100.4.0/24'
          delegations: [
            {
              name: 'aci-delegation'
              properties: {
                serviceName: 'Microsoft.ContainerInstance/containerGroups'
              }
            }
          ]
        }
      }
      {
        // Private endpoints for Foundry accounts (and any future private link resources)
        // privateEndpointNetworkPolicies must be Disabled for private endpoints to work
        name: 'snet-private-endpoints'
        properties: {
          addressPrefix: '10.100.5.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
      }
      {
        // Azure Load Testing VNet injection — engines are deployed into this subnet
        // during a private load test run. Minimum /26; /24 used for consistency.
        // privateEndpointNetworkPolicies must be Disabled per ALT requirements.
        // See: https://learn.microsoft.com/azure/load-testing/how-to-test-private-endpoint
        name: 'snet-loadtest'
        properties: {
          addressPrefix: '10.100.6.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output privateEndpointSubnetId string = '${vnet.id}/subnets/snet-private-endpoints'
output loadTestSubnetId string = '${vnet.id}/subnets/snet-loadtest'
output natGatewayPublicIp string = natGwPip.properties.ipAddress
