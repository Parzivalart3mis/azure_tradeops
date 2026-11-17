// Assigns the TradeOps guardrails initiative to one resource group.
targetScope = 'resourceGroup'

param initiativeId string
param effect string
param allowedLocations string[]

resource assignment 'Microsoft.Authorization/policyAssignments@2025-03-01' = {
  name: 'tradeops-guardrails'
  properties: {
    displayName: 'TradeOps guardrails (${resourceGroup().name})'
    policyDefinitionId: initiativeId
    enforcementMode: 'Default'
    parameters: {
      effect: { value: effect }
      allowedLocations: { value: allowedLocations }
    }
    nonComplianceMessages: [
      {
        message: 'Blocked by TradeOps guardrails. See docs/security.md for the control and how to request an exception.'
      }
    ]
  }
}
