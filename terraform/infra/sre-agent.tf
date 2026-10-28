resource "azurerm_user_assigned_identity" "agent" {
  name                = "id-sre-agent-${var.environment_name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "agent_reader" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.agent.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "agent_monitoring_reader" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Monitoring Reader"
  principal_id         = azurerm_user_assigned_identity.agent.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "agent_log_analytics_reader" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Log Analytics Reader"
  principal_id         = azurerm_user_assigned_identity.agent.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "agent_log_analytics_contributor" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Log Analytics Contributor"
  principal_id         = azurerm_user_assigned_identity.agent.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "agent_app_insights_contributor" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Application Insights Component Contributor"
  principal_id         = azurerm_user_assigned_identity.agent.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "agent_container_apps_contributor" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Container Apps Contributor"
  principal_id         = azurerm_user_assigned_identity.agent.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_monitor_action_group" "agent" {
  name                = "ag-sre-agent-${var.environment_name}"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "sre-agent"
  tags                = local.tags

  # The agent platform registers its receiver after provisioning.
  lifecycle {
    ignore_changes = [webhook_receiver]
  }
}

# SRE Agent is not yet exposed by AzureRM. Use its ARM API, as Bicep does.
resource "azapi_resource" "agent" {
  type                      = "Microsoft.App/agents@2026-01-01"
  name                      = "sre-agent-${var.environment_name}"
  parent_id                 = azurerm_resource_group.main.id
  location                  = azurerm_resource_group.main.location
  tags                      = local.tags
  schema_validation_enabled = false

  identity {
    type         = "SystemAssigned, UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.agent.id]
  }
  body = {
    properties = {
      upgradeChannel = "Stable"
      knowledgeGraphConfiguration = {
        identity         = azurerm_user_assigned_identity.agent.id
        managedResources = [azurerm_resource_group.main.id]
      }
      logConfiguration = {
        applicationInsightsConfiguration = {
          appId            = azurerm_application_insights.main.app_id
          connectionString = azurerm_application_insights.main.connection_string
        }
      }
      actionConfiguration = {
        identity    = azurerm_user_assigned_identity.agent.id
        mode        = "Autonomous"
        accessLevel = "High"
      }
      defaultModel = {
        provider = "Anthropic"
        name     = "Automatic"
      }
      experimentalSettings = {
        EnableWorkspaceTools = true
        EnableHttpTriggers   = true
        EnableV2AgentLoop    = true
      }
      incidentManagementConfiguration = {
        type           = "AzMonitor"
        connectionName = "azmonitor"
      }
    }
  }
  response_export_values = ["properties.agentEndpoint", "properties.provisioningState"]
  depends_on = [
    azurerm_role_assignment.agent_reader,
    azurerm_role_assignment.agent_monitoring_reader,
    azurerm_role_assignment.agent_log_analytics_reader,
    azurerm_role_assignment.agent_log_analytics_contributor,
    azurerm_role_assignment.agent_app_insights_contributor,
    azurerm_role_assignment.agent_container_apps_contributor,
    azurerm_monitor_action_group.agent,
  ]
}

resource "azapi_resource" "application_insights_connector" {
  type                      = "Microsoft.App/agents/connectors@2026-01-01"
  name                      = "app-insights"
  parent_id                 = azapi_resource.agent.id
  schema_validation_enabled = false
  body = {
    properties = {
      dataConnectorType = "AppInsights"
      dataSource        = azurerm_application_insights.main.connection_string
      extendedProperties = {
        armResourceId = azurerm_application_insights.main.id
        resource = {
          name = azurerm_application_insights.main.name
        }
        appId = azurerm_application_insights.main.app_id
      }
      identity = "system"
    }
  }
}

data "azurerm_client_config" "current" {}

resource "azurerm_role_assignment" "deployer_agent_administrator" {
  scope                = azapi_resource.agent.id
  role_definition_name = "SRE Agent Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "app_exception" {
  name                    = "alert-zava-app-exception-${var.environment_name}"
  display_name            = "alert-zava-app-exception-${var.environment_name}"
  resource_group_name     = azurerm_resource_group.main.name
  location                = azurerm_resource_group.main.location
  description             = "Zava storefront is returning HTTP 500 errors on product pages. Unhandled exceptions are being recorded by the backend."
  severity                = 2
  enabled                 = true
  scopes                  = [azurerm_log_analytics_workspace.main.id]
  evaluation_frequency    = "PT5M"
  window_duration         = "PT5M"
  skip_query_validation   = true
  auto_mitigation_enabled = true
  tags                    = local.tags
  criteria {
    query                   = "AppExceptions | where AppRoleName startswith \"ca-zava-backend\""
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0
    failing_periods {
      number_of_evaluation_periods             = 1
      minimum_failing_periods_to_trigger_alert = 1
    }
  }
  action {
    action_groups = [azurerm_monitor_action_group.agent.id]
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "availability" {
  name                    = "alert-zava-availability-${var.environment_name}"
  display_name            = "alert-zava-availability-${var.environment_name}"
  resource_group_name     = azurerm_resource_group.main.name
  location                = azurerm_resource_group.main.location
  description             = "Zava storefront catalog is unavailable. The backend is returning HTTP 503 to customer requests."
  severity                = 1
  enabled                 = true
  scopes                  = [azurerm_log_analytics_workspace.main.id]
  evaluation_frequency    = "PT5M"
  window_duration         = "PT5M"
  skip_query_validation   = true
  auto_mitigation_enabled = true
  tags                    = local.tags
  criteria {
    query                   = "AppRequests | where AppRoleName startswith \"ca-zava-backend\" | where ResultCode == \"503\""
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 3
    failing_periods {
      number_of_evaluation_periods             = 1
      minimum_failing_periods_to_trigger_alert = 1
    }
  }
  action {
    action_groups = [azurerm_monitor_action_group.agent.id]
  }
}
