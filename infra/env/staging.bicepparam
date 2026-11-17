// Staging: production-shaped release path (canary, smoke tests, automatic rollback) on
// cheaper SKUs. This is where the failing-release demo runs.
using '../main.bicep'

param environmentName = 'staging'
param tags = {
  application: 'tradeops'
  environment: 'staging'
  costCenter: 'CC-4410-PLATFORM'
  owner: 'platform-engineering'
  dataClassification: 'internal'
}
param network = {
  addressSpace: '10.20.0.0/16'
  containerAppsSubnet: '10.20.0.0/23'
  privateEndpointSubnet: '10.20.2.0/24'
}
param enablePrivateNetworking = false
param serviceBusSku = 'Standard'
param registrySku = 'Standard'
param storageSku = 'Standard_ZRS'
param zoneRedundant = true
param logRetentionInDays = 30
param logDailyQuotaGb = 2
param keyVaultPurgeProtection = true
param keyVaultSoftDeleteDays = 7
param alertEmailAddresses = ['platform-oncall@example.com']
param apiScale = { minReplicas: 1, maxReplicas: 5 }
param workerScale = { minReplicas: 1, maxReplicas: 5 }
