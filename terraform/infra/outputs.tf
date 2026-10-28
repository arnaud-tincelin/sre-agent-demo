output "AZURE_RESOURCE_GROUP" {
  value = azurerm_resource_group.main.name
}

output "AZURE_CONTAINER_APPS_ENVIRONMENT_ID" {
  value = azurerm_container_app_environment.main.id
}

output "AZURE_CONTAINER_APPS_ENVIRONMENT_NAME" {
  value = azurerm_container_app_environment.main.name
}

output "LOG_ANALYTICS_WORKSPACE_ID" {
  value = azurerm_log_analytics_workspace.main.workspace_id
}

output "LOG_ANALYTICS_RESOURCE_ID" {
  value = azurerm_log_analytics_workspace.main.id
}

output "APPLICATIONINSIGHTS_NAME" {
  value = azurerm_application_insights.main.name
}

output "APPLICATIONINSIGHTS_RESOURCE_ID" {
  value = azurerm_application_insights.main.id
}

output "SERVICE_ZAVA_BACKEND_NAME" {
  value = azurerm_container_app.backend.name
}

output "SERVICE_ZAVA_FRONTEND_NAME" {
  value = azurerm_container_app.frontend.name
}

output "SERVICE_ZAVA_FRONTEND_ENDPOINT" {
  value = "https://${azurerm_container_app.frontend.ingress[0].fqdn}"
}

output "AZURE_CONTAINER_REGISTRY_ENDPOINT" {
  value = azurerm_container_registry.main.login_server
}

output "AZURE_CONTAINER_REGISTRY_NAME" {
  value = azurerm_container_registry.main.name
}

output "SRE_AGENT_NAME" {
  value = azapi_resource.agent.name
}

output "SRE_AGENT_ENDPOINT" {
  value = azapi_resource.agent.output.properties.agentEndpoint
}
