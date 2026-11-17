// Representative values so PSRule can expand and scan the API template at PR time.
// Real deployments get their parameters from scripts/TradeOps (platform outputs + release).
using 'api.bicep'

param name = 'ca-tradeops-api-staging'
param tags = {
  application: 'tradeops'
  environment: 'staging'
  costCenter: 'CC-4410-PLATFORM'
  owner: 'platform-engineering'
  dataClassification: 'internal'
}
param environmentName = 'staging'
param containerAppsEnvironmentId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-tradeops-staging/providers/Microsoft.App/managedEnvironments/cae-tradeops-staging'
param image = 'crtradeopsstg000000.azurecr.io/tradeops@sha256:0000000000000000000000000000000000000000000000000000000000000000'
param registryLoginServer = 'crtradeopsstg000000.azurecr.io'
param revisionSuffix = 'r1-1'
param stableRevisionName = 'ca-tradeops-api-staging--r0-1'
param canaryWeight = 0
param identityId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-tradeops-staging/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-tradeops-api-staging'
param identityClientId = '00000000-0000-0000-0000-000000000001'
param appInsightsSecretUri = 'https://kv-tradeops-stg-000000.vault.azure.net/secrets/appinsights-connection-string'
param storageTableEndpoint = 'https://sttradeopsstg000000.table.core.windows.net/'
param ordersTable = 'orders'
param serviceBusFqdn = 'sb-tradeops-stg-000000.servicebus.windows.net'
param settlementQueue = 'settlement-requests'
param maxDeliveryCount = 5
param scale = { minReplicas: 1, maxReplicas: 5 }
param version = '1.0.0'
param gitSha = '0000000'
