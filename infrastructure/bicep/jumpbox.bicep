// Bicep: VNet-internal jumpbox — Azure Container Instances
//
// Purpose: Provides a Linux container inside the VNet for testing APIM,
//          which is deployed in Internal mode (no public internet access).
//
// Why ACI instead of a VM?
//   - No VM SKU selection needed — avoids SkuNotAvailable errors common in
//     trial/sponsored subscriptions with capacity restrictions.
//   - No Azure Bastion required — shell access via az container exec.
//   - Cheaper: ~$33/month (1 vCPU / 1 GB) vs ~$260/month (B2ms + Bastion Standard).
//   - On-demand: stop/start with az container stop/start to save costs.
//
// What this deploys:
//   - Azure Container Instance group running mcr.microsoft.com/azure-cli:latest
//   - Init: installs JMeter 5.6, openai Python package, creates /root/apim-tests/
//   - Subnet: snet-jumpbox (10.100.4.0/24) with Microsoft.ContainerInstance delegation
//
// Access the jumpbox after deployment:
//   az container exec -g <rg> -n aci-<prefix>-jumpbox --exec-command /bin/sh
//
// Once connected, test APIM via:
//   1. Add APIM private IP to hosts:
//        APIM_IP=$(az apim show -g <rg> -n <apim-name> --query privateIpAddresses[0] -o tsv)
//        echo "$APIM_IP  <apim-hostname>" >> /etc/hosts
//   2. Run Python test:
//        python3 /root/apim-tests/test.py
//   3. Run JMeter load test:
//        jmeter -n -t /root/apim-tests/apim-load-test.jmx \
//          -JAPIM_HOSTNAME=apim.example.azure-api.net \
//          -JBRONZE_KEY=<key> -JSILVER_KEY=<key>

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Location for all jumpbox resources')
param location string = resourceGroup().location

@description('Short company prefix used in resource names')
param prefix string = 'contoso'

@description('VNet resource ID — container group is injected into this VNet')
param vnetResourceId string

param tags object = {}

// ---------------------------------------------------------------------------
// Derived values
// ---------------------------------------------------------------------------

var containerGroupName = 'aci-${prefix}-jumpbox'
var jumpboxSubnetId = '${vnetResourceId}/subnets/snet-jumpbox'

// ---------------------------------------------------------------------------
// Init command — runs once at container start
//
// Base image: mcr.microsoft.com/azure-cli:latest
//   - Alpine-based; already contains: Python 3, pip3, curl, az CLI
//   - Pulled from Microsoft Container Registry via Azure backbone
//
// This command installs:
//   - OpenJDK 17 JRE (Alpine package) + wget   — for JMeter
//   - JMeter 5.6.3                              — load testing
//   - openai Python package                    — API functional testing
// ---------------------------------------------------------------------------

// The mcr.microsoft.com/azure-cli image is Alpine-based and already includes:
//   Python 3, pip3, curl, wget, az CLI — sufficient for APIM testing.
// We do NOT run apk add here because snet-jumpbox has no NAT gateway for
// outbound internet access. Install anything extra manually after exec-ing in.
var initCommand = [
  '/bin/sh'
  '-c'
  'mkdir -p /root/apim-tests && sleep infinity'
]

// ---------------------------------------------------------------------------
// ACI Container Group
//
// The snet-jumpbox subnet (10.100.4.0/24) must have delegation for
// Microsoft.ContainerInstance/containerGroups — see networking.bicep.
// ---------------------------------------------------------------------------

resource containerGroup 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: containerGroupName
  location: location
  tags: tags
  properties: {
    sku: 'Standard'
    containers: [
      {
        name: 'jumpbox'
        properties: {
          image: 'mcr.microsoft.com/azure-cli:latest'
          command: initCommand
          resources: {
            requests: {
              cpu: 1
              memoryInGB: 1
            }
          }
        }
      }
    ]
    osType: 'Linux'
    restartPolicy: 'Always'
    // VNet injection — container gets a private IP in snet-jumpbox
    subnetIds: [
      {
        id: jumpboxSubnetId
        name: 'snet-jumpbox'
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output containerGroupName string = containerGroup.name
output containerGroupId string = containerGroup.id
