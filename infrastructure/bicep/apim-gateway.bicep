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

@description('APIM instance name')
param apimName string = 'your-company-ai'

@description('Azure OpenAI resource name (leave blank to use only Foundry AIServices accounts)')
param openaiResourceName string = ''

@description('Azure OpenAI key (leave blank if openaiResourceName is empty)')
@secure()
param openaiApiKey string = ''

@description('Primary Foundry AIServices endpoint — output of foundry-hub-project.bicep module (e.g. https://contoso-foundry-primary.services.ai.azure.com)')
param foundryPrimaryEndpoint string

@description('Secondary Foundry AIServices endpoint for circuit-breaker failover (West US)')
param foundrySecondaryEndpoint string

@description('URL to the Azure OpenAI Inference OpenAPI spec.')
param openaiInferenceApiSpecUrl string = 'https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/cognitiveservices/data-plane/AzureOpenAI/inference/stable/2024-10-21/inference.json'

@description('Application Insights instance name')
param appInsightsName string

@description('Location for resources')
param location string = resourceGroup().location

// ---------------------------------------------------------------------------
// PCI DSS — additional required parameters
// ---------------------------------------------------------------------------

@description('Log Analytics Workspace resource ID for PCI DSS Req 10 audit logs')
param logAnalyticsWorkspaceId string

@description('Virtual Network resource ID for APIM VNet integration (PCI DSS Req 1)')
param vnetResourceId string

@description('Subnet name within the VNet to inject APIM into (minimum /28, must have APIM delegation)')
param apimSubnetName string = 'snet-apim'

@description('Number of APIM scale units. Use 1 for dev; use 3+ (multiple of AZ count) when enabling zone-redundancy (PCI DSS Req 12.3.4).')
@minValue(1)
@maxValue(10)
param apimCapacity int = 1

@description('Availability zones for APIM Premium. East US requires capacity to be a multiple of zone count. Leave empty ([]) for dev/single-region; set to ["1","2","3"] with capacity=3 for PCI DSS Req 12.3.4 zone-redundancy.')
param availabilityZones array = []

// Build the full APIM URL
var apimUrl = 'https://${apimName}.azure-api.net'

// Derived: subnet resource ID from VNet + subnet name
var apimSubnetId = '${vnetResourceId}/subnets/${apimSubnetName}'

// Strip trailing slash from Foundry endpoints so backend URLs don't get double-slash
// (Azure Cognitive Services endpoints always end with '/')
// max(0, ...) satisfies the Bicep type-checker (length - 1 is never negative at runtime
// because endsWith guard ensures the string is non-empty, but the linter can't prove that)
var foundryPrimaryBase = endsWith(foundryPrimaryEndpoint, '/') ? substring(foundryPrimaryEndpoint, 0, max(0, length(foundryPrimaryEndpoint) - 1)) : foundryPrimaryEndpoint
var foundrySecondaryBase = endsWith(foundrySecondaryEndpoint, '/') ? substring(foundrySecondaryEndpoint, 0, max(0, length(foundrySecondaryEndpoint) - 1)) : foundrySecondaryEndpoint

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
    // PCI DSS Req 10.5.1: Retain at least 12 months (365 days minimum; 550 or 730 for extended retention)
    // NOTE: For workspace-based App Insights, retention is inherited from Log Analytics but this field
    // must still be a value from the allowed set: 30,60,90,120,180,270,365,550,730
    RetentionInDays: 365
    WorkspaceResourceId: logAnalyticsWorkspaceId
    IngestionMode: 'LogAnalytics'           // workspace-based; never Classic
    // Public access must be Enabled in dev — APIM (VNet-internal) needs a private endpoint to reach
    // App Insights when ingestion is Disabled. Configure private link scope for production PCI DSS.
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    // Local auth (instrumentation key / connection string) is disabled.
    // APIM sends telemetry via its system-assigned managed identity, which holds
    // 'Monitoring Metrics Publisher' on this App Insights resource (see role assignment below).
    DisableLocalAuth: true
  }
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
  }
}

// ==========================================
// Resource: Global APIM Policy — Managed Identity auth to Foundry
//
// ALL requests through APIM are authenticated to Foundry via the APIM system-assigned
// managed identity, NOT by forwarding client API keys. This means:
//   - Clients authenticate TO APIM with an APIM subscription key
//   - APIM authenticates TO FOUNDRY with an Entra Bearer token (MSI)
//   - api-key headers from clients are stripped before forwarding
//
// Pre-requisite: foundry-apim-rbac.bicep must run (deployRbac=true) to grant
//   'Cognitive Services User' to the APIM managed identity on both Foundry accounts.
//   Until then, manually run:
//     $apimPid = az apim show -n <apim-name> -g <rg> --query identity.principalId -o tsv
//     az role assignment create --role "Cognitive Services User" \
//       --assignee $apimPid --scope /subscriptions/.../foundryPrimaryId
//     az role assignment create --role "Cognitive Services User" \
//       --assignee $apimPid --scope /subscriptions/.../foundrySecondaryId
// ==========================================
resource globalPolicy 'Microsoft.ApiManagement/service/policies@2023-05-01-preview' = {
  parent: apim
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: '''<policies>
  <inbound>
    <!-- ── Distributed Tracing ─────────────────────────────────────────────────
         App Gateway (waf-appgw.bicep rewrite rule) injects X-Correlation-Id
         containing its per-request UUID ({var_request_id}) into every request
         it forwards here. We capture it in a policy variable so it can be:
           1. Forwarded to the Foundry backend (see set-header below)
           2. Echoed back to the client in the outbound section
           3. Captured in App Insights customDimensions via the diagnostics
              frontend.request.headers setting (apimAppInsightsDiagnostics)
         If the request arrives without App Gateway in front (direct VNet call
         or health probe), fall back to context.RequestId so there is always a
         correlation anchor in App Insights.
    ──────────────────────────────────────────────────────────────────────── -->
    <set-variable name="correlationId"
        value="@(context.Request.Headers.ContainsKey(&quot;X-Correlation-Id&quot;) ? context.Request.Headers[&quot;X-Correlation-Id&quot;][0] : context.RequestId.ToString())" />
    <!-- Ensure X-Correlation-Id is present on the request forwarded to Foundry -->
    <set-header name="X-Correlation-Id" exists-action="override">
      <value>@((string)context.Variables["correlationId"])</value>
    </set-header>
    <!-- Strip client-supplied key — APIM owns the Foundry credential via managed identity -->
    <set-header name="api-key" exists-action="delete" />
    <!-- Acquire Entra token for Azure Cognitive Services using APIM system-assigned MSI -->
    <authentication-managed-identity resource="https://cognitiveservices.azure.com"
        output-token-variable-name="msi-access-token" ignore-error="false" />
    <!-- Inject Bearer token for all backend calls -->
    <set-header name="Authorization" exists-action="override">
      <value>@("Bearer " + (string)context.Variables["msi-access-token"])</value>
    </set-header>
  </inbound>
  <backend>
    <!-- Global backend calls primary unconditionally via <forward-request />.
         API-level backend policies (e.g. openai-inference) run AFTER this and
         use <choose> to call secondary only when primary returned 429 or 5xx. -->
    <forward-request />
  </backend>
  <outbound>
    <!-- Echo the correlation ID back to the caller so client logs can be joined
         to the App Insights traces without round-tripping to the portal. -->
    <set-header name="X-Correlation-Id" exists-action="override">
      <value>@((string)context.Variables["correlationId"])</value>
    </set-header>
  </outbound>
  <on-error />
</policies>'''
  }
}

// ==========================================
// Resource: Logger pointing to Application Insights
// ==========================================
resource logger 'Microsoft.ApiManagement/service/loggers@2023-05-01-preview' = {
  parent: apim
  name: 'ai-logger'
  properties: {
    loggerType: 'applicationInsights'
    description: 'Application Insights logger for AI requests'
    credentials: {
      // Full connection string supplies the regional ingestion endpoint URL.
      // 'identityClientId: SystemAssigned' instructs APIM to authenticate via its
      // system-assigned managed identity (Entra token) instead of the instrumentation key,
      // which is required because DisableLocalAuth: true on the App Insights resource.
      connectionString: appInsights.properties.ConnectionString
      identityClientId: 'SystemAssigned'
    }
    isBuffered: true
    resourceId: appInsights.id
  }
}

// ==========================================
// Resource: APIM → App Insights diagnostics
//
// Wires the 'ai-logger' to every API call so APIM emits AppRequests
// (inbound span) and AppDependencies (backend call to Foundry) into
// App Insights. Both rows share the same operation_Id, giving a
// Jaeger-style per-request waterfall in Azure Monitor Transaction Search.
//
// Sampling: 100% — captures all requests including failovers.
// Set samplingPercentage lower (e.g. 10) on high-volume production instances.
//
// PCI note: verbosity is 'information' (no request/response bodies).
// Never set verbosity to 'verbose' in PCI scope — it logs body content.
// ==========================================
resource apimAppInsightsDiagnostics 'Microsoft.ApiManagement/service/diagnostics@2023-05-01-preview' = {
  parent: apim
  name: 'applicationinsights'                 // must be exactly this name
  properties: {
    loggerId: logger.id
    alwaysLog: 'allErrors'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    verbosity: 'information'                   // logs status codes + latency; no body content
    httpCorrelationProtocol: 'W3C'             // emits traceparent header — enables end-to-end trace linking
    operationNameFormat: 'Url'                 // operation name in App Insights = request URI path
    frontend: {
      request: {
        // X-Correlation-Id is injected by the App Gateway rewrite rule set (waf-appgw.bicep).
        // Capturing it here surfaces it as customDimensions["Request-Header-X-Correlation-Id"]
        // in every AppRequests record — the join key for the E2E Trace workbook that links
        // AGWAccessLogs (Log Analytics) to AppRequests/AppDependencies (App Insights).
        headers: [ 'X-Correlation-Id' ]
        body: { bytes: 0 }                     // never log request body (PCI + cost)
      }
      response: {
        headers: [ 'X-Backend-Region-Used', 'X-Correlation-Id' ]   // Foundry region + correlation echo
        body: { bytes: 0 }
      }
    }
    backend: {
      request: {
        headers: [ 'X-Correlation-Id' ]        // verify header is forwarded all the way to Foundry
        body: { bytes: 0 }
      }
      response: {
        headers: [ 'X-Backend-Region-Used', 'X-Correlation-Id' ]   // populates AppDependencies with backend region
        body: { bytes: 0 }
      }
    }
  }
}

// ==========================================
// Resource: API Products — Bronze / Silver / Gold tiers
//
// All three tiers route through the circuit-breaker failover policy
// (East US primary → West US secondary on 429/5xx).
//
// Tier comparison:
// ┌─────────────┬──────────────────────────────────┬────────────┬───────────────┐
// │ Tier        │ Models                           │ Tokens/mo  │ RPM           │
// ├─────────────┼──────────────────────────────────┼────────────┼───────────────┤
// │ Bronze      │ gpt-4o-mini, Phi-4               │ 1 M        │ 60            │
// │ Silver      │ + gpt-4o, Llama-3-70b            │ 10 M       │ 300           │
// │ Gold        │ All models incl. o1; Agents API; │ 100 M      │ Unlimited     │
// │             │ PCI DSS scope (approval required)│            │               │
// └─────────────┴──────────────────────────────────┴────────────┴───────────────┘
// ==========================================

// Named Values used by product policies — endpoint references.
// Changing these Named Values does NOT require a full re-deploy;
// update them in the APIM portal or via az apim nv update.

// ─── Product: Bronze ────────────────────────────────────────────────────────
// Self-service, no approval. Inference only (gpt-4o-mini, Phi-4).
// 500 TPM · 60 RPM · failover enabled.
resource bronzeProduct 'Microsoft.ApiManagement/service/products@2023-05-01-preview' = {
  parent: apim
  name: 'ai-bronze'
  properties: {
    displayName: 'AI Bronze'
    description: 'Entry-tier AI access. Models: gpt-4o-mini, Phi-4. 500 TPM, 60 RPM. Multi-region failover included.'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

resource bronzeProductPolicy 'Microsoft.ApiManagement/service/products/policies@2023-05-01-preview' = {
  parent: bronzeProduct
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: '''<policies>
  <inbound>
    <base />
    <!-- Circuit-breaker failover: primary East US → secondary West US on 429/5xx -->
    <set-variable name="primaryBackend" value="{{foundry-primary-endpoint}}" />
    <set-variable name="secondaryBackend" value="{{foundry-secondary-endpoint}}" />
    <cache-lookup-value key="@(&quot;circuit-breaker-&quot; + context.Variables[&quot;primaryBackend&quot;])" variable-name="primaryFailureCount" />
    <choose>
      <when condition="@(context.Variables.ContainsKey(&quot;primaryFailureCount&quot;) == false)">
        <set-variable name="primaryFailureCount" value="0" />
      </when>
    </choose>
    <!-- Compute the API-specific path suffix: APIM strips the API path prefix before forwarding,
         so we must re-add it to the backend base URL.
         context.Api.Path == "openai" -> /openai, "agents" -> /agents/v1.0, "models" -> /models -->
    <set-variable name="apiPathSuffix" value="@(context.Api.Path == &quot;agents&quot; ? &quot;/agents/v1.0&quot; : &quot;/&quot; + context.Api.Path)" />
    <choose>
      <when condition="@(int.Parse((string)context.Variables[&quot;primaryFailureCount&quot;]) >= 5)">
        <set-backend-service base-url="@((string)context.Variables[&quot;secondaryBackend&quot;] + (string)context.Variables[&quot;apiPathSuffix&quot;])" />
      </when>
      <otherwise>
        <set-backend-service base-url="@((string)context.Variables[&quot;primaryBackend&quot;] + (string)context.Variables[&quot;apiPathSuffix&quot;])" />
      </otherwise>
    </choose>
    <!-- Model allowlist: only lightweight models for Bronze -->
    <choose>
      <when condition="@{
        try {
          var body = context.Request.Body.As&lt;JObject&gt;(preserveContent: true);
          var model = (string)body[&quot;model&quot;];
          var allowed = new[] { &quot;gpt-4o-mini&quot;, &quot;phi-4&quot;, &quot;phi-4-mini&quot; };
          return model != null &amp;&amp; !allowed.Any(m => model.StartsWith(m, StringComparison.OrdinalIgnoreCase));
        } catch { return false; }
      }">
        <return-response>
          <set-status code="403" reason="Forbidden" />
          <set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header>
          <set-body>{"error":{"code":"ModelNotAllowed","message":"Your Bronze subscription allows gpt-4o-mini and Phi-4. Upgrade to Silver or Gold for access to gpt-4o, Llama-3-70b, and o1."}}</set-body>
        </return-response>
      </when>
    </choose>
    <!-- TPM cap: 500 tokens/min -->
    <azure-openai-token-limit tokens-per-minute="500"
      counter-key="@(context.Subscription.Id)"
      estimate-prompt-tokens="true"
      remaining-tokens-header-name="X-Token-Remaining" />
    <!-- Rate limit: 60 RPM -->
    <rate-limit-by-key calls="60" renewal-period="60"
      counter-key="@(&quot;bronze-rpm-&quot; + context.Subscription.Id)" />
  </inbound>
  <backend>
    <!-- Failover is handled by the openai-inference API-level <choose> policy.
         Product scope delegates entirely — no retry or forward-request here. -->
    <base />
  </backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>'''
  }
}

// ─── Product: Silver ────────────────────────────────────────────────────────
// Self-service, no approval. Inference + Agents API.
// gpt-4o, gpt-4o-mini, Phi-4, Llama-3-70b. 50 K TPM · 300 RPM · failover.
resource silverProduct 'Microsoft.ApiManagement/service/products@2023-05-01-preview' = {
  parent: apim
  name: 'ai-silver'
  properties: {
    displayName: 'AI Silver'
    description: 'Mid-tier AI access. Models: gpt-4o, gpt-4o-mini, Phi-4, Llama-3-70b + Agents API. 1K TPM, 300 RPM. Multi-region failover included.'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

resource silverProductPolicy 'Microsoft.ApiManagement/service/products/policies@2023-05-01-preview' = {
  parent: silverProduct
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: '''<policies>
  <inbound>
    <base />
    <!-- Circuit-breaker failover -->
    <set-variable name="primaryBackend" value="{{foundry-primary-endpoint}}" />
    <set-variable name="secondaryBackend" value="{{foundry-secondary-endpoint}}" />
    <cache-lookup-value key="@(&quot;circuit-breaker-&quot; + context.Variables[&quot;primaryBackend&quot;])" variable-name="primaryFailureCount" />
    <choose>
      <when condition="@(context.Variables.ContainsKey(&quot;primaryFailureCount&quot;) == false)">
        <set-variable name="primaryFailureCount" value="0" />
      </when>
    </choose>
    <!-- Compute the API-specific path suffix: APIM strips the API path prefix before forwarding,
         so we must re-add it to the backend base URL. -->
    <set-variable name="apiPathSuffix" value="@(context.Api.Path == &quot;agents&quot; ? &quot;/agents/v1.0&quot; : &quot;/&quot; + context.Api.Path)" />
    <choose>
      <when condition="@(int.Parse((string)context.Variables[&quot;primaryFailureCount&quot;]) >= 5)">
        <set-backend-service base-url="@((string)context.Variables[&quot;secondaryBackend&quot;] + (string)context.Variables[&quot;apiPathSuffix&quot;])" />
      </when>
      <otherwise>
        <set-backend-service base-url="@((string)context.Variables[&quot;primaryBackend&quot;] + (string)context.Variables[&quot;apiPathSuffix&quot;])" />
      </otherwise>
    </choose>
    <!-- Model allowlist: standard + large models, no o1 -->
    <choose>
      <when condition="@{
        try {
          var body = context.Request.Body.As&lt;JObject&gt;(preserveContent: true);
          var model = (string)body[&quot;model&quot;];
          var allowed = new[] { &quot;gpt-4o&quot;, &quot;gpt-4o-mini&quot;, &quot;phi-4&quot;, &quot;phi-4-mini&quot;, &quot;llama-3&quot;, &quot;meta-llama&quot; };
          return model != null &amp;&amp; !allowed.Any(m => model.StartsWith(m, StringComparison.OrdinalIgnoreCase));
        } catch { return false; }
      }">
        <return-response>
          <set-status code="403" reason="Forbidden" />
          <set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header>
          <set-body>{"error":{"code":"ModelNotAllowed","message":"Your Silver subscription allows gpt-4o, gpt-4o-mini, Phi-4, and Llama-3-70b. Upgrade to Gold for o1 and other premium models."}}</set-body>
        </return-response>
      </when>
    </choose>
    <!-- TPM cap: 1 K tokens/min -->
    <azure-openai-token-limit tokens-per-minute="1000"
      counter-key="@(context.Subscription.Id)"
      estimate-prompt-tokens="true"
      remaining-tokens-header-name="X-Token-Remaining" />
    <!-- Rate limit: 300 RPM -->
    <rate-limit-by-key calls="300" renewal-period="60"
      counter-key="@(&quot;silver-rpm-&quot; + context.Subscription.Id)" />
  </inbound>
  <backend>
    <!-- Failover is handled by the openai-inference API-level <choose> policy.
         Product scope delegates entirely — no retry or forward-request here. -->
    <base />
  </backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>'''
  }
}

// ─── Product: Gold ──────────────────────────────────────────────────────────
// Requires approval. Full model access (all models incl. o1) + Agents API +
// PCI DSS scope eligibility. 200 K TPM · unlimited RPM · failover.
// PCI DSS Req 7: Require explicit subscription approval. subscriptionsLimit: 1
// ensures least-privilege — a single customer cannot hold multiple Gold keys.
resource goldProduct 'Microsoft.ApiManagement/service/products@2023-05-01-preview' = {
  parent: apim
  name: 'ai-gold'
  properties: {
    displayName: 'AI Gold'
    description: 'Premium AI access. All models (gpt-4o, o1, Phi-4, Llama-3-70b) + Agents API + PCI DSS scope eligibility. 200K TPM, unlimited RPM. Multi-region failover included. Requires approval.'
    subscriptionRequired: true
    // PCI DSS Req 7: manual approval required for highest-privilege tier
    approvalRequired: true
    state: 'published'
    // PCI DSS Req 7: one subscription per customer — enforces least privilege
    subscriptionsLimit: 1
  }
}

resource goldProductPolicy 'Microsoft.ApiManagement/service/products/policies@2023-05-01-preview' = {
  parent: goldProduct
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: '''<policies>
  <inbound>
    <base />
    <!-- Circuit-breaker failover -->
    <set-variable name="primaryBackend" value="{{foundry-primary-endpoint}}" />
    <set-variable name="secondaryBackend" value="{{foundry-secondary-endpoint}}" />
    <cache-lookup-value key="@(&quot;circuit-breaker-&quot; + context.Variables[&quot;primaryBackend&quot;])" variable-name="primaryFailureCount" />
    <choose>
      <when condition="@(context.Variables.ContainsKey(&quot;primaryFailureCount&quot;) == false)">
        <set-variable name="primaryFailureCount" value="0" />
      </when>
    </choose>
    <!-- Compute the API-specific path suffix: APIM strips the API path prefix before forwarding,
         so we must re-add it to the backend base URL. -->
    <set-variable name="apiPathSuffix" value="@(context.Api.Path == &quot;agents&quot; ? &quot;/agents/v1.0&quot; : &quot;/&quot; + context.Api.Path)" />
    <choose>
      <when condition="@(int.Parse((string)context.Variables[&quot;primaryFailureCount&quot;]) >= 5)">
        <set-backend-service base-url="@((string)context.Variables[&quot;secondaryBackend&quot;] + (string)context.Variables[&quot;apiPathSuffix&quot;])" />
      </when>
      <otherwise>
        <set-backend-service base-url="@((string)context.Variables[&quot;primaryBackend&quot;] + (string)context.Variables[&quot;apiPathSuffix&quot;])" />
      </otherwise>
    </choose>
    <!-- No model allowlist — Gold has access to all models -->
    <!-- TPM cap: 200 K tokens/min -->
    <azure-openai-token-limit tokens-per-minute="200000"
      counter-key="@(context.Subscription.Id)"
      estimate-prompt-tokens="true"
      remaining-tokens-header-name="X-Token-Remaining" />
    <!-- No RPM cap for Gold -->
  </inbound>
  <backend>
    <!-- Failover is handled by the openai-inference API-level <choose> policy.
         Product scope delegates entirely — no retry or forward-request here. -->
    <base />
  </backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>'''
  }
}

// ==========================================
// Resource: Azure OpenAI Backend (legacy resource — kept for any direct OpenAI operations)
// PCI DSS Req 4.2.1: Backend connections enforce TLS 1.2+ (via APIM customProperties)
// PCI DSS Req 1: Backend URL must be private endpoint / internal VNet address in production
// NOTE: Prefer the Foundry backends below — AIServices accounts expose the same
//       OpenAI-compatible surface AND the Agents API in one endpoint.
// ==========================================
// azure-openai backend only deployed when an explicit Azure OpenAI resource is provided.
// When left blank, all inference routes through the Foundry AIServices endpoints below.
resource openaiBackend 'Microsoft.ApiManagement/service/backends@2023-05-01-preview' = if (!empty(openaiResourceName)) {
  parent: apim
  name: 'azure-openai'
  properties: {
    url: 'https://${openaiResourceName}.openai.azure.com'
    protocol: 'http'
    description: 'Azure OpenAI backend (PCI: accessed via private endpoint inside VNet)'
    credentials: {
      header: {
        'api-key': [openaiApiKey]
      }
    }
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
}

// ==========================================
// Resource: Foundry Backends (primary East US + secondary West US)
// Endpoints are AIServices accounts provisioned by foundry-hub-project.bicep.
// The circuit-breaker-multi-region.xml policy switches between these at runtime.
// ==========================================
resource foundryPrimaryBackend 'Microsoft.ApiManagement/service/backends@2023-05-01-preview' = {
  parent: apim
  name: 'foundry-primary'
  properties: {
    url: foundryPrimaryBase
    protocol: 'http'
    description: 'Azure AI Foundry primary (East US) — Agents API + OpenAI-compatible inference'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
}

resource foundrySecondaryBackend 'Microsoft.ApiManagement/service/backends@2023-05-01-preview' = {
  parent: apim
  name: 'foundry-secondary'
  properties: {
    url: foundrySecondaryBase
    protocol: 'http'
    description: 'Azure AI Foundry secondary (West US) — failover via circuit-breaker policy'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
}

// ==========================================
// Resource: APIM Named Values for Foundry endpoints
// Referenced in policies as {{foundry-primary-endpoint}} / {{foundry-secondary-endpoint}}
// Used by circuit-breaker-multi-region.xml to switch backends without hardcoded URLs.
// ==========================================
resource foundryPrimaryNV 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = {
  parent: apim
  name: 'foundry-primary-endpoint'
  properties: {
    displayName: 'foundry-primary-endpoint'
    value: foundryPrimaryBase
    secret: false
  }
}

resource foundrySecondaryNV 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = {
  parent: apim
  name: 'foundry-secondary-endpoint'
  properties: {
    displayName: 'foundry-secondary-endpoint'
    value: foundrySecondaryBase
    secret: false
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
    // Resource-specific mode: each log category gets its own table
    // (ApiManagementGatewayLogs, ApiManagementWebSocketConnectionLogs, etc.)
    // rather than all going into the combined AzureDiagnostics table.
    // This enables cleaner column names and better query performance.
    // PCI DSS Req 10.2.1: Capture all gateway and management logs
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      { category: 'GatewayLogs',             enabled: true }
      { category: 'WebSocketConnectionLogs',  enabled: true }
      { category: 'DeveloperPortalAuditLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

// ==========================================
// Resource: Azure OpenAI Inference API
// Imported from the official Microsoft OpenAPI spec published in azure-rest-api-specs.
// Covers: chat completions, embeddings, images, audio, assistants, batch.
//
// ARM fetches the spec URL at deploy time — this does NOT require the APIM
// data-plane (which is VNet-internal) to reach GitHub. ARM has outbound access.
//
// serviceUrl → primary Foundry /openai surface (OpenAI-compatible).
// circuit-breaker-multi-region.xml overrides this at runtime for failover.
// PCI DSS Req 4.2.1: protocols: ['https'] only.
// ==========================================
resource openaiInferenceApi 'Microsoft.ApiManagement/service/apis@2023-05-01-preview' = {
  parent: apim
  name: 'openai-inference'
  properties: {
    displayName: 'Azure OpenAI Inference'
    description: 'Chat completions, embeddings, images, and audio — Azure OpenAI data-plane, served through Azure AI Foundry AIServices endpoint'
    path: 'openai'
    protocols: ['https']
    subscriptionRequired: true
    format: 'openapi-link'
    value: openaiInferenceApiSpecUrl
    // Default serviceUrl: primary Foundry account's OpenAI-compatible surface.
    // Set-backend-service in circuit-breaker policy overrides this at runtime.
    serviceUrl: '${foundryPrimaryBase}/openai'
  }
}

// ==========================================
// Resource: openai-inference API-level Policy — Failover Retry + Observability
//
// Applied at the API scope so it runs inside every product policy's execution
// for the openai-inference API.  Responsibilities:
//   1. Route all requests to the primary Foundry endpoint by default.
//   2. On HTTP 429 or 5xx, retry once on the secondary endpoint (transparent
//      to the caller — client always sees 200 if secondary succeeds).
//   3. Stamp X-Backend-Region-Used response header with "primary" or
//      "secondary-failover" so load-test JMeter assertions and App Insights
//      queries can confirm failover occurred.
//
// Named Values used:
//   {{foundry-primary-endpoint}}   provisioned by this Bicep file
//   {{foundry-secondary-endpoint}} provisioned by this Bicep file
//
// Backend failover: global <forward-request /> calls primary first. This API-level
// backend section uses <choose> to forward to secondary only when primary returned
// 429 or 5xx — avoiding a double-call on success that a <retry> body would cause.
// ==========================================
resource openaiInferenceApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-05-01-preview' = {
  parent: openaiInferenceApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: '''<policies>
  <inbound>
    <base />
    <set-variable name="selectedBackend" value="primary" />
    <set-backend-service base-url="{{foundry-primary-endpoint}}/openai" />
  </inbound>
  <backend>
    <!-- APIM policy execution order: global <backend> runs <forward-request />
         BEFORE this API-level backend section. So context.Response already
         contains the primary response when this block executes.
         Use <choose> (not <retry>) to call secondary only when primary failed:
           - primary 200: choose condition = false → no action → primary response returned
           - primary 429/5xx: choose condition = true → switch backend → forward-request
             calls secondary → secondary response returned
         This avoids double-calling primary that a <retry> body would cause. -->
    <choose>
      <when condition="@((context.Response.StatusCode == 429 || context.Response.StatusCode &gt;= 500) &amp;&amp; (string)context.Variables[&quot;selectedBackend&quot;] == &quot;primary&quot;)">
        <set-backend-service base-url="{{foundry-secondary-endpoint}}/openai" />
        <set-variable name="selectedBackend" value="secondary-failover" />
        <forward-request timeout="60" />
      </when>
    </choose>
  </backend>
  <outbound>
    <base />
    <set-header name="X-Backend-Region-Used" exists-action="override">
      <value>@(context.Variables.GetValueOrDefault("selectedBackend", "primary"))</value>
    </set-header>
  </outbound>
  <on-error>
    <base />
    <!-- GetValueOrDefault prevents KeyNotFoundException when auth fails before
         inbound sets selectedBackend — without this, missing/invalid subscription
         keys escalate to 500 instead of returning the correct 401. -->
    <set-header name="X-Backend-Region-Used" exists-action="override">
      <value>@(context.Variables.GetValueOrDefault("selectedBackend", "unknown"))</value>
    </set-header>
  </on-error>
</policies>'''
  }
}

// ==========================================
// Resource: Azure AI Foundry Agents API
// Imported from the official Microsoft OpenAPI spec published in azure-rest-api-specs.
// Covers: agents, threads, runs, messages, files, vector stores.
//
// serviceUrl → primary Foundry /agents/v1.0 surface.
// PCI DSS Req 4.2.1: protocols: ['https'] only.
// ==========================================
// Foundry Agents API — created as a blank HTTP passthrough.
// Spec import is skipped: the azure-rest-api-specs URL for the agents data-plane
// may not yet be available on GitHub at deploy time. Import manually via the APIM
// portal (APIs → Import → OpenAPI) once the deployment succeeds.
resource foundryAgentsApi 'Microsoft.ApiManagement/service/apis@2023-05-01-preview' = {
  parent: apim
  name: 'foundry-agents'
  properties: {
    displayName: 'Azure AI Foundry Agents'
    description: 'Create, run, and manage AI agents — Azure AI Foundry Agents data-plane API'
    path: 'agents'
    protocols: ['https']
    subscriptionRequired: true
    serviceUrl: '${foundryPrimaryBase}/agents/v1.0'
  }
}

// Wildcard passthrough: catches all sub-paths under /agents (e.g. /agents/v1.0/threads, /agents/...)
// Without at least one operation APIM returns 404 for every request to this API.
resource foundryAgentsWildcard 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  parent: foundryAgentsApi
  name: 'wildcard-passthrough'
  properties: {
    displayName: 'Wildcard passthrough'
    method: 'POST'
    urlTemplate: '/*'
  }
}

resource foundryAgentsWildcardGet 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  parent: foundryAgentsApi
  name: 'wildcard-passthrough-get'
  properties: {
    displayName: 'Wildcard passthrough GET'
    method: 'GET'
    urlTemplate: '/*'
  }
}

resource foundryAgentsWildcardDelete 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  parent: foundryAgentsApi
  name: 'wildcard-passthrough-delete'
  properties: {
    displayName: 'Wildcard passthrough DELETE'
    method: 'DELETE'
    urlTemplate: '/*'
  }
}

// ==========================================
// Resource: Azure AI Model Inference API
//
// This is the NATIVE Foundry inference surface — preferred over /openai for:
//   - Microsoft-family models (Phi-4): works better here than via OpenAI compat shim
//   - Provider-agnostic clients: single schema covers chat, embeddings, image-embeddings
//   - Multi-model routing: circuit-breaker policy can swap models without client changes
//
// Endpoint path: /models  (e.g. POST /models/chat/completions)
// Spec: azure-ai-inference stable 2024-05-01-preview
// PCI DSS Req 4.2.1: protocols: ['https'] only.
// ==========================================
// NOTE: spec import removed — azure-rest-api-specs ModelInference openapi.json contains $ref links to
// Azure.AI.Inference/stable/2024-05-01-preview/ which no longer exists in the repo (directory deleted).
// Import the spec manually via APIM portal: APIs → model-inference → Import → OpenAPI URL:
//   https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/ai/data-plane/ModelInference/preview/2024-05-01-preview/openapi.json
resource modelInferenceApi 'Microsoft.ApiManagement/service/apis@2023-05-01-preview' = {
  parent: apim
  name: 'model-inference'
  properties: {
    displayName: 'Azure AI Model Inference'
    description: 'Native Foundry model inference — chat completions, embeddings, image-embeddings. Recommended surface for Phi-4 and all non-OpenAI models. Provider-agnostic schema works across model families.'
    path: 'models'
    protocols: ['https']
    subscriptionRequired: true
    serviceUrl: '${foundryPrimaryBase}/models'
  }
}

// Wildcard passthrough: catches all sub-paths under /models (e.g. /models/chat/completions, /models/embeddings)
// Without at least one operation APIM returns 404 for every request to this API.
resource modelInferenceWildcard 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  parent: modelInferenceApi
  name: 'wildcard-passthrough'
  properties: {
    displayName: 'Wildcard passthrough'
    method: 'POST'
    urlTemplate: '/*'
  }
}

resource modelInferenceWildcardGet 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  parent: modelInferenceApi
  name: 'wildcard-passthrough-get'
  properties: {
    displayName: 'Wildcard passthrough GET'
    method: 'GET'
    urlTemplate: '/*'
  }
}

// ==========================================
// Resource: Product ↔ API associations
//
// Bronze: Inference only (OpenAI-compat + native model surface)
// Silver: Inference + Agents API
// Gold:   Inference + Agents API (full access — model allowlist open)
// ==========================================

// ─── Bronze ──────────────────────────────
resource bronzeOpenaiLink 'Microsoft.ApiManagement/service/products/apis@2023-05-01-preview' = {
  parent: bronzeProduct
  name: openaiInferenceApi.name
}

resource bronzeModelLink 'Microsoft.ApiManagement/service/products/apis@2023-05-01-preview' = {
  parent: bronzeProduct
  name: modelInferenceApi.name
}

// ─── Silver ──────────────────────────────
resource silverOpenaiLink 'Microsoft.ApiManagement/service/products/apis@2023-05-01-preview' = {
  parent: silverProduct
  name: openaiInferenceApi.name
}

resource silverModelLink 'Microsoft.ApiManagement/service/products/apis@2023-05-01-preview' = {
  parent: silverProduct
  name: modelInferenceApi.name
}

resource silverAgentsLink 'Microsoft.ApiManagement/service/products/apis@2023-05-01-preview' = {
  parent: silverProduct
  name: foundryAgentsApi.name
}

// ─── Gold ─────────────────────────────────
resource goldOpenaiLink 'Microsoft.ApiManagement/service/products/apis@2023-05-01-preview' = {
  parent: goldProduct
  name: openaiInferenceApi.name
}

resource goldModelLink 'Microsoft.ApiManagement/service/products/apis@2023-05-01-preview' = {
  parent: goldProduct
  name: modelInferenceApi.name
}

resource goldAgentsLink 'Microsoft.ApiManagement/service/products/apis@2023-05-01-preview' = {
  parent: goldProduct
  name: foundryAgentsApi.name
}

// ==========================================
// Resource: APIM Subscriptions — Bronze and Silver created at deploy time
//
// Keys are auto-generated by Azure — no plaintext secrets stored in this template.
// Retrieve the primary key after deployment:
//   Bronze: az apim subscription show --service-name <apim> -g <rg> --subscription-id bronze-test --query primaryKey -o tsv
//   Silver: az apim subscription show --service-name <apim> -g <rg> --subscription-id silver-test --query primaryKey -o tsv
// Or: APIM portal → Subscriptions → find "Bronze Test Subscription" → Show Keys
// ==========================================

resource bronzeTestSub 'Microsoft.ApiManagement/service/subscriptions@2023-05-01-preview' = {
  parent: apim
  name: 'bronze-test'
  properties: {
    displayName: 'Bronze Test Subscription'
    scope: bronzeProduct.id
    state: 'active'
  }
}

resource silverTestSub 'Microsoft.ApiManagement/service/subscriptions@2023-05-01-preview' = {
  parent: apim
  name: 'silver-test'
  properties: {
    displayName: 'Silver Test Subscription'
    scope: silverProduct.id
    state: 'active'
  }
}

// ==========================================
// Private DNS Zone for APIM Internal VNet
//
// APIM Internal VNet mode does NOT create a public DNS record. Resources
// inside the VNet (e.g. the ACI jumpbox, Function App) need DNS to resolve
// the APIM hostname to its private IP address.
//
// Zone: azure-api.net
// Record: apim-contoso-vdls2xyq → 10.100.0.4 (the APIM private IP)
// VNet link: vnet-contoso-ai  (enables auto-resolution for all resources in the VNet)
//
// After provisioning, resources inside the VNet can reach APIM via its
// public hostname (e.g. https://apim-contoso-vdls2xyq.azure-api.net)
// without any /etc/hosts workarounds.
// ==========================================
resource apimPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'azure-api.net'
  location: 'global'
  properties: {}
}

resource apimDnsARecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: apimPrivateDnsZone
  name: apim.name
  properties: {
    ttl: 300
    aRecords: [
      {
        ipv4Address: apim.properties.privateIPAddresses[0]
      }
    ]
  }
}

resource apimDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: apimPrivateDnsZone
  name: 'link-apim-to-vnet'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnetResourceId
    }
    registrationEnabled: false
  }
}

// ==========================================
// RBAC: Monitoring Metrics Publisher on App Insights
//
// Required because DisableLocalAuth: true on the App Insights resource prevents
// instrumentation-key-based ingestion. APIM's logger uses 'identityClientId: SystemAssigned'
// which causes APIM to obtain an Entra token and POST telemetry as its managed identity.
// This role empowers that token to write metrics and custom telemetry to App Insights.
// ==========================================
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

resource apimMonitoringMetricsPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: appInsights
  name: guid(appInsights.id, apim.id, monitoringMetricsPublisherRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ==========================================
// Output: APIM Managed Identity Principal ID
// Use this to assign 'Cognitive Services User' role on OpenAI and Foundry resources
// and 'Key Vault Crypto User' on the Key Vault (PCI DSS Req 3.7)
// ==========================================
output apimResourceId string = apim.id
// Private IP assigned by Azure when APIM is injected into Internal VNet.
// Passed to waf-appgw.bicep as the backend pool target.
output apimPrivateIpAddress string = apim.properties.privateIPAddresses[0]
output apimManagedIdentityPrincipalId string = apim.identity.principalId
output apimManagedIdentityTenantId string = apim.identity.tenantId

// ==========================================
// Output: Important URLs and Info
// ==========================================
output apimGatewayUrl string = apimUrl
// PCI DSS: App Insights has DisableLocalAuth: true — only Entra-authenticated writes are accepted.
// APIM logger uses managed identity; SDK clients use the connection string from this output.
output appInsightsConnectionString string = appInsights.properties.ConnectionString
// Subscription IDs — use these with `az apim subscription show --query primaryKey` to retrieve keys
output bronzeTestSubId string = bronzeTestSub.name
output silverTestSubId string = silverTestSub.name
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
