// Settlement worker container app. No ingress; single-revision mode; KEDA scales it on
// settlement-queue depth, authenticating to Service Bus with the worker's managed identity.
// It is deployed only after the API canary has been promoted, so a release that fails
// canary analysis never touches the consumer.
import { requiredTags, scaleConfig } from '../lib/types.bicep'

param name string
param location string = resourceGroup().location
param tags requiredTags
param environmentName string
param containerAppsEnvironmentId string
param image string
param registryLoginServer string

@maxLength(30)
param revisionSuffix string

param identityId string
param identityClientId string
param appInsightsSecretUri string
param storageTableEndpoint string
param ordersTable string
param serviceBusName string
param serviceBusFqdn string
param settlementQueue string
param maxDeliveryCount int
param scale scaleConfig
param version string
param gitSha string

@sys.description('Queue messages per replica before KEDA adds another replica.')
param messagesPerReplica int = 20

resource app 'Microsoft.App/containerApps@2025-07-01' = {
  name: name
  location: location
  tags: union(tags, { 'tradeops-release': version })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: {
    environmentId: containerAppsEnvironmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      maxInactiveRevisions: 10
      registries: [{ server: registryLoginServer, identity: identityId }]
      secrets: [
        {
          name: 'appinsights-connection-string'
          keyVaultUrl: appInsightsSecretUri
          identity: identityId
        }
      ]
    }
    template: {
      revisionSuffix: revisionSuffix
      // Settlement batches are short; give in-flight messages time to finish on scale-in.
      terminationGracePeriodSeconds: 60
      containers: [
        {
          name: 'worker'
          image: image
          command: ['python', '-m', 'tradeops.worker']
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'TRADEOPS_ENVIRONMENT', value: environmentName }
            { name: 'TRADEOPS_BACKEND', value: 'azure' }
            { name: 'TRADEOPS_VERSION', value: version }
            { name: 'TRADEOPS_GIT_SHA', value: gitSha }
            { name: 'TRADEOPS_STORAGE_TABLE_ENDPOINT', value: storageTableEndpoint }
            { name: 'TRADEOPS_ORDERS_TABLE', value: ordersTable }
            { name: 'TRADEOPS_SERVICEBUS_NAMESPACE', value: serviceBusFqdn }
            { name: 'TRADEOPS_SETTLEMENT_QUEUE', value: settlementQueue }
            { name: 'TRADEOPS_MAX_DELIVERY_COUNT', value: string(maxDeliveryCount) }
            { name: 'TRADEOPS_APPINSIGHTS_ENTRA_AUTH', value: 'true' }
            { name: 'AZURE_CLIENT_ID', value: identityClientId }
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', secretRef: 'appinsights-connection-string' }
          ]
        }
      ]
      scale: {
        minReplicas: scale.minReplicas
        maxReplicas: scale.maxReplicas
        rules: [
          {
            name: 'settlement-queue-depth'
            custom: {
              type: 'azure-servicebus'
              identity: identityId
              metadata: {
                namespace: serviceBusName
                queueName: settlementQueue
                messageCount: string(messagesPerReplica)
              }
            }
          }
        ]
      }
    }
  }
}

output appName string = app.name
output latestRevisionName string = app.properties.latestRevisionName
