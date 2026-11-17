// Key Vault with RBAC authorisation (no access policies) holding the platform's secrets.
// Apps read secrets as Container Apps Key Vault references through their managed identity;
// no secret value is ever placed in a template, pipeline variable or app setting.
import { requiredTags } from '../lib/types.bicep'

param location string
param tags requiredTags
param name string
param enablePrivateNetworking bool
param privateEndpointSubnetId string
param privateDnsZoneId string

@sys.description('Subnets admitted through the firewall via service endpoints (non-private environments).')
param allowedSubnetIds string[]
param logAnalyticsWorkspaceId string

@sys.description('Purge protection cannot be turned off again once on. Off in dev so teardown is clean.')
param enablePurgeProtection bool

@minValue(7)
@maxValue(90)
param softDeleteRetentionInDays int

@sys.description('Application Insights component whose connection string is stored as a secret.')
param appInsightsName string

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource vault 'Microsoft.KeyVault/vaults@2025-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: softDeleteRetentionInDays
    // ARM rejects an explicit false; the property must be omitted instead.
    enablePurgeProtection: enablePurgeProtection ? true : null
    publicNetworkAccess: enablePrivateNetworking ? 'Disabled' : 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: [
        for i in range(0, enablePrivateNetworking ? 0 : length(allowedSubnetIds)): { id: allowedSubnetIds[i] }
      ]
    }
  }

  resource appInsightsConnection 'secrets' = {
    name: 'appinsights-connection-string'
    properties: {
      value: appInsights.properties.ConnectionString
      contentType: 'text/plain'
      attributes: { enabled: true }
    }
  }
}

module endpoint 'private-endpoint.bicep' = if (enablePrivateNetworking) {
  name: 'pe-${name}'
  params: {
    name: 'pe-${name}'
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    targetResourceId: vault.id
    groupId: 'vault'
    privateDnsZoneId: privateDnsZoneId
  }
}

// diagnosticSettings' only GA version (2016-09-01) predates categoryGroup support.
#disable-next-line use-recent-api-versions
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: vault
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { categoryGroup: 'audit', enabled: true }
      { categoryGroup: 'allLogs', enabled: true }
    ]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

output id string = vault.id
output name string = vault.name
output uri string = vault.properties.vaultUri
output appInsightsSecretUri string = '${vault.properties.vaultUri}secrets/${vault::appInsightsConnection.name}'
