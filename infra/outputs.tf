###############################################################################
# Outputs. Never output secret values. Public surfaces are documented below.
###############################################################################

output "scenario" {
  description = "Selected immutable deployment scenario."
  value       = var.scenario
}

output "scenario_profile" {
  description = "Nonsecret effective security and integration profile."
  value = {
    control_endpoint_access = local.profile.control_endpoint_access
    private_network_enabled = local.profile.private_network_enabled
    sre_agent_enabled       = var.enable_sre_agents
    sre_agent_access_level  = local.profile.agent.access
    sre_agent_resource_role = local.profile.agent.role
    sre_agent_mode          = local.profile.agent.mode
    github_integration      = local.profile.github_integration
  }
}

output "resource_group_name" {
  description = "Name of the demo resource group."
  value       = azurerm_resource_group.this.name
}

output "location" {
  description = "Azure region the demo is deployed to."
  value       = azurerm_resource_group.this.location
}

output "acr_login_server" {
  description = "ACR login server used by the deploy script for build/push."
  value       = azurerm_container_registry.this.login_server
}

output "image_digests" {
  description = "Exact immutable manifest digests deployed by the current application revisions."
  value       = var.image_digests
}

output "acr_name" {
  description = "ACR resource name."
  value       = azurerm_container_registry.this.name
}

output "key_vault_name" {
  description = "Key Vault name (secrets are not output)."
  value       = azurerm_key_vault.this.name
}

output "app_insights_name" {
  description = "Application Insights resource name."
  value       = azurerm_application_insights.this.name
}

output "container_app_environment" {
  description = "Container Apps environment name."
  value       = azurerm_container_app_environment.this.name
}

output "app_vnet_name" {
  description = "Scenario C application VNet name; null for public scenarios A/B."
  value       = local.profile.private_network_enabled ? azurerm_virtual_network.app[0].name : null
}

output "sre_agent_subnet_name" {
  description = "Scenario C dedicated delegated SRE Agent subnet name; null for A/B."
  value       = local.profile.private_network_enabled ? azurerm_subnet.sre_agent[0].name : null
}

output "sre_agent_subnet_id" {
  description = "Scenario C dedicated delegated SRE Agent subnet ID; null for A/B."
  value       = local.profile.private_network_enabled ? azurerm_subnet.sre_agent[0].id : null
}

output "frontend_url" {
  description = "Public HTTPS URL of the frontend. This is the only public application endpoint."
  value       = var.deploy_apps ? "https://${azurerm_container_app.app["frontend"].ingress[0].fqdn}" : null
}

output "frontend_app_name" {
  description = "frontend Container App name."
  value       = var.deploy_apps ? azurerm_container_app.app["frontend"].name : null
}

output "checkout_app_name" {
  description = "checkout-api Container App name."
  value       = var.deploy_apps ? azurerm_container_app.app["checkout-api"].name : null
}

output "payment_app_name" {
  description = "payment-service Container App name."
  value       = var.deploy_apps ? azurerm_container_app.app["payment-service"].name : null
}

output "grafana_endpoint" {
  description = "Azure Managed Grafana endpoint (if enabled)."
  value       = var.enable_grafana ? azurerm_dashboard_grafana.this[0].endpoint : null
}

output "sre_agent_names" {
  description = "Provisioned SRE Agent names per scenario (empty unless enable_sre_agents)."
  value       = { for k, a in azapi_resource.agent : k => a.name }
}

output "sre_agent_ids" {
  description = "Provisioned SRE Agent ARM resource IDs per scenario."
  value       = { for k, a in azapi_resource.agent : k => a.id }
}

output "sre_agent_endpoints" {
  description = "SRE Agent data-plane endpoints returned by ARM; empty unless agents are enabled."
  value       = { for k, a in azapi_resource.agent : k => try(a.output.properties.agentEndpoint, null) }
}

output "sre_agent_identity_principal_ids" {
  description = "Each SRE Agent's user-assigned identity principal ID."
  value       = { for k, i in azurerm_user_assigned_identity.agent : k => i.principal_id }
}

output "sre_agent_identities" {
  description = "Nonsecret managed-identity identifiers required for SRE Agent data-plane reconciliation."
  value = {
    for k, a in azapi_resource.agent : k => {
      system_assigned_principal_id = try(a.output.identity.principalId, null)
      user_assigned_resource_id    = azurerm_user_assigned_identity.agent[k].id
      user_assigned_client_id      = azurerm_user_assigned_identity.agent[k].client_id
      user_assigned_principal_id   = azurerm_user_assigned_identity.agent[k].principal_id
      code_access_resource_id      = try(azurerm_user_assigned_identity.agent_code_access[k].id, null)
      code_access_client_id        = try(azurerm_user_assigned_identity.agent_code_access[k].client_id, null)
      code_access_principal_id     = try(azurerm_user_assigned_identity.agent_code_access[k].principal_id, null)
    }
  }
}

output "sre_agent_telemetry" {
  description = "Nonsecret workspace-based telemetry identifiers for later SRE Agent data-plane reconciliation."
  value = var.enable_sre_agents ? {
    application_insights_resource_id = azurerm_application_insights.this.id
    application_insights_app_id      = azurerm_application_insights.this.app_id
    log_analytics_resource_id        = azurerm_log_analytics_workspace.this.id
    log_analytics_workspace_id       = azurerm_log_analytics_workspace.this.workspace_id
  } : null
}

