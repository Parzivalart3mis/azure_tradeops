// Azure Monitor workbook: the TradeOps operations dashboard (monitoring/tradeops-workbook.json).
import { requiredTags } from '../lib/types.bicep'

param location string
param tags requiredTags
param environmentName string
param workspaceId string

var definition = replace(
  loadTextContent('../../monitoring/tradeops-workbook.json'),
  '__WORKSPACE_ID__',
  workspaceId
)

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, 'tradeops-operations-workbook')
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: 'TradeOps operations (${environmentName})'
    category: 'workbook'
    sourceId: workspaceId
    serializedData: definition
  }
}

output id string = workbook.id
