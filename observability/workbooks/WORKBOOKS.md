# Workbooks Reference

Three workbooks are deployed by `azd provision` into `rg-contoso-ai-platform-dev`. They answer different operational questions and draw from different data sources — they are intentionally kept separate.

| | Backend Routing Report | End-to-End Trace | Platform Health |
|---|---|---|---|
| **Primary audience** | Platform ops / SRE | LOB teams, developers, product owners | Platform ops / capacity planning |
| **Primary question** | Is the circuit breaker tripping? Which Foundry region is serving traffic? | Which LOB is calling what, how long did each layer take, am I hitting quota? | What is the platform-wide TPM, RPM, and latency percentile trend? |
| **Data source** | `ApiManagementGatewayLogs`, `AGWAccessLogs` | `AppRequests`, `AppDependencies` (exact join), `AGWAccessLogs` (separate table), `AGWFirewallLogs` | `ApiManagementGatewayLogs`, `AGWAccessLogs` (latency/RPM), `AppRequests` + `AppDependencies` (TPM) |
| **Ingestion delay** | ~30 seconds — unsampled | 2–5 minutes — subject to App Insights sampling | Latency/RPM: ~30 s · TPM: 2–5 min |
| **Granularity** | Aggregate trends; per-switch-event rows | Per-request rows; per-layer waterfall | Time-series trends; no per-request rows |
| **Use for incidents** | Yes — start here (fastest data) | Post-incident root-cause analysis | Capacity planning; sustained load review |
| **Default time range** | Last 1 hour | Last 4 hours | Last 1 hour |
| **Filters** | Time Range, Chart Granularity | Time Range, Subscription (LOB filter), Correlation ID | Time Range, Chart Granularity, Subscription (LOB filter) |

The KQL for every panel is available as standalone `.kql` files in [`KQL/backend-routing-report/`](KQL/backend-routing-report/), [`KQL/e2e-trace/`](KQL/e2e-trace/), and [`KQL/platform-health/`](KQL/platform-health/). Use them to run queries directly in Log Analytics, build alerts, or validate behaviour without opening the workbook UI.

After `azd provision`, find your workbooks in the Azure portal:
**Azure Monitor → Workbooks** — filter by your resource group (`rg-contoso-ai-platform-<env>`). All three workbooks appear with their display names.

---

## Workbook 1 — AppGW → APIM → Foundry Backend Routing Report

**File:** `observability/workbooks/backend-routing-report.workbook.json`

**Use this when:**
- You want to know whether the circuit breaker tripped during a load test or live incident
- You need to see the exact moment traffic shifted from Primary (East US) to Secondary (West US) Foundry
- You are reviewing weekly capacity trends — how much of the traffic went to each backend?
- You are investigating latency differences between primary and secondary Foundry regions

**Data source:** `ApiManagementGatewayLogs` and `AGWAccessLogs` in Log Analytics. These are raw gateway-level logs — every request APIM processes produces a row regardless of whether App Insights is configured. This makes the workbook reliable even if App Insights instrumentation is missing or misconfigured.

**Filters:**

| Filter | Values | Effect |
|---|---|---|
| **Time Range** | 5 min / 15 min / 30 min / 1 hr / 4 hr / 12 hr / 1 day | Scopes every panel |
| **Chart Granularity** | 1 min / 5 min / 15 min / 30 min / 1 hr | Controls the time-bucket width on all charts |

---

### Panel 1 — Traffic Summary (KPI tiles)

**Visualization:** Tiles  
**Data source:** `ApiManagementGatewayLogs`  
**KQL:** [panel-01-traffic-summary.kql](KQL/backend-routing-report/panel-01-traffic-summary.kql)

Four at-a-glance counters for the selected time range:

| Tile | What it counts |
|---|---|
| **Total Requests** | All requests that passed through APIM |
| **Primary Backend** | Requests forwarded to Primary Foundry (East US) |
| **Secondary Backend** | Requests forwarded to Secondary Foundry (West US) — elevated = circuit breaker was open |
| **Backend Errors** | Requests where APIM or Foundry returned 4xx or 5xx (after all retries) |

**Healthy state:** Primary >> Secondary. Secondary count near zero = circuit breaker never tripped. Backend Errors near zero = platform healthy.

---

### Panel 2 — Requests per Backend (area chart)

**Visualization:** Stacked area chart  
**Data source:** `ApiManagementGatewayLogs`  
**Colours:** Green = Primary (East US) · Orange = Secondary (West US) · Blue = No Backend (APIM-rejected)  
**KQL:** [panel-02-routing-timeline.kql](KQL/backend-routing-report/panel-02-routing-timeline.kql)

Shows request volume split by backend per time bucket. A **solid block of orange** with no green underneath means the circuit breaker was fully open — all traffic was failing over to secondary.

**What to look for:**
- A step-change from green to orange → circuit breaker trip event
- Orange staying elevated for many minutes → breaker did not reset (primary is still unhealthy)
- Blue growing alongside orange → quota exhaustion on top of failover (both backends overwhelmed)
- Orange receding and green resuming → successful recovery

---

### Panel 3 — Backend Switch Events (table)

**Visualization:** Table (sortable, filterable)  
**Data source:** `ApiManagementGatewayLogs`  
**KQL:** [panel-03-switch-events.kql](KQL/backend-routing-report/panel-03-switch-events.kql)

Each row is one point where APIM switched from one backend to a different one (compared to the previous request). Rows are ordered most-recent first.

**Direction labels:**

| Label | Meaning |
|---|---|
| 🔴 `Failover: primary → secondary (error re-routed)` | Primary returned 429 or 5xx — circuit breaker tripped and APIM re-routed to secondary |
| 🔴 `Failover: primary → secondary` | Traffic moved to secondary via a mid-request retry (no prior error on this specific request) |
| 🟡 `Recovery attempt: secondary → primary (failed — re-tripped)` | The circuit breaker reset timer fired and APIM tried primary again, but primary rejected with 429 or 5xx — the breaker immediately re-opened |
| 🟢 `Recovery: secondary → primary (successful)` | Circuit breaker reset, APIM tried primary, primary returned 2xx — primary is healthy again |

**Column guide:**

| Column | Description |
|---|---|
| `TimeGenerated` | When the switch occurred |
| `Direction` | One of the four labels above |
| `ResponseCode` | HTTP status the *client* received (after APIM transformation) |
| `BackendResponseCode` | HTTP status Foundry returned to APIM (before transformation) |
| `TotalTime (ms)` | End-to-end time in APIM — colour: green (fast) → red (slow), max 3 000 ms |
| `BackendTime (ms)` | Time APIM waited for Foundry to respond — colour: yellow → orange → red, max 2 000 ms |
| `LastErrorReason` | APIM internal error category if the switch was error-driven |
| `LastErrorMessage` | Human-readable error detail |
| `ApimSubscriptionId` | Which LOB subscription triggered the switch |

**Tip:** A `🟡` row immediately followed by a `🔴` row means the breaker is **flapping** — primary is repeatedly being tried and rejected. This indicates primary Foundry is exhausted but not yet fully unavailable.

---

### Panel 4 — Primary Backend Failures per Minute (bar chart)

**Visualization:** Bar chart (per-minute buckets)  
**Data source:** `ApiManagementGatewayLogs` filtered to `BackendUrl has "primary"` and errors only  
**Colours:** Orange = failure count · Red = circuit breaker threshold (5)  
**KQL:** [panel-04-primary-failures.kql](KQL/backend-routing-report/panel-04-primary-failures.kql)

Shows how many 429 + 5xx responses per minute came back from the Primary Foundry endpoint. The red line at **y = 5** is the circuit breaker threshold from `circuit-breaker-multi-region.xml` — when orange bars exceed red, the breaker trips.

**Always 1-minute buckets** regardless of the Chart Granularity filter (to preserve the accuracy of the threshold comparison).

---

### Panel 5 — Error Rate % by Backend (line chart)

**Visualization:** Line chart  
**Data source:** `ApiManagementGatewayLogs`  
**Colours:** Green = Primary (East US) · Orange = Secondary (West US)  
**KQL:** [panel-05-error-rate.kql](KQL/backend-routing-report/panel-05-error-rate.kql)

Error percentage per time bucket, split by backend. Shows whether secondary is clean after a failover (orange line stays near 0%) or whether it is also overwhelmed (orange line rises too).

A healthy failover pattern: primary error rate spikes → green line rises to 100% → shortly after, orange line stays flat near 0% (secondary absorbing traffic cleanly).

---

### Panel 6 — Full Chain Latency: AppGW → APIM → Foundry (line chart)

**Visualization:** Line chart (side by side with Panel 7)  
**Data source:** `ApiManagementGatewayLogs` joined to `AGWAccessLogs`  
**Colours:** Purple = AppGW · Blue = APIM Total · Green = Backend (Foundry only)  
**KQL:** [panel-06-chain-latency.kql](KQL/backend-routing-report/panel-06-chain-latency.kql)

Six series: P50 and P90 for each of the three layers. Shows end-to-end wall-clock latency as the client experiences it.

**How to diagnose latency spikes:**
- `Backend P50` rises, `APIM Total P50 − Backend P50` stays flat → Foundry is the bottleneck (model under load)
- `APIM Total P50 − Backend P50` rises, `Backend P50` stays flat → APIM policy overhead is the issue (check semantic cache, auth, quota policy)
- `AppGW P50 − APIM Total P50` rises → WAF inspection or TLS renegotiation overhead

---

### Panel 7 — APIM Latency by Backend — P50 / P90 (line chart)

**Visualization:** Line chart (side by side with Panel 6)  
**Data source:** `ApiManagementGatewayLogs` grouped by backend region  
**KQL:** [panel-07-latency-by-backend.kql](KQL/backend-routing-report/panel-07-latency-by-backend.kql)

P50 and P90 total + backend latency, split by Primary vs Secondary. Useful for measuring the cross-region overhead of Secondary (West US) relative to Primary (East US). Typical secondary overhead during failover: +300–500 ms extra due to the additional round-trip to West US.

---

### Panel 8 — Full Request Chain — AppGW → APIM → Foundry (table)

**Visualization:** Table (sortable, filterable), latest 500 requests  
**Data source:** `ApiManagementGatewayLogs`  
**KQL:** [panel-08-request-chain.kql](KQL/backend-routing-report/panel-08-request-chain.kql)

One row per request. All columns needed to trace a specific failure or latency spike.

| Column | Description |
|---|---|
| `TimeGenerated` | Request timestamp |
| `BackendRegion` | ✅ Primary (East US) or ⚠️ Secondary (West US) |
| `FailoverOccurred` | "Yes" if request reached secondary and got HTTP 200 (clean failover) |
| `ApimSubscriptionId` | LOB subscription that made the request |
| `ResponseCode` | Status the client received |
| `BackendResponseCode` | Status Foundry returned |
| `TotalTime (ms)` | Full APIM duration — colour: cold (blue, fast) → hot (red, slow), max 3 000 ms |
| `BackendTime (ms)` | Foundry wait time — colour: yellow → orange → red, max 2 000 ms |
| `IsRequestSuccess` | Boolean — false if APIM returned non-2xx |
| `LastErrorReason / LastErrorMessage` | APIM error details for failed requests |
| `CallerIpAddress` | App Gateway internal IP (10.100.1.x) — identifies the AGW instance |
| `CorrelationId` | Use this to look up the full APIM trace in the E2E Trace workbook |

---

## Workbook 2 — AppGW → APIM → Azure AI Foundry End-to-End Trace

**File:** `observability/workbooks/e2e-trace.workbook.json`

**Use this when:**
- You want to investigate a specific slow or failed request by Correlation ID
- You need per-layer latency percentiles (P50 / P95 / P99) for SLO reporting
- You want to see which models a specific LOB subscription is calling and how often
- You need to check the semantic cache hit rate
- A WAF rule is blocking or matching — you need to know which rule and which URI
- You want to understand the full traffic flow: LOB subscription → APIM product → Foundry backend

**Data source:** `AppRequests` and `AppDependencies` (App Insights, ingested via workspace-based LAW) plus `AGWAccessLogs` and `AGWFirewallLogs`. Requires App Insights to be correctly wired to APIM (the `applicationInsights` diagnostics block in `apim-gateway.bicep`).

> **Note on join accuracy:** AGWAccessLogs has no per-request UUID. Joining it to APIM rows via approximate client IP + 2-second time bucket is unreliable under concurrent load (e.g. a 429 from AGW can appear alongside an APIM 200 for a different request). The E2E Trace workbook therefore keeps these two sources in **separate tables** — an exact APIM + Foundry join (via `Request-X-Correlation-Id`), and a standalone AGW access log.

**Limitation:** App Insights has a 2–5 minute ingestion delay and is subject to sampling under high load. Do not use this workbook for real-time incident response — use the Backend Routing Report instead. Use this workbook for post-incident root-cause analysis.

**Filters:**

| Filter | Values | Effect |
|---|---|---|
| **Time Range** | 5 min / 15 min / 30 min / 1 hr / 4 hr / 1 day | Scopes every panel |
| **Subscription** | All or one of: `app-branch-advisor`, `app-aml-screening`, `app-credit-underwriting`, `app-investment-platform` | Narrows all traffic charts and tables to that LOB |
| **Correlation ID** | Paste a specific `X-Correlation-Id` value | Narrows the trace table and waterfall to one request |

---

### Panel 1 — Traffic Overview (KPI tiles)

**Visualization:** Tiles  
**Data source:** `AppRequests`, `AppDependencies`  
**KQL:** [panel-01-traffic-overview.kql](KQL/e2e-trace/panel-01-traffic-overview.kql)

Four tiles scoped by the Subscription filter:

| Tile | What it shows | Healthy range |
|---|---|---|
| **Total Requests** | Count of APIM-correlated requests in the time range; sub-label = avg APIM latency | Growing or steady |
| **Avg APIM Latency** | Mean time APIM spent per request (policy + Foundry round-trip) | < 1 500 ms normal; < 3 500 ms during failover |
| **Avg Foundry Latency** | Mean model inference time at the Foundry backend | gpt-4o-mini: 400–1 500 ms · gpt-4o: 800–3 000 ms · o1: 2 000–8 000 ms |
| **Failed Requests** | Requests where APIM returned non-2xx after all retries | 0 during normal operation |

Only requests carrying an `X-Correlation-Id` header are counted (App Gateway sets this on every forwarded request; WAF-blocked requests are excluded).

---

### Panel 2 — Requests per Subscription over Time (stacked bar chart)

**Visualization:** Stacked bar chart, 5-minute buckets  
**Data source:** `AppRequests`  
**KQL:** [panel-02-requests-per-subscription.kql](KQL/e2e-trace/panel-02-requests-per-subscription.kql)

Request volume over time, each colour = one APIM subscription (LOB). Tall bars with many colours = sustained concurrent load from multiple LOBs — the scenario that saturates primary Foundry TPM quota.

**What to look for:**
- One subscription suddenly dominating → a LOB is bursting beyond its quota
- Total bar height rising then crashing → failover or quota exhaustion stopping requests

---

### Panel 3 — Subscription → Product → Foundry Routing Summary (table)

**Visualization:** Table  
**Data source:** `AppRequests` (backend region from `Response-X-Backend-Region-Used` response header)  
**KQL:** [panel-03-flow-summary.kql](KQL/e2e-trace/panel-03-flow-summary.kql)

Aggregate flow table: one row per unique combination of (LOB subscription, APIM product tier, Foundry backend).

| Column | Description |
|---|---|
| `Subscription` | LOB APIM subscription name |
| `Product` | Tier colour-coded: 🟤 `ai-bronze` / ⚪ `ai-silver` / 🟡 `ai-gold` |
| `→ Foundry` | Which backend processed these requests |
| `Requests` | Total request count for this combination |
| `Errors` | Failed request count — heat bar (white → red) |
| `Error %` | Error percentage — heat bar (green = 0%, red = 100%) |
| `Avg APIM (ms)` | Mean APIM latency for this route — heat bar (white → orange) |

**"⚠ APIM rejected (no backend reached)"** in the Foundry column means APIM blocked the request before forwarding it. Common causes: quota exceeded, invalid subscription key, policy rejection, or APIM internal error. These requests show near-zero latency (< 5 ms) and 100% error rate.

---

### Panel 4 — Foundry Backend Health (table)

**Visualization:** Table  
**Data source:** `AppRequests` (backend region from `Response-X-Backend-Region-Used`)  
**KQL:** [panel-04-foundry-health.kql](KQL/e2e-trace/panel-04-foundry-health.kql)

One row per Foundry backend — latency percentiles and error rate aggregated across all LOB subscriptions.

| Column | Description |
|---|---|
| `Foundry Backend` | `Primary Foundry (East US)` or `Secondary Foundry (West US)` |
| `Requests` | Total requests routed to this backend |
| `Errors` | Failed count — heat bar |
| `Error %` | 0% = green, 100% = red |
| `Avg (ms)` | Mean latency — blue heat bar, max 5 000 ms |
| `p50 (ms)` | Median latency — blue heat bar, max 5 000 ms |
| `p95 (ms)` | 95th percentile — orange heat bar, max 15 000 ms |
| `p99 (ms)` | 99th percentile — red heat bar, max 30 000 ms |

---

### Panel 5 — Avg Latency per Layer (stacked bar chart)

**Visualization:** Stacked bar chart, 5-minute buckets  
**Data source:** `AppRequests` joined to `AppDependencies`  
**KQL:** [panel-05-avg-latency-per-layer.kql](KQL/e2e-trace/panel-05-avg-latency-per-layer.kql)

Each bar is divided into three stacked segments:

| Segment | Colour | What it measures |
|---|---|---|
| **App GW overhead** | Blue | WAF inspection + TLS termination — currently 0 (join is approximate; see per-request table for accurate values) |
| **APIM overhead** | Orange | Policy execution time: auth, quota check, cache lookup, header injection, logging — should be < 50 ms |
| **Foundry inference** | Green | AI model generation time — dominates for large prompts or slow models |

**Diagnosing spikes:** Orange segment grows → APIM policy is adding latency (check semantic cache miss rate). Green segment grows → Foundry is under load or a more expensive model was called.

---

### Panel 6 — APIM + Foundry Per-Request Trace (table)

**Visualization:** Table, up to 1 000 rows  
**Data source:** `AppRequests` joined to `AppDependencies` via `OperationId` (exact match via `Request-X-Correlation-Id`)  
**KQL:** [panel-06-apim-foundry-trace.kql](KQL/e2e-trace/panel-06-apim-foundry-trace.kql)

Exact per-request join between APIM and Foundry. Every row corresponds to exactly one real request — there is no cross-request contamination. Click any row to populate the **Correlation ID** filter and see that request's waterfall in the drilldown panel.

| Column | Description |
|---|---|
| `Time` | APIM request start time |
| `Corr ID` | `X-Correlation-Id` — click row to filter waterfall |
| `URL` | Full request URL |
| `APIM HTTP` | APIM HTTP status (✅ 2xx / ⚠️ 4xx / ❌ 5xx) |
| `APIM (ms)` | APIM total duration — orange heat bar, max 30 000 ms |
| `Foundry Backend` | ✅ primary or ⚠️ secondary-failover |
| `Foundry HTTP` | Status Foundry returned — icon |
| `Foundry (ms)` | Foundry inference time — green heat bar, max 30 000 ms |
| `Product` | APIM product tier |
| `Subscription` | LOB subscription name |

> AGW data is intentionally not joined here — see the **App Gateway access log** table below.

---

### Panel 6b — App Gateway Access Log (table)

**Visualization:** Table, latest 500 rows  
**Data source:** `AGWAccessLogs`  
**KQL:** [panel-06b-agw-access-log.kql](KQL/e2e-trace/panel-06b-agw-access-log.kql)

Standalone AGW log — every request the gateway received, including those **shed before reaching APIM** (WAF blocks, rate-limit drops). Because AGW has no per-request UUID this data is shown separately rather than joined to the APIM rows above.

**How to use it alongside Panel 6:**  
A request showing a 429 or 403 in this table with no corresponding `Corr ID` in the APIM table = the gateway rejected it before forwarding. A request that appears in both tables (same time window, same client IP) = successful end-to-end flow.

| Column | Description |
|---|---|
| `Time` | AGW log timestamp |
| `AGW HTTP` | HTTP status returned by AGW (✅ 2xx / ⚠️ 4xx / ❌ 5xx) |
| `AGW (ms)` | Time taken at the AGW layer — blue heat bar, max 30 000 ms |
| `Client IP` | Source IP of the caller |
| `URL` | Full request URI |
| `Method` | HTTP method |
| `Rule Hit` | WAF or routing rule that matched |
| `WAF Mode` | Detection or Prevention

---

### Panel 7 — Latency Percentiles by Layer (table)

**Visualization:** Table  
**Data source:** `AppRequests` joined to `AppDependencies`  
**KQL:** [panel-07-latency-percentiles.kql](KQL/e2e-trace/panel-07-latency-percentiles.kql)

P50 / P95 / P99 for three metrics, shown side by side:

| Columns | Colour | Max |
|---|---|---|
| APIM overhead p50 / p95 / p99 | Blue / Orange / Red | — |
| Foundry inference p50 / p95 / p99 | Blue / Orange / Red | — |
| Total APIM p50 / p95 / p99 | Blue / Orange / Red | — |

**Reading tail latency:** A large gap between p50 and p99 on Foundry inference = the model is occasionally slow (prompt length variance, cold start, or throttling). A large p99 on APIM overhead = a policy is occasionally stalling (e.g. a synchronous cache lookup on miss).

---

### Panel 8 — WAF Rule Matches / Blocks (table)

**Visualization:** Table, top 50 rules  
**Data source:** `AGWFirewallLogs`  
**KQL:** [panel-08-waf-rules.kql](KQL/e2e-trace/panel-08-waf-rules.kql)

WAF events from Application Gateway (OWASP CRS 3.2 + Bot Manager). The WAF runs **before** APIM — blocked requests here never reach APIM and will not appear in App Insights.

| Column | Description |
|---|---|
| `Rule Set` | OWASP CRS, Microsoft\_BotManagerRuleSet, etc. |
| `Rule ID` | Specific rule identifier — look up at owasp.org |
| `Message` | Human-readable rule description |
| `Blocked` | Requests actively rejected (HTTP 403) — red heat bar |
| `Matched` | Requests that matched the rule but were allowed through (Detection mode) — orange heat bar |
| `Total` | Total events for this rule |

**False positives:** AI API usage (JSON POST bodies with prompt text) can trigger OWASP rules for SQL injection or XSS on prompt content. Use the Rule ID to determine whether to add an exclusion for the specific URI path (`/openai/deployments/*/chat/completions`).

---

### Panel 9 — Request Routing: Client → APIM → Foundry Backend (table)

**Visualization:** Table, up to 1 000 rows  
**Data source:** `AppRequests` joined to `AppDependencies` and `AGWAccessLogs`  
**Click any row to populate the Correlation ID and drive the waterfall below.**  
**KQL:** [panel-09-request-routing.kql](KQL/e2e-trace/panel-09-request-routing.kql)

| Column | Description |
|---|---|
| `Time` | Request timestamp |
| `Corr ID` | `X-Correlation-Id` — click row to set filter |
| `Client IP` | Source IP from AGW |
| `Product` | Tier colour-coded: 🟤 Bronze / ⚪ Silver / 🟡 Gold |
| `Subscription` | LOB name |
| `→ APIM` | APIM instance link |
| `→ Foundry` | Foundry backend: Primary (East US) or Secondary (West US) |
| `AGW (ms)` | AGW overhead — blue heat bar |
| `APIM ovhd (ms)` | APIM policy overhead (excl. Foundry wait) — orange heat bar |
| `Foundry (ms)` | Foundry inference — green heat bar |
| `Total (ms)` | Full round-trip — yellow → orange → red heat bar |
| `HTTP` | APIM status icon |
| `OK` | Boolean success icon |

---

### Panel 10 — Per-Request Latency Waterfall (horizontal bar chart)

**Visualization:** Horizontal stacked bar chart, up to 50 requests  
**Data source:** `AppRequests` joined to `AppDependencies` and `AGWAccessLogs`  
**KQL:** [panel-10-waterfall-drilldown.kql](KQL/e2e-trace/panel-10-waterfall-drilldown.kql)

Driven by the **Correlation ID** filter. When a Correlation ID is set (by clicking a row in Panel 9, or pasting one), this chart shows the single matching request. When no Correlation ID is set, shows the 50 most recent requests.

Each horizontal bar = one request, divided proportionally into three segments:

| Segment | Colour | What it measures |
|---|---|---|
| **App Gateway (ms)** | Blue | WAF + TLS overhead before the request reached APIM |
| **APIM overhead (ms)** | Orange | Policy execution: auth, quota, logging, header injection (excluding Foundry wait) |
| **Foundry inference (ms)** | Green | AI model generation time |

**Row label format:** `HH:mm:ss [subscription] [product] [→ backend] [total ms]`

Use this chart to compare multiple requests at the same timestamp and immediately see which layer consumed the most time.

---

### Panel 11 — Per-Model Usage Breakdown (table)

**Visualization:** Table  
**Data source:** `AppRequests` (model extracted from the deployment URL path)  
**KQL:** [panel-11-model-usage.kql](KQL/e2e-trace/panel-11-model-usage.kql)

One row per (model, subscription) combination. No policy changes required — the model name is always present in `AppRequests.Url` as `/openai/deployments/<model>/chat/completions`.

| Column | Description |
|---|---|
| `Model` | Deployment name (e.g. `gpt-4o-mini`, `gpt-4o`, `Phi-4`, `Llama-3-70b`) |
| `Subscription` | LOB subscription |
| `Requests` | Total call count |
| `Errors` | Failed calls — ✅ 0 or ❌ > 0 icon |
| `Avg (ms)` | Mean latency — green (fast) → red (slow) |

---

### Panel 12 — Semantic Cache Hit Rate (table)

**Visualization:** Table  
**Data source:** `AppRequests` (requires `X-Cache` response header captured in APIM diagnostics)  
**KQL:** [panel-12-cache-hit-rate.kql](KQL/e2e-trace/panel-12-cache-hit-rate.kql)

> **Prerequisite:** The `X-Cache` header must be captured in the APIM diagnostics `frontend.response.headers` block in `apim-gateway.bicep`. Run `azd provision` once after that change to start populating data.

One row per subscription showing how often the semantic cache served a response vs forwarded to Foundry.

| Column | Description |
|---|---|
| `Subscription` | LOB subscription |
| `Total` | All requests with a cache status header |
| `Cache Hits` | Requests served from cache (X-Cache: HIT) |
| `Cache Misses` | Requests forwarded to Foundry (X-Cache: MISS) |
| `Hit Rate %` | 0% = red, 100% = green |

---

### Panel 13 — Token Quota Utilization (table)

**Visualization:** Table  
**Data source:** `AppRequests` joined to `AppDependencies` (token counts from `Response-Header-X-Tokens-Used`)  
**KQL:** [panel-13-token-quota.kql](KQL/e2e-trace/panel-13-token-quota.kql)

> **Prerequisite:** The `X-Tokens-Used` header must be captured in APIM diagnostics, and the `azure-openai-emit-token-metric` policy must be active. Run `azd provision` once after enabling to start populating data.

One row per subscription showing average TPM consumed vs the product tier cap.

| Column | Description |
|---|---|
| `Subscription` | LOB subscription |
| `Requests` | Total requests in the time window |
| `Total Tokens` | Sum of tokens consumed (prompt + completion) |
| `Avg TPM` | Average tokens per minute over the selected window |
| `TPM Cap` | Product tier limit: Bronze 500 · Silver 5 000 · Gold 5 500 |
| `% of Cap` | `Avg TPM / TPM Cap × 100` — use this to spot subscriptions approaching their quota |

---

## Workbook 3 — Azure AI Platform Health

**File:** `observability/workbooks/platform-health.workbook.json`

**Use this when:**
- You want a rolling time-series view of platform-wide TPM (not just a static average)
- You need to compare total RPM against per-LOB breakdown simultaneously
- You are doing capacity planning and want to see how close the platform is to Foundry's shared 1 000 TPM primary cap
- You want latency percentiles (P50/P95/P99) per layer as trends, not a single aggregate number
- You are reviewing the impact of a model change, traffic shift, or load test across all three metrics

**Data sources:**

| Panel | Source | Ingestion delay |
|---|---|---|
| TPM over time | `AppRequests` + `AppDependencies` (token header) | 2–5 min (App Insights) |
| Overall RPM | `ApiManagementGatewayLogs` | ~30 s (unsampled) |
| RPM by LOB | `ApiManagementGatewayLogs` | ~30 s (unsampled) |
| Latency percentiles | `ApiManagementGatewayLogs` + `AGWAccessLogs` | ~30 s (unsampled) |

**Filters:**

| Filter | Values | Effect |
|---|---|---|
| **Time Range** | 5 min / 15 min / 30 min / 1 hr / 4 hr / 12 hr / 1 day | Scopes every panel |
| **Chart Granularity** | 1 min / 5 min / 15 min / 30 min / 1 hr | Controls time-bucket width; RPM and TPM are normalised to tokens-per-minute equivalent regardless of bucket |
| **Subscription** | All or one LOB | Narrows TPM and RPM panels to that LOB (latency percentile panel shows platform-wide regardless) |

---

### Panel 1 — TPM Over Time (stacked area chart)

**Visualization:** Stacked area chart  
**Data source:** `AppRequests` joined to `AppDependencies`  
**KQL:** [panel-01-tpm-over-time.kql](KQL/platform-health/panel-01-tpm-over-time.kql)

One coloured band per APIM subscription (LOB). TPM is normalised to tokens-per-minute regardless of the bucket width selected.

**Foundry primary cap line: 1 000 TPM** — when combined bands approach this level, expect 429s on the primary backend and circuit-breaker failover to secondary (West US, 30K TPM). Cross-reference with the Backend Routing Report.

| Band | Description |
|---|---|
| Each colour | One APIM subscription (LOB) |
| Combined height | Total platform TPM |

---

### Panel 2a — Overall Platform RPM (line chart)

**Visualization:** Line chart (single series)  
**Data source:** `ApiManagementGatewayLogs`  
**KQL:** [panel-02a-rpm-total.kql](KQL/platform-health/panel-02a-rpm-total.kql)

Total requests/min across all subscriptions, normalised to the selected bucket width. Use alongside the TPM chart: RPM flat + TPM rising = requests using more tokens (larger prompts or longer responses); RPM rising + TPM flat = shorter requests, same aggregate load.

---

### Panel 2b — RPM by LOB Subscription (stacked area chart)

**Visualization:** Stacked area chart  
**Data source:** `ApiManagementGatewayLogs`  
**KQL:** [panel-02b-rpm-by-subscription.kql](KQL/platform-health/panel-02b-rpm-by-subscription.kql)

One coloured band per APIM subscription key, showing how load is distributed across LOBs over time.

**What to look for:**
- A single band dominating → that LOB is close to its product RPM limit
- Multiple bands growing simultaneously → combined load risk on Foundry primary pool

---

### Panel 3 — Latency Percentiles per Layer (multi-line chart)

**Visualization:** Line chart (9 series)  
**Data source:** `ApiManagementGatewayLogs` joined to `AGWAccessLogs` (time-bucket join)  
**KQL:** [panel-03-latency-percentiles-per-layer.kql](KQL/platform-health/panel-03-latency-percentiles-per-layer.kql)

Nine time-series lines: **P50 · P95 · P99** per layer.

| Layer | Colour family | Source | Healthy P99 |
|---|---|---|---|
| **App Gateway WAF** | 🔵 Blue (light→dark) | `AGWAccessLogs.TimeTaken × 1000` | < 200 ms |
| **APIM overhead** | 🟠 Orange (light→dark) | `TotalTime − BackendTime` | < 100 ms |
| **Foundry inference** | 🟢 Green (light→dark) | `BackendTime` | < 3 000 ms (gpt-4o-mini) |

**How to read this chart:**
- P50 and P99 diverging widely = bimodal traffic (cache hits vs cold inference in the same bucket)
- Foundry P99 spike = model cold start or failover latency (+300–500 ms for West US secondary)
- APIM overhead P99 spike = policy stall (semantic cache miss storm, synchronous Key Vault lookup)
- App GW P99 spike = WAF rule firing on a subset of requests — correlate with `AGWFirewallLogs`

> **Join note:** App GW metrics are joined to APIM by time bucket only (no per-request correlation available from `AGWAccessLogs`). The App GW percentile lines are therefore independent aggregates per bucket, not stitched to individual APIM requests. For per-request App GW timing, use the E2E Trace workbook.
