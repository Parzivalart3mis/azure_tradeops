// Order API container app, deployed once per release by scripts/TradeOps (Deploy-Release.ps1).
//
// Multiple-revision mode with labelled traffic:
//   first release      new revision 100%           label 'stable'
//   later releases     stable revision 100% - w    label 'stable'
//                      new revision w (0 at first) label 'canary'
// The release script then smoke-tests the canary through its label URL, moves traffic in
// steps with `az containerapp ingress traffic set`, and promotes or rolls back. This
// template never changes traffic on its own: the caller passes the current stable revision.
import { requiredTags, scaleConfig } from '../lib/types.bicep'

param name string
param location string = resourceGroup().location
param tags requiredTags
param environmentName string
param containerAppsEnvironmentId string

@sys.description('Image reference, pinned by digest: <registry>/tradeops@sha256:...')
param image string
param registryLoginServer string

@sys.description('Unique per deployment, e.g. r20261116-4521-1. Lowercase letters, digits and hyphens.')
@maxLength(30)
param revisionSuffix string

@sys.description('Revision currently serving production traffic. Empty on the first release.')
param stableRevisionName string = ''

@minValue(0)
@maxValue(100)
param canaryWeight int = 0

param identityId string
param identityClientId string
param appInsightsSecretUri string
param storageTableEndpoint string
param ordersTable string
param serviceBusFqdn string
param settlementQueue string
param maxDeliveryCount int
param scale scaleConfig

param version string
param gitSha string

@sys.description('Fault injection for the failing-release demo: fraction of /v1 requests that fail.')
param faultRate string = '0'

@sys.description('CIDRs allowed to call the API. Empty allows any source.')
param allowedIngressCidrs string[] = []

var newRevisionName = '${name}--${revisionSuffix}'
var isFirstRelease = empty(stableRevisionName)

var traffic = isFirstRelease
  ? [{ revisionName: newRevisionName, weight: 100, label: 'stable' }]
  : [
      { revisionName: stableRevisionName, weight: 100 - canaryWeight, label: 'stable' }
      { revisionName: newRevisionName, weight: canaryWeight, label: 'canary' }
    ]

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
      activeRevisionsMode: 'Multiple'
      maxInactiveRevisions: 20
      ingress: {
        external: true
        targetPort: 8080
        transport: 'http'
        allowInsecure: false
        traffic: traffic
        ipSecurityRestrictions: [
          for (cidr, i) in allowedIngressCidrs: {
            name: 'allow-${i}'
            action: 'Allow'
            ipAddressRange: cidr
          }
        ]
      }
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
      containers: [
        {
          name: 'api'
          image: image
          resources: { cpu: json('0.5'), memory: '1Gi' }
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
            { name: 'TRADEOPS_FAULT_RATE', value: faultRate }
            { name: 'TRADEOPS_APPINSIGHTS_ENTRA_AUTH', value: 'true' }
            { name: 'AZURE_CLIENT_ID', value: identityClientId }
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', secretRef: 'appinsights-connection-string' }
          ]
          probes: [
            {
              type: 'Startup'
              httpGet: { path: '/healthz', port: 8080 }
              periodSeconds: 2
              failureThreshold: 30
            }
            {
              type: 'Liveness'
              httpGet: { path: '/healthz', port: 8080 }
              periodSeconds: 10
              failureThreshold: 3
            }
            {
              type: 'Readiness'
              httpGet: { path: '/readyz', port: 8080 }
              periodSeconds: 5
              failureThreshold: 3
              timeoutSeconds: 3
            }
          ]
        }
      ]
      scale: {
        minReplicas: scale.minReplicas
        maxReplicas: scale.maxReplicas
        rules: [{ name: 'http', http: { metadata: { concurrentRequests: '50' } } }]
      }
    }
  }
}

output appName string = app.name
output fqdn string = app.properties.configuration.ingress.fqdn
output newRevisionName string = newRevisionName
output latestRevisionName string = app.properties.latestRevisionName
