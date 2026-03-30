// Azure Monitor Workbooks
// Deploys the AppGW → APIM → Foundry backend routing workbook so it is
// available under Azure Monitor → Workbooks immediately after `azd provision`.
//
// The workbook JSON lives at observability/workbooks/backend-routing-report.workbook.json
// and is embedded at compile-time via loadTextContent(). The hardcoded workspace
// resource ID is replaced at deploy-time with the actual logAnalyticsWorkspaceId
// so the workbook works in any subscription / resource group.

targetScope = 'resourceGroup'

param location string
param logAnalyticsWorkspaceId string
param tags object = {}

// Stable GUID derived from the resource group — idempotent across re-provisions.
var workbookId = guid(resourceGroup().id, 'backend-routing-report')

// Placeholder workspace resource ID that was hardcoded when the workbooks were authored.
// Both workbook JSONs reference this same placeholder — replaced at deploy time with the
// real Log Analytics workspace resource ID.
var placeholderWorkspaceId = '/subscriptions/d201ebeb-c470-4a6f-82d5-c2f95bb0dc1e/resourceGroups/rg-contoso-ai-platform-dev/providers/Microsoft.OperationalInsights/workspaces/law-contoso-ai-dev'

// ---------------------------------------------------------------------------
// Workbook 1: Backend Routing Report
// Shows circuit-breaker failover between primary (East US) and secondary (West US)
// Foundry backends, backend errors, and latency by region.
// ---------------------------------------------------------------------------
var rawContent = loadTextContent('../../observability/workbooks/backend-routing-report.workbook.json')
var serializedData = replace(rawContent, placeholderWorkspaceId, logAnalyticsWorkspaceId)

resource backendRoutingWorkbook 'Microsoft.Insights/workbooks@2022-04-01' = {
  name: workbookId
  location: location
  kind: 'shared'
  tags: tags
  properties: {
    displayName: 'AppGW → APIM → Foundry Backend Routing Report'
    serializedData: serializedData
    version: '1.0'
    sourceId: logAnalyticsWorkspaceId
    category: 'workbook'
  }
}

// ---------------------------------------------------------------------------
// Workbook 2: End-to-End Trace (Jaeger-style waterfall)
// Joins AGWAccessLogs (Log Analytics) with AppRequests / AppDependencies
// (App Insights) on X-Correlation-Id to render a per-layer latency waterfall:
//   App Gateway WAF  →  APIM Gateway  →  Azure AI Foundry
//
// Pre-requisite: the App Gateway rewrite rule set in waf-appgw.bicep must be
// deployed so {var_request_id} is stamped as X-Correlation-Id on every request,
// and the APIM diagnostics resource must capture that header (apim-gateway.bicep).
// ---------------------------------------------------------------------------
var e2eRawContent    = loadTextContent('../../observability/workbooks/e2e-trace.workbook.json')
var e2eSerializedData = replace(e2eRawContent, placeholderWorkspaceId, logAnalyticsWorkspaceId)

// Stable GUID for the E2E trace workbook — different seed from workbook 1.
var e2eWorkbookId = guid(resourceGroup().id, 'e2e-trace')

resource e2eTraceWorkbook 'Microsoft.Insights/workbooks@2022-04-01' = {
  name: e2eWorkbookId
  location: location
  kind: 'shared'
  tags: tags
  properties: {
    displayName: 'AppGW → APIM → Foundry End-to-End Trace'
    serializedData: e2eSerializedData
    version: '1.0'
    sourceId: logAnalyticsWorkspaceId
    category: 'workbook'
  }
}

output workbookId    string = backendRoutingWorkbook.id
output e2eWorkbookId string = e2eTraceWorkbook.id
