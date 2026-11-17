// User-assigned managed identities, one per workload. They are created (and granted their
// roles) before the container apps exist, so the first revision can already pull its image
// and read Key Vault.
import { requiredTags } from '../lib/types.bicep'

param location string
param tags requiredTags
param names string[]

resource identities 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = [
  for name in names: {
    name: name
    location: location
    tags: tags
  }
]

output identities array = [
  for (name, i) in names: {
    name: identities[i].name
    id: identities[i].id
    principalId: identities[i].properties.principalId
    clientId: identities[i].properties.clientId
  }
]
