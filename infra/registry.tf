###############################################################################
# Azure Container Registry - Premium supports Scenario C Private Link.
# A/B expose its RBAC-protected endpoint for local or hosted deployment; C
# disables public access. Admin and anonymous access are always disabled.
###############################################################################

resource "azurerm_container_registry" "this" {
  name                          = local.acr_name
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  sku                           = local.profile.private_network_enabled ? "Premium" : "Standard"
  admin_enabled                 = false
  anonymous_pull_enabled        = false
  public_network_access_enabled = !local.profile.private_network_enabled
  network_rule_bypass_option    = "None"
  tags                          = local.tags
}
