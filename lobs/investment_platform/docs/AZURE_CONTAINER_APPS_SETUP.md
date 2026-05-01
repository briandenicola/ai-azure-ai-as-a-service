# Azure Container Apps Deployment Setup

This guide walks you through setting up Azure Container Apps deployment for the AI Agent Starter.

## Prerequisites

- Azure subscription
- Azure CLI installed
- GitHub repository with Actions enabled

## 1. Create Azure Resources

```bash
# Set variables
RESOURCE_GROUP="ai-agent-starter-rg"
LOCATION="eastus"
CONTAINER_APP_NAME="ai-agent-starter"
CONTAINER_REGISTRY="aiagentstarteracr"
CONTAINER_ENV="ai-agent-env"

# Login to Azure
az login

# Create resource group
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION

# Create Azure Container Registry
az acr create \
  --resource-group $RESOURCE_GROUP \
  --name $CONTAINER_REGISTRY \
  --sku Basic \
  --admin-enabled true

# Get ACR credentials
ACR_USERNAME=$(az acr credential show --name $CONTAINER_REGISTRY --query username -o tsv)
ACR_PASSWORD=$(az acr credential show --name $CONTAINER_REGISTRY --query passwords[0].value -o tsv)

# Create Container Apps environment
az containerapp env create \
  --name $CONTAINER_ENV \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION

# Create Container App
az containerapp create \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --environment $CONTAINER_ENV \
  --image mcr.microsoft.com/azuredocs/containerapps-helloworld:latest \
  --target-port 8989 \
  --ingress external \
  --registry-server $CONTAINER_REGISTRY.azurecr.io \
  --registry-username $ACR_USERNAME \
  --registry-password $ACR_PASSWORD \
  --cpu 1.0 \
  --memory 2.0Gi \
  --min-replicas 1 \
  --max-replicas 5
```

## 2. Configure GitHub Secrets

Go to your GitHub repository → Settings → Secrets and variables → Actions

Add the following secrets:

### Required Secrets

```bash
# Get service principal (for GitHub Actions to access Azure)
az ad sp create-for-rbac \
  --name "github-actions-ai-agent-starter" \
  --role contributor \
  --scopes /subscriptions/{subscription-id}/resourceGroups/$RESOURCE_GROUP \
  --sdk-auth
```

Copy the entire JSON output and add as `AZURE_CREDENTIALS`

### Registry Credentials

```bash
AZURE_REGISTRY_USERNAME: <from ACR_USERNAME above>
AZURE_REGISTRY_PASSWORD: <from ACR_PASSWORD above>
```

### Application Secrets

```bash
AZURE_PROJECT_ENDPOINT: <Your Azure AI Project endpoint>
MODEL_DEPLOYMENT_NAME: <Your model deployment name, e.g., gpt-4>
```

### GitHub Token (optional)

```bash
GH_TOKEN: <GitHub personal access token for GitHub API access>
```

## 3. GitHub Secrets Summary

| Secret Name | Description | Example |
|-------------|-------------|---------|
| `AZURE_CREDENTIALS` | Service principal JSON | `{"clientId": "...", ...}` |
| `AZURE_REGISTRY_USERNAME` | ACR username | `aiagentstarteracr` |
| `AZURE_REGISTRY_PASSWORD` | ACR password | `***` |
| `AZURE_PROJECT_ENDPOINT` | Azure AI endpoint | `https://...cognitiveservices.azure.com` |
| `MODEL_DEPLOYMENT_NAME` | Model name | `gpt-4` |
| `GH_TOKEN` | GitHub token (optional) | `ghp_***` |

## 4. Update Workflow Variables

Edit `.github/workflows/deploy.yml` if needed:

```yaml
env:
  AZURE_CONTAINER_APP_NAME: ai-agent-starter        # Your container app name
  AZURE_RESOURCE_GROUP: ai-agent-starter-rg         # Your resource group
  AZURE_CONTAINER_REGISTRY: aiagentstarteracr       # Your ACR name (without .azurecr.io)
  AZURE_LOCATION: eastus                            # Your Azure region
  IMAGE_NAME: ai-agent-starter                      # Docker image name
```

## 5. Deploy

### Automatic Deployment (on push to main)

```bash
git add .
git commit -m "Deploy to Azure Container Apps"
git push origin main
```

### Manual Deployment

Go to GitHub → Actions → "CD - Deploy to Azure Container Apps" → Run workflow

## 6. Verify Deployment

```bash
# Get Container App URL
az containerapp show \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --query properties.configuration.ingress.fqdn \
  --output tsv

# Test the deployment
FQDN=$(az containerapp show --name $CONTAINER_APP_NAME --resource-group $RESOURCE_GROUP --query properties.configuration.ingress.fqdn -o tsv)

curl https://$FQDN/health
curl https://$FQDN/agent_status
```

## 7. Monitor and Manage

### View logs

```bash
# Stream logs
az containerapp logs show \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --follow

# View recent logs
az containerapp logs show \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --tail 100
```

### Scale the app

```bash
# Manual scale
az containerapp update \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --min-replicas 2 \
  --max-replicas 10

# View current scale
az containerapp show \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --query properties.template.scale
```

### View revisions

```bash
# List all revisions
az containerapp revision list \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --output table

# Activate a specific revision (rollback)
az containerapp revision activate \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --revision <revision-name>
```

## 8. Configure Custom Domain (Optional)

```bash
# Add custom domain
az containerapp hostname add \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --hostname api.yourdomain.com

# Bind certificate
az containerapp hostname bind \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --hostname api.yourdomain.com \
  --certificate <certificate-id>
```

## 9. Set Up Monitoring

```bash
# Enable Application Insights
az monitor app-insights component create \
  --app ai-agent-starter-insights \
  --location $LOCATION \
  --resource-group $RESOURCE_GROUP

# Get instrumentation key
INSTRUMENTATION_KEY=$(az monitor app-insights component show \
  --app ai-agent-starter-insights \
  --resource-group $RESOURCE_GROUP \
  --query instrumentationKey -o tsv)

# Add to Container App
az containerapp update \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --set-env-vars "APPLICATIONINSIGHTS_CONNECTION_STRING=InstrumentationKey=$INSTRUMENTATION_KEY"
```

## 10. Cost Management

Azure Container Apps pricing is based on:
- vCPU and memory allocation
- Number of requests
- Execution time

### Estimated Costs (as of 2026)

- **Development:** $10-30/month (1 vCPU, 2GB RAM, low traffic)
- **Production:** $50-200/month (2 vCPU, 4GB RAM, moderate traffic)

### Cost Optimization

```bash
# Set minimum replicas to 0 for dev environments
az containerapp update \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --min-replicas 0

# Use smaller resource allocation
az containerapp update \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --cpu 0.5 \
  --memory 1.0Gi
```

## Features

### ✅ Enabled

- **Auto-scaling:** 1-5 replicas based on load
- **HTTPS ingress:** External access with automatic TLS
- **Container registry:** Azure Container Registry integration
- **Health checks:** Automatic health monitoring
- **Revisions:** Multiple versions with traffic splitting
- **Rollback:** Automatic rollback on deployment failure
- **CI/CD:** GitHub Actions integration

### 🔧 Configuration

Edit environment variables in Container App:

```bash
az containerapp update \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --set-env-vars \
    "AZURE_PROJECT_ENDPOINT=https://..." \
    "MODEL_DEPLOYMENT_NAME=gpt-4" \
    "SERVER_PORT=8989"
```

## Troubleshooting

### Deployment fails

```bash
# Check container app status
az containerapp show \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --query properties.runningStatus

# View error logs
az containerapp logs show \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --tail 50
```

### Health check fails

1. Check logs for errors
2. Verify environment variables are set
3. Test `/health` endpoint locally with Docker
4. Ensure port 8989 is exposed

### Registry authentication issues

```bash
# Re-enable admin user
az acr update \
  --name $CONTAINER_REGISTRY \
  --admin-enabled true

# Get new credentials
az acr credential show --name $CONTAINER_REGISTRY

# Update GitHub secrets
```

## Resources

- [Azure Container Apps Documentation](https://docs.microsoft.com/azure/container-apps/)
- [GitHub Actions for Azure](https://github.com/Azure/actions)
- [Azure CLI Reference](https://docs.microsoft.com/cli/azure/)
- [Container Apps Pricing](https://azure.microsoft.com/pricing/details/container-apps/)
