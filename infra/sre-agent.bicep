// ── SRE Agent module ─────────────────────────────────────────────────────────
// Provisions the Azure SRE Agent, its managed identity + RBAC, the incident
// Action Group, and the two Azure Monitor alerts that drive the demo scenarios.

@description('The location used for all resources.')
param location string

@description('The azd environment name.')
param environmentName string

@description('Application Insights AppId the agent uses for log-to-code investigations.')
param appInsightsAppId string

@secure()
@description('Application Insights connection string the agent uses to read telemetry.')
param appInsightsConnectionString string

param appInsightsResourceId string

@description('Resource ID of the Log Analytics workspace the demo alerts query.')
param logAnalyticsWorkspaceId string

// ── Names ────────────────────────────────────────────────────────────────────
var sreAgentName = 'sre-agent-${environmentName}'
var sreAgentIdentityName = 'id-sre-agent-${environmentName}'
var actionGroupName = 'ag-sre-agent-${environmentName}'
// Response plans route on these names: 'app-exception' -> code-investigator,
// 'availability' -> platform-operator. Keep the substrings non-overlapping.
var appExceptionAlertName = 'alert-zava-app-exception-${environmentName}'
var availabilityAlertName = 'alert-zava-availability-${environmentName}'

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

// Container Apps Contributor on the resource group. This is what makes Scenario 2
// possible: the agent repairs the backend's configuration with
// `az containerapp update --set-env-vars CATALOG_SOURCE=builtin`.
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
    type: 'SystemAssigned, UserAssigned'
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

    #disable-next-line BCP037 // Supported by SRE Agent but missing from the published Bicep type.
    experimentalSettings: {
      EnableWorkspaceTools: true
      EnableHttpTriggers: true
      EnableV2AgentLoop: true
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
      #disable-next-line use-secure-value-for-secure-inputs // This data source is an ARM resource ID, not a secret.
      dataSource: appInsightsConnectionString
      extendedProperties: {
        armResourceId: appInsightsResourceId
        resource: {
          name: last(split(appInsightsResourceId, '/'))
        }
        appId: appInsightsAppId
      }
      identity: 'system'
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

// ── Alerts ─────────────────────────────────
// Two symptom-specific alerts, one per demo scenario. Descriptions stay
// symptom-only on purpose: the agent should investigate the evidence rather
// than read the root cause out of the alert text.
//
// skipQueryValidation is required because AppExceptions / AppRequests do not
// exist in a brand-new workspace until the app has sent its first telemetry.

// Scenario 1 – code fault. Unhandled exceptions surface as HTTP 500s.
// Not remediable from the platform; the agent files a GitHub issue.
resource zavaAppExceptionAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: appExceptionAlertName
  location: location
  properties: {
    displayName: appExceptionAlertName
    description: 'Zava storefront is returning HTTP 500 errors on product pages. Unhandled exceptions are being recorded by the backend.'
    severity: 2
    enabled: true
    scopes: [logAnalyticsWorkspaceId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    skipQueryValidation: true
    autoMitigate: true
    criteria: {
      allOf: [
        {
          query: 'AppExceptions | where AppRoleName startswith "ca-zava-backend"'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [sreAgentActionGroup.id]
    }
  }
}

// Scenario 2 – platform fault. The catalog routes return HTTP 503.
// Not remediable from code; the agent fixes the Container App configuration.
resource zavaAvailabilityAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: availabilityAlertName
  location: location
  properties: {
    displayName: availabilityAlertName
    description: 'Zava storefront catalog is unavailable. The backend is returning HTTP 503 to customer requests.'
    severity: 1
    enabled: true
    scopes: [logAnalyticsWorkspaceId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    skipQueryValidation: true
    autoMitigate: true
    criteria: {
      allOf: [
        {
          query: 'AppRequests | where AppRoleName startswith "ca-zava-backend" | where ResultCode == "503"'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 3
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [sreAgentActionGroup.id]
    }
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────────
output sreAgentName string = sreAgent.name
output sreAgentIdentityId string = sreAgentIdentity.id
output sreAgentIdentityPrincipalId string = sreAgentIdentity.properties.principalId
