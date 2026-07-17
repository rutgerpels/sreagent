###############################################################################
# Scenario C private deployment networking. A/B intentionally create none of
# these resources and therefore do not require access to a private runner VNet.
# Global peering lets the existing private runner reach regional endpoints.
###############################################################################

data "azurerm_virtual_network" "runner" {
  count = local.profile.private_network_enabled ? 1 : 0

  name                = var.runner_vnet_name
  resource_group_name = var.runner_vnet_resource_group
}

resource "azurerm_virtual_network" "app" {
  count = local.profile.private_network_enabled ? 1 : 0

  name                = "vnet-${var.prefix}-${var.environment}-${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  address_space       = [var.app_vnet_address_space]
  tags                = local.tags
}

resource "azurerm_subnet" "private_endpoints" {
  count = local.profile.private_network_enabled ? 1 : 0

  name                              = "private-endpoints-${local.suffix}"
  resource_group_name               = azurerm_resource_group.this.name
  virtual_network_name              = azurerm_virtual_network.app[0].name
  address_prefixes                  = [var.app_private_endpoint_subnet_address_prefix]
  private_endpoint_network_policies = "Disabled"

  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_subnet" "container_apps" {
  count = local.profile.private_network_enabled ? 1 : 0

  name                 = "container-apps-${local.suffix}"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.app[0].name
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

# Kept separate from the Container Apps infrastructure subnet so the SRE Agent
# can be connected manually through its Azure VNet workspace setting.
resource "azurerm_subnet" "sre_agent" {
  count = local.profile.private_network_enabled ? 1 : 0

  name                 = "sre-agent-${local.suffix}"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.app[0].name
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
  count = local.profile.private_network_enabled ? 1 : 0

  name                         = "peer-app-to-runner-${local.suffix}"
  resource_group_name          = azurerm_resource_group.this.name
  virtual_network_name         = azurerm_virtual_network.app[0].name
  remote_virtual_network_id    = data.azurerm_virtual_network.runner[0].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false

  depends_on = [
    azurerm_subnet.private_endpoints,
    azurerm_subnet.container_apps,
    azurerm_subnet.sre_agent,
  ]
}

resource "azurerm_virtual_network_peering" "runner_to_app" {
  count = local.profile.private_network_enabled ? 1 : 0

  name                         = "peer-runner-to-app-${local.suffix}"
  resource_group_name          = var.runner_vnet_resource_group
  virtual_network_name         = data.azurerm_virtual_network.runner[0].name
  remote_virtual_network_id    = azurerm_virtual_network.app[0].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false

  depends_on = [
    azurerm_subnet.private_endpoints,
    azurerm_subnet.container_apps,
    azurerm_subnet.sre_agent,
  ]
}

resource "azurerm_private_dns_zone" "key_vault" {
  count = local.profile.private_network_enabled ? 1 : 0

  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "key_vault" {
  count = local.profile.private_network_enabled ? 1 : 0

  name                  = "runner-vnet-kv-${local.suffix}"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.key_vault[0].name
  virtual_network_id    = data.azurerm_virtual_network.runner[0].id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "key_vault_app" {
  count = local.profile.private_network_enabled ? 1 : 0

  name                  = "app-vnet-kv-${local.suffix}"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.key_vault[0].name
  virtual_network_id    = azurerm_virtual_network.app[0].id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_endpoint" "key_vault" {
  count = local.profile.private_network_enabled ? 1 : 0

  name                = "pe-kv-${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  subnet_id           = azurerm_subnet.private_endpoints[0].id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-kv-${local.suffix}"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "key-vault"
    private_dns_zone_ids = [azurerm_private_dns_zone.key_vault[0].id]
  }

  depends_on = [
    azurerm_virtual_network_peering.app_to_runner,
    azurerm_virtual_network_peering.runner_to_app,
  ]
}

resource "azurerm_private_dns_zone" "acr" {
  count = local.profile.private_network_enabled ? 1 : 0

  name                = "privatelink.azurecr.io"
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr" {
  count = local.profile.private_network_enabled ? 1 : 0

  name                  = "runner-vnet-acr-${local.suffix}"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.acr[0].name
  virtual_network_id    = data.azurerm_virtual_network.runner[0].id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr_app" {
  count = local.profile.private_network_enabled ? 1 : 0

  name                  = "app-vnet-acr-${local.suffix}"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.acr[0].name
  virtual_network_id    = azurerm_virtual_network.app[0].id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_endpoint" "acr" {
  count = local.profile.private_network_enabled ? 1 : 0

  name                = "pe-acr-${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  subnet_id           = azurerm_subnet.private_endpoints[0].id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-acr-${local.suffix}"
    private_connection_resource_id = azurerm_container_registry.this.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "acr"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr[0].id]
  }

  depends_on = [
    azurerm_virtual_network_peering.app_to_runner,
    azurerm_virtual_network_peering.runner_to_app,
  ]
}
