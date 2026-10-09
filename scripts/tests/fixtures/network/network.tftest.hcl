mock_provider "azurerm" {
  mock_data "azurerm_virtual_network" {
    defaults = {
      id = "/subscriptions/test/resourceGroups/runner-network/providers/Microsoft.Network/virtualNetworks/runner"
    }
  }
}

run "managed_zones" {
  command = plan

  assert {
    condition = (
      length(azurerm_private_dns_zone.key_vault) == 1 &&
      length(azurerm_private_dns_zone.acr) == 1 &&
      length(azurerm_private_dns_zone_virtual_network_link.key_vault) == 1 &&
      length(azurerm_private_dns_zone_virtual_network_link.acr) == 1 &&
      azurerm_private_dns_zone_virtual_network_link.key_vault_app[0].private_dns_zone_name == azurerm_private_dns_zone.key_vault[0].name &&
      azurerm_private_dns_zone_virtual_network_link.acr_app[0].private_dns_zone_name == azurerm_private_dns_zone.acr[0].name
    )
    error_message = "Managed zones must own runner links and supply app-link names."
  }
}

run "shared_zones" {
  command = plan

  variables {
    key_vault_private_dns_zone_id = "/subscriptions/test/resourceGroups/shared-dns/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
    acr_private_dns_zone_id       = "/subscriptions/test/resourceGroups/shared-dns/providers/Microsoft.Network/privateDnsZones/privatelink.azurecr.io"
  }

  assert {
    condition = (
      length(azurerm_private_dns_zone.key_vault) == 0 &&
      length(azurerm_private_dns_zone.acr) == 0 &&
      length(azurerm_private_dns_zone_virtual_network_link.key_vault) == 0 &&
      length(azurerm_private_dns_zone_virtual_network_link.acr) == 0 &&
      azurerm_private_dns_zone_virtual_network_link.key_vault_app[0].private_dns_zone_name == "privatelink.vaultcore.azure.net" &&
      azurerm_private_dns_zone_virtual_network_link.acr_app[0].private_dns_zone_name == "privatelink.azurecr.io" &&
      azurerm_private_dns_zone_virtual_network_link.key_vault_app[0].resource_group_name == "shared-dns" &&
      azurerm_private_dns_zone_virtual_network_link.acr_app[0].resource_group_name == "shared-dns" &&
      length(azurerm_private_endpoint.key_vault[0].private_dns_zone_group[0].private_dns_zone_ids) == 1 &&
      length(azurerm_private_endpoint.acr[0].private_dns_zone_group[0].private_dns_zone_ids) == 1 &&
      azurerm_private_endpoint.key_vault[0].private_dns_zone_group[0].private_dns_zone_ids[0] == var.key_vault_private_dns_zone_id &&
      azurerm_private_endpoint.acr[0].private_dns_zone_group[0].private_dns_zone_ids[0] == var.acr_private_dns_zone_id
    )
    error_message = "Shared zones must be reused without new zones or runner links."
  }
}

run "shared_key_vault_only" {
  command = plan

  variables {
    key_vault_private_dns_zone_id = "/subscriptions/test/resourceGroups/shared-dns/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
  }

  assert {
    condition = (
      length(azurerm_private_dns_zone.key_vault) == 0 &&
      length(azurerm_private_dns_zone.acr) == 1 &&
      length(azurerm_private_dns_zone_virtual_network_link.key_vault_app) == 1 &&
      length(azurerm_private_dns_zone_virtual_network_link.acr_app) == 1
    )
    error_message = "Key Vault reuse must not disable the managed ACR zone."
  }
}

run "shared_acr_only" {
  command = plan

  variables {
    acr_private_dns_zone_id = "/subscriptions/test/resourceGroups/shared-dns/providers/Microsoft.Network/privateDnsZones/privatelink.azurecr.io"
  }

  assert {
    condition = (
      length(azurerm_private_dns_zone.key_vault) == 1 &&
      length(azurerm_private_dns_zone.acr) == 0 &&
      length(azurerm_private_dns_zone_virtual_network_link.key_vault_app) == 1 &&
      length(azurerm_private_dns_zone_virtual_network_link.acr_app) == 1
    )
    error_message = "ACR reuse must not disable the managed Key Vault zone."
  }
}

run "scenario_a" {
  command = plan

  variables {
    scenario = "A"
  }

  assert {
    condition = (
      length(azurerm_virtual_network.app) == 0 &&
      length(data.azurerm_virtual_network.runner) == 0 &&
      length(azurerm_private_dns_zone.key_vault) == 0 &&
      length(azurerm_private_dns_zone.acr) == 0 &&
      length(azurerm_private_dns_zone_virtual_network_link.key_vault_app) == 0 &&
      length(azurerm_private_dns_zone_virtual_network_link.acr_app) == 0 &&
      length(azurerm_private_endpoint.key_vault) == 0 &&
      length(azurerm_private_endpoint.acr) == 0
    )
    error_message = "Scenario A must not evaluate private-network resources."
  }
}

run "scenario_b" {
  command = plan

  variables {
    scenario = "B"
  }

  assert {
    condition = (
      length(azurerm_virtual_network.app) == 0 &&
      length(data.azurerm_virtual_network.runner) == 0 &&
      length(azurerm_private_dns_zone.key_vault) == 0 &&
      length(azurerm_private_dns_zone.acr) == 0 &&
      length(azurerm_private_dns_zone_virtual_network_link.key_vault_app) == 0 &&
      length(azurerm_private_dns_zone_virtual_network_link.acr_app) == 0 &&
      length(azurerm_private_endpoint.key_vault) == 0 &&
      length(azurerm_private_endpoint.acr) == 0
    )
    error_message = "Scenario B must not evaluate private-network resources."
  }
}
