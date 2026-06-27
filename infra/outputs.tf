###############################################################################
# Outputs. Never output secret values. frontend_url is the only public surface.
###############################################################################

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

output "frontend_url" {
  description = "Public HTTPS URL of the frontend (only public endpoint)."
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
