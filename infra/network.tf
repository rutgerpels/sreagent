###############################################################################
# Private deployment networking.
#
# The GitHub Actions runner lives in an existing shared VNet. Workloads and
# private endpoints live in a Terraform-managed VNet in the deployment region.
# Global VNet peering lets the runner reach the private endpoints even when the
# app and runner are in different Azure regions.
###############################################################################

data "azurerm_virtual_network" "runner" {
  name                = var.runner_vnet_name
  resource_group_name = var.runner_vnet_resource_group
}

resource "azurerm_virtual_network" "app" {
  name                = "vnet-${var.prefix}-${var.environment}-${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  address_space       = [var.app_vnet_address_space]
  tags                = local.tags
}

resource "azurerm_subnet" "private_endpoints" {
  name                              = "private-endpoints"
  resource_group_name               = azurerm_resource_group.this.name
  virtual_network_name              = azurerm_virtual_network.app.name
  address_prefixes                  = [var.app_private_endpoint_subnet_address_prefix]
  private_endpoint_network_policies = "Disabled"

  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_subnet" "container_apps" {
  name                 = "container-apps-${var.environment}"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = [var.container_apps_subnet_address_prefix]

  delegation {
    name = "container-apps-environments"

    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_subnet" "sre_agent" {
  name                 = "sre-agent-${var.environment}"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = [var.sre_agent_subnet_address_prefix]

  delegation {
    name = "sre-agent-environments"

    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_virtual_network_peering" "app_to_runner" {
  name                         = "peer-app-to-runner-${local.suffix}"
  resource_group_name          = azurerm_resource_group.this.name
  virtual_network_name         = azurerm_virtual_network.app.name
  remote_virtual_network_id    = data.azurerm_virtual_network.runner.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false

  depends_on = [
    azurerm_subnet.private_endpoints,
    azurerm_subnet.container_apps,
  ]
}

resource "azurerm_virtual_network_peering" "runner_to_app" {
  name                         = "peer-runner-to-app-${local.suffix}"
  resource_group_name          = var.runner_vnet_resource_group
  virtual_network_name         = data.azurerm_virtual_network.runner.name
  remote_virtual_network_id    = azurerm_virtual_network.app.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false

  depends_on = [
    azurerm_subnet.private_endpoints,
    azurerm_subnet.container_apps,
  ]
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

resource "azurerm_private_dns_zone_virtual_network_link" "key_vault_app" {
  name                  = "app-vnet-kv"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.key_vault.name
  virtual_network_id    = azurerm_virtual_network.app.id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_endpoint" "key_vault" {
  name                = "pe-kv-${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  subnet_id           = azurerm_subnet.private_endpoints.id
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

  depends_on = [
    azurerm_virtual_network_peering.app_to_runner,
    azurerm_virtual_network_peering.runner_to_app,
  ]
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

resource "azurerm_private_dns_zone_virtual_network_link" "acr_app" {
  name                  = "app-vnet-acr"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.acr.name
  virtual_network_id    = azurerm_virtual_network.app.id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_endpoint" "acr" {
  name                = "pe-acr-${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  subnet_id           = azurerm_subnet.private_endpoints.id
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

  depends_on = [
    azurerm_virtual_network_peering.app_to_runner,
    azurerm_virtual_network_peering.runner_to_app,
  ]
}
