###############################################################################
# Azure Monitor alerting. The memory alert fires the incident the SRE Agent
# picks up; the Action Group is what the agent / Teams subscribes to.
###############################################################################

resource "azurerm_monitor_action_group" "this" {
  name                = "ag-sre-${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  short_name          = "sreagent"
  tags                = local.tags

  # No receivers are wired in code. The Azure SRE Agent subscribes to this
  # action group during its portal onboarding (see docs/run-of-show.md).
  # Add an email_receiver here only if you want a human notification too.
}

# Working-set memory alert on payment-service. Only created once the apps exist.
resource "azurerm_monitor_metric_alert" "payment_memory" {
  count = var.deploy_apps ? 1 : 0

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
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.memory_alert_threshold_bytes
  }

  action {
    action_group_id = azurerm_monitor_action_group.this.id
  }

  tags = local.tags
}
