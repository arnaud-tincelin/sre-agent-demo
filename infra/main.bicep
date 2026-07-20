@description('The location used for all resources.')
param location string = resourceGroup().location

@description('The azd environment name.')
param environmentName string

// ── Names ────────────────────────────────────────────────────────────────────
var logAnalyticsWorkspaceName = 'law-${environmentName}'
var appInsightsName = 'appi-${environmentName}'
var containerAppsEnvironmentName = 'cae-${environmentName}'
var containerRegistryName = 'acr${uniqueString(resourceGroup().id, environmentName)}'
var appsIdentityName = 'id-zava-apps-${environmentName}'
var zavaBackendAppName = 'ca-zava-backend-${environmentName}'
var zavaFrontendAppName = 'ca-zava-frontend-${environmentName}'

// ── Built-in role IDs ────────────────────────────────────────────────────────
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

// ── Log Analytics Workspace ──────────────────────────────────────────────────
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

// ── Application Insights (workspace-based) ────────────────────────────────────
// Backend telemetry (logs, traces, requests, dependencies) lands here and in the
// linked Log Analytics workspace, giving the SRE Agent a second, richer log
// source alongside the container console logs.
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
    IngestionMode: 'LogAnalytics'
  }
}

// ── Container Apps Environment ───────────────────────────────────────────────
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

// ── Container Registry ───────────────────────────────────────────────────────
// azd builds the src/backend and src/frontend images and pushes them here
// (remoteBuild: true in azure.yaml). The Container Apps pull via managed identity.
resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: containerRegistryName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

// ── Container Apps – Managed Identity (ACR pull) ─────────────────────────────
resource appsIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: appsIdentityName
  location: location
}

// AcrPull on the registry so the Container Apps can pull their images.
resource acrPullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerRegistry.id, appsIdentity.id, acrPullRoleId)
  scope: containerRegistry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: appsIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── Zava Backend Container App ────────────────────────────────────────────────
// Internal ingress only – reachable from within the ACA environment.
// azd replaces the placeholder image with the built src/backend image on deploy.
resource zavaBackendApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: zavaBackendAppName
  location: location
  tags: {
    'azd-service-name': 'zava-backend'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${appsIdentity.id}': {}
    }
  }
  properties: {
    environmentId: containerAppsEnvironment.id
    configuration: {
      registries: [
        {
          server: containerRegistry.properties.loginServer
          identity: appsIdentity.id
        }
      ]
      ingress: {
        external: false // internal – only reachable by the frontend nginx proxy
        targetPort: 8080
      }
    }
    template: {
      containers: [
        {
          name: 'zava-backend'
          image: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              value: appInsights.properties.ConnectionString
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

// ── Zava Frontend Container App ───────────────────────────────────────────────
// External ingress – serves the React SPA to end users.
// nginx proxies /api/* to the backend using BACKEND_URL at runtime.
// azd replaces the placeholder image with the built src/frontend image on deploy.
resource zavaFrontendApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: zavaFrontendAppName
  location: location
  tags: {
    'azd-service-name': 'zava-frontend'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${appsIdentity.id}': {}
    }
  }
  properties: {
    environmentId: containerAppsEnvironment.id
    configuration: {
      registries: [
        {
          server: containerRegistry.properties.loginServer
          identity: appsIdentity.id
        }
      ]
      ingress: {
        external: true
        targetPort: 80
      }
    }
    template: {
      containers: [
        {
          name: 'zava-frontend'
          image: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            {
              name: 'BACKEND_URL'
              // ACA internal FQDN – reachable within the environment
              value: 'https://${zavaBackendApp.properties.configuration.ingress.fqdn}'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

// ── SRE Agent (module) ───────────────────────────────────────────────────────
// Agent, its managed identity + RBAC, the incident Action Group, and the Zava
// OOM metric alert live in sre-agent.bicep.
module sreAgent 'sre-agent.bicep' = {
  name: 'sre-agent'
  params: {
    location: location
    environmentName: environmentName
    appInsightsAppId: appInsights.properties.AppId
    appInsightsConnectionString: appInsights.properties.ConnectionString
    backendContainerAppId: zavaBackendApp.id
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────────
output AZURE_CONTAINER_APPS_ENVIRONMENT_ID string = containerAppsEnvironment.id
output AZURE_CONTAINER_APPS_ENVIRONMENT_NAME string = containerAppsEnvironment.name
output LOG_ANALYTICS_WORKSPACE_ID string = logAnalyticsWorkspace.properties.customerId
output LOG_ANALYTICS_RESOURCE_ID string = logAnalyticsWorkspace.id
output APPLICATIONINSIGHTS_NAME string = appInsights.name
output APPLICATIONINSIGHTS_RESOURCE_ID string = appInsights.id
// SERVICE_*_NAME outputs tell azd which container app to update with each built image.
output SERVICE_ZAVA_BACKEND_NAME string = zavaBackendApp.name
output SERVICE_ZAVA_FRONTEND_NAME string = zavaFrontendApp.name
output SRE_AGENT_NAME string = sreAgent.outputs.sreAgentName
// azd pushes the built images to this registry (remoteBuild).
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = containerRegistry.properties.loginServer
output AZURE_CONTAINER_REGISTRY_NAME string = containerRegistry.name
