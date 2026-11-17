// Storage account holding the order ledger (Azure Table Storage).
// Shared keys are disabled: the only way in is Entra ID with a data-plane RBAC role.
import { requiredTags } from '../lib/types.bicep'

param location string
param tags requiredTags
param name string
param tableName string

@allowed(['Standard_LRS', 'Standard_ZRS', 'Standard_GZRS'])
param skuName string

param enablePrivateNetworking bool
param privateEndpointSubnetId string
param privateDnsZoneId string

@sys.description('Subnets admitted through the firewall via service endpoints (non-private environments).')
param allowedSubnetIds string[]
param logAnalyticsWorkspaceId string

resource account 'Microsoft.Storage/storageAccounts@2025-06-01' = {
  name: name
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: skuName }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    allowCrossTenantReplication: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: enablePrivateNetworking ? 'Disabled' : 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: [
        for i in range(0, enablePrivateNetworking ? 0 : length(allowedSubnetIds)): { id: allowedSubnetIds[i] }
      ]
    }
    encryption: {
      requireInfrastructureEncryption: true
      keySource: 'Microsoft.Storage'
      services: {
        blob: { enabled: true, keyType: 'Account' }
        file: { enabled: true, keyType: 'Account' }
        table: { enabled: true, keyType: 'Account' }
        queue: { enabled: true, keyType: 'Account' }
      }
    }
  }

  resource blobService 'blobServices' = {
    name: 'default'
    properties: {
      deleteRetentionPolicy: { enabled: true, days: 7 }
      containerDeleteRetentionPolicy: { enabled: true, days: 7 }
    }
  }

  resource tableService 'tableServices' = {
    name: 'default'

    resource ordersTable 'tables' = {
      name: tableName
    }
  }
}

module endpoint 'private-endpoint.bicep' = if (enablePrivateNetworking) {
  name: 'pe-${name}-table'
  params: {
    name: 'pe-${name}-table'
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    targetResourceId: account.id
    groupId: 'table'
    privateDnsZoneId: privateDnsZoneId
  }
}

// diagnosticSettings' only GA version (2016-09-01) predates categoryGroup support.
#disable-next-line use-recent-api-versions
resource tableDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: account::tableService
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'Transaction', enabled: true }]
  }
}

output id string = account.id
output name string = account.name
output tableEndpoint string = account.properties.primaryEndpoints.table
output tableName string = account::tableService::ordersTable.name
