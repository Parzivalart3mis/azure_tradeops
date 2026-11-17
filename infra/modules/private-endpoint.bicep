// A private endpoint for one sub-resource, registered in its private DNS zone.
import { requiredTags } from '../lib/types.bicep'

param name string
param location string
param tags requiredTags
param subnetId string
param targetResourceId string

@sys.description('Sub-resource, e.g. vault, table, namespace, registry')
param groupId string

param privateDnsZoneId string

resource endpoint 'Microsoft.Network/privateEndpoints@2025-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: name
        properties: {
          privateLinkServiceId: targetResourceId
          groupIds: [groupId]
        }
      }
    ]
  }

  resource dns 'privateDnsZoneGroups' = {
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        { name: groupId, properties: { privateDnsZoneId: privateDnsZoneId } }
      ]
    }
  }
}
