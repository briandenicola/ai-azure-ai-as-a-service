# Run This First - One-Time Setup for Infrastructure Deployment
# Validates .env configuration and sets up GitHub Actions authentication

# Colors
$GREEN = "Green"
$CYAN = "Cyan"
$YELLOW = "Yellow"
$RED = "Red"

Write-Host "`n==================================================================" -ForegroundColor $CYAN
Write-Host "Infrastructure Setup - Run This First!" -ForegroundColor $CYAN
Write-Host "==================================================================" -ForegroundColor $CYAN
Write-Host "This script will:" -ForegroundColor $CYAN
Write-Host "  1. Validate your .env configuration" -ForegroundColor $CYAN
Write-Host "  2. Create GitHub Actions service principal" -ForegroundColor $CYAN
Write-Host "  3. Register Azure resource providers" -ForegroundColor $CYAN
Write-Host "  4. Configure GitHub secrets automatically" -ForegroundColor $CYAN
Write-Host "==================================================================" -ForegroundColor $CYAN

# ============================================================================
# STEP 1: Validate .env File Exists
# ============================================================================

Write-Host "`n[1/5] Checking for .env file..." -ForegroundColor $CYAN

$envPath = Join-Path $PSScriptRoot "..\.env"
if (-not (Test-Path $envPath)) {
    Write-Host "`nERROR: .env file not found!" -ForegroundColor $RED
    Write-Host "Expected location: $envPath" -ForegroundColor $YELLOW
    Write-Host "`nPlease create a .env file in the root directory with these required values:" -ForegroundColor $YELLOW
    Write-Host "  - GITHUB_PAT" -ForegroundColor $CYAN
    Write-Host "  - AZURE_SUBSCRIPTION_ID" -ForegroundColor $CYAN
    Write-Host "  - AZURE_PROJECT_ENDPOINT" -ForegroundColor $CYAN
    Write-Host "  - MODEL_DEPLOYMENT_NAME" -ForegroundColor $CYAN
    Write-Host "`nSee env.sample for a template.`n" -ForegroundColor $YELLOW
    exit 1
}

Write-Host "[OK] .env file found" -ForegroundColor $GREEN

# ============================================================================
# STEP 2: Parse and Validate Required Values
# ============================================================================

Write-Host "`n[2/5] Validating .env configuration..." -ForegroundColor $CYAN

# Parse .env file
$envVars = @{}
Get-Content $envPath | ForEach-Object {
    # Skip comments and empty lines
    if ($_ -match '^\s*#' -or $_ -match '^\s*$') {
        return
    }
    
    # Parse KEY=VALUE (handle quoted values)
    if ($_ -match '^\s*([^#=]+)\s*=\s*(.*)$') {
        $key = $matches[1].Trim()
        $value = $matches[2].Trim()
        
        # Remove quotes if present
        $value = $value -replace '^["'']|["'']$', ''
        
        if ($value) {
            $envVars[$key] = $value
        }
    }
}

# Define required variables
$requiredVars = @{
    "GITHUB_PAT" = "GitHub Personal Access Token for setting secrets"
    "AZURE_SUBSCRIPTION_ID" = "Azure subscription ID where resources will be deployed"
    "AZURE_PROJECT_ENDPOINT" = "Azure AI/OpenAI project endpoint URL"
    "MODEL_DEPLOYMENT_NAME" = "Model deployment name like gpt-4 or gpt-4.1"
}

# Validate all required variables
$missingVars = @()
$invalidVars = @()

foreach ($var in $requiredVars.GetEnumerator()) {
    $key = $var.Key
    $description = $var.Value
    
    if (-not $envVars.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($envVars[$key])) {
        $missingVars += "$key - $description"
    } else {
        # Basic format validation
        $value = $envVars[$key]
        
        switch ($key) {
            "GITHUB_PAT" {
                if ($value -notmatch '^(ghp_|github_pat_)[a-zA-Z0-9_]+$') {
                    $invalidVars += "$key - Should start with 'ghp_' or 'github_pat_'"
                }
            }
            "AZURE_SUBSCRIPTION_ID" {
                if ($value -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
                    $invalidVars += "$key - Should be a valid GUID format"
                }
            }
            "AZURE_PROJECT_ENDPOINT" {
                if ($value -notmatch '^https?://') {
                    $invalidVars += "$key - Should be a valid HTTPS URL"
                }
            }
            "MODEL_DEPLOYMENT_NAME" {
                if ($value.Length -lt 2) {
                    $invalidVars += "$key - Should be a valid model name like gpt-4"
                }
            }
        }
        
        Write-Host "[OK] $key" -ForegroundColor $GREEN
    }
}

# Report any issues
if ($missingVars.Count -gt 0 -or $invalidVars.Count -gt 0) {
    Write-Host "`nVALIDATION FAILED!" -ForegroundColor $RED
    
    if ($missingVars.Count -gt 0) {
        Write-Host "`nMissing required values in .env:" -ForegroundColor $YELLOW
        foreach ($var in $missingVars) {
            Write-Host "  ERROR: $var" -ForegroundColor $RED
        }
    }
    
    if ($invalidVars.Count -gt 0) {
        Write-Host "`nInvalid values in .env:" -ForegroundColor $YELLOW
        foreach ($var in $invalidVars) {
            Write-Host "  WARNING: $var" -ForegroundColor $YELLOW
        }
    }
    
    Write-Host "`nPlease fix the above issues in your .env file and try again.`n" -ForegroundColor $YELLOW
    exit 1
}

# Extract values for use
$GITHUB_PAT = $envVars["GITHUB_PAT"]
$AZURE_SUBSCRIPTION_ID = $envVars["AZURE_SUBSCRIPTION_ID"]
$AZURE_PROJECT_ENDPOINT = $envVars["AZURE_PROJECT_ENDPOINT"]
$MODEL_DEPLOYMENT_NAME = $envVars["MODEL_DEPLOYMENT_NAME"]

Write-Host "`n[OK] All required values present and valid" -ForegroundColor $GREEN
Write-Host "    Subscription ID: $AZURE_SUBSCRIPTION_ID" -ForegroundColor $GREEN
Write-Host "    Project Endpoint: $AZURE_PROJECT_ENDPOINT" -ForegroundColor $GREEN
Write-Host "    Model: $MODEL_DEPLOYMENT_NAME" -ForegroundColor $GREEN

# ============================================================================
# STEP 3: Get GitHub Repository Info
# ============================================================================

Write-Host "`n[3/5] Detecting GitHub repository..." -ForegroundColor $CYAN

try {
    $gitRemote = git remote get-url origin 2>$null
    if ($gitRemote -match 'github\.com[:/]([^/]+)/([^/\.]+)') {
        $GITHUB_OWNER = $matches[1]
        $GITHUB_REPO = $matches[2]
        Write-Host "[OK] Repository detected: $GITHUB_OWNER/$GITHUB_REPO" -ForegroundColor $GREEN
    } else {
        throw "Could not parse GitHub repository from git remote"
    }
} catch {
    Write-Host "`nERROR: Could not detect GitHub repository" -ForegroundColor $RED
    Write-Host "Make sure you're in a Git repository with a GitHub remote.`n" -ForegroundColor $YELLOW
    exit 1
}

# ============================================================================
# STEP 4: Create Service Principal and Register Providers
# ============================================================================

Write-Host "`n[4/5] Setting up Azure resources..." -ForegroundColor $CYAN

# Check Azure login
Write-Host "[->] Checking Azure login..." -ForegroundColor $YELLOW
$currentAccount = az account show 2>$null | ConvertFrom-Json
if (-not $currentAccount) {
    Write-Host "[->] Not logged in. Opening Azure login..." -ForegroundColor $YELLOW
    az login
    $currentAccount = az account show | ConvertFrom-Json
}

Write-Host "[OK] Logged in as: $($currentAccount.user.name)" -ForegroundColor $GREEN

# Set subscription
Write-Host "[->] Setting subscription..." -ForegroundColor $YELLOW
az account set --subscription $AZURE_SUBSCRIPTION_ID
Write-Host "[OK] Subscription set" -ForegroundColor $GREEN

# Create service principal
Write-Host "[->] Checking for existing service principal..." -ForegroundColor $YELLOW
$SP_NAME = "sp-ai-agent-starter-$GITHUB_REPO"

# Check if service principal already exists
$existingSP = az ad sp list --display-name $SP_NAME --query "[0].appId" -o tsv 2>$null

if ($existingSP) {
    Write-Host "[OK] Found existing service principal: $SP_NAME" -ForegroundColor $GREEN
    Write-Host "[->] Resetting credentials for existing service principal..." -ForegroundColor $YELLOW
    
    $SP_JSON = az ad sp credential reset `
        --id $existingSP `
        --output json `
        --only-show-errors 2>&1 | Where-Object { $_ -match '^\s*\{' -or $_ -match '^\s*"' -or $_ -match '^\s*\}' }
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`nERROR: Failed to reset service principal credentials" -ForegroundColor $RED
        Write-Host $SP_JSON -ForegroundColor $RED
        exit 1
    }
    
    Write-Host "[OK] Credentials reset for: $SP_NAME" -ForegroundColor $GREEN
} else {
    Write-Host "[->] Creating new service principal..." -ForegroundColor $YELLOW
    
    $SP_JSON = az ad sp create-for-rbac `
        --name $SP_NAME `
        --role Contributor `
        --scopes "/subscriptions/$AZURE_SUBSCRIPTION_ID" `
        --output json `
        --only-show-errors 2>&1 | Where-Object { $_ -match '^\s*\{' -or $_ -match '^\s*"' -or $_ -match '^\s*\}' }

    if ($LASTEXITCODE -ne 0) {
        Write-Host "`nERROR: Failed to create service principal" -ForegroundColor $RED
        Write-Host $SP_JSON -ForegroundColor $RED
        Write-Host "`nYou may need 'Application Administrator' role in Azure AD.`n" -ForegroundColor $YELLOW
        exit 1
    }
    
    Write-Host "[OK] Service principal created: $SP_NAME" -ForegroundColor $GREEN
}

$SP_OBJ = ($SP_JSON -join "`n") | ConvertFrom-Json
$AZURE_CLIENT_ID = $SP_OBJ.appId
$AZURE_CLIENT_SECRET = $SP_OBJ.password
$AZURE_TENANT_ID = $SP_OBJ.tenant

Write-Host "[->] Assigning 'User Access Administrator' role to service principal..." -ForegroundColor $YELLOW
az role assignment create `
    --assignee $AZURE_CLIENT_ID `
    --role "User Access Administrator" `
    --scope "/subscriptions/$AZURE_SUBSCRIPTION_ID" `
    --only-show-errors | Out-Null

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] User Access Administrator role assigned successfully" -ForegroundColor $GREEN
} else {
    Write-Host "[WARNING] Failed to assign User Access Administrator role - you may need to do this manually" -ForegroundColor $YELLOW
}

Write-Host "    Client ID: $AZURE_CLIENT_ID" -ForegroundColor $GREEN

# Register resource providers
Write-Host "[->] Registering Azure resource providers..." -ForegroundColor $YELLOW
$providers = @(
    "Microsoft.App",
    "Microsoft.ContainerRegistry",
    "Microsoft.OperationalInsights",
    "Microsoft.Insights",
    "Microsoft.ManagedIdentity"
)

foreach ($provider in $providers) {
    $state = az provider show --namespace $provider --query "registrationState" -o tsv 2>$null
    if ($state -eq "Registered") {
        Write-Host "  [OK] $provider" -ForegroundColor $GREEN
    } else {
        Write-Host "  [->] Registering $provider..." -ForegroundColor $YELLOW
        az provider register --namespace $provider --wait
        Write-Host "  [OK] $provider" -ForegroundColor $GREEN
    }
}

# ============================================================================
# STEP 5: Set GitHub Secrets
# ============================================================================

Write-Host "`n[5/5] Configuring GitHub secrets..." -ForegroundColor $CYAN

$secrets = @{
    "AZURE_CLIENT_ID" = $AZURE_CLIENT_ID
    "AZURE_CLIENT_SECRET" = $AZURE_CLIENT_SECRET
    "AZURE_TENANT_ID" = $AZURE_TENANT_ID
    "AZURE_SUBSCRIPTION_ID" = $AZURE_SUBSCRIPTION_ID
    "AZURE_PROJECT_ENDPOINT" = $AZURE_PROJECT_ENDPOINT
    "MODEL_DEPLOYMENT_NAME" = $MODEL_DEPLOYMENT_NAME
}

# Check for GitHub CLI
$ghInstalled = Get-Command gh -ErrorAction SilentlyContinue

if (-not $ghInstalled) {
    Write-Host "`nWARNING: GitHub CLI not found" -ForegroundColor $YELLOW
    Write-Host "Install from: https://cli.github.com/`n" -ForegroundColor $CYAN
    Write-Host "Run these commands manually to set secrets:" -ForegroundColor $YELLOW
    foreach ($secret in $secrets.GetEnumerator()) {
        Write-Host "gh secret set $($secret.Key) --body `"$($secret.Value)`" --repo $GITHUB_OWNER/$GITHUB_REPO" -ForegroundColor $CYAN
    }
    Write-Host ""
} else {
    # Set GitHub token for gh CLI
    $env:GH_TOKEN = $GITHUB_PAT
    
    Write-Host "Testing GitHub authentication..." -ForegroundColor $YELLOW
    $authTest = gh auth status 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`nERROR: GitHub CLI authentication failed" -ForegroundColor $RED
        Write-Host "Authenticating with PAT..." -ForegroundColor $YELLOW
        "$GITHUB_PAT" | gh auth login --with-token
    }
    Write-Host "[OK] GitHub authenticated" -ForegroundColor $GREEN
    
    foreach ($secret in $secrets.GetEnumerator()) {
        Write-Host "[->] Setting $($secret.Key)..." -ForegroundColor $YELLOW
        $secretValue = $secret.Value
        $result = "$secretValue" | gh secret set $secret.Key --repo "$GITHUB_OWNER/$GITHUB_REPO" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] $($secret.Key)" -ForegroundColor $GREEN
        } else {
            Write-Host "  [FAILED] $($secret.Key)" -ForegroundColor $RED
            Write-Host "  Error: $result" -ForegroundColor $RED
        }
    }
}

# ============================================================================
# Success Summary
# ============================================================================

Write-Host "`n==================================================================" -ForegroundColor $GREEN
Write-Host "SUCCESS: SETUP COMPLETE!" -ForegroundColor $GREEN
Write-Host "==================================================================" -ForegroundColor $GREEN

Write-Host "`nGitHub Secrets Configured:" -ForegroundColor $CYAN
foreach ($secret in $secrets.Keys) {
    Write-Host "  [OK] $secret" -ForegroundColor $GREEN
}

Write-Host "`nNext Steps:" -ForegroundColor $YELLOW
Write-Host ""
Write-Host "1. Commit and push your code:" -ForegroundColor $YELLOW
Write-Host "   git add ." -ForegroundColor $CYAN
Write-Host "   git commit -m 'Add infrastructure deployment'" -ForegroundColor $CYAN
Write-Host "   git push origin main" -ForegroundColor $CYAN
Write-Host ""
Write-Host "2. Deploy infrastructure via GitHub Actions:" -ForegroundColor $YELLOW
Write-Host "   - Go to: Actions -> Infrastructure - Deploy to Azure" -ForegroundColor $CYAN
Write-Host "   - Click: Run workflow" -ForegroundColor $CYAN
Write-Host "   - Select environment: dev" -ForegroundColor $CYAN
Write-Host "   - Select action: deploy" -ForegroundColor $CYAN
Write-Host "   - Click: Run workflow" -ForegroundColor $CYAN
Write-Host ""
Write-Host "3. After deployment, add these secrets from outputs:" -ForegroundColor $YELLOW
Write-Host "   - AZURE_CONTAINER_REGISTRY" -ForegroundColor $CYAN
Write-Host "   - AZURE_RESOURCE_GROUP" -ForegroundColor $CYAN
Write-Host "   - AZURE_CONTAINER_APP_NAME" -ForegroundColor $CYAN
Write-Host ""
Write-Host "==================================================================" -ForegroundColor $GREEN
Write-Host "Ready to deploy!" -ForegroundColor $GREEN
Write-Host "==================================================================`n" -ForegroundColor $GREEN
