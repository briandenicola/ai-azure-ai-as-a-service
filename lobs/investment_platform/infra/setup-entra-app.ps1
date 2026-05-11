<#
.SYNOPSIS
    Creates (or updates) the Entra App Registration needed for interactive
    user login in the investment-platform console app.  Idempotent — safe
    to re-run at any time.

.DESCRIPTION
    1. Discovers the current Azure tenant from `az account show`.
    2. Checks whether an app named "contoso-ai-investment-platform" already
       exists in the tenant.
    3. Creates it if absent; leaves it in place if it already exists.
    4. Ensures the app is configured as a public client (enables device code
       flow and interactive browser login — no client secret required).
    5. Patches the LOB .env file with ENTRA_CLIENT_ID and ENTRA_TENANT_ID.

.NOTES
    Run from any directory.  Prerequisites:
      - Azure CLI (`az`) — run `az login` first
      - Owner or Application Administrator role on the Entra tenant
      - The LOB .env file must exist at lobs/investment_platform/.env

    App Registration settings created:
      - Sign-in audience : AzureADMyOrg  (single tenant)
      - Public client    : enabled        (device code flow)
      - Redirect URIs    : http://localhost

    The app does NOT require a client secret.  Token acquisition is handled
    by the MSAL PublicClientApplication in auth/entra_auth.py.
#>

param(
    [string]$DisplayName = "contoso-ai-investment-platform"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$GREEN  = "Green"
$CYAN   = "Cyan"
$YELLOW = "Yellow"
$RED    = "Red"

Write-Host "`n=================================================================" -ForegroundColor $CYAN
Write-Host "  Entra App Registration Setup — Investment Platform" -ForegroundColor $CYAN
Write-Host "=================================================================" -ForegroundColor $CYAN
Write-Host "This script will:" -ForegroundColor $CYAN
Write-Host "  1. Discover the current Azure tenant" -ForegroundColor $CYAN
Write-Host "  2. Find or create the '$DisplayName' app registration" -ForegroundColor $CYAN
Write-Host "  3. Ensure public-client / device-code flow is enabled" -ForegroundColor $CYAN
Write-Host "  4. Patch .env with ENTRA_CLIENT_ID and ENTRA_TENANT_ID" -ForegroundColor $CYAN
Write-Host "=================================================================" -ForegroundColor $CYAN

# ── Locate the .env file ─────────────────────────────────────────────────────
$envFile = Resolve-Path (Join-Path $PSScriptRoot ".." ".env") -ErrorAction SilentlyContinue
if (-not $envFile) {
    Write-Host "`nERROR: .env file not found at $(Join-Path $PSScriptRoot '..' '.env')" -ForegroundColor $RED
    Write-Host "Create it from env.sample or run the main platform setup first.`n" -ForegroundColor $YELLOW
    exit 1
}
Write-Host "`n[OK] .env found at $envFile" -ForegroundColor $GREEN

# ── 1. Get tenant info ───────────────────────────────────────────────────────
Write-Host "`n[1/4] Getting current Azure account / tenant..." -ForegroundColor $CYAN

$account = az account show 2>&1 | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    Write-Host "`nERROR: Not logged in to Azure CLI.  Run: az login" -ForegroundColor $RED
    exit 1
}
$tenantId  = $account.tenantId
$subName   = $account.name
Write-Host "  Tenant : $tenantId" -ForegroundColor $GREEN
Write-Host "  Sub    : $subName"  -ForegroundColor $GREEN

# ── 2. Find or create the app registration ───────────────────────────────────
Write-Host "`n[2/4] Checking for existing app registration '$DisplayName'..." -ForegroundColor $CYAN

$appJson   = az ad app list --display-name $DisplayName --query "[0]" 2>&1
$existing  = $appJson | ConvertFrom-Json

if ($existing -and $existing.appId) {
    $clientId = $existing.appId
    $objectId = $existing.id
    Write-Host "  Found : $DisplayName ($clientId)" -ForegroundColor $GREEN
    Write-Host "  Skipping creation — app already exists." -ForegroundColor $YELLOW
} else {
    Write-Host "  Not found — creating app registration..." -ForegroundColor $YELLOW
    $newAppJson = az ad app create `
        --display-name $DisplayName `
        --sign-in-audience "AzureADMyOrg" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`nERROR: Failed to create app registration." -ForegroundColor $RED
        Write-Host $newAppJson -ForegroundColor $RED
        exit 1
    }
    $newApp   = $newAppJson | ConvertFrom-Json
    $clientId = $newApp.appId
    $objectId = $newApp.id
    Write-Host "  Created: $DisplayName ($clientId)" -ForegroundColor $GREEN
}

# ── 3. Ensure public-client config ───────────────────────────────────────────
Write-Host "`n[3/4] Ensuring public client config (device code / interactive)..." -ForegroundColor $CYAN
#
# isFallbackPublicClient = true  →  allows device code, Windows Integrated Auth,
# and username/password flows even if the redirect URI is not matched.
# publicClient.redirectUris includes http://localhost for interactive browser login.
#
$graphBody = '{"isFallbackPublicClient":true,"publicClient":{"redirectUris":["http://localhost"]}}'
az rest `
    --method  PATCH `
    --uri     "https://graph.microsoft.com/v1.0/applications/$objectId" `
    --headers "Content-Type=application/json" `
    --body    $graphBody 2>&1 | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Host "WARNING: Could not patch app via Graph API." -ForegroundColor $YELLOW
    Write-Host "You may need Application Administrator role." -ForegroundColor $YELLOW
    Write-Host "Proceeding — the app may still work if it was created with public-client enabled." -ForegroundColor $YELLOW
} else {
    Write-Host "  isFallbackPublicClient : true" -ForegroundColor $GREEN
    Write-Host "  Redirect URI           : http://localhost" -ForegroundColor $GREEN
}

# ── 4. Patch .env ────────────────────────────────────────────────────────────
Write-Host "`n[4/4] Patching .env with Entra values..." -ForegroundColor $CYAN

$envContent = Get-Content $envFile -Raw

function Set-EnvVar([string]$content, [string]$key, [string]$value) {
    # If the key already exists (with or without quotes), replace the line.
    # Otherwise append to the end.
    if ($content -match "(?m)^$key\s*=") {
        return $content -replace "(?m)^$key\s*=.*", "$key=`"$value`""
    } else {
        # Ensure file ends with a newline before appending
        if (-not $content.EndsWith("`n")) { $content += "`n" }
        return $content + "`n# Entra App Registration (investment-platform interactive login)`n$key=`"$value`"`n"
    }
}

$envContent = Set-EnvVar $envContent "ENTRA_CLIENT_ID" $clientId
$envContent = Set-EnvVar $envContent "ENTRA_TENANT_ID" $tenantId

# Write back without adding a BOM (important for python-dotenv)
[System.IO.File]::WriteAllText($envFile, $envContent, [System.Text.UTF8Encoding]::new($false))

Write-Host "  ENTRA_CLIENT_ID = $clientId" -ForegroundColor $GREEN
Write-Host "  ENTRA_TENANT_ID = $tenantId" -ForegroundColor $GREEN

# ── Summary ──────────────────────────────────────────────────────────────────
Write-Host "`n=================================================================" -ForegroundColor $GREEN
Write-Host "  App Registration ready.  Next steps:" -ForegroundColor $GREEN
Write-Host "" -ForegroundColor $GREEN
Write-Host "  1. Install dependencies:" -ForegroundColor $CYAN
Write-Host "       pip install -r requirements.txt" -ForegroundColor $CYAN
Write-Host "" -ForegroundColor $GREEN
Write-Host "  2. Run the console app:" -ForegroundColor $CYAN
Write-Host "       python chat.py" -ForegroundColor $CYAN
Write-Host "" -ForegroundColor $GREEN
Write-Host "  The app will prompt you to sign in via device code flow." -ForegroundColor $CYAN
Write-Host "  After first login the token is cached — no re-auth needed" -ForegroundColor $CYAN
Write-Host "  until the token expires (usually 1 hour)." -ForegroundColor $CYAN
Write-Host "=================================================================" -ForegroundColor $GREEN
