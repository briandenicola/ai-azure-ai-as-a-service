# Circuit Breaker Policy - Deployment Guide

## Overview
The circuit breaker policy provides automatic failover between Azure OpenAI regions when the primary endpoint becomes unavailable.

## How It Works

### States
1. **Closed (Normal)**: All traffic goes to primary region
2. **Open (Failing)**: After 5 failures in 5 minutes, traffic routes to secondary region
3. **Half-Open (Recovery)**: After both regions fail, reset counters and retry primary

### Failure Detection
- HTTP 429 (Rate Limit Exceeded)
- HTTP 500 (Internal Server Error)
- HTTP 503 (Service Unavailable)
- Network timeouts

### Recovery
- Successful request resets failure counter
- Counters expire after 5 minutes (auto-recovery)

## Deployment

### Step 1: Configure Backend Endpoints

In the policy XML, update these values:
```xml
<set-variable name="primaryBackend" value="https://YOUR-OPENAI-EASTUS.openai.azure.com" />
<set-variable name="secondaryBackend" value="https://YOUR-OPENAI-WESTUS.openai.azure.com" />
```

### Step 2: Apply via Infrastructure as Code

The circuit breaker policy is referenced in `infrastructure/bicep/apim-gateway.bicep` and applied automatically. To update the policy:

1. Edit `policies/apim/circuit-breaker-multi-region.xml` with your backend endpoint values
2. Run `azd provision` to push the updated policy to Azure

```powershell
azd provision --no-prompt
```

> Do **not** apply policy changes through the Azure Portal — they will be overwritten on the next `azd provision`.

### Step 3: Verify Configuration

Test failover:
```bash
# Normal request (should use primary)
curl -X POST https://YOUR-APIM.azure-api.net/ai/inference/chat/completions \
  -H "Ocp-Apim-Subscription-Key: YOUR-KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4o",
    "messages": [{"role": "user", "content": "Hello"}]
  }' \
  -v

# Check response header: X-Backend-Region-Used should be "primary"

# Simulate primary failure (block network to primary region)
# Next request should automatically use secondary
```

## Monitoring

### Application Insights Queries

**Circuit breaker events:**
```kql
customEvents
| where name == "CircuitBreakerFailure"
| project timestamp, backend, statusCode, failureCount, subscriptionId
| order by timestamp desc
```

**Failover frequency:**
```kql
traces
| where message contains "secondary-failover"
| summarize FailoverCount = count() by bin(timestamp, 5m)
| render timechart
```

**Region distribution:**
```kql
requests
| extend BackendRegion = tostring(customDimensions["X-Backend-Region-Used"])
| summarize Requests = count() by BackendRegion
| render piechart
```

### Grafana Dashboard

Add panel with query:
```
ApiManagementGatewayLogs
| extend Region = tostring(customDimensions['X-Backend-Region-Used'])
| summarize count() by bin(TimeGenerated, 1m), Region
```

## Cost Impact

### Scenario 1: Primary Healthy
- **Cost**: Same as single region
- All traffic to primary, no additional charges

### Scenario 2: Primary Fails (5% of time)
- **Failover traffic**: 5% of requests use secondary
- **Additional cost**: ~5% increase (secondary region charges)
- **Benefit**: High availability maintained

### Scenario 3: Both Regions Fail
- **Graceful degradation**: 503 errors returned to clients
- **Recovery**: Automatic when regions recover

## Tuning Parameters

### Failure Threshold
Default: 5 failures in 5 minutes

To make more sensitive (faster failover):
```xml
<when condition="@((int)context.Variables["primaryFailureCount"] >= 3)">
```

To make less sensitive (avoid premature failover):
```xml
<when condition="@((int)context.Variables["primaryFailureCount"] >= 10)">
```

### Cache Duration
Default: 300 seconds (5 minutes)

To recover faster:
```xml
<cache-store-value key="..." value="0" duration="60" />
```

To allow longer recovery time:
```xml
<cache-store-value key="..." value="0" duration="600" />
```

### Retry Interval
Default: 2 seconds between retries

To retry faster:
```xml
<retry condition="..." count="1" interval="1" first-fast-retry="true">
```

## Best Practices

1. **Deploy Secondary Region**: Ensure both primary and secondary OpenAI resources exist before enabling policy
2. **Test Failover**: Simulate primary failure in non-production environment
3. **Monitor Dashboards**: Set up alerts for high failover rates
4. **Regional Parity**: Deploy same models in both regions (gpt-4o, gpt-4, etc.)
5. **API Keys**: Store both region keys in APIM Named Values (encrypted)

## Troubleshooting

### Issue: Stuck on secondary region
**Cause**: Primary failure counter not resetting  
**Solution**: Manually reset cache or wait 5 minutes

### Issue: Both regions failing
**Cause**: Quota exhausted or service outage  
**Solution**: Check Azure Status page, request quota increase

### Issue: High latency spikes during failover
**Cause**: Cold start on secondary region  
**Solution**: Enable pre-warming on secondary region (configure in `infrastructure/bicep/apim-gateway.bicep`)

## Production Checklist

- [ ] Secondary OpenAI resource deployed
- [ ] Same models available in both regions
- [ ] APIM MSI granted `Cognitive Services User` on both Foundry accounts (see `foundry-apim-rbac.bicep`)
- [ ] Policy applied to AI-Premium product
- [ ] Grafana dashboard configured
- [ ] Alerts set up for high failover rate (>10%)
- [ ] Tested failover in staging environment
- [ ] Documented recovery procedures for DevOps team

## Related Policies

- `token-quota-by-department.xml`: Combine with circuit breaker for quota + failover
- `semantic-caching.xml`: Reduce backend load, improve failover resilience
- `auth-header-validation.xml`: Ensure auth before circuit breaker logic
