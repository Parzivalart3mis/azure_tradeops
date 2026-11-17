// A pipeline identity federated with one Azure DevOps service connection.
param name string
param location string
param tags object
param federationIssuer string
param federationSubject string

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: name
  location: location
  tags: tags

  resource federation 'federatedIdentityCredentials' = {
    name: 'azure-devops'
    properties: {
      issuer: federationIssuer
      subject: federationSubject
      audiences: ['api://AzureADTokenExchange']
    }
  }
}

output principalId string = identity.properties.principalId
output clientId string = identity.properties.clientId
