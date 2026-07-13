@description('The location used for all resources.')
param location string = resourceGroup().location

@description('The azd environment name.')
param environmentName string

var logAnalyticsWorkspaceName = 'law-${environmentName}'
var containerAppsEnvironmentName = 'cae-${environmentName}'

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: containerAppsEnvironmentName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspace.properties.customerId
        sharedKey: logAnalyticsWorkspace.listKeys().primarySharedKey
      }
    }
  }
}

output AZURE_CONTAINER_APPS_ENVIRONMENT_ID string = containerAppsEnvironment.id
output AZURE_CONTAINER_APPS_ENVIRONMENT_NAME string = containerAppsEnvironment.name
output LOG_ANALYTICS_WORKSPACE_ID string = logAnalyticsWorkspace.properties.customerId
output LOG_ANALYTICS_RESOURCE_ID string = logAnalyticsWorkspace.id
