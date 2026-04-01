# GitHub Copilot Instructions

## Infrastructure-as-Code: No Manual Azure Changes

**ALL changes to Azure resources MUST go through `azd deploy` or `azd provision`.**

This project uses Azure Developer CLI (`azd`) with Bicep (`infrastructure/bicep/`) as the single source of truth for all Azure infrastructure and application deployments. Manual one-off changes made directly in the Azure Portal, via `az` CLI resource mutations, or any other out-of-band method will drift from the declared state and will be overwritten on the next provision.

### Rules

1. **Never suggest `az resource update`, `az storage account update`, `az functionapp config`, or similar mutating `az` commands as a fix.** If a resource is misconfigured, find the correct Bicep file in `infrastructure/bicep/` and fix it there, then run `azd provision`.

2. **Never suggest Portal changes.** If a setting needs changing, it goes in Bicep.

3. **Application code changes** → `azd deploy` (re-packages and deploys the Function App zip)

4. **Infrastructure changes** (APIM policies, networking, storage, RBAC, app settings) → edit the relevant Bicep file, then `azd provision`.

5. **Policy changes** (APIM XML policies in `policies/apim/`) → Bicep references them; run `azd provision` to push updates.

6. **RBAC assignments** → defined in `infrastructure/bicep/foundry-apim-rbac.bicep` or `event-grid-automation.bicep`. Do not assign roles ad hoc with `az role assignment create` as a permanent fix.

### Key files

| What to change | File |
|---|---|
| Function App, storage, Event Grid | `infrastructure/bicep/event-grid-automation.bicep` |
| APIM gateway, products, subscriptions | `infrastructure/bicep/apim-gateway.bicep` |
| Networking, private endpoints | `infrastructure/bicep/networking.bicep` |
| RBAC for Foundry / APIM | `infrastructure/bicep/foundry-apim-rbac.bicep` |
| Key Vault, supporting resources | `infrastructure/bicep/supporting-infra.bicep` |
| Top-level wiring | `infrastructure/bicep/main.bicep` |

### Deploy commands

```bash
# Deploy application code only (fast)
azd deploy

# Provision infrastructure (Bicep) + deploy code
azd provision && azd deploy

# Full up (provision + deploy in one command)
azd up
```

### When diagnosing a broken deployment

Before suggesting an `az` CLI mutation as a fix:
1. Check whether the Bicep already declares the correct value.
2. If yes → the Azure resource has drifted. Run `azd provision` to reconcile — do not patch Azure directly.
3. If no → update the Bicep, commit, then run `azd provision`.

> **Example of what NOT to do**: `az storage account update --public-network-access Enabled`  
> **Correct approach**: Verify `event-grid-automation.bicep` has `publicNetworkAccess: 'Enabled'`, commit if needed, run `azd provision`.
