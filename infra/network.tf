###############################################################################
# Private deployment networking.
#
# The GitHub Actions runner lives in an existing shared VNet. Private endpoints
# are placed in its dedicated endpoint subnet, while Container Apps receives a
# separate delegated subnet so apps can resolve and pull from the private ACR.
###############################################################################

data "azurerm_virtual_network" "runner" {
  name                = var.runner_vnet_name
  resource_group_name = var.runner_vnet_resource_group
}

data "azurerm_subnet" "private_endpoints" {
  name                 = var.runner_private_endpoint_subnet_name
  virtual_network_name = data.azurerm_virtual_network.runner.name
  resource_group_name  = var.runner_vnet_resource_group
}

resource "azurerm_subnet" "container_apps" {
  name                 = "container-apps-${var.environment}"
  resource_group_name  = var.runner_vnet_resource_group
  virtual_network_name = data.azurerm_virtual_network.runner.name
  address_prefixes     = [var.container_apps_subnet_address_prefix]

  delegation {
    name = "container-apps-environments"

    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_private_dns_zone" "key_vault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "key_vault" {
  name                  = "runner-vnet-kv"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.key_vault.name
  virtual_network_id    = data.azurerm_virtual_network.runner.id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_endpoint" "key_vault" {
  name                = "pe-kv-${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = data.azurerm_virtual_network.runner.location
  subnet_id           = data.azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-kv-${local.suffix}"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "key-vault"
    private_dns_zone_ids = [azurerm_private_dns_zone.key_vault.id]
  }
}

resource "azurerm_private_dns_zone" "acr" {
  name                = "privatelink.azurecr.io"
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr" {
  name                  = "runner-vnet-acr"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.acr.name
  virtual_network_id    = data.azurerm_virtual_network.runner.id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_endpoint" "acr" {
  name                = "pe-acr-${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = data.azurerm_virtual_network.runner.location
  subnet_id           = data.azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-acr-${local.suffix}"
    private_connection_resource_id = azurerm_container_registry.this.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "acr"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr.id]
  }
}
