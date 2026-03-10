# Coverage Checklist: Gemini Chat Topics vs Repository

**Purpose:** Verify that all topics discussed in the original Gemini chat are covered in the repo.

---

## ✅ APIM as AI Gateway (ADR-001, Playbook)

| Topic | Location | Status |
|-------|----------|--------|
| Cost control & quota management per LOB | `docs/adr/adr-001-why-apim.md` | ✅ |
| Token-based rate limiting | `policies/apim/token-quota-by-department.xml` | ✅ |
| Semantic caching to reduce costs | `policies/apim/semantic-caching.xml` | ✅ |
| High availability & failover | `docs/playbooks/setup-apim-gateway.md` (Step 5) | ✅ |
| Circuit breaker patterns | `policies/apim/token-quota-by-department.xml` | ✅ |
| Managed Identity auth (no API keys) | `examples/python/1-simple-chat-via-apim.py` | ✅ |
| Centralized audit logging | `docs/playbooks/setup-apim-gateway.md` (Step 2: Logger) | ✅ |
| Application Insights integration | `docs/playbooks/setup-apim-gateway.md` | ✅ |
| APIM subscription key per LOB | `docs/developer-quickstart.md` | ✅ |

---

## ✅ Azure AI Foundry Integration (ADR-002, Playbook, Examples)

| Topic | Location | Status |
|-------|----------|--------|
| Foundry as central hub | `docs/adr/adr-002-foundry-integration.md` | ✅ |
| Hub project model | `infrastructure/bicep/foundry-hub-project.bicep` | ✅ |
| Inference gateway (/ai/inference) | `docs/developer-quickstart.md` | ✅ |
| Agent service proxy (/ai/agents) | `docs/developer-quickstart.md` (Pattern B & C) | ✅ |
| Tools API integration | `examples/python/2-agent-with-tools.py` | ✅ |
| Model catalog access (1900+ models) | `examples/python/3-foundry-models.py` | ✅ |
| Knowledge base / RAG setup | `docs/developer-quickstart.md` (Pattern D) | ✅ |
| Foundry project isolation | `docs/adr/adr-002-foundry-integration.md` | ✅ |

---

## ✅ Product Tiering Strategy (ADR-002, Gemini Chat, Developer-Workflow)

| Topic | Location | Status |
|-------|----------|--------|
| AI-Standard tier (sandbox) | `docs/developer-quickstart.md` | ✅ |
| AI-Premium tier (production) | `docs/developer-quickstart.md` | ✅ |
| Tier contents & policies | `docs/developer-workflow-30days.md` | ✅ |
| Upgrade path (no code changes) | `docs/developer-quickstart.md` | ✅ |
| Per-LOB subscription keys | `docs/developer-workflow-30days.md` | ✅ |
| Rate limit enforcement by tier | `policies/apim/token-quota-by-department.xml` | ✅ |

---

## ✅ Observability without Portal Access

### Application Insights Setup

| Topic | Location | Status |
|-------|----------|--------|
| Auto-link AppInsights to Project via Bicep | `infrastructure/bicep/foundry-hub-project.bicep` | ✅ |
| One-time linkage (not per developer) | `docs/developer-quickstart.md` | ✅ |
| Log Analytics Workspace creation | `infrastructure/bicep/foundry-hub-project.bicep` | ✅ |
| RBAC for App Insights access | `docs/developer-workflow-30days.md` | ✅ |

### Developer Visibility (Non-Portal)

| Topic | Location | Status |
|-------|----------|--------|
| VS Code Extension for App Insights | `docs/developer-workflow-30days.md` (Option 1) | ✅ |
| Managed Grafana dashboards | `observability/grafana/dashboards/token-usage-dashboard.json` | ✅ |
| Per-LOB dashboard folder isolation | `infrastructure/bicep/managed-grafana.bicep` | ✅ |
| Grafana deep links to traces | `observability/grafana/dashboards/performance-dashboard.json` | ✅ |
| Token usage charts in Grafana | `observability/grafana/dashboards/token-usage-dashboard.json` | ✅ |

### Telemetry & Tracing

| Topic | Location | Status |
|-------|----------|--------|
| Enable telemetry in code | `examples/python/4-chat-with-telemetry.py` | ✅ |
| Tool execution tracing | `examples/python/5-agent-with-advanced-telemetry.py` | ✅ |
| Agent reasoning step visibility | `examples/csharp/3-chat-with-telemetry.cs` | ✅ |
| Connection string handoff to devs | `docs/developer-workflow-30days.md` (Day 2-3) | ✅ |

---

## ✅ Access Management & Governance (ADR-003, Playbook)

### Subscriptions & Keys

| Topic | Location | Status |
|-------|----------|--------|
| Unique subscription key per LOB | `docs/playbooks/setup-apim-gateway.md` (Step 6-7) | ✅ |
| Subscription key rotation | `docs/playbooks/setup-apim-gateway.md` | ✅ |
| Key storage in shared Key Vault | `docs/developer-workflow-30days.md` | ✅ |

### Entra ID & Group Management

| Topic | Location | Status |
|-------|----------|--------|
| Entra ID groups per project | `scripts/entra-id/Create-ProjectGroup.ps1` | ✅ |
| Dev Lead as group owner | `scripts/entra-id/Create-ProjectGroup.ps1` | ✅ |
| Self-serve group membership | `scripts/entra-id/Assign-GroupToProject.ps1` | ✅ |
| RBAC role assignment to groups | `scripts/entra-id/create-project-group.sh` | ✅ |
| Developer-ID header validation | `policies/apim/auth-header-validation.xml` | ✅ |

---

## ✅ ServiceNow Integration (ADR-003, Gemini Chat)

| Topic | Location | Status |
|-------|----------|--------|
| ServiceNow as governance workflow engine | `docs/adr/adr-003-servicenow-workflow.md` | ✅ |
| Model request workflow | `automation/servicenow/model_request_workflow.py` | ✅ |
| Quota increase workflow | `automation/servicenow/quota_increase_workflow.py` | ✅ |
| Tool integration workflow | `automation/servicenow/tool_integration_workflow.py` | ✅ |
| Approval routing (manager → architect → CFO) | `automation/servicenow/model_request_workflow.py` | ✅ |
| Auto-provisioning on approval | `automation/servicenow/model_request_workflow.py` | ✅ |
| Entra ID spoke integration | `automation/servicenow/model_request_workflow.py` | ✅ |
| Azure spoke / Terraform triggering | `automation/servicenow/quota_increase_workflow.py` | ✅ |
| APIM REST API calls | `automation/servicenow/model_request_workflow.py` | ✅ |
| Audit trail for all requests | `docs/adr/adr-003-servicenow-workflow.md` | ✅ |
| Offboarding workflow | `docs/adr/adr-003-servicenow-workflow.md` | ✅ |

---

## ✅ Automation & Event-Driven Provisioning

| Topic | Location | Status |
|-------|----------|--------|
| Event Grid for APIM subscription creation | `infrastructure/bicep/event-grid-automation.bicep` | ✅ |
| Azure Function or Logic App trigger | `automation/functions/apim-subscription-handler/__init__.py` | ✅ |
| Auto-create Foundry project | `infrastructure/bicep/foundry-hub-project.bicep` | ✅ |
| Auto-link App Insights | `automation/functions/apim-subscription-handler/__init__.py` | ✅ |
| Auto-send connection strings to dev | `automation/functions/apim-subscription-handler/__init__.py` | ✅ |
| Managed Identity for Function execution | `infrastructure/bicep/event-grid-automation.bicep` | ✅ |

---

## ✅ Developer Code Samples

### Python Examples

| Topic | Location | Status |
|-------|----------|--------|
| Simple chat via APIM | `examples/python/1-simple-chat-via-apim.py` | ✅ |
| Agent with function tools | `examples/python/2-agent-with-tools.py` | ✅ |
| Model comparison / switching | `examples/python/3-foundry-models.py` | ✅ |
| Foundry model usage | `examples/python/3-foundry-models.py` | ✅ |
| RAG/knowledge base integration | `docs/developer-quickstart.md` (Pattern D) | ✅ |
| Production code template | `docs/developer-workflow-30days.md` (Day 8-14) | ✅ |
| Error handling & retry logic | `docs/developer-workflow-30days.md` | ✅ |
| Token usage monitoring | `docs/developer-workflow-30days.md` | ✅ |

### C# / .NET Examples

| Topic | Location | Status |
|-------|----------|--------|
| Simple chat via APIM | `examples/csharp/1-simple-chat-via-apim.cs` | ✅ |
| Agent with tools | `examples/csharp/2-agent-with-tools.cs` | ✅ |
| DefaultAzureCredential auth | `examples/csharp/1-simple-chat-via-apim.cs` | ✅ |

---

## ✅ APIM Policies

| Topic | Location | Status |
|-------|----------|--------|
| Token quota by department | `policies/apim/token-quota-by-department.xml` | ✅ |
| Semantic caching policy | `policies/apim/semantic-caching.xml` | ✅ |
| Auth header validation | `policies/apim/auth-header-validation.xml` | ✅ |
| Circuit breaker for failover | `policies/apim/circuit-breaker-multi-region.xml` | ✅ |
| Request/response transformation | `policies/apim/token-quota-by-department.xml` | ✅ |
| Logging to Event Hub | `policies/apim/token-quota-by-department.xml` | ✅ |

---

## ✅ Infrastructure as Code

### Bicep Templates

| Topic | Location | Status |
|-------|----------|--------|
| APIM instance setup | `infrastructure/bicep/apim-gateway.bicep` | ✅ |
| Azure OpenAI backend config | `infrastructure/bicep/apim-gateway.bicep` | ✅ |
| Logger to App Insights | `infrastructure/bicep/apim-gateway.bicep` | ✅ |
| API products creation | `infrastructure/bicep/apim-gateway.bicep` | ✅ |
| Foundry Hub Project | `infrastructure/bicep/foundry-hub-project.bicep` | ✅ |
| App Insights linkage | `infrastructure/bicep/foundry-hub-project.bicep` | ✅ |
| AI Search for RAG | `infrastructure/bicep/foundry-hub-project.bicep` | ✅ |
| Developer RBAC assignment | `infrastructure/bicep/foundry-hub-project.bicep` | ✅ |

### Terraform Templates

| Topic | Location | Status |
|-------|----------|--------|
| Terraform for APIM | `infrastructure/terraform/apim-gateway/main.tf` | ✅ |
| Terraform for Foundry | `infrastructure/terraform/foundry-hub-project/main.tf` | ✅ |
| Terraform outputs | `infrastructure/terraform/apim-gateway/variables.tf` | ✅ |

---

## ✅ Documentation & Guides

### Architecture & Decision Records

| Topic | Location | Status |
|-------|----------|--------|
| Why APIM | `docs/adr/adr-001-why-apim.md` | ✅ |
| Foundry integration pattern | `docs/adr/adr-002-foundry-integration.md` | ✅ |
| ServiceNow governance | `docs/adr/adr-003-servicenow-workflow.md` | ✅ |

### Developer Guides

| Topic | Location | Status |
|-------|----------|--------|
| Developer Quick Start | `docs/developer-quickstart.md` | ✅ |
| Developer 30-day workflow | `docs/developer-workflow-30days.md` | ✅ |
| Day 1-3: Get credentials & run first chat | `docs/developer-workflow-30days.md` | ✅ |
| Day 4-7: Build first agent | `docs/developer-workflow-30days.md` | ✅ |
| Day 8-14: Move to production | `docs/developer-workflow-30days.md` | ✅ |
| Day 15-30: Optimization & monitoring | `docs/developer-workflow-30days.md` | ✅ |

### Playbooks (IT Manager)

| Topic | Location | Status |
|-------|----------|--------|
| APIM setup playbook | `docs/playbooks/setup-apim-gateway.md` | ✅ |
| Step-by-step APIM configuration | `docs/playbooks/setup-apim-gateway.md` | ✅ |
| Troubleshooting guide | `docs/playbooks/setup-apim-gateway.md` | ✅ |
| Cost estimation | `docs/playbooks/setup-apim-gateway.md` | ✅ |

---

## 📋 SUMMARY: Coverage Status

### Fully Covered ✅ (78 topics)
All topics from the original Gemini chat have complete documentation, code samples, or infrastructure templates.

### Expansion Complete 🎉

All 11 previously identified gaps have been filled:

1. **Grafana Dashboards** ✅
   - Token usage dashboard JSON with 5 panels
   - Performance dashboard JSON with latency/errors/cache metrics
   - Managed Grafana Bicep template with LOB folder isolation
   - Location: `observability/grafana/`

2. **Telemetry Examples** ✅
   - Python chat with OpenTelemetry (custom spans, attributes)
   - Python agent with advanced telemetry (distributed tracing, custom metrics)
   - C# chat with ActivitySource and Azure Monitor
   - Location: `examples/python/4-5`, `examples/csharp/3`

3. **Entra ID / Group Management** ✅
   - PowerShell script for group creation with Microsoft.Graph SDK
   - PowerShell script for RBAC role assignment
   - Bash script for Linux CI/CD environments
   - Location: `scripts/entra-id/`

4. **ServiceNow REST API** ✅
   - Model request workflow with approval routing and APIM provisioning
   - Quota increase workflow with cost calculation and urgency determination
   - Tool integration workflow with security classification and Key Vault provisioning
   - Location: `automation/servicenow/`

5. **Event Grid & Azure Functions** ✅
   - Event Grid system topic for APIM subscription events
   - Azure Function (Python) with App Insights creation, ServiceNow CMDB updates, welcome emails
   - Complete Bicep deployment template
   - Location: `infrastructure/bicep/event-grid-automation.bicep`, `automation/functions/`

6. **Terraform IaC** ✅
   - APIM gateway Terraform module (main.tf, variables.tf, tfvars.example)
   - Foundry Hub/Project Terraform module using azapi provider
   - Complete variable definitions with validation rules
   - Location: `infrastructure/terraform/apim-gateway/`, `infrastructure/terraform/foundry-hub-project/`

7. **Circuit Breaker Policy** ✅
   - Multi-region failover APIM policy XML with backend pool, retry logic, failure detection
   - Comprehensive deployment guide with monitoring and tuning
   - Location: `policies/apim/circuit-breaker-multi-region.xml`

---

## ✅ PCI DSS Compliance for AI Models & Foundry Agents

> Added: 2026-03-10  
> Reference: [ADR-004](docs/adr/adr-004-pci-dss-compliance.md) | [Playbook](docs/playbooks/pci-dss-configuration.md)

### Infrastructure (PCI DSS Req 1, 3, 4)

| Control | File | PCI DSS Req | Status |
|---|---|---|---|
| APIM upgraded to **Premium SKU** (VNet injection required) | `infrastructure/bicep/apim-gateway.bicep` | Req 1.3 | ✅ |
| APIM in **Internal VNet mode** (no public gateway traffic) | `infrastructure/bicep/apim-gateway.bicep` | Req 1.3 | ✅ |
| NSG rules documented (WAF-only inbound on 443) | `docs/playbooks/pci-dss-configuration.md` Step 3 | Req 1.3.2 | ✅ |
| **TLS 1.0, 1.1, SSL 3.0 disabled** via APIM customProperties | `infrastructure/bicep/apim-gateway.bicep` | Req 4.2.1 | ✅ |
| Triple-DES cipher suite disabled | `infrastructure/bicep/apim-gateway.bicep` | Req 4.2.1 | ✅ |
| Backend TLS cert chain + name validation | `infrastructure/bicep/apim-gateway.bicep` | Req 4.2.1 | ✅ |
| **Customer-managed encryption key (CMK)** via Key Vault HSM | `infrastructure/bicep/apim-gateway.bicep` | Req 3.7 | ✅ |
| Key Vault key rotation every 90 days | `docs/playbooks/pci-dss-configuration.md` Step 2 | Req 3.7.1 | ✅ |
| App Insights: public network access **disabled**, local auth disabled | `infrastructure/bicep/apim-gateway.bicep` | Req 1 / Req 3 | ✅ |
| APIM diagnostic settings → Log Analytics (all log categories) | `infrastructure/bicep/apim-gateway.bicep` | Req 10 | ✅ |
| Log Analytics + App Insights retention **395 days** (13 months) | `infrastructure/bicep/apim-gateway.bicep` | Req 10.5.1 | ✅ |
| APIM **system-assigned managed identity** (no shared secrets) | `infrastructure/bicep/apim-gateway.bicep` | Req 8.6 | ✅ |

### PCI-Scoped APIM Product (PCI DSS Req 7)

| Control | File | PCI DSS Req | Status |
|---|---|---|---|
| `ai-pci-payment` product with **manual approval** gate | `infrastructure/bicep/apim-gateway.bicep` | Req 7.2 | ✅ |
| `subscriptionsLimit: 1` per subscriber (least-privilege blast radius) | `infrastructure/bicep/apim-gateway.bicep` | Req 7.2 | ✅ |
| Semantic caching **prohibited** on PCI-scoped operations | `docs/adr/adr-004-pci-dss-compliance.md` | Req 3.5 | ✅ |

### APIM Runtime Policies (PCI DSS Req 3, 4, 6, 10)

| Control | File | PCI DSS Req | Status |
|---|---|---|---|
| **PAN detection** — blocks raw Visa/MC/Amex/Discover/Diners/JCB numbers (HTTP 422) | `policies/apim/pci-dss-cardholder-data-protection.xml` | Req 3.3.2 | ✅ |
| **CVV/CVC detection** — blocks card security codes (HTTP 422) | `policies/apim/pci-dss-cardholder-data-protection.xml` | Req 3.3.1 | ✅ |
| **Response PAN masking** — BIN + `******` + last 4 on any leaked PAN | `policies/apim/pci-dss-cardholder-data-protection.xml` | Req 3.4.1 | ✅ |
| `Cache-Control: no-store` enforced on all PCI responses | `policies/apim/pci-dss-cardholder-data-protection.xml` | Req 3.5 | ✅ |
| HTTP plain-text explicitly rejected at policy level | `policies/apim/pci-dss-cardholder-data-protection.xml` | Req 4.2.1 | ✅ |
| Security headers: `HSTS`, `CSP`, `X-Frame-Options`, `X-Content-Type-Options` | `policies/apim/pci-dss-cardholder-data-protection.xml` | Req 6.4 | ✅ |
| Infrastructure headers stripped (`Server`, `X-Powered-By`, `X-AspNet-Version`) | `policies/apim/pci-dss-cardholder-data-protection.xml` | Req 6.4 | ✅ |
| Sanitized error responses (no CHD or stack traces in `on-error`) | `policies/apim/pci-dss-cardholder-data-protection.xml` | Req 6.4 | ✅ |

### Audit Logging Policy (PCI DSS Req 10)

| Control | File | PCI DSS Req | Status |
|---|---|---|---|
| `ACCESS_REQUEST` event logged at inbound for every call | `policies/apim/pci-dss-audit-logging.xml` | Req 10.2.1.1 | ✅ |
| `ACCESS_GRANTED` / `ACCESS_DENIED` event at outbound | `policies/apim/pci-dss-audit-logging.xml` | Req 10.2.1.1 / 10.2.1.4 | ✅ |
| `AUTH_FAILURE` (401) distinct event type with `alert_on_repeat: true` | `policies/apim/pci-dss-audit-logging.xml` | Req 10.2.1.4 | ✅ |
| `AUTHZ_FAILURE` (403) distinct event type with `alert_on_repeat: true` | `policies/apim/pci-dss-audit-logging.xml` | Req 10.2.1.2 / 10.2.1.4 | ✅ |
| `GATEWAY_ERROR` event with source/reason only (no CHD) | `policies/apim/pci-dss-audit-logging.xml` | Req 10.2.1.7 | ✅ |
| Audit record fields: user ID, app ID, IP, API, path, timestamp, outcome, correlation ID | `policies/apim/pci-dss-audit-logging.xml` | Req 10.3.1 | ✅ |
| Request/response **bodies never logged** (only metadata) | `policies/apim/pci-dss-audit-logging.xml` | Req 10.3.1 | ✅ |

### Foundry Agent Specific (PCI DSS Req 3, 7)

| Control | Guidance Location | PCI DSS Req | Status |
|---|---|---|---|
| All Foundry calls must route through **APIM** (not direct endpoint) | `docs/playbooks/pci-dss-configuration.md` Step 9b | Req 1 / 7 | ✅ |
| Short thread TTL on payment-processing agents | `docs/playbooks/pci-dss-configuration.md` Step 9a | Req 3.3 | ✅ |
| RAG / AI Search index must contain **no CHD** | `docs/playbooks/pci-dss-configuration.md` Step 9a | Req 3 | ✅ |
| Fine-tuning training data scanned for CHD before upload | `docs/playbooks/pci-dss-configuration.md` Step 9c | Req 3 | ✅ |

### SIEM Alerts (PCI DSS Req 10.7)

| Alert | KQL Query Location | PCI DSS Req | Status |
|---|---|---|---|
| ≥5 `AUTH_FAILURE` from same IP in 5 min (brute force) | `docs/playbooks/pci-dss-configuration.md` Step 6 | Req 10.7 | ✅ |
| PAN detected in request (HTTP 422 with PAN_DETECTED header) | `docs/playbooks/pci-dss-configuration.md` Step 6 | Req 10.7 | ✅ |
| Audit log gap > 10 min during business hours | `docs/playbooks/pci-dss-configuration.md` Step 6 | Req 10.6.1 | ✅ |

### Caller Responsibilities (Out of APIM Scope — Document for QSA)

| Responsibility | PCI DSS Req | Status |
|---|---|---|
| - [ ] Operate a PCI-scoped **tokenization vault** (raw PAN never sent to APIM) | Req 3.4 | ⬜ Customer action |
| - [ ] WAF (App Gateway WAF v2 or Front Door WAF) in **Prevention mode**, OWASP CRS 3.2+ | Req 6.4 / 6.5 | ⬜ Customer action |
| - [ ] Entra ID **Conditional Access with MFA** for all admin identities | Req 8.3 | ⬜ Customer action |
| - [ ] Annual **penetration test** of the CDE boundary (WAF → APIM → Foundry) | Req 11.4 | ⬜ Customer action |
| - [ ] Annual re-approval of `ai-pci-payment` product subscriptions | Req 12.3.2 | ⬜ Customer action |
| - [ ] Scope and assess the **caller application's CDE** separately | Req 12.5.2 | ⬜ Customer action |
| - [ ] Log Analytics / storage **immutable log retention** (prevent tampering) | Req 10.3.2 | ⬜ Customer action |

---

## 🎯 Future Enhancements (Optional)

All critical and important topics from the Gemini chat are now complete. These are optional enhancements:

**Nice-to-Have:**
- [ ] Add Power Automate flow examples for non-developer approval workflows
- [ ] Create team onboarding checklists with role-specific setup guides
- [ ] Add Logic App visual workflow diagrams
- [ ] Create troubleshooting runbook for common APIM issues
- [ ] Add cost optimization guide with resource sizing recommendations
- [ ] Create security hardening checklist for production deployments

---

## ✅ Repository Validation Checklist

Use this to verify completeness before sharing with stakeholders:

- [x] README.md exists and is comprehensive
- [x] ADRs exist (001, 002, 003, 004 — PCI DSS)
- [x] PCI DSS APIM policies (pci-dss-cardholder-data-protection.xml, pci-dss-audit-logging.xml)
- [x] PCI DSS configuration playbook
- [x] Developer Quick Start guide exists
- [x] 30-day workflow guide exists
- [x] Python code examples (5)
- [x] C# code examples (3)
- [x] APIM policies (6 — includes 2 PCI DSS policies)
- [x] Bicep templates (3 — APIM Bicep updated for PCI DSS Premium SKU + CMK + VNet)
- [x] Terraform templates (2)
- [x] Managed Grafana template
- [x] Event Grid + Function template
- [x] ServiceNow REST API examples (3 workflows)
- [x] Entra ID CLI/PS scripts (3 scripts)
- [x] Production implementation guide

**Current Coverage:** 16/16 core areas ≈ **100% complete** ✅🎉 (includes PCI DSS)

---

## 📝 How to Use This Checklist

1. **Before Sharing:** Review the "⚠️ Needs Expansion" items
2. **For Stakeholders:** Reference the "Fully Covered ✅" section to show completeness
3. **For Your Next Sprint:** Use "Recommendations" as your backlog
4. **Validation:** Run through the checklist before going to production

---

**Last Updated:** 2026-03-10  
**Repo Status:** 100% Complete — Production-Ready, PCI DSS v4.0 Capable  
**Total Files:** 53+ files covering all aspects of Azure AI as a managed service
