###############################################################################
# Observability: Log Analytics + workspace-based Application Insights.
# Diagnostic settings route platform logs/metrics to Log Analytics (§6 rule 11).
###############################################################################

resource "azurerm_log_analytics_workspace" "this" {
  name                = "law-${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_application_insights" "this" {
  name                = "appi-${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  workspace_id        = azurerm_log_analytics_workspace.this.id
  application_type    = "web"
  tags                = local.tags
}

# Scenario A's portal-owned Observability Agent needs an issue container distinct
# from Log Analytics. West Europe supports the preview; the app region is unchanged.
resource "azurerm_monitor_workspace" "observability_agent" {
  count = var.scenario == "A" ? 1 : 0

  name                = "amw-observability-${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = "westeurope"

  # Scenario A has no private-link path for the Azure-hosted agent or operator.
  # This public monitoring endpoint requires Azure RBAC; it is not app ingress.
  public_network_access_enabled = true
  tags                          = local.tags
}

resource "azurerm_user_assigned_identity" "observability_agent" {
  count = var.scenario == "A" ? 1 : 0

  name                = "id-observability-${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_monitor_workspace.observability_agent[0].location
  tags                = local.tags
}

resource "azurerm_role_assignment" "observability_agent_issues" {
  count = var.scenario == "A" ? 1 : 0

  scope                            = azurerm_monitor_workspace.observability_agent[0].id
  role_definition_name             = "Issue Contributor"
  principal_id                     = azurerm_user_assigned_identity.observability_agent[0].principal_id
  skip_service_principal_aad_check = true
}

# The preview requires subscription-level alert discovery and telemetry reads.
# Monitoring Reader is the documented read-only exception, not workload Contributor.
resource "azurerm_role_assignment" "observability_agent_monitoring" {
  count = var.scenario == "A" ? 1 : 0

  scope                            = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_name             = "Monitoring Reader"
  principal_id                     = azurerm_user_assigned_identity.observability_agent[0].principal_id
  skip_service_principal_aad_check = true
}

# --- Diagnostic settings to Log Analytics for auditability ---

resource "azurerm_monitor_diagnostic_setting" "acr" {
  name                       = "diag-acr"
  target_resource_id         = azurerm_container_registry.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "keyvault" {
  name                       = "diag-kv"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "aca_env" {
  name                       = "diag-aca-env"
  target_resource_id         = azurerm_container_app_environment.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
