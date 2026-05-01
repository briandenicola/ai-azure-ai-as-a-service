# Infrastructure Setup Guide
# Run these commands to set up everything needed for deployment

# ============================================================================
# STEP 1: Create Service Principal for GitHub Actions (ONE-TIME SETUP)
# ============================================================================

# Set your subscription ID
$SUBSCRIPTION_ID = "your-subscription-id"
$REPO_NAME = "your-github-username/ai-agent-starter"

# Login to Azure
az login

# Set the subscription
az account set --subscription $SUBSCRIPTION_ID

# Create service principal for GitHub Actions with Contributor role
Write-Host "Creating GitHub Actions service principal..." -ForegroundColor Cyan
$SP_JSON = az ad sp create-for-rbac `
  --name "sp-ai-agent-starter-github" `
  --role Contributor `
  --scopes "/subscriptions/$SUBSCRIPTION_ID" `
  --sdk-auth

# Parse the JSON to extract individual values
$SP_OBJ = $SP_JSON | ConvertFrom-Json

# Grant User Access Administrator role for role assignment creation
Write-Host "Adding User Access Administrator role..." -ForegroundColor Cyan
az role assignment create `
  --assignee $SP_OBJ.clientId `
  --role "User Access Administrator" `
  --scope "/subscriptions/$SUBSCRIPTION_ID"

# Display the service principal information
Write-Host "`n==================================================================" -ForegroundColor Green
Write-Host "GitHub Secrets - Service Principal" -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green

# Parse the JSON to extract individual values
$SP_OBJ = $SP_JSON | ConvertFrom-Json

Write-Host "`nAdd these as separate GitHub secrets:" -ForegroundColor Yellow
Write-Host ""
Write-Host "AZURE_CLIENT_ID:" -ForegroundColor Cyan
Write-Host $SP_OBJ.clientId -ForegroundColor White
Write-Host ""
Write-Host "AZURE_CLIENT_SECRET:" -ForegroundColor Cyan
Write-Host $SP_OBJ.clientSecret -ForegroundColor White
Write-Host ""
Write-Host "AZURE_TENANT_ID:" -ForegroundColor Cyan
Write-Host $SP_OBJ.tenantId -ForegroundColor White
Write-Host ""
Write-Host "AZURE_SUBSCRIPTION_ID:" -ForegroundColor Cyan
Write-Host $SP_OBJ.subscriptionId -ForegroundColor White
Write-Host ""
Write-Host "`n==================================================================" -ForegroundColor Green
Write-Host "Repository → Settings → Secrets and variables → Actions → New repository secret" -ForegroundColor Yellow
Write-Host "==================================================================`n" -ForegroundColor Green

# ============================================================================
# STEP 2: Get Azure AI Project Endpoint (if using Azure AI Foundry)
# ============================================================================

Write-Host "`n==================================================================" -ForegroundColor Cyan
Write-Host "Azure AI Project Endpoint Setup" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

# Option A: If you have an existing Azure AI project
Write-Host "`nOption A: List existing Azure AI projects:" -ForegroundColor Yellow
az cognitiveservices account list --query "[?kind=='AIServices'].{Name:name, Endpoint:properties.endpoint}" -o table

# Option B: Create a new Azure AI project (if needed)
Write-Host "`nOption B: Create new Azure AI resource (if needed):" -ForegroundColor Yellow
$AI_RESOURCE_GROUP = "ai-agent-starter-shared-rg"
$AI_RESOURCE_NAME = "ai-agent-starter-openai"
$LOCATION = "eastus"

Write-Host "To create a new Azure OpenAI resource, run:" -ForegroundColor Yellow
Write-Host "az group create --name $AI_RESOURCE_GROUP --location $LOCATION" -ForegroundColor Gray
Write-Host "az cognitiveservices account create \`" -ForegroundColor Gray
Write-Host "  --name $AI_RESOURCE_NAME \`" -ForegroundColor Gray
Write-Host "  --resource-group $AI_RESOURCE_GROUP \`" -ForegroundColor Gray
Write-Host "  --kind OpenAI \`" -ForegroundColor Gray
Write-Host "  --sku S0 \`" -ForegroundColor Gray
Write-Host "  --location $LOCATION" -ForegroundColor Gray

Write-Host "`nThen get the endpoint:" -ForegroundColor Yellow
Write-Host "az cognitiveservices account show \`" -ForegroundColor Gray
Write-Host "  --name $AI_RESOURCE_NAME \`" -ForegroundColor Gray
Write-Host "  --resource-group $AI_RESOURCE_GROUP \`" -ForegroundColor Gray
Write-Host "  --query properties.endpoint \`" -ForegroundColor Gray
Write-Host "  --output tsv" -ForegroundColor Gray

# ============================================================================
# STEP 3: Required GitHub Secrets Summary
# ============================================================================

Write-Host "`n==================================================================" -ForegroundColor Green
Write-Host "Required GitHub Secrets" -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
Write-Host "Add these secrets to your GitHub repository:" -ForegroundColor Yellow
Write-Host ""
Write-Host "Service Principal (from Step 1):" -ForegroundColor Cyan
Write-Host "  - AZURE_CLIENT_ID" -ForegroundColor White
Write-Host "  - AZURE_CLIENT_SECRET" -ForegroundColor White
Write-Host "  - AZURE_TENANT_ID" -ForegroundColor White
Write-Host "  - AZURE_SUBSCRIPTION_ID" -ForegroundColor White
Write-Host ""
Write-Host "Azure AI Configuration:" -ForegroundColor Cyan
Write-Host "  - AZURE_PROJECT_ENDPOINT" -ForegroundColor White
Write-Host "    → Format: https://your-resource.openai.azure.com/" -ForegroundColor Gray
Write-Host ""
Write-Host "  - MODEL_DEPLOYMENT_NAME" -ForegroundColor White
Write-Host "    → Your model deployment name (e.g., 'gpt-4')" -ForegroundColor Gray
Write-Host ""
Write-Host "==================================================================`n" -ForegroundColor Green

# ============================================================================
# STEP 4: Easy Commands to Set GitHub Secrets (using GitHub CLI)
# ============================================================================

Write-Host "`n==================================================================" -ForegroundColor Cyan
Write-Host "Quick Setup with GitHub CLI (optional)" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

Write-Host "`nIf you have GitHub CLI installed, run these commands:" -ForegroundColor Yellow
Write-Host ""
Write-Host "# Navigate to your repository" -ForegroundColor Gray
Write-Host "cd path\to\ai-agent-starter" -ForegroundColor Gray
Write-Host ""
Write-Host "# Set service principal secrets" -ForegroundColor Gray
Write-Host "gh secret set AZURE_CLIENT_ID --body `"<client-id-from-above>`"" -ForegroundColor Gray
Write-Host "gh secret set AZURE_CLIENT_SECRET --body `"<client-secret-from-above>`"" -ForegroundColor Gray
Write-Host "gh secret set AZURE_TENANT_ID --body `"<tenant-id-from-above>`"" -ForegroundColor Gray
Write-Host "gh secret set AZURE_SUBSCRIPTION_ID --body `"<subscription-id-from-above>`"" -ForegroundColor Gray
Write-Host ""
Write-Host "# Set Azure AI secrets" -ForegroundColor Gray
Write-Host "gh secret set AZURE_PROJECT_ENDPOINT --body `"https://your-resource.openai.azure.com/`"" -ForegroundColor Gray
Write-Host "gh secret set MODEL_DEPLOYMENT_NAME --body `"gpt-4`"" -ForegroundColor Gray
Write-Host ""

# ============================================================================
# STEP 5: Verify Setup
# ============================================================================

Write-Host "`n==================================================================" -ForegroundColor Green
Write-Host "Verify Your Setup" -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green

Write-Host "`nBefore deploying, verify:" -ForegroundColor Yellow
Write-Host "[ ] Service principal created" -ForegroundColor White
Write-Host "[ ] GitHub secrets configured:" -ForegroundColor White
Write-Host "    - AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID" -ForegroundColor Gray
Write-Host "    - AZURE_PROJECT_ENDPOINT, MODEL_DEPLOYMENT_NAME" -ForegroundColor Gray
Write-Host "[ ] Azure subscription has required resource providers registered" -ForegroundColor White
Write-Host "[ ] You have Contributor access to the subscription" -ForegroundColor White
Write-Host ""

# Check resource providers
Write-Host "Checking required Azure resource providers..." -ForegroundColor Cyan
$providers = @(
    "Microsoft.App",
    "Microsoft.ContainerRegistry",
    "Microsoft.OperationalInsights",
    "Microsoft.Insights",
    "Microsoft.ManagedIdentity"
)

foreach ($provider in $providers) {
    $state = az provider show --namespace $provider --query "registrationState" -o tsv
    if ($state -eq "Registered") {
        Write-Host "[✓] $provider - Registered" -ForegroundColor Green
    } else {
        Write-Host "[!] $provider - Not Registered (registering...)" -ForegroundColor Yellow
        az provider register --namespace $provider --wait
        Write-Host "[✓] $provider - Registered" -ForegroundColor Green
    }
}

# ============================================================================
# STEP 6: Next Steps
# ============================================================================

Write-Host "`n==================================================================" -ForegroundColor Green
Write-Host "Next Steps - Deploy Infrastructure" -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green

Write-Host "`n1. Push your code to GitHub:" -ForegroundColor Yellow
Write-Host "   git add ." -ForegroundColor Gray
Write-Host "   git commit -m `"Add infrastructure deployment`"" -ForegroundColor Gray
Write-Host "   git push origin main" -ForegroundColor Gray
Write-Host ""

Write-Host "2. Go to GitHub Actions:" -ForegroundColor Yellow
Write-Host "   → Actions tab in your repository" -ForegroundColor Gray
Write-Host "   → Select 'Infrastructure - Deploy to Azure'" -ForegroundColor Gray
Write-Host "   → Click 'Run workflow'" -ForegroundColor Gray
Write-Host "   → Choose environment: dev" -ForegroundColor Gray
Write-Host "   → Choose action: deploy" -ForegroundColor Gray
Write-Host "   → Click 'Run workflow'" -ForegroundColor Gray
Write-Host ""

Write-Host "3. After infrastructure deploys, get the outputs and add to GitHub secrets:" -ForegroundColor Yellow
Write-Host "   AZURE_CONTAINER_REGISTRY" -ForegroundColor Gray
Write-Host "   AZURE_RESOURCE_GROUP" -ForegroundColor Gray
Write-Host "   AZURE_CONTAINER_APP_NAME" -ForegroundColor Gray
Write-Host ""

Write-Host "4. Deploy the application:" -ForegroundColor Yellow
Write-Host "   → Actions → CD - Deploy to Azure Container Apps" -ForegroundColor Gray
Write-Host "   → Run workflow" -ForegroundColor Gray
Write-Host ""

Write-Host "`n==================================================================" -ForegroundColor Green
Write-Host "Setup script complete!" -ForegroundColor Green
Write-Host "==================================================================`n" -ForegroundColor Green
