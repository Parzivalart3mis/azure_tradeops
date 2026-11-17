// Role assignments for a pipeline identity on one resource group. A non-empty condition
// is an ABAC condition (version 2.0) that constrains the assignment.
targetScope = 'resourceGroup'

param principalId string

@sys.description('Deterministic seed for assignment names, so what-if can predict them.')
param identityName string
param grants { role: string, condition: string }[]

resource assignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for grant in grants: {
    name: guid(resourceGroup().id, identityName, grant.role)
    properties: {
      principalId: principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', grant.role)
      condition: empty(grant.condition) ? null : grant.condition
      conditionVersion: empty(grant.condition) ? null : '2.0'
    }
  }
]
