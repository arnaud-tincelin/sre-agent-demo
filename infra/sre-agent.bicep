// ── SRE Agent module ─────────────────────────────────────────────────────────
// Provisions the Azure SRE Agent, its managed identity + RBAC, the incident
// Action Group, and the Zava OOM metric alert that drives the demo.

@description('The location used for all resources.')
param location string

@description('The azd environment name.')
param environmentName string

@description('Application Insights AppId the agent uses for log-to-code investigations.')
param appInsightsAppId string

@secure()
@description('Application Insights connection string the agent uses to read telemetry.')
param appInsightsConnectionString string

@description('Resource ID of the Zava backend Container App the memory alert monitors.')
param backendContainerAppId string

// ── Names ────────────────────────────────────────────────────────────────────
var sreAgentName = 'sre-agent-${environmentName}'
var sreAgentIdentityName = 'id-sre-agent-${environmentName}'
var actionGroupName = 'ag-sre-agent-${environmentName}'

// ── Built-in role IDs ────────────────────────────────────────────────────────
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var monitoringReaderRoleId = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
var logAnalyticsReaderRoleId = '73c42c96-874c-492b-b04d-ab87d138a893'
var logAnalyticsContributorRoleId = '92aaf0da-9dab-42b6-94a3-d43ce8d16293'
var appInsightsComponentContributorRoleId = 'ae349356-3a1b-4a5e-921d-050484c6347e'
var containerAppsContributorRoleId = '358470bc-b998-42bd-ab17-a7e34c199c0f'

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

// Log Analytics Reader on the resource group (run KQL queries; detected at the
// resource-group scope the SRE Agent manages)
resource logAnalyticsReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreAgentIdentity.id, logAnalyticsReaderRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logAnalyticsReaderRoleId)
    principalId: sreAgentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Log Analytics Contributor on the resource group (read all monitoring data and
// edit monitoring settings)
resource logAnalyticsContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreAgentIdentity.id, logAnalyticsContributorRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logAnalyticsContributorRoleId)
    principalId: sreAgentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Application Insights Component Contributor on the resource group (manage
// Application Insights components used for log-to-code investigations)
resource appInsightsContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreAgentIdentity.id, appInsightsComponentContributorRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      appInsightsComponentContributorRoleId
    )
    principalId: sreAgentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Container Apps Contributor on the resource group (scale/remediate the Zava
// Container App, e.g. `az containerapp update --max-replicas 4`)
resource containerAppsContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreAgentIdentity.id, containerAppsContributorRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', containerAppsContributorRoleId)
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
      managedResources: [
        resourceGroup().id
      ]
    }

    logConfiguration: {
      applicationInsightsConfiguration: {
        appId: appInsightsAppId
        connectionString: appInsightsConnectionString
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

    incidentManagementConfiguration: {
      type: 'AzMonitor'
      connectionName: 'azmonitor'
    }
  }

  resource applicationInsightsConnector 'connectors' = {
    name: 'app-insights'
    properties: {
      dataConnectorType: 'AppInsights'
      dataSource: appInsightsConnectionString
      identity: sreAgentIdentity.id
      extendedProperties: {}
    }
  }
}

resource zavaMemoryAlert 'Microsoft.Insights/metricAlerts@2024-03-01-preview' = {
  name: 'Zava backend memory alert'
  location: 'global'
  properties: {
    description: 'Zava backend memory > 500 MiB - OOM pressure detected.'
    severity: 2
    enabled: true
    scopes: [backendContainerAppId]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighMemoryUsage'
          metricNamespace: 'Microsoft.App/containerApps'
          metricName: 'WorkingSetBytes'
          operator: 'GreaterThanOrEqual'
          threshold: 524288000 // 500 MiB in bytes
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

// ── Metric Alert – Zava backend latency ───────────────────────────────────────
// Fires when the backend's average HTTP response time exceeds 200 ms, which the
// AVeryMemoryIntensiveFunction leak causes as memory pressure builds (each
// leaked block adds request latency).
resource zavaResponseTimeAlert 'Microsoft.Insights/metricAlerts@2024-03-01-preview' = {
  name: 'Zava backend latency alert'
  location: 'global'
  properties: {
    description: 'Zava backend average response time > 200 ms - latency degradation detected.'
    severity: 3
    enabled: true
    scopes: [backendContainerAppId]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighResponseTime'
          metricNamespace: 'Microsoft.App/containerApps'
          metricName: 'ResponseTime'
          operator: 'GreaterThan'
          threshold: 200 // milliseconds
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
output sreAgentName string = sreAgent.name
output sreAgentIdentityId string = sreAgentIdentity.id
output sreAgentIdentityPrincipalId string = sreAgentIdentity.properties.principalId
