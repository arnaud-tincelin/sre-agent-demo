@description('The location used for all resources.')
param location string = resourceGroup().location

@description('The azd environment name.')
param environmentName string

@description('GitHub repository (owner/repo) for the SRE Agent GitHub connector, e.g. "myorg/sre-agent-demo".')
param githubRepository string = ''

@secure()
@description('GitHub PAT with Issues:Read+Write so the SRE Agent can open issues. Set via: azd env set GITHUB_PAT <token>')
param githubPat string = ''

// ── Names ────────────────────────────────────────────────────────────────────
var logAnalyticsWorkspaceName    = 'law-${environmentName}'
var containerAppsEnvironmentName = 'cae-${environmentName}'
var zavaBackendAppName           = 'ca-zava-backend-${environmentName}'
var zavaFrontendAppName          = 'ca-zava-frontend-${environmentName}'
var sreAgentName                 = 'sre-agent-${environmentName}'
var sreAgentIdentityName         = 'id-sre-agent-${environmentName}'
var actionGroupName              = 'ag-sre-agent-${environmentName}'
var memoryAlertName              = 'alert-zava-oom-${environmentName}'

// ── Built-in role IDs ────────────────────────────────────────────────────────
var readerRoleId            = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var monitoringReaderRoleId  = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
var logAnalyticsReaderRoleId = '73c42c96-874c-492b-b04d-ab87d138a893'

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

// ── Zava Backend Container App ────────────────────────────────────────────────
// Internal ingress only – reachable from within the ACA environment.
// azd replaces the placeholder image with the built src/backend image on deploy.
resource zavaBackendApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: zavaBackendAppName
  location: location
  properties: {
    environmentId: containerAppsEnvironment.id
    configuration: {
      ingress: {
        external: false  // internal – only reachable by the frontend nginx proxy
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
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 4
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
  properties: {
    environmentId: containerAppsEnvironment.id
    configuration: {
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
        maxReplicas: 2
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

// ── Azure SRE Agent ──────────────────────────────────────────────────────────
// NOTE: Microsoft.App/agents is a preview resource type (public preview as of
// mid-2025). Verify the exact API version and property schema against the
// current preview documentation before deploying to production.
resource sreAgent 'Microsoft.App/agents@2025-02-02-preview' = {
  name: sreAgentName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${sreAgentIdentity.id}': {}
    }
  }
  properties: {
    logAnalyticsWorkspace: {
      resourceId: logAnalyticsWorkspace.id
      workspaceId: logAnalyticsWorkspace.properties.customerId
    }
    incidentPlatforms: [
      {
        platformType: 'AzureMonitor'
        enabled: true
        actionGroupId: sreAgentActionGroup.id
      }
    ]
    connectors: !empty(githubPat) ? [
      {
        connectorType: 'GitHub'
        repository: githubRepository
        pat: githubPat
      }
    ] : []
  }
}

// ── Metric Alert – Zava OOM / memory pressure ─────────────────────────────────
// Fires when Zava's working-set memory exceeds 800 MiB (≈80 % of the 1 Gi
// container limit), which indicates AVeryMemoryIntensiveFunction is running.
resource zavaMemoryAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: memoryAlertName
  location: 'global'
  properties: {
    description: 'Zava Container App memory > 800 MiB – AVeryMemoryIntensiveFunction OOM pressure detected.'
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
// SERVICE_*_NAME outputs tell azd which container app to update with each built image.
output SERVICE_ZAVA_BACKEND_NAME string = zavaBackendApp.name
output SERVICE_ZAVA_FRONTEND_NAME string = zavaFrontendApp.name
output SRE_AGENT_NAME string = sreAgent.name
