// Least-privilege, data-plane role assignments for the workload identities. Each grant is
// scoped to the single resource (or queue) the workload needs, never the resource group.
//
//   api     AcrPull (registry)  KV Secrets User (vault)  SB Data Sender (queue)
//           Table Data Contributor (storage)  Monitoring Metrics Publisher (App Insights)
//   worker  AcrPull (registry)  KV Secrets User (vault)  SB Data Receiver (queue)
//           SB Data Owner (queue, for the KEDA scaler's queue-length read)
//           Table Data Contributor (storage)  Monitoring Metrics Publisher (App Insights)

param apiPrincipalId string
param workerPrincipalId string
param registryName string
param keyVaultName string
param serviceBusName string
param queueName string
param storageAccountName string
param appInsightsName string

var roles = {
  acrPull: '7f951dda-4ed3-4680-a7ca-43fe172d538d'
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6' // built-in role id, not a secret: gitleaks:allow
  serviceBusDataSender: '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39'
  serviceBusDataReceiver: '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0'
  serviceBusDataOwner: '090c5cfd-751d-490a-894a-3ce6f1109419'
  storageTableDataContributor: '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
  monitoringMetricsPublisher: '3913510d-42f4-4e42-8a64-420c390055eb'
}

resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' existing = {
  name: registryName
}

resource vault 'Microsoft.KeyVault/vaults@2025-05-01' existing = {
  name: keyVaultName
}

resource namespace 'Microsoft.ServiceBus/namespaces@2026-01-01' existing = {
  name: serviceBusName

  resource queue 'queues' existing = {
    name: queueName
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2025-06-01' existing = {
  name: storageAccountName
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

var workloads = [
  { principalId: apiPrincipalId, queueRoles: [roles.serviceBusDataSender] }
  { principalId: workerPrincipalId, queueRoles: [roles.serviceBusDataReceiver, roles.serviceBusDataOwner] }
]

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for w in workloads: {
    name: guid(registry.id, w.principalId, roles.acrPull)
    scope: registry
    properties: {
      principalId: w.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.acrPull)
    }
  }
]

resource secretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for w in workloads: {
    name: guid(vault.id, w.principalId, roles.keyVaultSecretsUser)
    scope: vault
    properties: {
      principalId: w.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.keyVaultSecretsUser)
    }
  }
]

resource tableData 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for w in workloads: {
    name: guid(storage.id, w.principalId, roles.storageTableDataContributor)
    scope: storage
    properties: {
      principalId: w.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId(
        'Microsoft.Authorization/roleDefinitions',
        roles.storageTableDataContributor
      )
    }
  }
]

resource telemetryPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for w in workloads: {
    name: guid(appInsights.id, w.principalId, roles.monitoringMetricsPublisher)
    scope: appInsights
    properties: {
      principalId: w.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId(
        'Microsoft.Authorization/roleDefinitions',
        roles.monitoringMetricsPublisher
      )
    }
  }
]

var queueGrants = flatten(map(workloads, w => map(w.queueRoles, r => { principalId: w.principalId, role: r })))

resource queueData 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for g in queueGrants: {
    name: guid(namespace::queue.id, g.principalId, g.role)
    scope: namespace::queue
    properties: {
      principalId: g.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', g.role)
    }
  }
]
