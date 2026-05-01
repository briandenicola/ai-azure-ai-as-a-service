#!/bin/bash
# Infrastructure Setup Guide
# Run this script to set up everything needed for deployment

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ============================================================================
# STEP 1: Create Service Principal for GitHub Actions (ONE-TIME SETUP)
# ============================================================================

echo -e "${CYAN}============================================================================${NC}"
echo -e "${CYAN}STEP 1: Create Service Principal for GitHub Actions${NC}"
echo -e "${CYAN}============================================================================${NC}"

# Prompt for subscription ID
read -p "Enter your Azure Subscription ID: " SUBSCRIPTION_ID
read -p "Enter your GitHub repository (username/repo): " REPO_NAME

# Login to Azure
echo -e "${YELLOW}Logging in to Azure...${NC}"
az login

# Set the subscription
az account set --subscription "$SUBSCRIPTION_ID"

# Create service principal for GitHub Actions
echo -e "${CYAN}Creating GitHub Actions service principal...${NC}"
SP_JSON=$(az ad sp create-for-rbac \
  --name "sp-ai-agent-starter-github" \
  --role Contributor \
  --scopes "/subscriptions/$SUBSCRIPTION_ID" \
  --sdk-auth)

# Parse JSON and extract values
CLIENT_ID=$(echo "$SP_JSON" | grep -o '"clientId": "[^"]*' | cut -d'"' -f4)
CLIENT_SECRET=$(echo "$SP_JSON" | grep -o '"clientSecret": "[^"]*' | cut -d'"' -f4)
TENANT_ID=$(echo "$SP_JSON" | grep -o '"tenantId": "[^"]*' | cut -d'"' -f4)
SUBSCRIPTION_ID=$(echo "$SP_JSON" | grep -o '"subscriptionId": "[^"]*' | cut -d'"' -f4)

# Grant User Access Administrator role for role assignment creation
echo -e "${CYAN}Adding User Access Administrator role...${NC}"
az role assignment create \
  --assignee "$CLIENT_ID" \
  --role "User Access Administrator" \
  --scope "/subscriptions/$SUBSCRIPTION_ID"

# Display the service principal information
echo -e "${GREEN}==================================================================${NC}"
echo -e "${GREEN}GitHub Secrets - Service Principal${NC}"
echo -e "${GREEN}==================================================================${NC}"

# Parse JSON and extract values
CLIENT_ID=$(echo "$SP_JSON" | grep -o '"clientId": "[^"]*' | cut -d'"' -f4)
CLIENT_SECRET=$(echo "$SP_JSON" | grep -o '"clientSecret": "[^"]*' | cut -d'"' -f4)
TENANT_ID=$(echo "$SP_JSON" | grep -o '"tenantId": "[^"]*' | cut -d'"' -f4)
SUBSCRIPTION_ID=$(echo "$SP_JSON" | grep -o '"subscriptionId": "[^"]*' | cut -d'"' -f4)

echo -e "\n${YELLOW}Add these as separate GitHub secrets:${NC}\n"
echo -e "${CYAN}AZURE_CLIENT_ID:${NC}"
echo -e "${NC}$CLIENT_ID${NC}"
echo ""
echo -e "${CYAN}AZURE_CLIENT_SECRET:${NC}"
echo -e "${NC}$CLIENT_SECRET${NC}"
echo ""
echo -e "${CYAN}AZURE_TENANT_ID:${NC}"
echo -e "${NC}$TENANT_ID${NC}"
echo ""
echo -e "${CYAN}AZURE_SUBSCRIPTION_ID:${NC}"
echo -e "${NC}$SUBSCRIPTION_ID${NC}"
echo ""
echo -e "${GREEN}==================================================================${NC}"
echo -e "${YELLOW}Repository → Settings → Secrets and variables → Actions → New repository secret${NC}"
echo -e "${GREEN}==================================================================${NC}"

# Save individual values for later use
cat > sp-credentials.txt <<EOF
AZURE_CLIENT_ID=$CLIENT_ID
AZURE_CLIENT_SECRET=$CLIENT_SECRET
AZURE_TENANT_ID=$TENANT_ID
AZURE_SUBSCRIPTION_ID=$SUBSCRIPTION_ID
EOF

echo -e "${GREEN}[✓] Saved to: sp-credentials.txt${NC}"

# ============================================================================
# STEP 2: Get Azure AI Project Endpoint
# ============================================================================

echo -e "\n${CYAN}============================================================================${NC}"
echo -e "${CYAN}STEP 2: Azure AI Project Endpoint Setup${NC}"
echo -e "${CYAN}============================================================================${NC}"

echo -e "\n${YELLOW}Option A: List existing Azure AI projects:${NC}"
az cognitiveservices account list --query "[?kind=='AIServices' || kind=='OpenAI'].{Name:name, Endpoint:properties.endpoint}" -o table

echo -e "\n${YELLOW}Option B: Create new Azure AI resource (if needed):${NC}"
read -p "Do you want to create a new Azure OpenAI resource? (y/N): " CREATE_AI

if [[ "$CREATE_AI" =~ ^[Yy]$ ]]; then
    AI_RESOURCE_GROUP="ai-agent-starter-shared-rg"
    AI_RESOURCE_NAME="ai-agent-starter-openai"
    LOCATION="eastus"
    
    echo -e "${CYAN}Creating resource group...${NC}"
    az group create --name "$AI_RESOURCE_GROUP" --location "$LOCATION"
    
    echo -e "${CYAN}Creating Azure OpenAI resource (this may take a few minutes)...${NC}"
    az cognitiveservices account create \
      --name "$AI_RESOURCE_NAME" \
      --resource-group "$AI_RESOURCE_GROUP" \
      --kind OpenAI \
      --sku S0 \
      --location "$LOCATION"
    
    ENDPOINT=$(az cognitiveservices account show \
      --name "$AI_RESOURCE_NAME" \
      --resource-group "$AI_RESOURCE_GROUP" \
      --query properties.endpoint \
      --output tsv)
    
    echo -e "${GREEN}[✓] Azure OpenAI Endpoint: $ENDPOINT${NC}"
else
    read -p "Enter your Azure OpenAI endpoint URL: " ENDPOINT
fi

# ============================================================================
# STEP 3: Model Deployment
# ============================================================================

echo -e "\n${CYAN}============================================================================${NC}"
echo -e "${CYAN}STEP 3: Model Deployment Name${NC}"
echo -e "${CYAN}============================================================================${NC}"

read -p "Enter your model deployment name (default: gpt-4): " MODEL_NAME
MODEL_NAME=${MODEL_NAME:-gpt-4}

# ============================================================================
# STEP 4: Register Required Resource Providers
# ============================================================================

echo -e "\n${CYAN}============================================================================${NC}"
echo -e "${CYAN}STEP 4: Registering Required Resource Providers${NC}"
echo -e "${CYAN}============================================================================${NC}"

PROVIDERS=(
    "Microsoft.App"
    "Microsoft.ContainerRegistry"
    "Microsoft.OperationalInsights"
    "Microsoft.Insights"
    "Microsoft.ManagedIdentity"
)

for PROVIDER in "${PROVIDERS[@]}"; do
    STATE=$(az provider show --namespace "$PROVIDER" --query "registrationState" -o tsv)
    if [ "$STATE" == "Registered" ]; then
        echo -e "${GREEN}[✓] $PROVIDER - Registered${NC}"
    else
        echo -e "${YELLOW}[!] $PROVIDER - Not Registered (registering...)${NC}"
        az provider register --namespace "$PROVIDER" --wait
        echo -e "${GREEN}[✓] $PROVIDER - Registered${NC}"
    fi
done

# ============================================================================
# STEP 5: GitHub Secrets Setup
# ============================================================================

echo -e "\n${GREEN}============================================================================${NC}"
echo -e "${GREEN}Required GitHub Secrets${NC}"
echo -e "${GREEN}============================================================================${NC}"
echo -e "${YELLOW}Add these secrets to your GitHub repository:${NC}\n"

echo -e "${CYAN}Service Principal (from Step 1):${NC}"
echo -e "  - AZURE_CLIENT_ID"
echo -e "  - AZURE_CLIENT_SECRET"
echo -e "  - AZURE_TENANT_ID"
echo -e "  - AZURE_SUBSCRIPTION_ID"

echo -e "\n${CYAN}Azure AI Configuration:${NC}"
echo -e "  - AZURE_PROJECT_ENDPOINT"
echo -e "   → $ENDPOINT"

echo -e "\n  - MODEL_DEPLOYMENT_NAME"
echo -e "   → $MODEL_NAME"

echo -e "\n${GREEN}============================================================================${NC}"

# Save configuration
cat > setup-config.txt <<EOF
AZURE_PROJECT_ENDPOINT=$ENDPOINT
MODEL_DEPLOYMENT_NAME=$MODEL_NAME
SUBSCRIPTION_ID=$SUBSCRIPTION_ID
EOF

echo -e "${GREEN}[✓] Configuration saved to: setup-config.txt${NC}"

# ============================================================================
# STEP 6: GitHub CLI Setup (Optional)
# ============================================================================

echo -e "\n${CYAN}============================================================================${NC}"
echo -e "${CYAN}Quick Setup with GitHub CLI (optional)${NC}"
echo -e "${CYAN}============================================================================${NC}"

if command -v gh &> /dev/null; then
    echo -e "${GREEN}GitHub CLI detected!${NC}"
    read -p "Do you want to set GitHub secrets now using GitHub CLI? (y/N): " SET_SECRETS
    
    if [[ "$SET_SECRETS" =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}Setting GitHub secrets...${NC}"
        
        # Set service principal secrets
        echo "$CLIENT_ID" | gh secret set AZURE_CLIENT_ID
        echo -e "${GREEN}[✓] AZURE_CLIENT_ID set${NC}"
        
        echo "$CLIENT_SECRET" | gh secret set AZURE_CLIENT_SECRET
        echo -e "${GREEN}[✓] AZURE_CLIENT_SECRET set${NC}"
        
        echo "$TENANT_ID" | gh secret set AZURE_TENANT_ID
        echo -e "${GREEN}[✓] AZURE_TENANT_ID set${NC}"
        
        echo "$SUBSCRIPTION_ID" | gh secret set AZURE_SUBSCRIPTION_ID
        echo -e "${GREEN}[✓] AZURE_SUBSCRIPTION_ID set${NC}"
        
        # Set Azure AI secrets
        echo "$ENDPOINT" | gh secret set AZURE_PROJECT_ENDPOINT
        echo -e "${GREEN}[✓] AZURE_PROJECT_ENDPOINT set${NC}"
        
        echo "$MODEL_NAME" | gh secret set MODEL_DEPLOYMENT_NAME
        echo -e "${GREEN}[✓] MODEL_DEPLOYMENT_NAME set${NC}"
        
        echo -e "${GREEN}All secrets configured!${NC}"
    fi
else
    echo -e "${YELLOW}GitHub CLI not found. Install it from: https://cli.github.com/${NC}"
    echo -e "${YELLOW}Or manually add secrets via GitHub web interface${NC}"
fi

# ============================================================================
# STEP 7: Next Steps
# ============================================================================

echo -e "\n${GREEN}============================================================================${NC}"
echo -e "${GREEN}Next Steps - Deploy Infrastructure${NC}"
echo -e "${GREEN}============================================================================${NC}"

echo -e "\n${YELLOW}1. Push your code to GitHub:${NC}"
echo -e "   git add ."
echo -e "   git commit -m 'Add infrastructure deployment'"
echo -e "   git push origin main"

echo -e "\n${YELLOW}2. Go to GitHub Actions:${NC}"
echo -e "   → Actions tab in your repository"
echo -e "   → Select 'Infrastructure - Deploy to Azure'"
echo -e "   → Click 'Run workflow'"
echo -e "   → Choose environment: dev"
echo -e "   → Choose action: deploy"
echo -e "   → Click 'Run workflow'"

echo -e "\n${YELLOW}3. After infrastructure deploys, add these secrets:${NC}"
echo -e "   AZURE_CONTAINER_REGISTRY"
echo -e "   AZURE_RESOURCE_GROUP"
echo -e "   AZURE_CONTAINER_APP_NAME"

echo -e "\n${YELLOW}4. Deploy the application:${NC}"
echo -e "   → Actions → CD - Deploy to Azure Container Apps"
echo -e "   → Run workflow"

echo -e "\n${GREEN}============================================================================${NC}"
echo -e "${GREEN}Setup complete!${NC}"
echo -e "${GREEN}============================================================================${NC}\n"

# Cleanup reminder
echo -e "${YELLOW}⚠️  Security reminder:${NC}"
echo -e "   - Delete sp-credentials.txt after adding to GitHub secrets"
echo -e "   - Delete azure-credentials.json after adding to GitHub secrets"
echo -e "   - Keep setup-config.txt safe or delete after use"
echo -e "   - Never commit these files to Git!\n"
