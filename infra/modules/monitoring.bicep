// Log Analytics workspace, workspace-based Application Insights and the on-call action group.
import { requiredTags } from '../lib/types.bicep'

param location string
param tags requiredTags
param workspaceName string
param appInsightsName string
param actionGroupName string

@minValue(30)
@maxValue(730)
param retentionInDays int

@sys.description('Daily ingestion cap in GB, a cost guardrail. -1 means no cap.')
param dailyQuotaGb int

param alertEmailAddresses string[]

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-07-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionInDays
    workspaceCapping: { dailyQuotaGb: dailyQuotaGb }
    features: {
      // Queries must use Entra ID; workspace shared keys are not used anywhere in the platform.
      disableLocalAuth: true
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    IngestionMode: 'LogAnalytics'
    // Ingestion requires an Entra ID token (Monitoring Metrics Publisher role), so a
    // leaked connection string cannot be used to inject telemetry.
    DisableLocalAuth: true
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'global'
  tags: tags
  properties: {
    groupShortName: take(replace(actionGroupName, '-', ''), 12)
    enabled: true
    emailReceivers: [
      for (address, i) in alertEmailAddresses: {
        name: 'oncall-${i}'
        emailAddress: address
        useCommonAlertSchema: true
      }
    ]
  }
}

output workspaceId string = workspace.id
output workspaceName string = workspace.name
output workspaceCustomerId string = workspace.properties.customerId
output appInsightsId string = appInsights.id
output appInsightsName string = appInsights.name
output actionGroupId string = actionGroup.id
