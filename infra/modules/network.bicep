// VNet with two subnets (Container Apps infrastructure, private endpoints), their NSGs,
// and the private DNS zones that let workloads resolve private endpoints by name.
import { networkConfig, requiredTags } from '../lib/types.bicep'

param location string
param tags requiredTags
param vnetName string
param network networkConfig

@sys.description('CIDRs allowed to reach the public Container Apps ingress. Empty means any.')
param allowedIngressCidrs string[]

@sys.description('Create private DNS zones for private endpoints.')
param enablePrivateNetworking bool

param logAnalyticsWorkspaceId string

// Service tags are only valid in the singular property; CIDR lists go in the plural one.
var ingressFromInternet = empty(allowedIngressCidrs)

// Container Apps workload-profile environments receive ingress on 80/443 and the
// envoy node ports 31080/31443, plus Azure Load Balancer health probes.
resource acaNsg 'Microsoft.Network/networkSecurityGroups@2025-05-01' = {
  name: 'nsg-${vnetName}-aca'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowHttpsIngress'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: ingressFromInternet ? 'Internet' : null
          sourceAddressPrefixes: ingressFromInternet ? null : allowedIngressCidrs
          sourcePortRange: '*'
          destinationAddressPrefix: network.containerAppsSubnet
          destinationPortRanges: ['443', '31443']
        }
      }
      {
        name: 'AllowHttpRedirectIngress'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: ingressFromInternet ? 'Internet' : null
          sourceAddressPrefixes: ingressFromInternet ? null : allowedIngressCidrs
          sourcePortRange: '*'
          destinationAddressPrefix: network.containerAppsSubnet
          destinationPortRanges: ['80', '31080']
        }
      }
      {
        name: 'AllowAzureLoadBalancer'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: network.containerAppsSubnet
          destinationPortRange: '30000-32767'
        }
      }
      {
        name: 'DenyInternetManagementPorts'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: ['22', '3389', '5985', '5986']
        }
      }
      {
        name: 'DenyLateralManagementOutbound'
        properties: {
          priority: 4001
          direction: 'Outbound'
          access: 'Deny'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: ['22', '3389']
        }
      }
    ]
  }
}

resource peNsg 'Microsoft.Network/networkSecurityGroups@2025-05-01' = {
  name: 'nsg-${vnetName}-pe'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowVnetInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: network.privateEndpointSubnet
          destinationPortRange: '443'
        }
      }
      {
        name: 'DenyAllOtherInbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'DenyLateralManagementOutbound'
        properties: {
          priority: 4001
          direction: 'Outbound'
          access: 'Deny'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: ['22', '3389']
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2025-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [network.addressSpace] }
    subnets: [
      {
        name: 'snet-aca'
        properties: {
          addressPrefix: network.containerAppsSubnet
          networkSecurityGroup: { id: acaNsg.id }
          delegations: [
            { name: 'aca', properties: { serviceName: 'Microsoft.App/environments' } }
          ]
          // Without private endpoints, Key Vault and Storage firewalls admit only this
          // subnet through service endpoints.
          serviceEndpoints: enablePrivateNetworking
            ? []
            : [{ service: 'Microsoft.KeyVault' }, { service: 'Microsoft.Storage' }]
        }
      }
      {
        name: 'snet-pe'
        properties: {
          addressPrefix: network.privateEndpointSubnet
          networkSecurityGroup: { id: peNsg.id }
          privateEndpointNetworkPolicies: 'Enabled'
          defaultOutboundAccess: false
        }
      }
    ]
  }

  resource acaSubnet 'subnets' existing = {
    name: 'snet-aca'
  }

  resource peSubnet 'subnets' existing = {
    name: 'snet-pe'
  }
}

// diagnosticSettings' only GA version (2016-09-01) predates categoryGroup support.
#disable-next-line use-recent-api-versions
resource acaNsgDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: acaNsg
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
  }
}

#disable-next-line use-recent-api-versions
resource peNsgDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: peNsg
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
  }
}

// Zone names come from the cloud environment so the template also works in sovereign clouds.
var privateDnsZoneNames = {
  keyVault: 'privatelink.vaultcore.azure.net'
  table: 'privatelink.table.${environment().suffixes.storage}'
  serviceBus: 'privatelink.servicebus.windows.net'
  registry: 'privatelink${environment().suffixes.acrLoginServer}'
}

resource privateDnsZones 'Microsoft.Network/privateDnsZones@2024-06-01' = [
  for zone in items(privateDnsZoneNames): if (enablePrivateNetworking) {
    name: zone.value
    location: 'global'
    tags: tags
  }
]

resource privateDnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (zone, i) in items(privateDnsZoneNames): if (enablePrivateNetworking) {
    parent: privateDnsZones[i]
    name: 'link-${vnetName}'
    location: 'global'
    tags: tags
    properties: {
      registrationEnabled: false
      virtualNetwork: { id: vnet.id }
    }
  }
]

output vnetId string = vnet.id
output containerAppsSubnetId string = vnet::acaSubnet.id
output privateEndpointSubnetId string = vnet::peSubnet.id

@sys.description('Private DNS zone ids keyed by service; empty strings when private networking is off.')
output privateDnsZoneIds object = {
  keyVault: enablePrivateNetworking ? resourceId('Microsoft.Network/privateDnsZones', privateDnsZoneNames.keyVault) : ''
  table: enablePrivateNetworking ? resourceId('Microsoft.Network/privateDnsZones', privateDnsZoneNames.table) : ''
  serviceBus: enablePrivateNetworking ? resourceId('Microsoft.Network/privateDnsZones', privateDnsZoneNames.serviceBus) : ''
  registry: enablePrivateNetworking ? resourceId('Microsoft.Network/privateDnsZones', privateDnsZoneNames.registry) : ''
}
