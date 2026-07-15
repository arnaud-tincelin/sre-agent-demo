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
var sreAgentName = 'sre-agent-${environmentName}'
var sreAgentIdentityName = 'id-sre-agent-${environmentName}'
var actionGroupName = 'ag-sre-agent-${environmentName}'
var memoryAlertName = 'alert-zava-oom-${environmentName}'

// ── Built-in role IDs ────────────────────────────────────────────────────────
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var monitoringReaderRoleId = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
var logAnalyticsReaderRoleId = '73c42c96-874c-492b-b04d-ab87d138a893'
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

// ── SRE Agent – Managed Identity ─────────────────────────────────────────────
resource sreAgentIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: sreAgentIdentityName
  location: location
}

// Reader on the resource group (list resources, describe Container Apps)
resource readerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreAgentIdentity.id, readerRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: sreAgentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Monitoring Reader on the resource group (read Azure Monitor alerts + metrics)
resource monitoringReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreAgentIdentity.id, monitoringReaderRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReaderRoleId)
    principalId: sreAgentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Log Analytics Reader on the workspace (run KQL queries)
resource logAnalyticsReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(logAnalyticsWorkspace.id, sreAgentIdentity.id, logAnalyticsReaderRoleId)
  scope: logAnalyticsWorkspace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logAnalyticsReaderRoleId)
    principalId: sreAgentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── Action Group – SRE Agent incident platform entry point ───────────────────
// The Azure Monitor alert fires into this action group; the SRE Agent is
// registered as a receiver on the action group via its incident platform.
resource sreAgentActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'global'
  properties: {
    groupShortName: 'sre-agent'
    enabled: true
  }
}

resource sreAgent 'Microsoft.App/agents@2026-01-01' = {
  name: sreAgentName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${sreAgentIdentity.id}': {}
    }
  }
  properties: {
    upgradeChannel: 'Stable'

    knowledgeGraphConfiguration: {
      identity: sreAgentIdentity.id
      managedResources: []
    }

    logConfiguration: {
      applicationInsightsConfiguration: {
        appId: appInsights.properties.AppId
      }
    }

    actionConfiguration: {
      identity: sreAgentIdentity.id
      mode: 'Autonomous'
      accessLevel: 'High'
    }

    defaultModel: {
      provider: 'Anthropic'
      name: 'Automatic'
    }
  }
}

// ── SRE Agent – GitHub integration (configured in the agent Builder) ─────────
// GitHub is NOT wired up through a Microsoft.App/agents/connectors resource:
// 'GitHub' is not a valid ARM dataConnectorType (valid types are Kusto, Mcp,
// Outlook, Teams), so an ARM connector for it deploys but reports "Failed".
//
// Instead, configure GitHub via the agent Builder (data plane), per docs:
//   • Code Access  (Builder > Code Access)  – source code reading / RCA
//   • GitHub Connector (Builder > Connectors) – open issues, PRs, workflows
// Both use the PAT from `azd env set GITHUB_PAT <token>` and the repository
// from `azd env set GITHUB_REPOSITORY <owner/repo>`.

// ── Metric Alert – Zava OOM / memory pressure ─────────────────────────────────
// Fires when Zava's working-set memory exceeds 800 MiB (≈80 % of the 1 Gi
// container limit), which indicates AVeryMemoryIntensiveFunction is running.
resource zavaMemoryAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: memoryAlertName
  location: 'global'
  properties: {
    description: 'Zava Container App memory > 800 MiB - AVeryMemoryIntensiveFunction OOM pressure detected.'
    severity: 2
    enabled: true
    scopes: [zavaBackendApp.id]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighMemoryUsage'
          metricNamespace: 'Microsoft.App/containerApps'
          metricName: 'WorkingSetBytes'
          operator: 'GreaterThan'
          threshold: 838860800 // 800 MiB in bytes
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: sreAgentActionGroup.id
      }
    ]
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
output SRE_AGENT_NAME string = sreAgent.name
// azd pushes the built images to this registry (remoteBuild).
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = containerRegistry.properties.loginServer
output AZURE_CONTAINER_REGISTRY_NAME string = containerRegistry.name
