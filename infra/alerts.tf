###############################################################################
# Azure Monitor alerting. The memory alert fires the incident the SRE Agent
# picks up; the Action Group is what the agent / Teams subscribes to.
###############################################################################

resource "azurerm_monitor_action_group" "this" {
  name                = "ag-sre-${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  short_name          = "sreagent"
  tags                = local.tags

  # No receivers are wired in code. The Azure SRE Agent does NOT subscribe to
  # this action group — it ingests alerts by polling the Azure Monitor Alerts
  # API (~1-min scanner) for the resource groups its managed identity can read,
  # once Azure Monitor is connected as its incident platform (see
  # docs/sre-agent-setup.md). Add an email_receiver here only for human
  # notification; it is not required for the agent.
}

# Working-set memory alert on payment-service. Only created once the apps exist.
# Scenario D uses request-failure alerts instead, so it is skipped there.
resource "azurerm_monitor_metric_alert" "payment_memory" {
  count = var.deploy_apps && var.scenario != "D" ? 1 : 0

  name                = "alert-payment-memory-${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  scopes              = [azurerm_container_app.app["payment-service"].id]
  description         = "payment-service working-set memory is climbing — possible leak."
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"
  auto_mitigate       = true

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "WorkingSetBytes"
    # A five-minute average filters ordinary one-sample fluctuations while
    # preserving correct behavior if payment-service scales to multiple replicas.
    aggregation = "Average"
    operator    = "GreaterThan"
    threshold   = var.memory_alert_threshold_bytes
  }

  action {
    action_group_id = azurerm_monitor_action_group.this.id
  }

  tags = local.tags
}

# Scenario D: request-failure alerts on Application Insights. Probes
# (/health, /ready) are excluded so only real order traffic counts. Windows are
# short and static so the alert fires within minutes of the fault starting.
locals {
  payment_alert_enabled = var.scenario == "D" && var.deploy_apps
  payment_alert_freq    = "PT${var.payment_alert_frequency_minutes}M"
  # The window must cover the evaluation interval or failures fall between runs.
  payment_alert_window = "PT${max(var.payment_alert_window_minutes, var.payment_alert_frequency_minutes)}M"
}

# The only alert the SRE Agent response plan targets.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "payment_failures" {
  count = local.payment_alert_enabled ? 1 : 0

  name                    = "alert-payment-failures-${local.suffix}"
  resource_group_name     = azurerm_resource_group.this.name
  location                = azurerm_resource_group.this.location
  description             = "payment-service /pay requests are failing (payment processor unavailable)."
  severity                = 2
  enabled                 = true
  evaluation_frequency    = local.payment_alert_freq
  window_duration         = local.payment_alert_window
  scopes                  = [azurerm_application_insights.this.id]
  auto_mitigation_enabled = true

  criteria {
    query                   = <<-KQL
      requests
      | where cloud_RoleName == "payment-service"
      | where name has "/pay" and name !has "health" and name !has "ready"
      | where success == false
    KQL
    time_aggregation_method = "Count"
    operator                = "GreaterThanOrEqual"
    threshold               = 3
  }

  action {
    action_groups = [azurerm_monitor_action_group.this.id]
  }

  tags = local.tags
}

# Customer-impact evidence for the investigation. Not an SRE Agent trigger.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "checkout_failures" {
  count = local.payment_alert_enabled ? 1 : 0

  name                    = "alert-checkout-failures-${local.suffix}"
  resource_group_name     = azurerm_resource_group.this.name
  location                = azurerm_resource_group.this.location
  description             = "checkout-api order requests are failing."
  severity                = 2
  enabled                 = true
  evaluation_frequency    = local.payment_alert_freq
  window_duration         = local.payment_alert_window
  scopes                  = [azurerm_application_insights.this.id]
  auto_mitigation_enabled = true

  criteria {
    query                   = <<-KQL
      requests
      | where cloud_RoleName == "checkout-api"
      | where name has "/checkout" and name !has "health" and name !has "ready"
      | where success == false
    KQL
    time_aggregation_method = "Count"
    operator                = "GreaterThanOrEqual"
    threshold               = 3
  }

  action {
    action_groups = [azurerm_monitor_action_group.this.id]
  }

  tags = local.tags
}
