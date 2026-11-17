// Azure TradeOps platform: everything an environment needs except the container apps
// themselves, which are deployed per release by infra/apps/*.bicep so that an
// infrastructure change never moves live traffic between revisions.
//
// Deploy (one resource group per environment, created by infra/bootstrap):
//   az deployment group create -g rg-tradeops-dev -n tradeops-platform \
//     -f infra/main.bicep -p infra/env/dev.bicepparam
targetScope = 'resourceGroup'

import { environmentType, networkConfig, requiredTags, scaleConfig, shortEnvironmentName } from 'lib/types.bicep'

@sys.description('Deployment stage.')
param environmentName environmentType

param location string = resourceGroup().location
param workload string = 'tradeops'
param tags requiredTags
param network networkConfig

@sys.description('Private endpoints and public access disabled on PaaS services. Needs Premium Service Bus and ACR.')
param enablePrivateNetworking bool

@sys.description('CIDRs allowed to reach the API ingress. Empty allows any source.')
param allowedIngressCidrs string[] = []

@allowed(['Standard', 'Premium'])
param serviceBusSku string

@allowed(['Basic', 'Standard', 'Premium'])
param registrySku string

@allowed(['Standard_LRS', 'Standard_ZRS', 'Standard_GZRS'])
param storageSku string

param zoneRedundant bool
param logRetentionInDays int
param logDailyQuotaGb int
param keyVaultPurgeProtection bool
param keyVaultSoftDeleteDays int
param alertEmailAddresses string[]
param errorRateThresholdPct int = 5
param latencyP95ThresholdMs int = 1000

@sys.description('Replica bounds for the API and worker, consumed by the release pipeline.')
param apiScale scaleConfig
param workerScale scaleConfig

param deployDatabricks bool = false

var envCode = shortEnvironmentName(environmentName)
var suffix = take(uniqueString(subscription().id, resourceGroup().id, workload), 6)
var names = {
  vnet: 'vnet-${workload}-${environmentName}'
  logAnalytics: 'log-${workload}-${environmentName}'
  appInsights: 'appi-${workload}-${environmentName}'
  actionGroup: 'ag-${workload}-${environmentName}'
  keyVault: 'kv-${workload}-${envCode}-${suffix}'
  registry: 'cr${workload}${envCode}${suffix}'
  serviceBus: 'sb-${workload}-${envCode}-${suffix}'
  storage: 'st${workload}${envCode}${suffix}'
  containerAppsEnv: 'cae-${workload}-${environmentName}'
  apiIdentity: 'id-${workload}-api-${environmentName}'
  workerIdentity: 'id-${workload}-worker-${environmentName}'
  apiApp: 'ca-${workload}-api-${environmentName}'
  workerApp: 'ca-${workload}-worker-${environmentName}'
  databricks: 'dbw-${workload}-${environmentName}'
}
var settlementQueue = 'settlement-requests'
var ordersTable = 'orders'
var maxDeliveryCount = 5

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    tags: tags
    workspaceName: names.logAnalytics
    appInsightsName: names.appInsights
    actionGroupName: names.actionGroup
    retentionInDays: logRetentionInDays
    dailyQuotaGb: logDailyQuotaGb
    alertEmailAddresses: alertEmailAddresses
  }
}

module net 'modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
    tags: tags
    vnetName: names.vnet
    network: network
    allowedIngressCidrs: allowedIngressCidrs
    enablePrivateNetworking: enablePrivateNetworking
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

module identities 'modules/identity.bicep' = {
  name: 'identities'
  params: {
    location: location
    tags: tags
    names: [names.apiIdentity, names.workerIdentity]
  }
}

module vault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    location: location
    tags: tags
    name: names.keyVault
    enablePrivateNetworking: enablePrivateNetworking
    privateEndpointSubnetId: net.outputs.privateEndpointSubnetId
    privateDnsZoneId: net.outputs.privateDnsZoneIds.keyVault
    allowedSubnetIds: [net.outputs.containerAppsSubnetId]
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    enablePurgeProtection: keyVaultPurgeProtection
    softDeleteRetentionInDays: keyVaultSoftDeleteDays
    // Name rather than module output keeps what-if precise; workspaceId above already
    // makes this module wait for monitoring.
    appInsightsName: names.appInsights
  }
}

module registry 'modules/registry.bicep' = {
  name: 'registry'
  params: {
    location: location
    tags: tags
    name: names.registry
    sku: registrySku
    enablePrivateNetworking: enablePrivateNetworking
    privateEndpointSubnetId: net.outputs.privateEndpointSubnetId
    privateDnsZoneId: net.outputs.privateDnsZoneIds.registry
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

module bus 'modules/servicebus.bicep' = {
  name: 'servicebus'
  params: {
    location: location
    tags: tags
    name: names.serviceBus
    queueName: settlementQueue
    sku: serviceBusSku
    maxDeliveryCount: maxDeliveryCount
    enablePrivateNetworking: enablePrivateNetworking
    privateEndpointSubnetId: net.outputs.privateEndpointSubnetId
    privateDnsZoneId: net.outputs.privateDnsZoneIds.serviceBus
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    tags: tags
    name: names.storage
    tableName: ordersTable
    skuName: storageSku
    enablePrivateNetworking: enablePrivateNetworking
    privateEndpointSubnetId: net.outputs.privateEndpointSubnetId
    privateDnsZoneId: net.outputs.privateDnsZoneIds.table
    allowedSubnetIds: [net.outputs.containerAppsSubnetId]
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

module rbac 'modules/rbac.bicep' = {
  name: 'rbac'
  params: {
    apiPrincipalId: identities.outputs.identities[0].principalId
    workerPrincipalId: identities.outputs.identities[1].principalId
    // Deterministic names (not module outputs) keep what-if predictions precise.
    registryName: names.registry
    keyVaultName: names.keyVault
    serviceBusName: names.serviceBus
    queueName: settlementQueue
    storageAccountName: names.storage
    appInsightsName: names.appInsights
  }
  dependsOn: [registry, vault, bus, storage]
}

module containerAppsEnv 'modules/containerapps-env.bicep' = {
  name: 'containerapps-env'
  params: {
    location: location
    tags: tags
    name: names.containerAppsEnv
    infrastructureSubnetId: net.outputs.containerAppsSubnetId
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    zoneRedundant: zoneRedundant
  }
}

module alerts 'modules/alerts.bicep' = {
  name: 'alerts'
  params: {
    location: location
    tags: tags
    environmentName: environmentName
    workspaceId: monitoring.outputs.workspaceId
    serviceBusId: bus.outputs.id
    actionGroupId: monitoring.outputs.actionGroupId
    errorRateThresholdPct: errorRateThresholdPct
    latencyP95ThresholdMs: latencyP95ThresholdMs
  }
}

module workbook 'modules/workbook.bicep' = {
  name: 'workbook'
  params: {
    location: location
    tags: tags
    environmentName: environmentName
    workspaceId: monitoring.outputs.workspaceId
  }
}

module databricks 'modules/databricks.bicep' = if (deployDatabricks) {
  name: 'databricks'
  params: {
    location: location
    tags: tags
    name: names.databricks
  }
}

// ---------------------------------------------------------------------------------------
// Platform contract. scripts/TradeOps reads these outputs from the `tradeops-platform`
// deployment to deploy releases, so names never have to be recomputed outside Bicep.
// ---------------------------------------------------------------------------------------
output environmentName string = environmentName
output location string = location
output tags object = tags
output containerAppsEnvironmentId string = containerAppsEnv.outputs.id
output containerAppsDefaultDomain string = containerAppsEnv.outputs.defaultDomain
output registryName string = registry.outputs.name
output registryLoginServer string = registry.outputs.loginServer
output keyVaultName string = vault.outputs.name
output appInsightsSecretUri string = vault.outputs.appInsightsSecretUri
output storageTableEndpoint string = storage.outputs.tableEndpoint
output ordersTable string = storage.outputs.tableName
output serviceBusName string = bus.outputs.name
output serviceBusFqdn string = bus.outputs.fqdn
output settlementQueue string = bus.outputs.queueName
output maxDeliveryCount int = maxDeliveryCount
output logAnalyticsWorkspaceId string = monitoring.outputs.workspaceId
output logAnalyticsCustomerId string = monitoring.outputs.workspaceCustomerId
output appInsightsName string = monitoring.outputs.appInsightsName
output apiAppName string = names.apiApp
output workerAppName string = names.workerApp
output apiIdentityId string = identities.outputs.identities[0].id
output apiIdentityClientId string = identities.outputs.identities[0].clientId
output workerIdentityId string = identities.outputs.identities[1].id
output workerIdentityClientId string = identities.outputs.identities[1].clientId
output apiScale object = apiScale
output workerScale object = workerScale
output databricksUrl string = deployDatabricks ? databricks!.outputs.url : ''
