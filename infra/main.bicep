targetScope = 'subscription'

@description('Short workload name used in resources names.')
@minLength(3)
@maxLength(12)
param workload string = 'stackdemo'

@description('Environment name')
@allowed([
  'dev'
  'prod'
])
param environment string = 'dev'

@description('Azure region for all resources')
param location string = 'southeastasia'

@description('Container image to run')
param containerImage string = 'mcr.microsoft.com/k8se/quickstart:latest'

@description('Tags applied to every resources')
param tags object = {}

var baseName = '${workload}-${environment}'
var allTags = union(tags, {
  workload: workload
  environment: environment
  managedBy: 'deployment-stack'
})

resource rg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: 'rg-${baseName}'
  location: location
  tags: allTags
}

module monitoring 'modules/monitoring.bicep' = {
  scope: rg
  name: 'monitoring'
  params: {
    baseName: baseName
    location: location
    tags: allTags
  }
}

module containerapp 'modules/containerapp.bicep' = {
  scope: rg
  name: 'containerApp'
  params: {
    baseName: baseName
    location: location
    tags: allTags
    containerImage: containerImage
    logAnalyticsWorkspaceName: monitoring.outputs.workspaceName
    minReplicas: environment == 'prod' ? 1 : 0
  }
}

output resourceGroupName string = rg.name
output appUrl string = containerapp.outputs.url
