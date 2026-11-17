// One-time subscription bootstrap, run by a subscription Owner:
//   * a resource group per environment, plus rg-tradeops-cicd for the pipeline identities
//   * one user-assigned identity per environment for Azure DevOps, federated with that
//     environment's service connection (workload identity federation: no client secrets)
//   * each identity scoped to its own resource group only:
//       Contributor
//       Role Based Access Control Administrator, constrained by an ABAC condition so it
//       can only grant the seven data-plane roles the workloads need. It cannot grant
//       Owner, Contributor or User Access Administrator, so a compromised pipeline cannot
//       escalate its own privileges.
//   * promotion rights: staging may read and pull from dev's registry, prod from staging's
//     (Reader to resolve the release digest, AcrPull to import it).
//
//   az deployment sub create -l eastus2 -f infra/bootstrap/main.bicep -p infra/bootstrap/bootstrap.bicepparam
targetScope = 'subscription'

param location string = 'eastus2'
param workload string = 'tradeops'

@sys.description('Workload identity federation issuer shown on the Azure DevOps service connection.')
param federationIssuer string

@sys.description('Federation subject per environment, as shown on each service connection.')
param federationSubjects {
  dev: string
  staging: string
  prod: string
}

param tags object = {
  application: 'tradeops'
  costCenter: 'CC-4410-PLATFORM'
  owner: 'platform-engineering'
  dataClassification: 'internal'
}

var environments = ['dev', 'staging', 'prod']

var roles = {
  contributor: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
  rbacAdministrator: 'f58310d9-a9f6-439a-9e8d-f62e7b41a168'
  acrPush: '8311e382-0749-4cb8-b61a-304f252e45ec'
  acrPull: '7f951dda-4ed3-4680-a7ca-43fe172d538d'
  reader: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
}

// The only roles the pipeline may hand out (see infra/modules/rbac.bicep).
var assignableRoles = [
  '7f951dda-4ed3-4680-a7ca-43fe172d538d' // AcrPull
  '4633458b-17de-408a-b874-0445c86b69e6' // Key Vault Secrets User
  '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39' // Azure Service Bus Data Sender
  '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0' // Azure Service Bus Data Receiver
  '090c5cfd-751d-490a-894a-3ce6f1109419' // Azure Service Bus Data Owner (queue scope, KEDA)
  '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3' // Storage Table Data Contributor
  '3913510d-42f4-4e42-8a64-420c390055eb' // Monitoring Metrics Publisher
]
var roleList = join(assignableRoles, ', ')
var constrainedDelegation = '((!(ActionMatches{\'Microsoft.Authorization/roleAssignments/write\'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${roleList}})) AND ((!(ActionMatches{\'Microsoft.Authorization/roleAssignments/delete\'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${roleList}}))'

resource cicdGroup 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: 'rg-${workload}-cicd'
  location: location
  tags: union(tags, { environment: 'shared' })
}

resource environmentGroups 'Microsoft.Resources/resourceGroups@2025-04-01' = [
  for env in environments: {
    name: 'rg-${workload}-${env}'
    location: location
    tags: union(tags, { environment: env })
  }
]

module pipelineIdentities 'pipeline-identity.bicep' = [
  for env in environments: {
    name: 'pipeline-identity-${env}'
    scope: cicdGroup
    params: {
      name: 'id-${workload}-pipeline-${env}'
      location: location
      tags: union(tags, { environment: env })
      federationIssuer: federationIssuer
      federationSubject: federationSubjects[env]
    }
  }
]

module environmentAccess 'pipeline-access.bicep' = [
  for (env, i) in environments: {
    name: 'pipeline-access-${env}'
    scope: environmentGroups[i]
    params: {
      principalId: pipelineIdentities[i].outputs.principalId
      identityName: 'id-${workload}-pipeline-${env}'
      grants: concat(
        [
          { role: roles.contributor, condition: '' }
          { role: roles.rbacAdministrator, condition: constrainedDelegation }
        ],
        // dev builds and pushes images; later stages import them by digest.
        env == 'dev' ? [{ role: roles.acrPush, condition: '' }] : []
      )
    }
  }
]

// Promotion: each stage may read images from the stage before it.
module promotionAccess 'pipeline-access.bicep' = [
  for (env, i) in environments: if (i > 0) {
    name: 'pipeline-promotion-${env}'
    scope: environmentGroups[max(i - 1, 0)]
    params: {
      principalId: pipelineIdentities[i].outputs.principalId
      identityName: 'id-${workload}-pipeline-${env}'
      grants: [{ role: roles.reader, condition: '' }, { role: roles.acrPull, condition: '' }]
    }
  }
]

output pipelineIdentities array = [
  for (env, i) in environments: {
    environment: env
    clientId: pipelineIdentities[i].outputs.clientId
    resourceGroup: environmentGroups[i].name
  }
]
output tenantId string = tenant().tenantId
output subscriptionId string = subscription().subscriptionId
