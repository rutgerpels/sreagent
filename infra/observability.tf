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
  # Scenario D ingests telemetry only with Entra ID (Monitoring Metrics
  # Publisher); instrumentation-key ingestion is disabled with no fallback.
  local_authentication_enabled = var.scenario != "D"
  tags                         = local.tags
}

# Scenarios A and D: the portal-owned Observability Agent needs an issue container distinct
# from Log Analytics. West Europe supports the preview; the app region is unchanged.
resource "azurerm_monitor_workspace" "observability_agent" {
  count = local.observability_agent_enabled ? 1 : 0

  name                = "amw-observability-${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = "westeurope"

  # The Azure-hosted agent and operator have no private-link path in this preview.
  # This public monitoring endpoint requires Azure RBAC; it is not app ingress.
  public_network_access_enabled = true
  tags                          = local.tags
}

resource "azurerm_user_assigned_identity" "observability_agent" {
  count = local.observability_agent_enabled ? 1 : 0

  name                = "id-observability-${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_monitor_workspace.observability_agent[0].location
  tags                = local.tags
}

resource "azurerm_role_assignment" "observability_agent_issues" {
  count = local.observability_agent_enabled ? 1 : 0

  scope                            = azurerm_monitor_workspace.observability_agent[0].id
  role_definition_name             = "Issue Contributor"
  principal_id                     = azurerm_user_assigned_identity.observability_agent[0].principal_id
  skip_service_principal_aad_check = true
}

# The preview requires subscription-level alert discovery and telemetry reads.
# Monitoring Reader is the documented read-only exception, not workload Contributor.
resource "azurerm_role_assignment" "observability_agent_monitoring" {
  count = local.observability_agent_enabled ? 1 : 0

  scope                            = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_name             = "Monitoring Reader"
  principal_id                     = azurerm_user_assigned_identity.observability_agent[0].principal_id
  skip_service_principal_aad_check = true
}

# Scenario D: provision the Observability Agent resource itself. The preview supports
# ARM/Bicep (not the azurerm provider), so azapi creates it; Scenario A stays portal-onboarded.
# Issue Contributor on the workspace and subscription Monitoring Reader are granted above.
locals {
  observability_agent_d_enabled = var.scenario == "D" && local.observability_agent_enabled

  observability_agent_d_instructions = join("\n", [
    "Always create an issue for alert-payment-failures-${local.suffix} and alert-checkout-failures-${local.suffix}, even when only one has fired.",
    "ContosoPay call chain: frontend calls checkout-api, which calls payment-service. Checkout failures that follow payment failures are a downstream symptom, not a separate root cause.",
    "The checkout and payment paths are business-critical.",
    "Do not correlate alerts from other demo resource groups with alerts from ${azurerm_resource_group.this.name}.",
    "Include [OPS-REVIEW] in every issue title.",
  ])
}

resource "azapi_resource" "observability_agent" {
  count = local.observability_agent_d_enabled ? 1 : 0

  type      = "Microsoft.Monitor/observabilityAgents@2026-05-01-preview"
  name      = "oba-${local.suffix}"
  location  = azurerm_monitor_workspace.observability_agent[0].location
  parent_id = azurerm_resource_group.this.id
  tags      = local.tags

  # Preview resource type; the bundled azapi schema may not know it yet.
  schema_validation_enabled = false

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.observability_agent[0].id]
  }

  body = {
    properties = {
      monitoringAccountId = azurerm_monitor_workspace.observability_agent[0].id
      enabled             = true
      operations = [
        {
          type         = "IssueCreation"
          mode         = "Auto"
          instructions = local.observability_agent_d_instructions
        },
        {
          type = "Investigation"
          mode = "Auto"
        },
      ]
    }
  }

  depends_on = [
    azurerm_role_assignment.observability_agent_issues,
    azurerm_role_assignment.observability_agent_monitoring,
  ]
}

resource "azapi_resource" "observability_agent_monitored_app_insights" {
  count = local.observability_agent_d_enabled ? 1 : 0

  type      = "Microsoft.Monitor/observabilityAgents/monitoredResources@2026-05-01-preview"
  name      = "appi-${local.suffix}"
  parent_id = azapi_resource.observability_agent[0].id

  schema_validation_enabled = false

  body = {
    properties = {
      resourceId   = azurerm_application_insights.this.id
      enabled      = true
      isAutonomous = true
    }
  }
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
