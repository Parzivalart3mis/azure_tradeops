// Production: private endpoints for Key Vault, Storage, Service Bus and ACR with public
// access disabled; zone redundancy; Premium SKUs; 90-day logs; Sev1 alerts.
// Cost note: Premium Service Bus and ACR dominate the bill (see docs/cost.md).
using '../main.bicep'

param environmentName = 'prod'
param tags = {
  application: 'tradeops'
  environment: 'prod'
  costCenter: 'CC-4410-PLATFORM'
  owner: 'platform-engineering'
  dataClassification: 'confidential'
}
param network = {
  addressSpace: '10.30.0.0/16'
  containerAppsSubnet: '10.30.0.0/23'
  privateEndpointSubnet: '10.30.2.0/24'
}
param enablePrivateNetworking = true
param serviceBusSku = 'Premium'
param registrySku = 'Premium'
param storageSku = 'Standard_GZRS'
param zoneRedundant = true
param logRetentionInDays = 90
param logDailyQuotaGb = 10
param keyVaultPurgeProtection = true
param keyVaultSoftDeleteDays = 90
param alertEmailAddresses = ['platform-oncall@example.com']
param errorRateThresholdPct = 2
param latencyP95ThresholdMs = 750
param apiScale = { minReplicas: 2, maxReplicas: 10 }
param workerScale = { minReplicas: 2, maxReplicas: 10 }
