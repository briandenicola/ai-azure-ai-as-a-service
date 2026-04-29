#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Create a self-signed SSL certificate in Key Vault for App Gateway WAF v2 and
  wire up all prerequisites so that 'azd provision' deploys the gateway on the
  first attempt.

.DESCRIPTION
  App Gateway + Key Vault cert creates a chicken-and-egg:
    • App Gateway reads its SSL cert from KV using a User-Assigned Managed Identity (UAMI)
    • The UAMI only gets Key Vault Certificate User RBAC after App Gateway deploys
    • But App Gateway MUST have KV access at deploy time or the ARM deployment fails

  This script breaks the cycle:
    1. Creates the self-signed cert in Key Vault (CN = App Gateway public FQDN)
    2. Pre-creates the UAMI with the exact name that Bicep will use
    3. Grants 'Key Vault Certificate User' to that UAMI before provisioning
    4. Exports the cert as a PKCS12 truststore so JMeter can validate it in load tests
    5. Sets AZURE_SSL_CERT_KV_SECRET_ID in the azd environment

.NOTES
  Run ONCE before 'azd provision'.
  For prod: replace the self-signed cert by importing a CA-signed cert:
    az keyvault certificate import --vault-name <your-kv-name> \
        --name appgw-ssl-cert --file your-cert.pfx
  Then re-run 'azd provision' — App Gateway replaces the cert with no downtime.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Environment ────────────────────────────────────────────────────────────────
. "$PSScriptRoot/_resolve-env.ps1"
# KV, APPGW_NAME, APPGW_FQDN all resolved from the live resource group above.
# Fall back to sensible defaults if resources not yet deployed.
$KV        = if ($KV_NAME)   { $KV_NAME }   else { throw "No Key Vault found in '$RG'. Run: azd provision" }
$CERT_NAME = 'appgw-ssl-cert-2'
# APPGW_NAME resolved by _resolve-env.ps1; derive FQDN from public IP if available.
# If App Gateway not yet deployed APPGW_NAME / APPGW_FQDN will be empty — that is fine,
# the cert creation step does not require App Gateway to exist yet.
# Derive the expected App Gateway name from the Bicep naming convention:
#   agw-${companyPrefix}-ai-primary  (matches main.bicep appGwName param)
# This works whether App Gateway is already deployed or not.
$expectedAppGwName = "agw-$companyPrefix-ai-primary"
if (-not $APPGW_NAME) { $APPGW_NAME = $expectedAppGwName }
$UAMI_NAME = "$APPGW_NAME-identity"

# FQDN: use live public IP DNS label if already deployed; otherwise derive from name.
# DNS label in Bicep = toLower('${companyPrefix}-ai-gw-${apimNameSuffix}') — globally unique.
# Extract the suffix from the APIM name: 'apim-contoso-lcjrut5z' -> 'lcjrut5z'
if (-not $APPGW_FQDN) {
    if ($APIM_NAME) {
        $apimSuffix = ($APIM_NAME -replace "^apim-$companyPrefix-", '')
        $dnsLabel   = "$($companyPrefix.ToLower())-ai-gw-$apimSuffix"
        $APPGW_FQDN = "$dnsLabel.$PRIMARY_LOCATION.cloudapp.azure.com"
    } else {
        # APIM not yet deployed (unlikely in postprovision hook) — use placeholder
        $APPGW_FQDN = "$($APPGW_NAME.ToLower()).$PRIMARY_LOCATION.cloudapp.azure.com"
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$testsDir  = Join-Path $repoRoot 'tests'

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  App Gateway WAF v2 — Prerequisites Setup"                         -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  Resource Group : $RG"
Write-Host "  Key Vault      : $KV"
Write-Host "  Certificate    : $CERT_NAME  (CN=$APPGW_FQDN)"
Write-Host "  App Gateway    : $APPGW_NAME"
Write-Host "  UAMI           : $UAMI_NAME"
Write-Host ""

# ── Step 0 : Grant Key Vault Administrator to the deploying user ──────────────
# az role assignment create is idempotent — returns existing if already assigned.
# This is required for a fresh deployment where Bicep hasn't run the RBAC module yet.
Write-Host "=== Step 0: Grant Key Vault Administrator to deploying user ===" -ForegroundColor Cyan
$kvId          = az keyvault show --name $KV --resource-group $RG --query id -o tsv
$deployingUser = az ad signed-in-user show --query id -o tsv 2>$null
if (-not $deployingUser) {
    $deployingUser = _Resolve-AzdEnv 'AZURE_DEPLOYING_USER_OBJECT_ID'
}
if ($deployingUser) {
    az role assignment create `
        --role '00482a5a-887f-4fb3-b363-3b7fe8e74483' `
        --assignee-object-id $deployingUser `
        --assignee-principal-type User `
        --scope $kvId `
        --only-show-errors -o none 2>$null
    Write-Host "  KV Administrator assigned (idempotent). Waiting 30s for propagation..."
    Start-Sleep 30
} else {
    Write-Host "  Could not determine deploying user OID — skipping KV Admin grant. Will retry on Forbidden." -ForegroundColor Yellow
}

# ── Step 1 : Create self-signed certificate in Key Vault ──────────────────────
Write-Host "=== Step 1: Create self-signed certificate in Key Vault ==" -ForegroundColor Cyan

$policyPath = Join-Path $env:TEMP 'appgw-cert-policy.json'
@{
    issuerParameters = @{ name = 'Self' }
    keyProperties    = @{
        exportable = $true
        keySize    = 2048
        keyType    = 'RSA'
        reuseKey   = $false
    }
    lifetimeActions = @(
        @{ action = @{ actionType = 'AutoRenew' }; trigger = @{ daysBeforeExpiry = 30 } }
    )
    secretProperties = @{ contentType = 'application/x-pkcs12' }
    x509CertificateProperties = @{
        subject          = "CN=$APPGW_FQDN"
        ekus             = @('1.3.6.1.5.5.7.3.1')  # TLS server auth
        validityInMonths = 12
        subjectAlternativeNames = @{
            dnsNames = @($APPGW_FQDN)
        }
    }
} | ConvertTo-Json -Depth 6 | Set-Content $policyPath

$existingCert = az keyvault certificate show --vault-name $KV --name $CERT_NAME -o json 2>$null |
    ConvertFrom-Json -ErrorAction SilentlyContinue

if ($existingCert) {
    Write-Host "  Certificate '$CERT_NAME' already exists — skipping creation." -ForegroundColor Yellow
} else {
    Write-Host "  Creating certificate (this takes 10-30 seconds)..."
    # Retry up to 10x with 15s back-off to handle RBAC propagation delay after provisioning.
    $createAttempts = 10
    $createOk = $false
    for ($attempt = 1; $attempt -le $createAttempts; $attempt++) {
        $createErr = az keyvault certificate create --vault-name $KV --name $CERT_NAME --policy "@$policyPath" -o none 2>&1
        if ($LASTEXITCODE -eq 0) { $createOk = $true; break }
        if ($createErr -match 'Forbidden|ForbiddenByRbac') {
            Write-Host "  RBAC not propagated yet (attempt $attempt/$createAttempts) — waiting 15s..." -ForegroundColor Yellow
            Start-Sleep 15
        } else {
            throw "Certificate creation failed: $createErr"
        }
    }
    if (-not $createOk) { throw "Certificate creation still Forbidden after $($createAttempts * 15)s — check KV RBAC." }

    $maxWait = 12   # 12 x 5s = 60s
    $i = 0
    do {
        Start-Sleep 5
        $state = az keyvault certificate show --vault-name $KV --name $CERT_NAME `
                    --query "attributes.enabled" -o tsv 2>$null
        $i++
    } while ($state -ne 'true' -and $i -lt $maxWait)

    if ($state -ne 'true') { throw "Certificate creation timed out after $($maxWait * 5) seconds." }
    Write-Host "  Certificate '$CERT_NAME' created successfully." -ForegroundColor Green
}

# Versioned secret ID — format App Gateway requires
$secretId = az keyvault certificate show --vault-name $KV --name $CERT_NAME --query "sid" -o tsv
Write-Host "  Secret ID: $secretId"

# ── Step 2 : Export cert + build PKCS12 truststore for JMeter ─────────────────
# App Gateway's cert subject must match the FQDN used in load tests.
# JMeter rejects self-signed certs unless the test engine trusts them.
# We export the public cert and build a PKCS12 truststore that the load test
# uploads to Azure Load Testing as an ADDITIONAL_ARTIFACTS file.
Write-Host ""
Write-Host "=== Step 2: Export certificate and build JMeter truststore ===" -ForegroundColor Cyan

$secretValue = az keyvault secret show --id $secretId --query "value" -o tsv
$pfxBytes    = [Convert]::FromBase64String($secretValue)

# Load PFX with .NET, no password (KV self-signed certs have no PFX password by default)
$pfx = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
    $pfxBytes, [string]::Empty,
    [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
)

# Export public cert (DER) — uploaded alongside JMX so JMeter can load it at test time
$certDerPath = Join-Path $testsDir 'appgw-cert.cer'
[IO.File]::WriteAllBytes($certDerPath, $pfx.Export(
    [System.Security.Cryptography.X509Certificates.X509ContentType]::Cert
))
Write-Host "  Public cert (DER) → $certDerPath" -ForegroundColor Green

# Build a PKCS12 bundle (acts as JMeter truststore)
# JMeter / Java accepts PKCS12 as a truststore via javax.net.ssl.trustStoreType=PKCS12
$truststore    = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certDerPath)
$tsPassword    = 'changeit'
$tsBytes       = $truststore.Export(
    [System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12,
    $tsPassword
)
$truststorePath = Join-Path $testsDir 'appgw-truststore.p12'
[IO.File]::WriteAllBytes($truststorePath, $tsBytes)
Write-Host "  PKCS12 truststore  → $truststorePath  (password: $tsPassword)" -ForegroundColor Green

# Write jmeter system.properties that tells JMeter/Java to use this truststore
# File is uploaded alongside the JMX; JMeter looks in its current directory first
$syspropsPath = Join-Path $testsDir 'appgw-system.properties'
@"
# JMeter system properties for AppGW load test — references the truststore uploaded
# alongside the JMX as an ADDITIONAL_ARTIFACTS file in Azure Load Testing.
# The filename (no path) works because ALT places all test files in the same directory.
javax.net.ssl.trustStore=appgw-truststore.p12
javax.net.ssl.trustStorePassword=$tsPassword
javax.net.ssl.trustStoreType=PKCS12
"@ | Set-Content $syspropsPath
Write-Host "  system.properties  → $syspropsPath" -ForegroundColor Green

# ── Step 3 : Pre-create App Gateway UAMI ─────────────────────────────────────
# The UAMI name matches waf-appgw.bicep: "${appGwName}-identity"
# Pre-creating it lets us grant KV RBAC BEFORE azd provision runs AppGW deployment.
Write-Host ""
Write-Host "=== Step 3: Pre-create App Gateway UAMI '$UAMI_NAME' ===" -ForegroundColor Cyan

$uami = az identity show --name $UAMI_NAME -g $RG -o json 2>$null |
    ConvertFrom-Json -ErrorAction SilentlyContinue

if ($uami) {
    Write-Host "  UAMI already exists — principalId: $($uami.principalId)" -ForegroundColor Yellow
} else {
    $uami = az identity create --name $UAMI_NAME -g $RG -o json | ConvertFrom-Json
    Write-Host "  UAMI created — principalId: $($uami.principalId)" -ForegroundColor Green
    Write-Host "  Waiting 30 s for Entra ID propagation..."
    Start-Sleep 30
}

# ── Step 4 : Grant 'Key Vault Certificate User' to UAMI ───────────────────────
Write-Host ""
Write-Host "=== Step 4: Grant 'Key Vault Certificate User' to UAMI ===" -ForegroundColor Cyan

$kvResourceId = az keyvault show --name $KV -g $RG --query id -o tsv
$existingRole = @(az role assignment list `
    --role "Key Vault Certificate User" `
    --assignee $uami.principalId `
    --scope $kvResourceId `
    -o json 2>$null | ConvertFrom-Json)

if ($existingRole.Count -gt 0) {
    Write-Host "  Role already assigned — skipping." -ForegroundColor Yellow
} else {
    az role assignment create `
        --role "Key Vault Certificate User" `
        --assignee-object-id $uami.principalId `
        --assignee-principal-type ServicePrincipal `
        --scope $kvResourceId `
        -o none
    Write-Host "  Key Vault Certificate User role assigned." -ForegroundColor Green
    Write-Host "  Waiting 30 s for RBAC propagation..."
    Start-Sleep 30
}

# ── Step 5 : Set azd environment variables ────────────────────────────────────
Write-Host ""
Write-Host "=== Step 5: Set azd environment variables ===" -ForegroundColor Cyan

azd env set AZURE_SSL_CERT_KV_SECRET_ID $secretId
azd env set AZURE_DEPLOY_RBAC true
Write-Host "  AZURE_SSL_CERT_KV_SECRET_ID = $secretId" -ForegroundColor Green
Write-Host "  AZURE_DEPLOY_RBAC            = true"      -ForegroundColor Green

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "==================================================================" -ForegroundColor Green
Write-Host "  Prerequisites complete!"                                          -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  AppGW FQDN (available after provision):"
Write-Host "    https://$APPGW_FQDN"
Write-Host ""
Write-Host "  Files written to tests/:"
Write-Host "    appgw-cert.cer         — public cert (DER)"
Write-Host "    appgw-truststore.p12   — PKCS12 truststore for JMeter"
Write-Host "    appgw-system.properties — JMeter system props for ALT"
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Yellow
Write-Host "    1. azd provision                  — deploys App Gateway (~5-10 min)"
Write-Host "    2. scripts\run-appgw-smoke-test.ps1  — creates ALT test + runs comparison"
Write-Host ""
