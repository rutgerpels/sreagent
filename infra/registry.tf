###############################################################################
# Azure Container Registry — Premium for Private Link, admin user disabled (R6).
# Apps and the private runner use the VNet endpoint; no admin keys exist.
###############################################################################

resource "azurerm_container_registry" "this" {
  name                          = local.acr_name
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  sku                           = "Premium"
  admin_enabled                 = false
  public_network_access_enabled = false
  network_rule_bypass_option    = "None"
  tags                          = local.tags
}
