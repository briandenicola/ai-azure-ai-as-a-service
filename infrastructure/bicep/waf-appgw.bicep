// Bicep: Application Gateway WAF v2 — Regional WAF Layer
//
// PCI DSS Req 6.4 / 6.5.4:
//   "Automated technical solutions that protect web-facing apps from attacks."
//   WAF must operate in Prevention mode (not Detection) with OWASP CRS 3.2+.
//
// Deploy one instance per region from main.bicep:
//   - Primary   (East US): wafAppGwPrimary   — APIM East US internal IP
//   - Secondary (West US): wafAppGwSecondary  — APIM West US internal IP
//     (West US requires APIM Premium additionalLocations setting)
//
// Full inbound traffic path:
//   Internet
//     → Azure Front Door WAF (Standard Premium, global — see README PCI §13)
//     → App Gateway WAF v2  (this resource, regional)
//     → APIM Internal VNet  (Premium SKU, VNet-injected)
//     → Azure AI Foundry    (private endpoint)

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Azure region for this App Gateway (e.g. eastus, westus)')
param location string

@description('Application Gateway resource name')
param appGwName string

@description('VNet resource ID that APIM is injected into. App Gateway is deployed into this same VNet.')
param vnetResourceId string

@description('Name of the dedicated App Gateway subnet (must not contain any other resources and must have no delegation; minimum /26)')
param appGwSubnetName string = 'snet-appgw'

@description('APIM private IP address within the VNet — used as the App Gateway backend pool target. Comes from apim-gateway.bicep output apimPrivateIpAddress.')
param apimInternalIpAddress string

@description('APIM gateway hostname (e.g. contoso-ai.azure-api.net) for backend SNI and health probe host header')
param apimGatewayHostname string

@secure()
@description('Key Vault secret ID for the SSL certificate PFX (full URI including version). PCI DSS Req 4.2.1: TLS 1.2+ enforced at listener.')
param sslCertKeyVaultSecretId string

@description('Minimum App Gateway scale units (2+ for HA; PCI DSS Req 12.3.4)')
@minValue(1)
@maxValue(125)
param capacity int = 2

@description('Availability zones for zone-redundant deployment (PCI DSS Req 12.3.4)')
param availabilityZones array = ['1', '2', '3']

param tags object = {}

@description('Log Analytics workspace resource ID for AppGW diagnostic settings. Pass the same workspace used by APIM diagnostics.')
param logAnalyticsWorkspaceId string

@description('DNS label for the Public IP. Must be globally unique within the region. Defaults to toLower(appGwName) if not provided. Bicep callers should pass a value that includes a uniqueString suffix.')
param domainNameLabel string = toLower(appGwName)

// ---------------------------------------------------------------------------
// Derived values
// ---------------------------------------------------------------------------

var appGwSubnetId = '${vnetResourceId}/subnets/${appGwSubnetName}'

// ---------------------------------------------------------------------------
// Resource: User-Assigned Managed Identity
// Required for App Gateway to read the SSL certificate from Key Vault.
// PCI DSS Req 8.6: No static credentials — UAMI used for cert retrieval.
// ---------------------------------------------------------------------------

resource appGwIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${appGwName}-identity'
  location: location
  tags: tags
}

// ---------------------------------------------------------------------------
// Note: Key Vault Certificate User RBAC for this identity is assigned in
// main.bicep via kv-cert-rbac.bicep, which supports cross-resource-group KV.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Resource: Public IP — zone-redundant Standard SKU
// PCI DSS Req 12.3.4: Zone-redundant for HA.
// Static allocation required for App Gateway v2.
// ---------------------------------------------------------------------------

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: '${appGwName}-pip'
  location: location
  tags: tags
  zones: availabilityZones
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    // domainNameLabel required so that dnsSettings.fqdn is populated (used in output).
    // Passed in from main.bicep as a uniqueString-based value to avoid global DNS conflicts.
    dnsSettings: {
      domainNameLabel: domainNameLabel
    }
  }
}

// ---------------------------------------------------------------------------
// Resource: WAF Policy
// PCI DSS Req 6.4 / 6.5.4:
//   - Prevention mode (not Detection) — blocks requests rather than just logs
//   - OWASP CRS 3.2 — covers OWASP Top 10 including injection, XSS, SSRF
//   - Microsoft Bot Manager 1.0 — blocks malicious bots and scrapers
//   - Request body inspection enabled (catches payload-based attacks)
//
// NOTE: Do NOT set mode to 'Detection' — PCI DSS Req 6.4 requires blocking,
// and a QSA will flag Detection-only WAFs as non-compliant.
// ---------------------------------------------------------------------------

resource wafPolicy 'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies@2023-05-01' = {
  name: '${appGwName}-waf-policy'
  location: location
  tags: tags
  properties: {
    policySettings: {
      state: 'Enabled'
      // PCI DSS Req 6.4: MUST be Prevention. Detection mode does not satisfy Req 6.4.
      mode: 'Prevention'
      requestBodyCheck: true
      maxRequestBodySizeInKb: 128   // Large enough for AI prompts; increase if needed
      fileUploadLimitInMb: 100
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'OWASP'
          // PCI DSS ADR-004 Req 6.5.4: Must be CRS 3.2 or higher
          ruleSetVersion: '3.2'
        }
        {
          // Blocks known bad bots, vulnerability scanners, and credential stuffing tools
          ruleSetType: 'Microsoft_BotManagerRuleSet'
          ruleSetVersion: '1.0'
        }
      ]
      exclusions: [
        // Exclude the Authorization header from all OWASP managed rules.
        // Entra Bearer JWTs contain base64url-encoded JSON that triggers OWASP
        // CRS rules (e.g. 942100 SQL injection, 941xxx XSS) due to characters
        // like dots, plus signs, and encoded payloads in the JWT signature.
        // The JWT itself is validated by APIM's validate-jwt policy — WAF does
        // not need to inspect it.
        {
          matchVariable: 'RequestHeaderNames'
          selectorMatchOperator: 'Equals'
          selector: 'Authorization'
          exclusionManagedRuleSets: [
            {
              ruleSetType: 'OWASP'
              ruleSetVersion: '3.2'
              ruleGroups: []   // empty = exclude all rule groups for this header
            }
          ]
        }
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// Resource: Application Gateway WAF v2
//
// Inbound traffic path:
//   Client HTTPS 443
//     → Frontend: Public IP
//     → Listener: HTTPS 443, TLS 1.2+ (AppGwSslPolicy20220101), cert from Key Vault
//     → WAF Policy: OWASP CRS 3.2 + Bot Manager (Prevention)
//     → Routing Rule (Basic)
//     → Backend Pool: APIM private IP
//     → Backend HTTP Settings: HTTPS 443, SNI = apimGatewayHostname, 180s timeout
//     → Health Probe: HTTPS GET /status-0123456789abcdef on apimGatewayHostname
//
// PCI DSS controls:
//   Req 4.2.1  — TLS 1.2+ enforced via AppGwSslPolicy20220101; TLS 1.0/1.1 disabled
//   Req 6.4    — WAF in Prevention mode with CRS 3.2 + Bot Manager
//   Req 6.5.4  — OWASP CRS 3.2 + Prevention mode
//   Req 12.3.4 — Zone-redundant WAF_v2 SKU, autoscale enabled
// ---------------------------------------------------------------------------

resource appGw 'Microsoft.Network/applicationGateways@2023-05-01' = {
  name: appGwName
  location: location
  tags: tags
  zones: availabilityZones
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${appGwIdentity.id}': {}
    }
  }
  properties: {
    sku: {
      name: 'WAF_v2'
      tier: 'WAF_v2'
    }
    // Autoscale between capacity and 10 units — handles AI inference burst traffic
    autoscaleConfiguration: {
      minCapacity: capacity
      maxCapacity: 10
    }
    // Associate WAF policy at the gateway level (applies to all listeners by default)
    firewallPolicy: {
      id: wafPolicy.id
    }
    gatewayIPConfigurations: [
      {
        name: 'appgw-ip-config'
        properties: {
          subnet: { id: appGwSubnetId }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'appgw-frontend-public'
        properties: {
          publicIPAddress: { id: publicIp.id }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'port-443'
        properties: { port: 443 }
      }
    ]
    sslCertificates: [
      {
        name: 'apim-ssl-cert'
        properties: {
          // Reference SSL cert from Key Vault via UAMI — no secret ever stored in App GW.
          // PCI DSS Req 3.5: Cryptographic material protected in Key Vault HSM.
          // The UAMI above is granted Key Vault Certificate User before this resource deploys.
          keyVaultSecretId: sslCertKeyVaultSecretId
        }
      }
    ]
    sslPolicy: {
      // PCI DSS Req 4.2.1: Enforce TLS 1.2+ at the App Gateway listener level.
      // AppGwSslPolicy20220101 disables TLS 1.0, TLS 1.1, and SSL 3.0.
      policyType: 'Predefined'
      policyName: 'AppGwSslPolicy20220101'
    }
    httpListeners: [
      {
        name: 'appgw-https-listener'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', appGwName, 'appgw-frontend-public')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appGwName, 'port-443')
          }
          protocol: 'Https'
          sslCertificate: {
            id: resourceId('Microsoft.Network/applicationGateways/sslCertificates', appGwName, 'apim-ssl-cert')
          }
          firewallPolicy: { id: wafPolicy.id }
          requireServerNameIndication: false
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'apim-backend-pool'
        properties: {
          // APIM's private IP within the VNet — never a public IP.
          // PCI DSS Req 1.3: No direct path from internet to APIM.
          backendAddresses: [
            { ipAddress: apimInternalIpAddress }
          ]
        }
      }
    ]
    probes: [
      {
        name: 'apim-health-probe'
        properties: {
          protocol: 'Https'
          // Use APIM gateway hostname for SNI so the cert is presented correctly
          host: apimGatewayHostname
          // APIM built-in health endpoint — returns 200 when gateway is healthy
          path: '/status-0123456789abcdef'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: false
          match: {
            statusCodes: ['200-399']
          }
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'apim-backend-settings'
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          // 180s timeout: AI inference (especially streaming) can take time.
          // Adjust down for non-streaming workloads.
          requestTimeout: 180
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', appGwName, 'apim-health-probe')
          }
          pickHostNameFromBackendAddress: false
          // Set APIM hostname so the backend validates the correct TLS cert (SNI)
          hostName: apimGatewayHostname
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'apim-routing-rule'
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGwName, 'appgw-https-listener')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', appGwName, 'apim-backend-pool')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', appGwName, 'apim-backend-settings')
          }
          // Attach the rewrite rule set so every request gets X-Correlation-Id injected.
          rewriteRuleSet: {
            id: resourceId('Microsoft.Network/applicationGateways/rewriteRuleSets', appGwName, 'inject-correlation-id')
          }
        }
      }
    ]

    // ---------------------------------------------------------------------------
    // Rewrite Rule Set: inject X-Correlation-Id for distributed tracing
    //
    // Azure Application Gateway does not have a built-in UUID generator, so we
    // compose a pseudo-unique per-request ID from supported server variables:
    //   {var_client_ip}-{var_client_port}
    //
    // Example value: "10.0.0.1-50234"
    // Uniqueness: TCP source port is unique per active connection — the same
    // client IP + port cannot be reused for a new connection while the original
    // is still open, so this pair is unique within any live request window.
    //
    // This header flows through the full pipeline:
    //   AppRequests.customDimensions["Request-Header-X-Correlation-Id"] (App Insights)
    //   → AppDependencies.customDimensions["Request-Header-X-Correlation-Id"] (App Insights)
    //
    // The E2E Trace workbook uses the embedded client IP and timestamp to do an
    // approximate time-bucket join back to AGWAccessLogs for the AppGW layer timing.
    // ---------------------------------------------------------------------------
    rewriteRuleSets: [
      {
        name: 'inject-correlation-id'
        properties: {
          rewriteRules: [
            {
              name: 'add-x-correlation-id'
              ruleSequence: 100
              conditions: []           // apply unconditionally to every request
              actionSet: {
                // Forward to APIM (and on to Foundry) — core correlation anchor
                requestHeaderConfigurations: [
                  {
                    headerName: 'X-Correlation-Id'
                    headerValue: '{var_client_ip}-{var_client_port}'
                  }
                ]
                // Echo back to the calling client for end-to-end diagnostics
                responseHeaderConfigurations: [
                  {
                    headerName: 'X-Correlation-Id'
                    headerValue: '{var_client_ip}-{var_client_port}'
                  }
                ]
              }
            }
          ]
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output appGwPublicIp string = publicIp.properties.ipAddress
output appGwResourceId string = appGw.id
output appGwFqdn string = publicIp.properties.dnsSettings.fqdn
output appGwIdentityPrincipalId string = appGwIdentity.properties.principalId

// ---------------------------------------------------------------------------
// Resource: Diagnostic Settings — AppGW access, WAF firewall, and performance logs
//
// Logs in Dedicated (resource-specific) mode — each category gets its own table:
//   AGWAccessLogs     — per-request HTTP log (status, timing, client IP, UA)
//   AGWFirewallLogs   — WAF rule matches (Matched/Blocked); use for tuneouts
//   AGWPerformanceLogs — instance-level metrics (throughput, connection count)
//
// This mirrors the APIM configuration (resource-specific Dedicated mode) so
// all AI gateway logs are queryable from dedicated tables in Log Analytics.
// ---------------------------------------------------------------------------

resource appGwDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: appGw
  name: 'appgw-diagnostics'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      { category: 'ApplicationGatewayAccessLog',      enabled: true }
      { category: 'ApplicationGatewayFirewallLog',     enabled: true }
      { category: 'ApplicationGatewayPerformanceLog',  enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}
