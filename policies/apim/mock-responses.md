# APIM Mock Responses for Load Testing

Mock responses intercept requests in the APIM **inbound** stage and call `return-response`
before the `backend` stage runs. Foundry is never called — zero tokens consumed.

---

## How Mock Responses Work in APIM

```
Client → APIM inbound policy
            ↓
       [mock decision]
       ↙            ↘
return-response    forward to Foundry
(no backend call)  (normal path)
```

All mock techniques use the same two policy primitives:

```xml
<return-response>
    <set-status code="200" reason="OK" />
    <set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header>
    <set-body>/* JSON string here */</set-body>
</return-response>
```

---

## Technique 1 — Unconditional Mock (Always)

Route 100% of traffic to a static mock. No request inspection needed.

```xml
<inbound>
    <base />
    <return-response>
        <set-status code="200" reason="OK" />
        <set-header name="Content-Type" exists-action="override">
            <value>application/json</value>
        </set-header>
        <set-header name="X-Mock-Response" exists-action="override">
            <value>true</value>
        </set-header>
        <set-body>{
  "id": "chatcmpl-mock-001",
  "object": "chat.completion",
  "model": "gpt-4o-mini",
  "choices": [{
    "index": 0,
    "message": { "role": "assistant", "content": "Mock response." },
    "finish_reason": "stop"
  }],
  "usage": { "prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15 }
}</set-body>
    </return-response>
</inbound>
```

**Use when:** token budget is exhausted; smoke-testing APIM policy logic; CI/CD pipeline tests.

---

## Technique 2 — Header-Triggered Mock

Client sends a request header (`X-Use-Mock: true`) to opt into the mock path.
Real traffic without the header flows normally to Foundry.

```xml
<inbound>
    <base />
    <choose>
        <when condition="@(context.Request.Headers.GetValueOrDefault("X-Use-Mock","false") == "true")">
            <return-response>
                <set-status code="200" reason="OK" />
                <set-header name="Content-Type" exists-action="override">
                    <value>application/json</value>
                </set-header>
                <set-header name="X-Mock-Response" exists-action="override">
                    <value>true</value>
                </set-header>
                <set-body>{
  "id": "chatcmpl-mock-001",
  "object": "chat.completion",
  "choices": [{
    "index": 0,
    "message": { "role": "assistant", "content": "Mock response (header-triggered)." },
    "finish_reason": "stop"
  }],
  "usage": { "prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15 }
}</set-body>
            </return-response>
        </when>
    </choose>
</inbound>
```

**JMeter usage:** add HTTP Header Manager with `X-Use-Mock: true` to load test thread groups.
**Production safety:** real LOB apps never send this header → zero risk of accidental mock in prod.

---

## Technique 3 — Product/Subscription-Scoped Mock

Mock only specific APIM products or subscriptions. Useful for isolating Bronze/Silver/Gold
test traffic while keeping Gold on live Foundry.

```xml
<inbound>
    <base />
    <choose>
        <!-- Mock Bronze and Silver load test subscriptions only -->
        <when condition="@(new [] {"app-branch-advisor","app-aml-screening","app-credit-underwriting"}
                            .Contains(context.Subscription?.Name ?? ""))">
            <return-response>
                <set-status code="200" reason="OK" />
                <set-header name="Content-Type" exists-action="override">
                    <value>application/json</value>
                </set-header>
                <set-body>{
  "id": "chatcmpl-mock-001",
  "object": "chat.completion",
  "choices": [{
    "index": 0,
    "message": { "role": "assistant", "content": "Mock response." },
    "finish_reason": "stop"
  }],
  "usage": { "prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15 }
}</set-body>
            </return-response>
        </when>
        <!-- Investment-Platform (Gold) hits real Foundry -->
    </choose>
</inbound>
```

---

## Technique 4 — Request Body-Driven Dynamic Mock

Read values from the request body and reflect them back in the mock response.
This is the most powerful technique — the load test controls the mock output.

### Values you can read from the OpenAI request body

| Request field | C# expression | Example value |
|---|---|---|
| `max_tokens` | `body["max_tokens"]?.Value<int>() ?? 100` | `200` |
| `model` (from URL) | `context.Request.MatchedParameters["deployment-id"]` | `gpt-4o-mini` |
| `messages[last].content` | `body["messages"]?.Last["content"]?.Value<string>()` | `"Hello"` |
| `temperature` | `body["temperature"]?.Value<double>() ?? 1.0` | `0.7` |
| Subscription name | `context.Subscription?.Name` | `app-aml-screening` |
| Product name | `context.Product?.Name` | `ai-silver` |

### Example — echo max_tokens as completion_tokens in usage block

```xml
<inbound>
    <base />
    <set-variable name="requestBody" value="@(context.Request.Body.As<JObject>(preserveContent: true))" />
    <choose>
        <when condition="@(context.Request.Headers.GetValueOrDefault("X-Use-Mock","false") == "true")">
            <return-response>
                <set-status code="200" reason="OK" />
                <set-header name="Content-Type" exists-action="override">
                    <value>application/json</value>
                </set-header>
                <set-body>@{
                    var body   = (JObject)context.Variables["requestBody"];
                    var model  = context.Request.MatchedParameters.GetValueOrDefault("deployment-id", "gpt-4o-mini");
                    var maxTok = body["max_tokens"]?.Value<int>() ?? 100;
                    var prompt = body["messages"]?.Last["content"]?.Value<string>() ?? "";
                    var promptTok = prompt.Length / 4;   // rough token estimate
                    return JsonConvert.SerializeObject(new {
                        id      = "chatcmpl-mock-" + context.RequestId,
                        @object = "chat.completion",
                        model   = model,
                        choices = new[] { new {
                            index         = 0,
                            message       = new { role = "assistant", content = $"Mock reply to: {prompt}" },
                            finish_reason = "stop"
                        }},
                        usage = new {
                            prompt_tokens     = promptTok,
                            completion_tokens = maxTok,
                            total_tokens      = promptTok + maxTok
                        }
                    });
                }</set-body>
            </return-response>
        </when>
    </choose>
</inbound>
```

---

## Technique 5 — Simulated Throttling (Controlled 429s)

Force Foundry-like 429 responses to verify circuit-breaker and retry logic without
consuming any tokens or hitting real quota limits.

```xml
<inbound>
    <base />
    <!-- Inject 429s on ~30% of requests to stress failover policy -->
    <choose>
        <when condition="@(new Random().Next(100) < 30)">
            <return-response>
                <set-status code="429" reason="Too Many Requests" />
                <set-header name="Retry-After" exists-action="override"><value>1</value></set-header>
                <set-header name="Content-Type" exists-action="override">
                    <value>application/json</value>
                </set-header>
                <set-header name="X-Mock-Throttle" exists-action="override">
                    <value>true</value>
                </set-header>
                <set-body>{
  "error": {
    "code": "429",
    "message": "Requests to the ChatCompletions_Create Operation have exceeded token rate limit."
  }
}</set-body>
            </return-response>
        </when>
    </choose>
</inbound>
```

**For this repo:** this replaces the need for real Foundry quota exhaustion to test the
circuit-breaker in `circuit-breaker-multi-region.xml`. The policy sees a 429 from
"Foundry" and increments the failure counter exactly as if it were real.

**Control the throttle rate from JMeter:** pass `X-Mock-Throttle-Rate: 30` header and
read it in the policy:
```xml
<when condition="@{
    var rate = int.Parse(context.Request.Headers
        .GetValueOrDefault("X-Mock-Throttle-Rate", "0"));
    return new Random().Next(100) < rate;
}">
```

---

## Technique 6 — Latency Simulation

Add artificial delay to simulate slow Foundry responses without hitting real backends.
Useful for testing timeout handling, p95/p99 latency budgets, and waterfall chart shape.

```xml
<inbound>
    <base />
    <choose>
        <when condition="@(context.Request.Headers.GetValueOrDefault("X-Use-Mock","false") == "true")">
            <!-- Simulate 800ms Foundry inference latency -->
            <wait duration="800" />
            <return-response>
                <set-status code="200" reason="OK" />
                <set-header name="Content-Type" exists-action="override">
                    <value>application/json</value>
                </set-header>
                <set-body>{ "choices": [{ "message": { "role": "assistant",
                    "content": "Simulated 800ms response." }, "finish_reason": "stop" }],
                    "usage": { "prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15 }
                }</set-body>
            </return-response>
        </when>
    </choose>
</inbound>
```

**Control from JMeter:** pass `X-Mock-Latency-Ms: 1200` and read it in the policy:
```xml
<wait duration="@(int.Parse(context.Request.Headers.GetValueOrDefault("X-Mock-Latency-Ms","0")))" />
```

---

## Technique 7 — Named Value Flag (Environment Switch)

Store a `mock-mode` flag in APIM Named Values (set via Bicep or portal).
Flip the flag to switch all traffic between mock and live without touching the policy XML.

**Step 1 — Add Named Value in Bicep (`apim-gateway.bicep`):**
```bicep
resource mockModeNamedValue 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = {
  parent: apim
  name: 'mock-mode'
  properties: {
    displayName: 'mock-mode'
    value: 'false'         // set to 'true' to enable mock for all requests
    secret: false
  }
}
```

**Step 2 — Read in policy:**
```xml
<inbound>
    <base />
    <choose>
        <when condition="@("{{mock-mode}}" == "true")">
            <return-response>
                <set-status code="200" reason="OK" />
                <set-header name="Content-Type" exists-action="override">
                    <value>application/json</value>
                </set-header>
                <set-body>{ "choices": [{ "message": { "role": "assistant",
                    "content": "Mock mode is ON — no Foundry calls." },
                    "finish_reason": "stop" }],
                    "usage": { "prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15 }
                }</set-body>
            </return-response>
        </when>
    </choose>
</inbound>
```

**Flip via CLI (no redeploy, takes effect in <30 seconds):**
```bash
az apim nv update \
  --service-name apim-contoso-vdls2xyq \
  --resource-group rg-contoso-ai-platform-dev \
  --named-value-id mock-mode \
  --value true
```

---

## Comparison Matrix

| Technique | Token cost | JMeter change needed | Foundry called | Controls 429s | Controls latency | Per-sub scoping |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| 1 — Unconditional | 0 | None | ❌ | ✅ | ✅ | ❌ |
| 2 — Header-triggered | 0 | Add header | ❌ | ✅ | ✅ | ❌ |
| 3 — Product/sub scoped | Mixed | None | Partial | ✅ | ✅ | ✅ |
| 4 — Body-driven dynamic | 0 | Optional | ❌ | ❌ | ❌ | ❌ |
| 5 — Simulated throttling | 0 | Optional header | ❌ | ✅ | ❌ | ✅ |
| 6 — Latency simulation | 0 | Add header | ❌ | ❌ | ✅ | ❌ |
| 7 — Named Value flag | 0 | None | ❌ | ✅ | ✅ | ❌ |

---

## Recommended Combination for This Repo

For **failover load testing without consuming tokens**, combine **Techniques 2 + 5**:

1. JMeter sends `X-Use-Mock: true` on all threads
2. Policy returns 200 for ~70% of requests (mock normal traffic)
3. Policy returns 429 for ~30% of requests (mock Foundry throttling)  
4. Circuit-breaker in `circuit-breaker-multi-region.xml` sees the 429s and trips to secondary
5. `X-Backend-Region-Used` header is still set correctly in outbound → workbook reports correctly
6. Zero Foundry tokens consumed

**Add to `circuit-breaker-multi-region.xml` inbound, before the backend selection block:**
```xml
<!-- LOAD TEST MOCK: intercept before backend selection so X-Backend-Region-Used
     is still set correctly by the outbound stage for workbook accuracy.
     Remove or set X-Use-Mock header to false for production traffic. -->
<choose>
    <when condition="@(context.Request.Headers.GetValueOrDefault("X-Use-Mock","false") == "true")">
        <set-variable name="mockThrottleRate"
            value="@(int.Parse(context.Request.Headers.GetValueOrDefault("X-Mock-Throttle-Rate","0")))" />
        <choose>
            <when condition="@(new Random().Next(100) < (int)context.Variables["mockThrottleRate"])">
                <return-response>
                    <set-status code="429" reason="Too Many Requests" />
                    <set-header name="Retry-After" exists-action="override"><value>1</value></set-header>
                    <set-header name="Content-Type" exists-action="override">
                        <value>application/json</value>
                    </set-header>
                    <set-body>{"error":{"code":"429","message":"Mock throttle."}}</set-body>
                </return-response>
            </when>
            <otherwise>
                <return-response>
                    <set-status code="200" reason="OK" />
                    <set-header name="Content-Type" exists-action="override">
                        <value>application/json</value>
                    </set-header>
                    <set-header name="X-Backend-Region-Used" exists-action="override">
                        <value>primary</value>
                    </set-header>
                    <set-body>{"id":"chatcmpl-mock","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"Mock."},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}</set-body>
                </return-response>
            </otherwise>
        </choose>
    </when>
</choose>
```

**JMeter thread group headers:**
```
X-Use-Mock: true
X-Mock-Throttle-Rate: 30     ← 30% 429s → trips circuit breaker reliably
```
