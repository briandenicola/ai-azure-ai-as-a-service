#!/bin/bash
# Run This First - One-Time Setup for Infrastructure Deployment
# Validates .env configuration and sets up GitHub Actions authentication

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}==================================================================${NC}"
echo -e "${CYAN}Infrastructure Setup - Run This First!${NC}"
echo -e "${CYAN}==================================================================${NC}"
echo -e "${CYAN}This script will:${NC}"
echo -e "${CYAN}  1. Validate your .env configuration${NC}"
echo -e "${CYAN}  2. Create GitHub Actions service principal${NC}"
echo -e "${CYAN}  3. Register Azure resource providers${NC}"
echo -e "${CYAN}  4. Configure GitHub secrets automatically${NC}"
echo -e "${CYAN}==================================================================${NC}"

# ============================================================================
# STEP 1: Validate .env File Exists
# ============================================================================

echo -e "\n${CYAN}[1/5] Checking for .env file...${NC}"

ENV_FILE="../.env"
if [ ! -f "$ENV_FILE" ]; then
    echo -e "\n${RED}❌ ERROR: .env file not found!${NC}"
    echo -e "${YELLOW}Expected location: $ENV_FILE${NC}"
    echo -e "\n${YELLOW}Please create a .env file in the root directory with these required values:${NC}"
    echo -e "${CYAN}  - GITHUB_PAT${NC}"
    echo -e "${CYAN}  - AZURE_SUBSCRIPTION_ID${NC}"
    echo -e "${CYAN}  - AZURE_PROJECT_ENDPOINT${NC}"
    echo -e "${CYAN}  - MODEL_DEPLOYMENT_NAME${NC}"
    echo -e "\n${YELLOW}See env.sample for a template.${NC}\n"
    exit 1
fi

echo -e "${GREEN}[✓] .env file found${NC}"

# ============================================================================
# STEP 2: Parse and Validate Required Values
# ============================================================================

echo -e "\n${CYAN}[2/5] Validating .env configuration...${NC}"

# Source .env file (export variables)
set -a
source "$ENV_FILE"
set +a

# Define required variables
declare -A REQUIRED_VARS=(
    ["GITHUB_PAT"]="GitHub Personal Access Token for setting secrets"
    ["AZURE_SUBSCRIPTION_ID"]="Azure subscription ID where resources will be deployed"
    ["AZURE_PROJECT_ENDPOINT"]="Azure AI/OpenAI project endpoint URL"
    ["MODEL_DEPLOYMENT_NAME"]="Model deployment name (e.g., gpt-4, gpt-4.1)"
)

# Validate all required variables
MISSING_VARS=()
INVALID_VARS=()

for VAR in "${!REQUIRED_VARS[@]}"; do
    DESCRIPTION="${REQUIRED_VARS[$VAR]}"
    VALUE="${!VAR}"
    
    if [ -z "$VALUE" ]; then
        MISSING_VARS+=("$VAR - $DESCRIPTION")
    else
        # Basic format validation
        case "$VAR" in
            "GITHUB_PAT")
                if [[ ! "$VALUE" =~ ^(ghp_|github_pat_)[a-zA-Z0-9_]+$ ]]; then
                    INVALID_VARS+=("$VAR - Should start with 'ghp_' or 'github_pat_'")
                fi
                ;;
            "AZURE_SUBSCRIPTION_ID")
                if [[ ! "$VALUE" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
                    INVALID_VARS+=("$VAR - Should be a valid GUID format")
                fi
                ;;
            "AZURE_PROJECT_ENDPOINT")
                if [[ ! "$VALUE" =~ ^https?:// ]]; then
                    INVALID_VARS+=("$VAR - Should be a valid HTTPS URL")
                fi
                ;;
            "MODEL_DEPLOYMENT_NAME")
                if [ ${#VALUE} -lt 2 ]; then
                    INVALID_VARS+=("$VAR - Should be a valid model name (e.g., gpt-4)")
                fi
                ;;
        esac
        
        echo -e "${GREEN}[✓] $VAR${NC}"
    fi
done

# Report any issues
if [ ${#MISSING_VARS[@]} -gt 0 ] || [ ${#INVALID_VARS[@]} -gt 0 ]; then
    echo -e "\n${RED}❌ VALIDATION FAILED!${NC}"
    
    if [ ${#MISSING_VARS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}Missing required values in .env:${NC}"
        for VAR in "${MISSING_VARS[@]}"; do
            echo -e "${RED}  ❌ $VAR${NC}"
        done
    fi
    
    if [ ${#INVALID_VARS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}Invalid values in .env:${NC}"
        for VAR in "${INVALID_VARS[@]}"; do
            echo -e "${YELLOW}  ⚠️  $VAR${NC}"
        done
    fi
    
    echo -e "\n${YELLOW}Please fix the above issues in your .env file and try again.${NC}\n"
    exit 1
fi

echo -e "\n${GREEN}[✓] All required values present and valid${NC}"
echo -e "${GREEN}    Subscription ID: $AZURE_SUBSCRIPTION_ID${NC}"
echo -e "${GREEN}    Project Endpoint: $AZURE_PROJECT_ENDPOINT${NC}"
echo -e "${GREEN}    Model: $MODEL_DEPLOYMENT_NAME${NC}"

# ============================================================================
# STEP 3: Get GitHub Repository Info
# ============================================================================

echo -e "\n${CYAN}[3/5] Detecting GitHub repository...${NC}"

GIT_REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
if [[ $GIT_REMOTE =~ github\.com[:/]([^/]+)/([^/\.]+) ]]; then
    GITHUB_OWNER="${BASH_REMATCH[1]}"
    GITHUB_REPO="${BASH_REMATCH[2]}"
    echo -e "${GREEN}[✓] Repository detected: $GITHUB_OWNER/$GITHUB_REPO${NC}"
else
    echo -e "\n${RED}❌ ERROR: Could not detect GitHub repository${NC}"
    echo -e "${YELLOW}Make sure you're in a Git repository with a GitHub remote.${NC}\n"
    exit 1
fi

# ============================================================================
# STEP 4: Create Service Principal and Register Providers
# ============================================================================

echo -e "\n${CYAN}[4/5] Setting up Azure resources...${NC}"

# Check Azure login
echo -e "${YELLOW}[→] Checking Azure login...${NC}"
if ! az account show &> /dev/null; then
    echo -e "${YELLOW}[→] Not logged in. Opening Azure login...${NC}"
    az login
fi

CURRENT_USER=$(az account show --query user.name -o tsv)
echo -e "${GREEN}[✓] Logged in as: $CURRENT_USER${NC}"

# Set subscription
echo -e "${YELLOW}[→] Setting subscription...${NC}"
az account set --subscription "$AZURE_SUBSCRIPTION_ID"
echo -e "${GREEN}[✓] Subscription set${NC}"

# Create service principal
echo -e "${YELLOW}[->] Checking for existing service principal...${NC}"
SP_NAME="sp-ai-agent-starter-$GITHUB_REPO"

# Check if service principal already exists
EXISTING_SP=$(az ad sp list --display-name "$SP_NAME" --query "[0].appId" -o tsv 2>/dev/null)

if [ -n "$EXISTING_SP" ]; then
    echo -e "${GREEN}[OK] Found existing service principal: $SP_NAME${NC}"
    echo -e "${YELLOW}[->] Resetting credentials for existing service principal...${NC}"
    
    SP_JSON=$(az ad sp credential reset \
        --id "$EXISTING_SP" \
        --output json \
        --only-show-errors 2>&1)
    
    if [ $? -ne 0 ]; then
        echo -e "\n${RED}ERROR: Failed to reset service principal credentials${NC}"
        echo -e "${RED}$SP_JSON${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}[OK] Credentials reset for: $SP_NAME${NC}"
else
    echo -e "${YELLOW}[->] Creating new service principal...${NC}"
    
    SP_JSON=$(az ad sp create-for-rbac \
        --name "$SP_NAME" \
        --role Contributor \
        --scopes "/subscriptions/$AZURE_SUBSCRIPTION_ID" \
        --output json \
        --only-show-errors 2>&1)

    if [ $? -ne 0 ]; then
        echo -e "\n${RED}ERROR: Failed to create service principal${NC}"
        echo -e "${RED}$SP_JSON${NC}"
        echo -e "\n${YELLOW}You may need 'Application Administrator' role in Azure AD.${NC}\n"
        exit 1
    fi
    
    echo -e "${GREEN}[OK] Service principal created: $SP_NAME${NC}"
fi

AZURE_CLIENT_ID=$(echo "$SP_JSON" | jq -r '.appId')
AZURE_CLIENT_SECRET=$(echo "$SP_JSON" | jq -r '.password')
AZURE_TENANT_ID=$(echo "$SP_JSON" | jq -r '.tenant')

echo -e "${GREEN}    Client ID: $AZURE_CLIENT_ID${NC}"

# Grant User Access Administrator role for role assignment creation
echo -e "${YELLOW}[->] Assigning 'User Access Administrator' role to service principal...${NC}"
az role assignment create \
    --assignee "$AZURE_CLIENT_ID" \
    --role "User Access Administrator" \
    --scope "/subscriptions/$AZURE_SUBSCRIPTION_ID" \
    --only-show-errors >/dev/null 2>&1

if [ $? -eq 0 ]; then
    echo -e "${GREEN}[OK] User Access Administrator role assigned successfully${NC}"
else
    echo -e "${YELLOW}[WARNING] Failed to assign User Access Administrator role - you may need to do this manually${NC}"
fi

# Register resource providers
echo -e "${YELLOW}[→] Registering Azure resource providers...${NC}"
PROVIDERS=(
    "Microsoft.App"
    "Microsoft.ContainerRegistry"
    "Microsoft.OperationalInsights"
    "Microsoft.Insights"
    "Microsoft.ManagedIdentity"
)

for PROVIDER in "${PROVIDERS[@]}"; do
    STATE=$(az provider show --namespace "$PROVIDER" --query "registrationState" -o tsv 2>/dev/null || echo "NotRegistered")
    if [ "$STATE" == "Registered" ]; then
        echo -e "  ${GREEN}[✓] $PROVIDER${NC}"
    else
        echo -e "  ${YELLOW}[→] Registering $PROVIDER...${NC}"
        az provider register --namespace "$PROVIDER" --wait
        echo -e "  ${GREEN}[✓] $PROVIDER${NC}"
    fi
done

# ============================================================================
# STEP 5: Set GitHub Secrets
# ============================================================================

echo -e "\n${CYAN}[5/5] Configuring GitHub secrets...${NC}"

# Export GitHub token for gh CLI
export GH_TOKEN=$GITHUB_PAT

# Check for GitHub CLI
if command -v gh &> /dev/null; then
    echo -e "${YELLOW}[→] Setting secrets with GitHub CLI...${NC}"
    
    echo "$AZURE_CLIENT_ID" | gh secret set AZURE_CLIENT_ID --repo "$GITHUB_OWNER/$GITHUB_REPO" 2>/dev/null && \
        echo -e "  ${GREEN}[✓] AZURE_CLIENT_ID${NC}" || echo -e "  ${RED}[!] Failed to set AZURE_CLIENT_ID${NC}"
    
    echo "$AZURE_CLIENT_SECRET" | gh secret set AZURE_CLIENT_SECRET --repo "$GITHUB_OWNER/$GITHUB_REPO" 2>/dev/null && \
        echo -e "  ${GREEN}[✓] AZURE_CLIENT_SECRET${NC}" || echo -e "  ${RED}[!] Failed to set AZURE_CLIENT_SECRET${NC}"
    
    echo "$AZURE_TENANT_ID" | gh secret set AZURE_TENANT_ID --repo "$GITHUB_OWNER/$GITHUB_REPO" 2>/dev/null && \
        echo -e "  ${GREEN}[✓] AZURE_TENANT_ID${NC}" || echo -e "  ${RED}[!] Failed to set AZURE_TENANT_ID${NC}"
    
    echo "$AZURE_SUBSCRIPTION_ID" | gh secret set AZURE_SUBSCRIPTION_ID --repo "$GITHUB_OWNER/$GITHUB_REPO" 2>/dev/null && \
        echo -e "  ${GREEN}[✓] AZURE_SUBSCRIPTION_ID${NC}" || echo -e "  ${RED}[!] Failed to set AZURE_SUBSCRIPTION_ID${NC}"
    
    echo "$AZURE_PROJECT_ENDPOINT" | gh secret set AZURE_PROJECT_ENDPOINT --repo "$GITHUB_OWNER/$GITHUB_REPO" 2>/dev/null && \
        echo -e "  ${GREEN}[✓] AZURE_PROJECT_ENDPOINT${NC}" || echo -e "  ${RED}[!] Failed to set AZURE_PROJECT_ENDPOINT${NC}"
    
    echo "$MODEL_DEPLOYMENT_NAME" | gh secret set MODEL_DEPLOYMENT_NAME --repo "$GITHUB_OWNER/$GITHUB_REPO" 2>/dev/null && \
        echo -e "  ${GREEN}[✓] MODEL_DEPLOYMENT_NAME${NC}" || echo -e "  ${RED}[!] Failed to set MODEL_DEPLOYMENT_NAME${NC}"
    
else
    echo -e "\n${YELLOW}⚠️  GitHub CLI not found${NC}"
    echo -e "${CYAN}Install from: https://cli.github.com/${NC}\n"
    echo -e "${YELLOW}Run these commands manually to set secrets:${NC}"
    echo -e "${CYAN}echo \"$AZURE_CLIENT_ID\" | gh secret set AZURE_CLIENT_ID --repo $GITHUB_OWNER/$GITHUB_REPO${NC}"
    echo -e "${CYAN}echo \"$AZURE_CLIENT_SECRET\" | gh secret set AZURE_CLIENT_SECRET --repo $GITHUB_OWNER/$GITHUB_REPO${NC}"
    echo -e "${CYAN}echo \"$AZURE_TENANT_ID\" | gh secret set AZURE_TENANT_ID --repo $GITHUB_OWNER/$GITHUB_REPO${NC}"
    echo -e "${CYAN}echo \"$AZURE_SUBSCRIPTION_ID\" | gh secret set AZURE_SUBSCRIPTION_ID --repo $GITHUB_OWNER/$GITHUB_REPO${NC}"
    echo -e "${CYAN}echo \"$AZURE_PROJECT_ENDPOINT\" | gh secret set AZURE_PROJECT_ENDPOINT --repo $GITHUB_OWNER/$GITHUB_REPO${NC}"
    echo -e "${CYAN}echo \"$MODEL_DEPLOYMENT_NAME\" | gh secret set MODEL_DEPLOYMENT_NAME --repo $GITHUB_OWNER/$GITHUB_REPO${NC}"
    echo ""
fi

# ============================================================================
# Success Summary
# ============================================================================

echo -e "\n${GREEN}==================================================================${NC}"
echo -e "${GREEN}✅ SETUP COMPLETE!${NC}"
echo -e "${GREEN}==================================================================${NC}"

echo -e "\n${CYAN}GitHub Secrets Configured:${NC}"
echo -e "${GREEN}  ✓ AZURE_CLIENT_ID${NC}"
echo -e "${GREEN}  ✓ AZURE_CLIENT_SECRET${NC}"
echo -e "${GREEN}  ✓ AZURE_TENANT_ID${NC}"
echo -e "${GREEN}  ✓ AZURE_SUBSCRIPTION_ID${NC}"
echo -e "${GREEN}  ✓ AZURE_PROJECT_ENDPOINT${NC}"
echo -e "${GREEN}  ✓ MODEL_DEPLOYMENT_NAME${NC}"

echo -e "\n${YELLOW}📋 Next Steps:${NC}"
echo ""
echo -e "${YELLOW}1. Commit and push your code:${NC}"
echo -e "${CYAN}   git add .${NC}"
echo -e "${CYAN}   git commit -m 'Add infrastructure deployment'${NC}"
echo -e "${CYAN}   git push origin main${NC}"
echo ""
echo -e "${YELLOW}2. Deploy infrastructure via GitHub Actions:${NC}"
echo -e "${CYAN}   • Go to: Actions → Infrastructure - Deploy to Azure${NC}"
echo -e "${CYAN}   • Click: Run workflow${NC}"
echo -e "${CYAN}   • Select environment: dev${NC}"
echo -e "${CYAN}   • Select action: deploy${NC}"
echo -e "${CYAN}   • Click: Run workflow${NC}"
echo ""
echo -e "${YELLOW}3. After deployment, add these secrets from outputs:${NC}"
echo -e "${CYAN}   • AZURE_CONTAINER_REGISTRY${NC}"
echo -e "${CYAN}   • AZURE_RESOURCE_GROUP${NC}"
echo -e "${CYAN}   • AZURE_CONTAINER_APP_NAME${NC}"
echo ""
echo -e "${GREEN}==================================================================${NC}"
echo -e "${GREEN}🚀 You're ready to deploy!${NC}"
echo -e "${GREEN}==================================================================${NC}\n"
