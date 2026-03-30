# Simple smoke-test for gpt-4o-mini.
#
# Three modes:
#
# 1. DIRECT (local dev) — call Foundry endpoint with an API key.
#    APIM is in Internal VNet mode and is not reachable from the public internet.
#    Use this mode for quick iteration without VPN.
#
#      pip install openai
#      $env:FOUNDRY_API_KEY = $(az cognitiveservices account keys list `
#          --name contoso-foundry-primary `
#          --resource-group rg-contoso-ai-platform-dev --query key1 -o tsv)
#      python tests/simple.py
#
# 2. VIA APIM (production path) — call APIM; APIM authenticates to Foundry via
#    managed identity (no Foundry key leaves the gateway).
#    Requires VPN/jumpbox access (APIM is Internal VNet mode), plus:
#      - APIM managed identity has "Cognitive Services User" on both Foundry accounts
#        (deployRbac=true in azd, or manually: az role assignment create)
#      - An APIM subscription key (see step 3 below)
#
# 3. JUMPBOX TESTING (recommended — no VPN required)
#    Deploy the jumpbox: azd env set AZURE_DEPLOY_JUMPBOX true
#                        azd env set JUMPBOX_ADMIN_PASSWORD <strong-password>
#                        azd provision
#
#    Connect via Azure Bastion:
#      Azure portal → Virtual Machines → vm-contoso-jumpbox → Connect → Bastion
#      OR native client: az network bastion rdp --name bas-contoso-jumpbox -g rg-contoso-ai-platform-dev --target-resource-id <vmId>
#
#    Once on the jumpbox (run in PowerShell as Administrator):
#
#      # 1. Add APIM to hosts file so the hostname resolves to its private IP:
#      $RG   = "rg-contoso-ai-platform-dev"
#      $APIM = "apim-contoso-vdls2xyq"
#      $ip   = az apim show --name $APIM -g $RG --query "properties.privateIPAddresses[0]" -o tsv
#      Add-Content C:\Windows\System32\drivers\etc\hosts "$ip  $APIM.azure-api.net"
#
#      # 2. Get your Bronze subscription key:
#      $env:APIM_SUBSCRIPTION_KEY = az apim subscription show `
#          --service-name $APIM -g $RG --subscription-id bronze-test --query primaryKey -o tsv
#
#      # 3. Run this script:
#      $env:TEST_MODE = "apim"
#      python C:\apim-tests\simple.py
#
#    For load testing, copy the JMeter plan and run headless:
#      jmeter -n -t C:\apim-tests\apim-load-test.jmx -l C:\apim-tests\results.jtl `
#        -JAPIM_HOSTNAME=$APIM.azure-api.net `
#        -JBRONZE_KEY=$bronzeKey `
#        -JSILVER_KEY=$silverKey
#      # HTML report:
#      jmeter -g C:\apim-tests\results.jtl -o C:\apim-tests\html-report
#
#      Set MODE="apim" and $env:APIM_SUBSCRIPTION_KEY below.

import os
from openai import AzureOpenAI

MODE = os.environ.get("TEST_MODE", "direct")  # "direct" | "apim"

if MODE == "apim":
    # APIM handles auth to Foundry via managed identity — client only needs an APIM subscription key
    client = AzureOpenAI(
        azure_endpoint="https://apim-contoso-vdls2xyq.azure-api.net/openai",
        api_key=os.environ["APIM_SUBSCRIPTION_KEY"],
        api_version="2024-10-21",
    )
else:
    # Direct to Foundry — for local dev without VPN
    client = AzureOpenAI(
        azure_endpoint="https://contoso-foundry-primary.cognitiveservices.azure.com/openai",
        api_key=os.environ["FOUNDRY_API_KEY"],
        api_version="2024-10-21",
    )

print(f"Mode: {MODE}")
response = client.chat.completions.create(
    model="gpt-4o-mini",
    messages=[{"role": "user", "content": "Hello!"}],
)
print(response.choices[0].message.content)