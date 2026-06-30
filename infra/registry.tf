###############################################################################
# Azure Container Registry — Standard SKU, admin user disabled (R6).
# Apps pull via managed identity (AcrPull); no admin keys exist.
###############################################################################

resource "azurerm_container_registry" "this" {
  name                          = local.acr_name
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  sku                           = "Standard"
  admin_enabled                 = false
  public_network_access_enabled = true
  tags                          = local.tags
}
