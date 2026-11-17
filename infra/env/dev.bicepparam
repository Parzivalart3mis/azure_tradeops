// Development: cheapest viable footprint. Public PaaS endpoints behind firewalls that only
// admit the Container Apps subnet (service endpoints), Entra-only auth, scale-to-zero worker.
using '../main.bicep'

param environmentName = 'dev'
param tags = {
  application: 'tradeops'
  environment: 'dev'
  costCenter: 'CC-4410-PLATFORM'
  owner: 'platform-engineering'
  dataClassification: 'internal'
}
param network = {
  addressSpace: '10.10.0.0/16'
  containerAppsSubnet: '10.10.0.0/23'
  privateEndpointSubnet: '10.10.2.0/24'
}
param enablePrivateNetworking = false
param serviceBusSku = 'Standard'
param registrySku = 'Standard'
param storageSku = 'Standard_LRS'
param zoneRedundant = true
param logRetentionInDays = 30
param logDailyQuotaGb = 1
param keyVaultPurgeProtection = false
param keyVaultSoftDeleteDays = 7
param alertEmailAddresses = ['platform-oncall@example.com']
param apiScale = { minReplicas: 1, maxReplicas: 3 }
param workerScale = { minReplicas: 0, maxReplicas: 3 }
