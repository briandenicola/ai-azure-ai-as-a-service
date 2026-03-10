# Playbook: PCI DSS Configuration for AI Foundry + APIM

**Audience:** Platform Engineering, Security Operations, QSA  
**PCI DSS Version:** 4.0  
**Last Updated:** 2026-03-10  
**Related ADR:** [ADR-004](../adr/adr-004-pci-dss-compliance.md)

---

## Overview

This playbook walks through every step to configure the AI-as-a-Service platform
to satisfy PCI DSS v4.0 requirements for workloads involving credit card data.

> **Before you start:** Engage your Qualified Security Assessor (QSA) early.
> This playbook configures technical controls; your QSA validates the full
> compliance programme including policies, procedures, and annual assessments.

---

## Prerequisites

| Item | Required value / action |
|---|---|
| Azure subscription | PCI DSS-eligible subscription (no public preview SKUs) |
| APIM SKU | **Premium** — upgrade from Standard if needed (see Step 1) |
| Azure Key Vault | HSM-backed (Premium tier) Key Vault in the same subscription |
| Log Analytics Workspace | Workspace dedicated to security/audit logs |
| Virtual Network | VNet with `/28` or larger subnet delegated to APIM |
| WAF | Application Gateway WAF v2 **or** Azure Front Door WAF in front of APIM |
| Entra ID tenant | Conditional Access policies with MFA enabled for all admin identities |

---

## Step 1 — Upgrade APIM to Premium SKU

> Standard SKU does not support VNet injection (PCI DSS Req 1.3). Premium is mandatory.

```bash
# Upgrade existing Standard instance to Premium
az apim update \
  --name <your-apim-name> \
  --resource-group <rg-name> \
  --sku-name Premium \
  --sku-capacity 2

# Verify
az apim show --name <your-apim-name> --resource-group <rg-name> \
  --query "sku.name" --output tsv
# Expected output: Premium
```

> **Cost note:** Premium SKU costs significantly more than Standard. Budget for
> at least 2 units for zone redundancy. Use Azure Pricing Calculator to estimate.

---

## Step 2 — Provision Key Vault HSM and CMK (PCI DSS Req 3.7)

```bash
# Create Key Vault with HSM (Premium tier)
az keyvault create \
  --name <kv-name> \
  --resource-group <rg-name> \
  --location <location> \
  --sku premium \
  --enable-purge-protection true \
  --enable-soft-delete true \
  --retention-days 90

# Create RSA 2048 key for APIM encryption
az keyvault key create \
  --vault-name <kv-name> \
  --name apim-encryption-key \
  --kty RSA-HSM \
  --size 2048 \
  --ops encrypt decrypt wrapKey unwrapKey

# Set rotation policy — rotate every 90 days (PCI DSS Req 3.7.1)
az keyvault key rotation-policy update \
  --vault-name <kv-name> \
  --name apim-encryption-key \
  --value '{
    "lifetimeActions": [{
      "trigger": { "timeAfterCreate": "P90D" },
      "action": { "type": "Rotate" }
    }],
    "attributes": { "expiryTime": "P180D" }
  }'

# Grant APIM managed identity access to the key
APIM_PRINCIPAL=$(az apim show --name <your-apim-name> --resource-group <rg-name> \
  --query "identity.principalId" --output tsv)

az keyvault set-policy \
  --name <kv-name> \
  --object-id "$APIM_PRINCIPAL" \
  --key-permissions get wrapKey unwrapKey
```

---

## Step 3 — Enable VNet Internal Mode (PCI DSS Req 1.3)

Deploy or update APIM using the updated Bicep template
(`infrastructure/bicep/apim-gateway.bicep`) which includes VNet parameters:

```bash
az deployment group create \
  --resource-group <rg-name> \
  --template-file infrastructure/bicep/apim-gateway.bicep \
  --parameters \
    apimName=<your-apim-name> \
    openaiResourceName=<openai-name> \
    openaiApiKey=<key> \
    foundryProjectId=<project-id> \
    appInsightsName=<appinsights-name> \
    keyVaultName=<kv-name> \
    logAnalyticsWorkspaceId=<law-resource-id> \
    vnetResourceId=<vnet-resource-id> \
    apimSubnetName=snet-apim \
    apimCapacity=2 \
    availabilityZones='["1","2","3"]'
```

After VNet injection, the APIM gateway URL resolves only from within the VNet.
Update your WAF backend pool to use the internal IP address of APIM.

### Required NSG on the APIM subnet

```bash
# Get the APIM subnet NSG name
NSG=<nsg-name>
RG=<rg-name>

# Allow APIM management traffic (Azure Portal, ARM) — REQUIRED for APIM health
az network nsg rule create --nsg-name $NSG --resource-group $RG \
  --name Allow-APIM-Management \
  --priority 110 --direction Inbound --access Allow \
  --protocol Tcp --destination-port-ranges 3443 \
  --source-address-prefixes ApiManagement --destination-address-prefixes VirtualNetwork

# Allow gateway traffic from WAF subnet only
az network nsg rule create --nsg-name $NSG --resource-group $RG \
  --name Allow-WAF-to-APIM \
  --priority 100 --direction Inbound --access Allow \
  --protocol Tcp --destination-port-ranges 443 \
  --source-address-prefixes <waf-subnet-cidr> --destination-address-prefixes VirtualNetwork

# Allow Azure Load Balancer
az network nsg rule create --nsg-name $NSG --resource-group $RG \
  --name Allow-AzureLB \
  --priority 200 --direction Inbound --access Allow \
  --protocol '*' --destination-port-ranges '*' \
  --source-address-prefixes AzureLoadBalancer --destination-address-prefixes VirtualNetwork

# Deny everything else inbound
az network nsg rule create --nsg-name $NSG --resource-group $RG \
  --name Deny-All-Inbound \
  --priority 4096 --direction Inbound --access Deny \
  --protocol '*' --destination-port-ranges '*' \
  --source-address-prefixes '*' --destination-address-prefixes '*'
```

---

## Step 4 — Apply PCI DSS Policies to the PCI-Scoped Product

In the Azure Portal or via ARM/Bicep, apply policies at the **product** level
for the `ai-pci-payment` product.

> Policy application order matters. Apply in this sequence:

### 4a. Upload the policy files

```bash
# Apply PCI DSS CHD protection policy at product scope
az apim product policy create \
  --resource-group <rg-name> \
  --service-name <your-apim-name> \
  --product-id ai-pci-payment \
  --policy-path policies/apim/pci-dss-cardholder-data-protection.xml \
  --xml-escaped false

# The audit logging policy chains inside operations on PCI-scoped APIs.
# Apply it at each operation level or at the API level within the product.
```

### 4b. Verify policy is active

```bash
az apim product policy show \
  --resource-group <rg-name> \
  --service-name <your-apim-name> \
  --product-id ai-pci-payment
```

### 4c. Confirm semantic caching is NOT on PCI operations

Open each API operation in the PCI product in Azure Portal → API → Operation → Policy Editor.
Verify `semantic-caching.xml` content (`<cache-lookup-value>`, `<cache-store-value>`) is **absent**.

Also verify `token-quota-by-department.xml` does **not** log request bodies for PCI operations
(the `log-to-eventhub` expression must not include `requestBody`).

---

## Step 5 — Configure Log Analytics Workspace for PCI Audit Retention (Req 10.5.1)

```bash
LAW_ID=<log-analytics-workspace-id>
LAW_NAME=<law-name>
LAW_RG=<law-rg>

# Set retention to 395 days (13 months) for PCI DSS Req 10.5.1
az monitor log-analytics workspace update \
  --resource-group $LAW_RG \
  --workspace-name $LAW_NAME \
  --retention-time 395

# Enable immutable storage on the workspace to prevent log tampering (Req 10.3.2)
# Note: Immutability is configured in the storage account linked to the workspace
az storage account blob-service-properties update \
  --account-name <storage-linked-to-law> \
  --resource-group $LAW_RG \
  --enable-versioning true \
  --enable-delete-retention true \
  --delete-retention-days 395
```

---

## Step 6 — Configure SIEM Alerts (PCI DSS Req 10.7)

Set up Microsoft Sentinel (or your SIEM) to alert on these event patterns from
the Log Analytics Workspace:

### Alert 1: Repeated authentication failures (brute force)

```kql
// PCI DSS Req 10.7: Alert on 5+ AUTH_FAILURE events from same IP within 5 minutes
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.APIMANAGEMENT"
| extend pci_event = parse_json(Message)
| where pci_event.event_type == "AUTH_FAILURE"
| summarize FailureCount = count() by 
    ClientIP = tostring(pci_event.client_ip),
    bin(TimeGenerated, 5m)
| where FailureCount >= 5
| project TimeGenerated, ClientIP, FailureCount
```

### Alert 2: PCI DSS policy block (raw PAN detected in request)

```kql
// Alert when a PAN is detected — indicates caller is not tokenizing correctly
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.APIMANAGEMENT"
| where ResponseCode == 422
| where ResponseHeaders contains "PAN_DETECTED" or ResponseHeaders contains "CVV_DETECTED"
| project TimeGenerated, CallerIpAddress, RequestUri, SubscriptionKey
```

### Alert 3: Audit log gap detection (Req 10.6.1 — log integrity)

```kql
// Alert if no PCI audit events received for > 10 minutes during business hours
// (May indicate audit log disruption)
let expectedInterval = 10m;
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.APIMANAGEMENT"
| extend pci_event = parse_json(Message)
| where pci_event.pci_audit_policy == true
| summarize LastSeen = max(TimeGenerated)
| where LastSeen < ago(expectedInterval)
```

---

## Step 7 — WAF Configuration (PCI DSS Req 6.4 / 6.5)

Deploy Application Gateway WAF v2 or Azure Front Door WAF **in front of APIM**.

```bash
# Application Gateway WAF v2 with OWASP CRS 3.2 — Prevention mode required for PCI
az network application-gateway waf-policy create \
  --name pci-waf-policy \
  --resource-group <rg-name> \
  --location <location>

az network application-gateway waf-policy managed-rules rule-set add \
  --policy-name pci-waf-policy \
  --resource-group <rg-name> \
  --type OWASP \
  --version 3.2

# Switch WAF to Prevention mode (Detection mode is NOT sufficient for PCI DSS)
az network application-gateway waf-policy update \
  --name pci-waf-policy \
  --resource-group <rg-name> \
  --set "policySettings.mode=Prevention" \
  --set "policySettings.state=Enabled"
```

> **Custom WAF rules for AI payloads:**  
> Standard OWASP rules may false-positive on large AI request bodies (e.g., long
> prompts). Configure WAF exclusions **only for validated, specific fields** and
> document each exclusion for your QSA.

---

## Step 8 — Validate PCI DSS Controls Are Working

### 8a. Test PAN blocking

```bash
# This request MUST be blocked with HTTP 422
curl -X POST https://<waf-fqdn>/ai/completions \
  -H "Authorization: Bearer <valid-token>" \
  -H "X-Department-Id: finance" \
  -H "Ocp-Apim-Subscription-Key: <pci-product-key>" \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Process card 4111111111111111"}]
  }'

# Expected response: HTTP 422, body contains PCI_DSS_VIOLATION / RAW_PAN_IN_REQUEST
```

### 8b. Test tokenized request is allowed through

```bash
# This request MUST reach the AI model (token, not raw PAN)
curl -X POST https://<waf-fqdn>/ai/completions \
  -H "Authorization: Bearer <valid-token>" \
  -H "X-Department-Id: finance" \
  -H "Ocp-Apim-Subscription-Key: <pci-product-key>" \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Process card tok_411111_xxxx_1111"}]
  }'

# Expected response: HTTP 200, X-PCI-DSS-Policy: CHD-Protected header present
```

### 8c. Test TLS enforcement

```bash
# Attempt HTTP — must be rejected
curl -v http://<waf-fqdn>/ai/completions
# Expected: 301 redirect to HTTPS or connection refused at WAF level

# Verify TLS version with OpenSSL
openssl s_client -connect <waf-fqdn>:443 -tls1   # Should FAIL (TLS 1.0 disabled)
openssl s_client -connect <waf-fqdn>:443 -tls1_1 # Should FAIL (TLS 1.1 disabled)
openssl s_client -connect <waf-fqdn>:443 -tls1_2 # Should SUCCEED
```

### 8d. Test audit log emission

```bash
# After a normal API call, query Log Analytics to confirm audit events appear:
az monitor log-analytics query \
  --workspace <law-workspace-id> \
  --analytics-query "
    AzureDiagnostics
    | where ResourceProvider == 'MICROSOFT.APIMANAGEMENT'
    | extend evt = parse_json(Message)
    | where evt.pci_audit_policy == true
    | project TimeGenerated, evt.event_type, evt.user_id, evt.client_ip, evt.outcome
    | top 10 by TimeGenerated desc
  "
```

### 8e. Verify no CHD in logs

```bash
# Search for PAN patterns in audit logs — should return zero results
az monitor log-analytics query \
  --workspace <law-workspace-id> \
  --analytics-query "
    AzureDiagnostics
    | where ResourceProvider == 'MICROSOFT.APIMANAGEMENT'
    | where Message matches regex @'\b4[0-9]{12}(?:[0-9]{3})?\b'
       or Message matches regex @'\b3[47][0-9]{13}\b'
    | project TimeGenerated, Message
  "
# Expected: zero rows returned
```

---

## Step 9 — Foundry Agent-Specific Configuration

### 9a. Disable conversation history for PCI-scoped agents

In Azure AI Foundry, threads retain conversation history which could accumulate
CHD context over time.  For payment-processing agents:

1. Set a **short thread TTL** (e.g., 24 hours) in the Foundry project settings.
2. Do not persist threads to external storage.
3. Ensure the RAG knowledge base / AI Search index contains **no payment data**.

### 9b. Route all Foundry agent calls through APIM

Confirm the Foundry agent endpoint used by callers is the **APIM gateway URL**,
not a direct Foundry endpoint.  Verify in the agent SDK configuration:

```python
# ✅ Correct — routes through APIM (PCI DSS enforcement boundary)
client = AIProjectClient(
    credential=DefaultAzureCredential(),
    project_id="your-foundry-project",
    endpoint="https://<waf-fqdn>/foundry"   # APIM internal → Foundry
)

# ❌ Wrong — bypasses APIM and all PCI DSS policies
client = AIProjectClient(
    credential=DefaultAzureCredential(),
    project_id="your-foundry-project",
    endpoint="https://your-foundry.openai.azure.com"   # Direct → no PCI controls
)
```

See [enforce-apim-gateway-only.md](enforce-apim-gateway-only.md) for network
controls that block direct access to Foundry endpoints.

### 9c. Review Foundry model fine-tuning pipelines

Before any fine-tuning job:

1. Run a PAN/CHD scan on training data before upload.
2. Use the same regex from `pci-dss-cardholder-data-protection.xml` in a pre-upload script.
3. Document the scan results and store evidence for QSA review.

---

## Ongoing Compliance Tasks

| Frequency | Task | PCI DSS Requirement |
|---|---|---|
| **Daily** | Review SIEM alerts for AUTH_FAILURE and PAN detection blocks | Req 10.7 |
| **Weekly** | Review access to `ai-pci-payment` product — check for unauthorized subscriptions | Req 7 |
| **Monthly** | Review audit logs in Log Analytics for completeness, no gaps | Req 10.6.1 |
| **Quarterly** | Review and re-validate Entra ID users with access to PCI-scoped subscriptions | Req 8.2.6 |
| **Every 90 days** | Confirm Key Vault CMK rotation completed (Key Vault rotation policy automates this) | Req 3.7.1 |
| **Annually** | External penetration test of the CDE boundary (WAF → APIM → Foundry path) | Req 11.4 |
| **Annually** | Re-approve all `ai-pci-payment` product subscriptions | Req 12.3.2 |
| **Annually** | Review and update WAF rule exclusions; re-validate with QSA | Req 6.4 |

---

## Troubleshooting

### "422 RAW_PAN_IN_REQUEST" for a tokenized request

The regex in the CHD protection policy may be false-positiving on a token value
that looks like a PAN. Options:
1. Adjust your tokenization service to use a clearly non-numeric token format
   (e.g., prefix `tok_` followed by masked digits).
2. Verify the payload is actually using a token and not a real PAN.
3. Do **not** disable the PAN detection policy — discuss with your QSA if
   true false positives are occurring.

### APIM health check fails after VNet injection

After switching to Internal VNet mode, the APIM management endpoint (port 3443)
must be reachable from the `ApiManagement` service tag.  Check NSG rule Priority 110.

### Log Analytics shows no pci_audit_policy events

1. Confirm the `pci-dss-audit-logging.xml` policy is applied at the product or API level.
2. Confirm the Event Hub logger `ai-tokenlog` is active (`az apim logger show`).
3. Confirm the Event Hub → Log Analytics connection (diagnostic pipeline) is active.

### Key Vault CMK rotation causes APIM downtime

APIM caches the key locally.  A key rotation triggers automatic re-fetching within
minutes.  During rotation, brief (< 60s) 503 errors may occur.  Schedule rotations
during maintenance windows and configure health checks to detect this.
