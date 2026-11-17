// Optional Azure Databricks workspace for the synthetic-transaction analytics pipeline
// (databricks/). Off by default: it is the most expensive optional component.
import { requiredTags } from '../lib/types.bicep'

param location string
param tags requiredTags
param name string

@allowed(['premium', 'standard'])
param sku string = 'premium'

resource workspace 'Microsoft.Databricks/workspaces@2026-01-01' = {
  name: name
  location: location
  tags: tags
  sku: { name: sku }
  properties: {
    computeMode: 'Hybrid'
    managedResourceGroupId: subscriptionResourceId('Microsoft.Resources/resourceGroups', '${resourceGroup().name}-dbw-managed')
    publicNetworkAccess: 'Enabled'
    requiredNsgRules: 'AllRules'
    parameters: {
      enableNoPublicIp: { value: true }
    }
  }
}

output id string = workspace.id
output url string = workspace.properties.workspaceUrl
