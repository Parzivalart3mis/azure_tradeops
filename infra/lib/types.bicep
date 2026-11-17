// Shared types for the platform and its environment parameter files.

@export()
@sys.description('Deployment stage. Drives naming, sizing and how hardened the network is.')
type environmentType = 'dev' | 'staging' | 'prod'

@export()
@sys.description('Tags every resource must carry; Azure Policy denies resources without them.')
type requiredTags = {
  application: string
  environment: environmentType
  costCenter: string
  owner: string
  dataClassification: 'public' | 'internal' | 'confidential'
  *: string
}

@export()
type networkConfig = {
  @sys.description('VNet address space, e.g. 10.20.0.0/16')
  addressSpace: string
  @sys.description('Container Apps infrastructure subnet; /27 minimum for workload-profile environments')
  containerAppsSubnet: string
  @sys.description('Subnet for private endpoints')
  privateEndpointSubnet: string
}

@export()
type scaleConfig = {
  @minValue(0)
  minReplicas: int
  @minValue(1)
  maxReplicas: int
}

@export()
@sys.description('Short environment code used inside globally-unique, length-limited names.')
func shortEnvironmentName(env environmentType) string => env == 'staging' ? 'stg' : (env == 'prod' ? 'prd' : 'dev')
