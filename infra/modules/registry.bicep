// Azure Container Registry. No admin user; pushes use the pipeline's federated identity and
// pulls use each app's managed identity (AcrPull). Images move between environments with
// `az acr import` by digest, so prod runs exactly the bytes that passed staging.
import { requiredTags } from '../lib/types.bicep'

param location string
param tags requiredTags
param name string

@allowed(['Basic', 'Standard', 'Premium'])
param sku string

@sys.description('Requires Premium. Disables public access and adds a private endpoint.')
param enablePrivateNetworking bool
param privateEndpointSubnetId string
param privateDnsZoneId string
param logAnalyticsWorkspaceId string

var isPremium = sku == 'Premium'

resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: name
  location: location
  tags: tags
  sku: { name: sku }
  properties: {
    adminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: enablePrivateNetworking && isPremium ? 'Disabled' : 'Enabled'
    networkRuleBypassOptions: 'AzureServices'
    zoneRedundancy: isPremium ? 'Enabled' : 'Disabled'
    policies: {
      retentionPolicy: { status: isPremium ? 'enabled' : 'disabled', days: 30 }
      // Content trust is superseded by Notation signing; left off deliberately.
      exportPolicy: isPremium ? { status: enablePrivateNetworking ? 'disabled' : 'enabled' } : null
    }
  }
}

module endpoint 'private-endpoint.bicep' = if (enablePrivateNetworking && isPremium) {
  name: 'pe-${name}'
  params: {
    name: 'pe-${name}'
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    targetResourceId: registry.id
    groupId: 'registry'
    privateDnsZoneId: privateDnsZoneId
  }
}

// diagnosticSettings' only GA version (2016-09-01) predates categoryGroup support.
#disable-next-line use-recent-api-versions
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: registry
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

output id string = registry.id
output name string = registry.name
output loginServer string = registry.properties.loginServer
