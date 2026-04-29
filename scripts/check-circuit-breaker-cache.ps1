. "$PSScriptRoot/_resolve-env.ps1"

# Reset the circuit-breaker cache by setting primaryFailureCount to 0
# The cache key format is: "circuit-breaker-" + foundry-primary-endpoint value
# = "circuit-breaker-https://contoso-foundry-primary.cognitiveservices.azure.com"

# Use the APIM Cache API to clear the circuit-breaker entry
# APIM internal cache is the default cache (id="default")
Write-Host "Checking APIM cache entries for circuit-breaker..."
try {
    $caches = Invoke-RestMethod -Method Get -Uri "$base/caches?api-version=2023-05-01-preview" -Headers @{Authorization="Bearer $t"}
    $caches.value | ForEach-Object { Write-Host "Cache: $($_.name) - $($_.properties.resourceId)" }
} catch { Write-Host "Error: $($_.Exception.Message)" }
