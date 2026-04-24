# Playbook: Request Tracing — End-to-End Correlation

**Audience:** Platform Engineers, Developers  
**Complexity:** Intermediate

> **All infrastructure is managed via `azd provision`.** Diagnostic settings, APIM logger configuration, App Gateway rewrite rules, and alert rules are all defined in Bicep. Do not reconfigure observability resources in the Azure Portal — changes will be overwritten on the next provision.

---

## Overview

Every request that enters this platform crosses three layers before reaching the AI model:

```
Internet caller
    │
    ▼
App Gateway / WAF     (waf-appgw.bicep)
    │
    ▼
APIM Premium          (apim-gateway.bicep)          ← rate-limit, auth, caching
    │
    ▼
Azure AI Foundry      (foundry-hub-project.bicep)   ← model inference
    │
    ▼
Model response (back through the same chain)
```

This playbook explains the two correlation mechanisms that link those layers, what data each layer emits, and how to use them to trace a specific request — whether for debugging a slow call, confirming a 429 originated at Layer 1 vs Layer 2, or running a post-incident root-cause analysis.

---

## The Two Correlation Identifiers

### `X-Correlation-Id` — the cross-layer anchor

A custom HTTP request header set by App Gateway and carried through the full pipeline. Its value is derived from two App Gateway server variables:

```
X-Correlation-Id: {var_client_ip}-{var_client_port}
```

Example: `10.0.0.5-52341`

**Why this format, not a UUID?** App Gateway's `{var_request_id}` server variable is only populated for WebSocket connections — for HTTP/HTTPS requests it is always empty. The `client_ip:client_port` pair is unique within any live request window because the OS cannot reuse the same TCP 4-tuple while the original connection is still open.

**Where it is set:** `waf-appgw.bicep` → rewrite rule set `inject-correlation-id`. The rule fires on every request unconditionally and also echoes `X-Correlation-Id` back on the response — so calling applications receive the same ID on the response and can log it locally for correlation without portal access.

**Fallback for direct VNet calls:** Requests that reach APIM without passing through App Gateway (health probes, ACI jumpbox calls, VNet-internal tooling) do not carry a pre-set `X-Correlation-Id`. The APIM global policy detects this and falls back to `context.RequestId.ToString()` — APIM's own per-request GUID — so there is always a correlation anchor in App Insights, regardless of ingress path.

The policy expression in `apim-gateway.bicep`:

```csharp
// Inbound — set-variable "correlationId"
context.Request.Headers.ContainsKey("X-Correlation-Id")
  ? context.Request.Headers["X-Correlation-Id"][0]
  : context.RequestId.ToString()
```

### `OperationId` — the App Insights W3C trace link

APIM is configured with `httpCorrelationProtocol: 'W3C'` in `apim-gateway.bicep`. This means APIM injects a W3C `traceparent` header on every outbound call to Foundry. The `traceparent` carries a **trace ID** that App Insights records as `OperationId` in both rows it emits for the same request:

- `AppRequests` — the inbound APIM span (request received at gateway)
- `AppDependencies` — the outbound backend span (APIM → Foundry call)

Both rows share the same `OperationId`, giving a parent/child relationship that App Insights renders as a Jaeger-style waterfall. `ApiManagementGatewayLogs` (Log Analytics) does **not** carry W3C trace IDs — it cannot link individual calls to Foundry backend spans. App Insights is the only data source that provides per-request parent/child timing across layers.

---

## Data Sources Per Layer

| Layer | Data source | Table / location | What it records | Join key(s) |
|---|---|---|---|---|
| **App Gateway / WAF** | Log Analytics | `AGWAccessLogs` | Client IP, URI, WAF rule matches, total wall time (`timeTaken`) | `X-Correlation-Id` (via `httpXCorrelationId` column) |
| **APIM inbound span** | Application Insights | `AppRequests` | Full request metadata — HTTP method, URL, duration, HTTP status, `X-Correlation-Id` in `customDimensions` | `OperationId`, `customDimensions["Request-Header-X-Correlation-Id"]` |
| **APIM → Foundry call** | Application Insights | `AppDependencies` | Backend call to Foundry — URL, duration, backend HTTP status, `X-Backend-Region-Used` | `OperationId` (same as parent `AppRequests` row) |
| **APIM gateway log** | Log Analytics | `ApiManagementGatewayLogs` | Routing decision, response code, backend URL, subscription ID | `CorrelationId` column (populated from `context.RequestId`) |
| **PCI DSS audit record** | Log Analytics (Event Hub sink) | Custom table or Event Hub stream | Subscription ID, LOB app identity (`appid`), **end-user identity (`user_oid`, `user_upn`)**, client IP, operation, product, department, timestamp | `pci-audit-request-id` = `context.RequestId` |

> **Body logging is disabled.** APIM diagnostic settings have `body: { bytes: 0 }` on both request and response for PCI DSS Req 3.3. `BackendResponseBody` in `ApiManagementGatewayLogs` will be `null` for every row. This is intentional — for token counts, use the `azure-openai-emit-token-metric` policy output in Application Insights custom metrics rather than response body parsing.

---

## Caller Identity vs Correlation ID

Correlation IDs (`X-Correlation-Id`, `OperationId`) identify a **request**. They answer "what path did this call take?" not "who made it?". These are separate signals with different purposes and different data sources.

### The two identity levels in this platform

| Signal | What it identifies | Where it lives | Trustworthy? |
|---|---|---|---|
| **APIM subscription key** (`Ocp-Apim-Subscription-Key`) | The LOB application or team | `ApiManagementGatewayLogs.SubscriptionId`, PCI audit `subscription_id` | Yes — APIM-validated |
| **Entra JWT `appid`/`azp`** | The service principal of the calling LOB app | PCI audit `app_id` | Yes — cryptographically signed by Entra ID |
| **Entra JWT `oid`** | The specific human user who triggered the action | PCI audit `user_oid` | Yes — cryptographically signed by Entra ID |
| **Entra JWT `upn`/`preferred_username`** | The user's login name (e.g. `drew@contoso.com`) | PCI audit `user_upn` | Yes — cryptographically signed by Entra ID |

The APIM subscription key gives you LOB-level accountability. The JWT `oid` and `upn` give you per-user accountability for AI actions — "which person clicked the button that triggered this model call?"

### Why LOB apps can (and should) propagate user identity

If the LOB app already requires a user login (Entra ID SSO), the user's JWT is already available upstream. The app should pass it to APIM as `Authorization: Bearer <token>`. APIM's `pci-dss-audit-logging.xml` policy then extracts `oid`, `upn`, and `appid` from the token and logs all three on every audit event — no custom code required on the LOB side.

```
User logs into LOB app
        │
        ▼
Entra ID issues JWT (contains: oid, upn, appid, tid)
        │
        ▼
LOB app calls APIM
    Authorization: Bearer <JWT>
    Ocp-Apim-Subscription-Key: <key>
    X-Department-Id: <department>
        │
        ▼
APIM PCI audit log records:
    subscription_id = <APIM subscription>    ← LOB team identity
    app_id          = <JWT appid>            ← LOB application identity
    user_oid        = <JWT oid>              ← human user (Entra object ID)
    user_upn        = <JWT upn>              ← human user (login name)
    correlation_id  = <X-Correlation-Id>    ← request trace anchor
```

### What NOT to do — the spoofable header anti-pattern

Do **not** pass user identity as a plain custom header:

```
X-User-Id: drew@contoso.com   ← spoofable, no cryptographic proof
```

Anyone can send any value in a custom header. There is no signature to verify. This pattern fails PCI DSS Req 10.2.1.1 ("individual user access") because the "identity" is unverifiable. Use JWT claims only.

### Multi-agent and OBO scenarios

If the LOB app calls downstream services on behalf of the user (agent chains, tool calls, Foundry sub-agents), user context is lost if the downstream call uses a new service credential rather than the original token. Two correct approaches:

- **On-Behalf-Of (OBO) flow**: The app exchanges the user token for a new token scoped to the downstream service — the `oid` is preserved and the new token is still tied to the original user.
- **Claims propagation**: Extract `oid` and `upn` at the APIM boundary, set them as trusted request variables, and pass them explicitly to downstream services via internal headers (only safe inside a private VNet where intermediate hops are trusted).

For this platform's Silver and Gold tier use of the Agents API, the Foundry agent itself runs under APIM's managed identity — the Foundry call is always service-to-service. The user `oid`/`upn` are captured at the APIM boundary (in the PCI audit log) and do not need to be re-propagated to Foundry; they are already recorded against the same `request_id`.

### Querying by user identity in the audit log

```kql
// All AI actions triggered by a specific user in the last 7 days
// (query the Event Hub sink table — adjust table name to match your sink config)
AzureDiagnostics
| where TimeGenerated > ago(7d)
| where properties_user_upn_s == "drew@contoso.com"
| project
    TimeGenerated,
    properties_user_oid_s,
    properties_user_upn_s,
    properties_app_id_s,
    properties_subscription_id_s,
    properties_api_s,
    properties_operation_s,
    properties_product_s,
    properties_http_status_code_s,
    properties_request_id_s
| order by TimeGenerated desc
```

---

## Headers Captured in App Insights

The APIM diagnostics resource in `apim-gateway.bicep` is configured to capture specific headers into `customDimensions`. These are the fields you can filter on in App Insights queries:

| `customDimensions` key | Value | Set by |
|---|---|---|
| `Request-Header-X-Correlation-Id` | The correlation ID (App Gateway or APIM fallback) | APIM frontend diagnostics — inbound request header |
| `Response-Header-X-Correlation-Id` | Same ID echoed back to caller | APIM frontend diagnostics — outbound response header |
| `Response-Header-X-Backend-Region-Used` | `primary` or `secondary-failover` | Foundry response header, captured by APIM backend diagnostics |
| `Response-Header-X-Tokens-Used` | Token count (if `azure-openai-emit-token-metric` is configured) | Foundry response, captured in APIM outbound |
| `Response-Header-X-Cache` | Cache hit/miss status | APIM semantic cache policy outbound |

---

## Tracing a Specific Request — Step-by-Step

### 1. Obtain the `X-Correlation-Id`

The correlation ID is echoed back to the calling client on every response as the `X-Correlation-Id` response header. If you have the ID from a client log, skip to step 2.

If you only have a time window, use the coverage query in the [Diagnostic Queries](#diagnostic-queries) section to find recent request IDs.

### 2. Find the App Gateway record

```kql
// App Gateway WAF — find the client-facing record
AGWAccessLogs
| where TimeGenerated > ago(2h)
| where httpXCorrelationId == "<your-correlation-id>"
| project
    TimeGenerated,
    clientIP,
    requestUri,
    httpStatusCode,
    timeTakenMs,
    httpXCorrelationId,
    ruleSetType,     // non-empty = WAF rule fired
    ruleId           // specific rule that matched
```

`timeTakenMs` here is the wall-clock time as seen by App Gateway — the full round trip including APIM processing time and Foundry inference time.

### 3. Find the APIM inbound span

```kql
// App Insights — APIM inbound span
AppRequests
| where TimeGenerated > ago(2h)
| where customDimensions["Request-Header-X-Correlation-Id"] == "<your-correlation-id>"
| project
    TimeGenerated,
    OperationId,
    Name,
    DurationMs,
    ResultCode,
    customDimensions["Request-Header-X-Correlation-Id"],
    customDimensions["Response-Header-X-Backend-Region-Used"],
    customDimensions["Response-Header-X-Cache"]
```

Note the `OperationId` — you will use it in step 4.

### 4. Find the Foundry backend span

```kql
// App Insights — APIM → Foundry dependency call
AppDependencies
| where TimeGenerated > ago(2h)
| where OperationId == "<operation-id-from-step-3>"
| project
    TimeGenerated,
    OperationId,
    Target,          // Foundry endpoint URL
    DurationMs,      // Foundry inference time only
    ResultCode,
    Data             // operation type
```

The `DurationMs` here is the Foundry-only inference time. The difference between `AppRequests.DurationMs` and `AppDependencies.DurationMs` is the APIM overhead (policy execution, auth token acquisition, semantic cache check).

```
APIM overhead = AppRequests.DurationMs − AppDependencies.DurationMs
```

### 5. Find the PCI DSS audit record

```kql
// Log Analytics — PCI audit log for this request
// (table name depends on your Event Hub sink configuration — adjust as needed)
AzureDiagnostics
| where TimeGenerated > ago(2h)
| where properties_pci_audit_request_id_s == "<context-request-id>"
| project
    TimeGenerated,
    properties_pci_audit_sub_id_s,
    properties_pci_audit_user_id_s,
    properties_pci_audit_app_id_s,
    properties_user_oid_s,           // end-user Entra object ID
    properties_user_upn_s,           // end-user login name (e.g. drew@contoso.com)
    properties_pci_audit_client_ip_s,
    properties_pci_audit_product_s,
    properties_pci_audit_department_s,
    properties_pci_audit_operation_s
```

> Note: `pci-audit-request-id` = `context.RequestId` (APIM's internal GUID), not the `X-Correlation-Id`. To link the audit record to the App Gateway trace, join via the APIM gateway log's `CorrelationId` column first.

### 6. Full cross-layer join (single query)

```kql
// Cross-layer join: AppGW → APIM → Foundry for a single correlation ID
let corrId = "<your-correlation-id>";
let apimSpan = AppRequests
    | where customDimensions["Request-Header-X-Correlation-Id"] == corrId
    | project OperationId, ApimDurationMs = DurationMs, ApimResultCode = ResultCode,
              BackendRegion = tostring(customDimensions["Response-Header-X-Backend-Region-Used"]),
              CacheStatus   = tostring(customDimensions["Response-Header-X-Cache"]);
let foundrySpan = AppDependencies
    | project OperationId, FoundryDurationMs = DurationMs, FoundryResultCode = ResultCode,
              FoundryTarget = Target;
let agwRecord = AGWAccessLogs
    | where httpXCorrelationId == corrId
    | project AgwDurationMs = timeTakenMs, AgwStatus = httpStatusCode,
              ClientIp = clientIP, RequestUri = requestUri, WafRule = ruleId;
apimSpan
| join kind=leftouter foundrySpan on OperationId
| join kind=leftouter agwRecord on $left.OperationId == $right.OperationId   // approximate — see note
| extend ApimOverheadMs = ApimDurationMs - FoundryDurationMs
| project
    RequestUri,
    ClientIp,
    AgwDurationMs,
    ApimDurationMs,
    FoundryDurationMs,
    ApimOverheadMs,
    ApimResultCode,
    FoundryResultCode,
    AgwStatus,
    BackendRegion,
    CacheStatus,
    WafRule
```

> **Join note:** `AGWAccessLogs` does not carry `OperationId` — the App Gateway join above is simplified for clarity. In practice, use the [End-to-End Trace workbook](#using-the-workbooks) which handles the approximate time-bucket join correctly, or join via `X-Correlation-Id` and a time window rather than `OperationId`.

---

## Diagnostic Queries

### Check `X-Correlation-Id` coverage (propagation health check)

Run this after any infrastructure change to confirm App Gateway is still injecting the header:

```kql
// Coverage: what % of AppRequests have X-Correlation-Id set?
AppRequests
| where TimeGenerated > ago(1h)
| extend corrId = tostring(customDimensions["Request-Header-X-Correlation-Id"])
| summarize
    Total         = count(),
    WithCorrId    = countif(isnotempty(corrId)),
    WithoutCorrId = countif(isempty(corrId)),
    CoveragePct   = round(100.0 * countif(isnotempty(corrId)) / count(), 1)
```

This query is also available as a named query in [`scripts/analyze-appinsights.ps1`](../../scripts/analyze-appinsights.ps1) (query block 6). A coverage of < 100% indicates some requests are arriving via a path that bypasses App Gateway — they will carry `context.RequestId` as the fallback correlation anchor rather than the App Gateway IP:port ID.

### Find slow requests and their correlation IDs (last hour)

```kql
// Top 20 slowest requests — each row has an X-Correlation-Id for drill-down
AppRequests
| where TimeGenerated > ago(1h)
| top 20 by DurationMs desc
| project
    TimeGenerated,
    DurationMs,
    ResultCode,
    Name,
    CorrelationId = tostring(customDimensions["Request-Header-X-Correlation-Id"]),
    BackendRegion = tostring(customDimensions["Response-Header-X-Backend-Region-Used"]),
    OperationId
```

### Find all requests for a given APIM subscription key (LOB drill-down)

```kql
// All requests for a specific APIM subscription (LOB) in the last 24h
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where SubscriptionId == "<apim-subscription-id>"
| project
    TimeGenerated,
    OperationId       = CorrelationId,
    ResponseCode,
    BackendResponseCode,
    DurationMs        = TotalTime,
    BackendUrl,
    IsRequestSuccess
| order by TimeGenerated desc
```

### Confirm a 429 was Layer 1 (Foundry) vs Layer 2 (APIM)

```kql
// Distinguish where a 429 originated
ApiManagementGatewayLogs
| where TimeGenerated > ago(1h)
| where ResponseCode == 429
| extend Source = case(
    BackendResponseCode == 429, "Layer 1 — Foundry capacity exhausted",
    BackendResponseCode == 0,   "Layer 2 — APIM policy rejected before reaching backend",
    "Layer 2 — APIM rejected with backend code"
  )
| summarize Count = count() by Source
```

- `BackendResponseCode == 429`: the request reached Foundry but Foundry returned 429 — Layer 1 capacity is exhausted.
- `BackendResponseCode == 0`: APIM rejected the request before forwarding it — Layer 2 (`azure-openai-token-limit` policy fired).

### Measure APIM overhead vs Foundry inference time (per-request, last 30 min)

```kql
// Per-request latency decomposition: APIM processing time vs Foundry inference
AppRequests
| where TimeGenerated > ago(30m)
| join kind=inner (
    AppDependencies
    | project OperationId, FoundryDurationMs = DurationMs
  ) on OperationId
| extend ApimOverheadMs = DurationMs - FoundryDurationMs
| summarize
    P50_ApimOverheadMs  = percentile(ApimOverheadMs, 50),
    P95_ApimOverheadMs  = percentile(ApimOverheadMs, 95),
    P50_FoundryMs       = percentile(FoundryDurationMs, 50),
    P95_FoundryMs       = percentile(FoundryDurationMs, 95)
```

Sustained APIM overhead > 200 ms at P95 warrants investigation — possible causes include semantic cache miss spikes, auth token acquisition latency, or policy execution time from the CHD masking policy.

### WAF blocks with downstream APIM correlation

```kql
// WAF blocks in the last hour, with the X-Correlation-Id for downstream lookup
AGWAccessLogs
| where TimeGenerated > ago(1h)
| where httpStatusCode == 403 or isnotempty(ruleId)
| project
    TimeGenerated,
    clientIP,
    requestUri,
    httpStatusCode,
    ruleSetType,
    ruleId,
    ruleGroup,
    CorrelationId = httpXCorrelationId
| order by TimeGenerated desc
```

A WAF block (403 at App Gateway) does not produce an `AppRequests` row — the request is dropped before reaching APIM. If a caller reports a 403, check `AGWAccessLogs` first before searching App Insights.

---

## Using the Workbooks

Two Managed Workbooks are deployed by `azd provision` in the platform resource group. They serve different diagnostic needs:

| Workbook | When to use | Data source |
|---|---|---|
| **Backend Routing Report** | Real-time incident response — primary vs secondary traffic split, circuit-breaker events, per-minute error rate | `ApiManagementGatewayLogs`, `AGWAccessLogs` (Log Analytics — low ingestion lag) |
| **End-to-End Trace** | Post-incident root-cause analysis — per-request latency waterfall, WAF rule correlation, per-layer P50/P95/P99 | `AGWAccessLogs` + `AppRequests` + `AppDependencies` joined on `X-Correlation-Id` and `OperationId` |

The **End-to-End Trace** workbook's per-request table includes a clickable `X-Correlation-Id` column that opens the corresponding App Insights Transaction Search view — no manual query required for single-request drill-down.

> **Ingestion lag:** `AppRequests` and `AppDependencies` in App Insights have a 2–5 minute ingestion delay and may be sampled under high load. `ApiManagementGatewayLogs` ingests within ~30 seconds and is unsampled. During an active incident, use the Backend Routing Report. Switch to the End-to-End Trace workbook once the incident is mitigated and you need per-request detail.

---

## Setting the Correlation ID from Client Code

The `X-Correlation-Id` response header is always echoed back to the calling client. LOB developers should log it alongside every request for local correlation:

```python
import openai
import logging

logger = logging.getLogger(__name__)

client = openai.AzureOpenAI(
    azure_endpoint="https://<apim-name>.azure-api.net",
    api_key="<apim-subscription-key>",
    max_retries=0,
)

response = client.chat.completions.create(
    model="gpt-4o-mini",
    messages=[{"role": "user", "content": "Hello"}],
)

# Log the correlation ID for local → platform trace linkage
correlation_id = response._raw_response.headers.get("X-Correlation-Id")
logger.info("Request complete", extra={
    "correlation_id": correlation_id,
    "model": "gpt-4o-mini",
    "tokens_used": response.usage.total_tokens,
})
```

With `correlation_id` in local logs, a developer can hand it to the Platform Engineer to trace the call end-to-end without requiring portal access.

LOB developers can also set their own value before the request reaches App Gateway (for example, a UUID from their own application trace context) — App Gateway's rewrite rule uses `exists-action: override`, so **a pre-set `X-Correlation-Id` will be overwritten** by the App Gateway value. If you need to propagate an upstream application trace ID alongside the platform correlation ID, use a different header name (e.g., `X-App-Request-Id`) and request the Platform Engineer to add it to the APIM diagnostics header capture list.

---

## Troubleshooting — When Traces Are Missing or Incomplete

### End-to-End Trace workbook returns no rows

The per-request join requires three things to be simultaneously working:

| Prerequisite | Where configured | How to verify |
|---|---|---|
| App Gateway `inject-correlation-id` rewrite rule is active | `waf-appgw.bicep` — `rewriteRuleSets` on the routing rule | Run the coverage KQL query above — `CoveragePct` should be ~100% |
| APIM `applicationinsights` diagnostics resource exists | `apim-gateway.bicep` — `apimAppInsightsDiagnostics` resource | Check APIM → APIs → Diagnostics in portal, or verify `azd provision` succeeded |
| APIM logger is wired to App Insights | `apim-gateway.bicep` — `logger` resource with `loggerType: 'applicationInsights'` | Check `AppRequests` in App Insights for recent rows — absence means the logger is broken |

After any failed `azd provision`, verify all three. Do not re-enable them via portal — fix the Bicep and re-run.

### `AppRequests` exists but `AppDependencies` is missing

The parent/child W3C link is established by `httpCorrelationProtocol: 'W3C'` on the APIM diagnostics resource. If `AppDependencies` rows are absent for an `OperationId` that has an `AppRequests` row:

- The Foundry call may have been served from the **semantic cache** — a cache hit returns a response directly from APIM without calling Foundry, so no `AppDependencies` row is emitted. Check `customDimensions["Response-Header-X-Cache"]` for `HIT`.
- The call may have been **rate-limited at Layer 2** (APIM rejected before forwarding). Check `BackendResponseCode == 0` in `ApiManagementGatewayLogs`.
- The APIM diagnostics resource may have been reconfigured with a different `httpCorrelationProtocol`. Run `azd provision` to restore it.

### `X-Correlation-Id` in App Insights has the `context.RequestId` GUID format instead of `ip-port`

The request reached APIM without passing through App Gateway. Expected for:
- ACI jumpbox calls (direct VNet)
- Health probes
- Load tests that target APIM directly

Not a problem — the fallback is intentional. If production traffic is showing GUID-format correlation IDs, check whether App Gateway is routing traffic to APIM correctly (backend pool health in `AGWAccessLogs`).

### WAF block — no corresponding App Insights record

403s returned by App Gateway do not produce `AppRequests` rows. Search `AGWAccessLogs` with the `X-Correlation-Id` from the client error. If `ruleId` is populated, the block was a WAF rule match. If `httpStatusCode == 403` but `ruleId` is empty, the block was an App Gateway listener or SSL policy rejection.

---

## PCI DSS Constraints on Trace Data

| Constraint | Detail |
|---|---|
| **Never enable body logging** | `verbosity: 'information'` on the APIM diagnostics resource is intentional. `'verbose'` logs request/response bodies which may contain cardholder data. This must not be changed in any environment within PCI scope. |
| **Correlation IDs do not contain CHD** | `X-Correlation-Id` = `client_ip-client_port`. Neither field is a PCI DSS sensitive data element — IP addresses and port numbers are metadata, not cardholder data. Safe to log. |
| **`pci-audit-request-id` is the audit anchor** | The PCI DSS audit log (`pci-dss-audit-logging.xml`) records `context.RequestId` as `pci-audit-request-id`. This is APIM's internal GUID — correlate it to `ApiManagementGatewayLogs.CorrelationId` to link audit records to gateway logs. |
| **Audit log retention is 395 days** | Log Analytics workspace is configured for 395-day retention for PCI DSS Req 10.5.1. Do not reduce this. App Insights retention defaults to 90 days — sufficient for operational debugging but not the system of record for compliance. |

---

## Reference

| Resource | Purpose |
|---|---|
| `infrastructure/bicep/waf-appgw.bicep` | App Gateway `inject-correlation-id` rewrite rule set |
| `infrastructure/bicep/apim-gateway.bicep` | Global policy (`correlationId` variable), APIM logger, diagnostics resource (`httpCorrelationProtocol: W3C`) |
| `policies/apim/pci-dss-audit-logging.xml` | PCI DSS audit record — fields logged per request |
| `observability/workbooks/` | E2E Trace and Backend Routing Report workbook JSON |
| `infrastructure/bicep/workbooks.bicep` | Workbook deployment — do not edit workbook JSON in portal |
| `scripts/analyze-appinsights.ps1` | PowerShell wrapper with named App Insights queries including correlation ID coverage check (query 6) |
| [App Insights Transaction Search](https://learn.microsoft.com/en-us/azure/azure-monitor/app/transaction-search-and-diagnostics) | Portal tool for exploring individual distributed traces by `OperationId` |
| [W3C Trace Context specification](https://www.w3.org/TR/trace-context/) | `traceparent` header format used by `httpCorrelationProtocol: W3C` |
