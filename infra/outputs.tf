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
    remediation_broker      = local.profile.broker_enabled
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
  description = "Public HTTPS URL of the frontend. The Entra-protected broker is the only other public endpoint when enabled."
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

output "sre_agent_identity_principal_ids" {
  description = "Each SRE Agent's user-assigned identity principal id (for portal/data-plane wiring)."
  value       = { for k, i in azurerm_user_assigned_identity.agent : k => i.principal_id }
}

output "sre_remediation_broker_enabled" {
  description = "Whether the selected scenario implies the remediation broker (Scenario C only)."
  value       = local.profile.broker_enabled
}

output "sre_remediation_broker_endpoint_url" {
  description = "Entra-protected public Streamable-HTTP endpoint, ending in /mcp; null until the app deployment phase."
  value       = var.deploy_apps && local.profile.broker_enabled ? "https://${azurerm_container_app.sre_remediation_broker[0].ingress[0].fqdn}/mcp" : null
}

output "sre_remediation_broker_app_name" {
  description = "Container App name for deployment workflows; null until the app deployment phase."
  value       = var.deploy_apps && local.profile.broker_enabled ? azurerm_container_app.sre_remediation_broker[0].name : null
}

output "sre_remediation_broker_entra_token_scope" {
  description = "Nonsecret Entra client-credentials scope the SRE Agent requests for the broker."
  value       = local.profile.broker_enabled ? var.sre_remediation_entra_token_scope : null
}

output "sre_remediation_broker_identity_principal_id" {
  description = "Principal/object ID of the broker's dedicated user-assigned managed identity."
  value       = local.profile.broker_enabled ? azurerm_user_assigned_identity.sre_remediation_broker[0].principal_id : null
}

output "sre_remediation_broker_identity_client_id" {
  description = "Client ID of the broker's dedicated user-assigned managed identity."
  value       = local.profile.broker_enabled ? azurerm_user_assigned_identity.sre_remediation_broker[0].client_id : null
}

output "sre_remediation_broker_key_uri" {
  description = "Scenario C unversioned URI metadata for the out-of-band imported broker signing key; never key material."
  value       = local.profile.broker_enabled ? "${azurerm_key_vault.this.vault_uri}keys/${var.sre_remediation_github_app_private_key_name}" : null
}
