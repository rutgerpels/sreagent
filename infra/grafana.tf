###############################################################################
# Azure Managed Grafana (optional, on by default via var.enable_grafana).
# Non-zone-redundant (R3). System-assigned identity granted Monitoring Reader
# so dashboards can query Azure Monitor / App Insights / Log Analytics.
###############################################################################

resource "azurerm_dashboard_grafana" "this" {
  count = var.enable_grafana ? 1 : 0

  name                              = "graf-${local.suffix}"
  resource_group_name               = azurerm_resource_group.this.name
  location                          = azurerm_resource_group.this.location
  grafana_major_version             = "12"
  sku                               = "Standard"
  api_key_enabled                   = false
  deterministic_outbound_ip_enabled = false
  public_network_access_enabled     = true
  zone_redundancy_enabled           = false
  tags                              = local.tags

  identity {
    type = "SystemAssigned"
  }
}

# Let Grafana read monitoring data across the demo resource group.
resource "azurerm_role_assignment" "grafana_monitoring_reader" {
  count                = var.enable_grafana ? 1 : 0
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Monitoring Reader"
  principal_id         = azurerm_dashboard_grafana.this[0].identity[0].principal_id
}

# Grant the deployer Grafana Admin so they can sign in and build dashboards.
resource "azurerm_role_assignment" "grafana_admin" {
  count                = var.enable_grafana ? 1 : 0
  scope                = azurerm_dashboard_grafana.this[0].id
  role_definition_name = "Grafana Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}
