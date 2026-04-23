# ADR-001: Why Azure API Management as the AI Gateway

**Status:** Accepted  
**Date:** February 2026  
**Supersedes:** N/A

## Context

When deploying Azure AI (LLMs, Agents) to internal developers, IT managers face several challenges:

1. **Uncontrolled costs** - One runaway app can exhaust the entire org's Azure OpenAI quota
2. **Security & compliance** - No centralized audit trail; keys distributed to many teams
3. **Multi-region failover** - Manual retry logic if one region gets rate-limited
4. **Observability** - No single place to see all AI requests across teams
5. **Chargeback** - Hard to track spend by LOB, cost center, application

## Decision

**Use Azure API Management (APIM) as a centralized AI Gateway** in front of all Azure OpenAI and Azure AI Foundry endpoints.

APIM sits between developers and models, providing:
- Rate limiting & quota enforcement per team/app
- Semantic caching (reduce token costs by ~40%)
- Auto-failover across regions
- Centralized audit logging
- Managed Identity auth (no key distribution)
- Request/response transformation

## Alternatives Considered

### ❌ Direct Azure OpenAI Endpoints
**Pros:** Simple, no additional layer
**Cons:** No cost controls, no caching, keys scattered across teams, audit trails fragmented

### ❌ Custom Gateway (Python/Node.js)
**Pros:** Maximum flexibility
**Cons:** High maintenance, duplicate functionality, another service to operate

### ✅ Azure API Management (Chosen)
**Pros:** Enterprise SLA, built-in policies, deep Azure integration, semantic caching, connection pooling
**Cons:** Additional cost (~$100-500/mo depending on tier)

## Consequences

### Positive 🟢

1. **Cost Visibility** - Track every token at APIM layer; set quotas per department
2. **Resilience** - Auto-failover on rate limits without app code changes
3. **Security** - Managed Identity replaces scattered API keys
4. **Compliance** - Audit trail of every request at the gateway layer
5. **Performance** - Semantic caching reduces token consumption for repeated queries
6. **Flexibility** - Swap backend models without changing app code

### Negative 🔴

1. **Added Latency** - ~5-10ms per request (acceptable for AI workloads)
2. **Operational Complexity** - Another service to configure & monitor
3. **Cost** - APIM Premium tier pricing (~$4,000+/month for two units in two regions)
4. **Learning Curve** - Teams need to understand APIM policies

## Implementation

1. Deploy APIM in Premium tier (required for VNet injection and multi-region support)
2. Create three products: `/ai/inference`, `/ai/agents`, `/ai/completions`
3. Configure rate limiting policies (tokens per day per team)
4. Set up semantic caching for model endpoints
5. Enable Application Insights integration
6. Configure failover backends for multi-region support

## Cost Estimate

| Item | Cost/Month |
|------|-----------|
| APIM Premium (2 units × 2 regions) | ~$4,000 |
| Log Analytics (395-day retention) | ~$200 |
| **Total** | **~$4,200** |

*Offset by: semantic caching saving ~30-40% of token costs, eliminating waste from uncontrolled usage*

## How Developers Experience This

❌ **Without APIM:**
```python
from openai import AzureOpenAI
client = AzureOpenAI(
    api_key="very-secret-key-shared-in-slack",
    azure_endpoint="https://my-org-eastus.openai.azure.com"
)
```

✅ **With APIM (This Design):**
```python
from azure.ai.projects import AIProjectClient
client = AIProjectClient(
    credential=DefaultAzureCredential(),  # Your corporate identity
    endpoint="https://my-org-ai.azure-api.net"  # Single gateway
)
```

Developers use their **corporate identity** instead of managing keys.

## Related Decisions

- [ADR-002: Foundry Integration Pattern](adr-002-foundry-integration.md)
- [ADR-003: ServiceNow Provisioning Workflow](adr-003-servicenow-workflow.md)

## References

- [AI Gateway in Azure API Management - Microsoft Learn](https://learn.microsoft.com/azure/api-management/api-management-features#api-gateway)
- [Semantic Caching in APIM](https://learn.microsoft.com/)

---

## Revision History

| Version | Date | Author | Change |
|---------|------|--------|--------|
| 1.0 | Feb 2026 | Platform Team | Initial version |
