// TradeOps guardrails as custom Azure Policy definitions, grouped in one initiative and
// assigned (Deny) to each TradeOps resource group. These are the last line of defence:
// even a change made by hand in the portal, outside the pipeline, is rejected by ARM.
//
// The pipeline catches the same problems earlier (PSRule for Azure at PR time, see
// ps-rule.yaml); this layer makes them impossible rather than merely detected.
//
// Deployed once per subscription by a platform administrator (needs Resource Policy
// Contributor), never by the release pipeline:
//   az deployment sub create -l eastus2 -f infra/governance/policies.bicep \
//     -p resourceGroupNames='["rg-tradeops-dev","rg-tradeops-staging","rg-tradeops-prod"]'
targetScope = 'subscription'

@sys.description('Resource groups the initiative is assigned to.')
param resourceGroupNames string[]

@sys.description('Regions resources may be deployed to.')
param allowedLocations string[] = ['eastus2', 'centralus']

@allowed(['Deny', 'Audit'])
param effect string = 'Deny'

var category = 'TradeOps Guardrails'

// name -> { displayName, description, mode, rule }. Each rule's `then` uses the shared effect.
var definitions = {
  'tradeops-storage-no-public-blob': {
    displayName: 'Storage accounts must not allow public blob access'
    mode: 'Indexed'
    if: {
      allOf: [
        { field: 'type', equals: 'Microsoft.Storage/storageAccounts' }
        { field: 'Microsoft.Storage/storageAccounts/allowBlobPublicAccess', notEquals: false }
      ]
    }
  }
  'tradeops-storage-no-shared-key': {
    displayName: 'Storage accounts must disable shared key (account key) access'
    mode: 'Indexed'
    if: {
      allOf: [
        { field: 'type', equals: 'Microsoft.Storage/storageAccounts' }
        { field: 'Microsoft.Storage/storageAccounts/allowSharedKeyAccess', notEquals: false }
      ]
    }
  }
  'tradeops-storage-secure-transport': {
    displayName: 'Storage accounts must require HTTPS and TLS 1.2 or later'
    mode: 'Indexed'
    if: {
      allOf: [
        { field: 'type', equals: 'Microsoft.Storage/storageAccounts' }
        {
          anyOf: [
            { field: 'Microsoft.Storage/storageAccounts/supportsHttpsTrafficOnly', notEquals: true }
            { field: 'Microsoft.Storage/storageAccounts/minimumTlsVersion', notIn: ['TLS1_2', 'TLS1_3'] }
          ]
        }
      ]
    }
  }
  'tradeops-keyvault-rbac': {
    displayName: 'Key vaults must use the Azure RBAC permission model'
    mode: 'Indexed'
    if: {
      allOf: [
        { field: 'type', equals: 'Microsoft.KeyVault/vaults' }
        { field: 'Microsoft.KeyVault/vaults/enableRbacAuthorization', notEquals: true }
      ]
    }
  }
  'tradeops-acr-no-admin-user': {
    displayName: 'Container registries must not enable the admin user'
    mode: 'Indexed'
    if: {
      allOf: [
        { field: 'type', equals: 'Microsoft.ContainerRegistry/registries' }
        { field: 'Microsoft.ContainerRegistry/registries/adminUserEnabled', equals: true }
      ]
    }
  }
  'tradeops-servicebus-no-local-auth': {
    displayName: 'Service Bus namespaces must disable SAS (local) authentication'
    mode: 'Indexed'
    if: {
      allOf: [
        { field: 'type', equals: 'Microsoft.ServiceBus/namespaces' }
        { field: 'Microsoft.ServiceBus/namespaces/disableLocalAuth', notEquals: true }
      ]
    }
  }
  'tradeops-containerapps-https-only': {
    displayName: 'Container Apps ingress must not allow insecure (HTTP) connections'
    mode: 'Indexed'
    if: {
      allOf: [
        { field: 'type', equals: 'Microsoft.App/containerApps' }
        { field: 'Microsoft.App/containerApps/configuration.ingress.allowInsecure', equals: true }
      ]
    }
  }
  'tradeops-required-tags': {
    displayName: 'Resources must carry costCenter, owner and dataClassification tags'
    mode: 'Indexed'
    if: {
      anyOf: [
        { field: 'tags[costCenter]', exists: false }
        { field: 'tags[owner]', exists: false }
        { field: 'tags[dataClassification]', exists: false }
      ]
    }
  }
}

resource policyDefinitions 'Microsoft.Authorization/policyDefinitions@2025-03-01' = [
  for def in items(definitions): {
    name: def.key
    properties: {
      displayName: def.value.displayName
      policyType: 'Custom'
      mode: def.value.mode
      metadata: { category: category, version: '1.0.0' }
      parameters: {
        effect: {
          type: 'String'
          allowedValues: ['Deny', 'Audit', 'Disabled']
          defaultValue: 'Deny'
        }
      }
      policyRule: {
        if: def.value.if
        then: { effect: '[parameters(\'effect\')]' }
      }
    }
  }
]

resource allowedLocationsDefinition 'Microsoft.Authorization/policyDefinitions@2025-03-01' = {
  name: 'tradeops-allowed-locations'
  properties: {
    displayName: 'Resources must be deployed to approved regions'
    policyType: 'Custom'
    mode: 'Indexed'
    metadata: { category: category, version: '1.0.0' }
    parameters: {
      effect: { type: 'String', allowedValues: ['Deny', 'Audit', 'Disabled'], defaultValue: 'Deny' }
      allowedLocations: { type: 'Array' }
    }
    policyRule: {
      if: {
        allOf: [
          { field: 'location', notIn: '[parameters(\'allowedLocations\')]' }
          { field: 'location', notEquals: 'global' }
        ]
      }
      then: { effect: '[parameters(\'effect\')]' }
    }
  }
}

var definitionReferences = [
  for def in items(definitions): {
    policyDefinitionReferenceId: def.key
    policyDefinitionId: subscriptionResourceId('Microsoft.Authorization/policyDefinitions', def.key)
    parameters: { effect: { value: '[parameters(\'effect\')]' } }
  }
]

resource initiative 'Microsoft.Authorization/policySetDefinitions@2025-03-01' = {
  name: 'tradeops-guardrails'
  properties: {
    displayName: 'TradeOps guardrails'
    description: 'Security baseline for the TradeOps platform. Assigned with Deny.'
    policyType: 'Custom'
    metadata: { category: category, version: '1.0.0' }
    parameters: {
      effect: { type: 'String', allowedValues: ['Deny', 'Audit', 'Disabled'], defaultValue: 'Deny' }
      allowedLocations: { type: 'Array' }
    }
    policyDefinitions: concat(definitionReferences, [
      {
        policyDefinitionReferenceId: 'tradeops-allowed-locations'
        policyDefinitionId: allowedLocationsDefinition.id
        parameters: {
          effect: { value: '[parameters(\'effect\')]' }
          allowedLocations: { value: '[parameters(\'allowedLocations\')]' }
        }
      }
    ])
  }
  dependsOn: [policyDefinitions]
}

module assignments 'policy-assignment.bicep' = [
  for rg in resourceGroupNames: {
    name: 'tradeops-guardrails-${rg}'
    scope: resourceGroup(rg)
    params: {
      initiativeId: initiative.id
      effect: effect
      allowedLocations: allowedLocations
    }
  }
]

output initiativeId string = initiative.id
