// Container Apps managed environment: VNet-integrated, workload-profile based, logs to
// Azure Monitor through diagnostic settings (no workspace shared key needed) and mTLS
// between apps.
import { requiredTags } from '../lib/types.bicep'

param location string
param tags requiredTags
param name string
param infrastructureSubnetId string
param logAnalyticsWorkspaceId string
param zoneRedundant bool

resource environment 'Microsoft.App/managedEnvironments@2025-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: infrastructureSubnetId
      internal: false
    }
    workloadProfiles: [
      { name: 'Consumption', workloadProfileType: 'Consumption' }
    ]
    zoneRedundant: zoneRedundant
    appLogsConfiguration: { destination: 'azure-monitor' }
    peerAuthentication: { mtls: { enabled: true } }
    peerTrafficConfiguration: { encryption: { enabled: true } }
  }
}

// diagnosticSettings' only GA version (2016-09-01) predates categoryGroup support.
#disable-next-line use-recent-api-versions
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: environment
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

output id string = environment.id
output name string = environment.name
output defaultDomain string = environment.properties.defaultDomain
output staticIp string = environment.properties.staticIp
