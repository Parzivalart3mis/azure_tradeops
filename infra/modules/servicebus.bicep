// Service Bus namespace and the settlement queue.
//  * disableLocalAuth: SAS keys are off; senders and receivers use Entra ID only.
//  * requiresDuplicateDetection: the API uses the order id as MessageId, so a retried
//    publish of the same order is dropped by the broker (no double settlement).
//  * maxDeliveryCount 5, then the dead-letter queue, which is alerted on.
import { requiredTags } from '../lib/types.bicep'

param location string
param tags requiredTags
param name string
param queueName string

@allowed(['Standard', 'Premium'])
param sku string

@minValue(1)
@maxValue(100)
param maxDeliveryCount int

@sys.description('Requires Premium. Disables public access and adds a private endpoint.')
param enablePrivateNetworking bool
param privateEndpointSubnetId string
param privateDnsZoneId string
param logAnalyticsWorkspaceId string

var isPremium = sku == 'Premium'

resource namespace 'Microsoft.ServiceBus/namespaces@2026-01-01' = {
  name: name
  location: location
  tags: tags
  sku: { name: sku, tier: sku, capacity: isPremium ? 1 : null }
  properties: {
    disableLocalAuth: true
    minimumTlsVersion: '1.2'
    publicNetworkAccess: enablePrivateNetworking && isPremium ? 'Disabled' : 'Enabled'
    zoneRedundant: isPremium
  }

  resource queue 'queues' = {
    name: queueName
    properties: {
      requiresDuplicateDetection: true
      duplicateDetectionHistoryTimeWindow: 'PT1H'
      maxDeliveryCount: maxDeliveryCount
      lockDuration: 'PT1M'
      deadLetteringOnMessageExpiration: true
      defaultMessageTimeToLive: 'P1D'
      enablePartitioning: false
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
    targetResourceId: namespace.id
    groupId: 'namespace'
    privateDnsZoneId: privateDnsZoneId
  }
}

// diagnosticSettings' only GA version (2016-09-01) predates categoryGroup support.
#disable-next-line use-recent-api-versions
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: namespace
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

output id string = namespace.id
output name string = namespace.name
output queueId string = namespace::queue.id
output queueName string = namespace::queue.name
// serviceBusEndpoint is https://<name>.servicebus.windows.net:443/; keep only the host.
output fqdn string = split(replace(namespace.properties.serviceBusEndpoint, 'https://', ''), ':')[0]
