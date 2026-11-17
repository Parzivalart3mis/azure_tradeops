// Copy the issuer and subjects from each Azure DevOps service connection
// (Project settings > Service connections > New > Azure Resource Manager >
//  Workload identity federation (manual)). The values below are placeholders.
using 'main.bicep'

param location = 'eastus2'
param federationIssuer = 'https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000/v2.0'
param federationSubjects = {
  dev: '/eid1/c/pub/t/REPLACE/a/REPLACE/sc/REPLACE/sc-tradeops-dev'
  staging: '/eid1/c/pub/t/REPLACE/a/REPLACE/sc/REPLACE/sc-tradeops-staging'
  prod: '/eid1/c/pub/t/REPLACE/a/REPLACE/sc/REPLACE/sc-tradeops-prod'
}
