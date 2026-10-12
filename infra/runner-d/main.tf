locals {
  tags = merge({
    project    = "sre-agent-demo"
    scenario   = "D"
    role       = "private-runner"
    managed_by = "terraform"
  }, var.tags)
}

resource "azurerm_resource_group" "runner" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "runner" {
  name                = var.vnet_name
  location            = azurerm_resource_group.runner.location
  resource_group_name = azurerm_resource_group.runner.name
  address_space       = [var.vnet_address_space]
  tags                = local.tags
}

# Default NSG rules already deny inbound traffic from the internet; these NSGs
# exist so both subnets carry an explicit, auditable boundary.
resource "azurerm_network_security_group" "runner" {
  name                = "${var.vnet_name}-runner-nsg"
  location            = azurerm_resource_group.runner.location
  resource_group_name = azurerm_resource_group.runner.name
  tags                = local.tags
}

resource "azurerm_network_security_group" "private_endpoints" {
  name                = "${var.vnet_name}-private-endpoints-nsg"
  location            = azurerm_resource_group.runner.location
  resource_group_name = azurerm_resource_group.runner.name
  tags                = local.tags
}

resource "azurerm_subnet" "runner" {
  name                 = "runner"
  resource_group_name  = azurerm_resource_group.runner.name
  virtual_network_name = azurerm_virtual_network.runner.name
  address_prefixes     = [var.runner_subnet_prefix]
}

resource "azurerm_subnet" "private_endpoints" {
  name                              = "private-endpoints"
  resource_group_name               = azurerm_resource_group.runner.name
  virtual_network_name              = azurerm_virtual_network.runner.name
  address_prefixes                  = [var.private_endpoint_subnet_prefix]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_subnet_network_security_group_association" "runner" {
  subnet_id                 = azurerm_subnet.runner.id
  network_security_group_id = azurerm_network_security_group.runner.id
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}

# Outbound-only internet (GitHub, package registries, Azure control plane). The
# public IP belongs to the NAT gateway; the VM itself has no public address and
# there is no inbound path to it.
resource "azurerm_public_ip" "nat" {
  name                = "pip-${var.vnet_name}-nat"
  location            = azurerm_resource_group.runner.location
  resource_group_name = azurerm_resource_group.runner.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway" "runner" {
  name                = "nat-${var.vnet_name}"
  location            = azurerm_resource_group.runner.location
  resource_group_name = azurerm_resource_group.runner.name
  sku_name            = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "runner" {
  nat_gateway_id       = azurerm_nat_gateway.runner.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "runner" {
  subnet_id      = azurerm_subnet.runner.id
  nat_gateway_id = azurerm_nat_gateway.runner.id
}

resource "azurerm_network_interface" "runner" {
  name                = "nic-${var.vm_name}"
  location            = azurerm_resource_group.runner.location
  resource_group_name = azurerm_resource_group.runner.name
  tags                = local.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.runner.id
    private_ip_address_allocation = "Dynamic"
  }

  depends_on = [azurerm_subnet_nat_gateway_association.runner]
}

resource "azurerm_linux_virtual_machine" "runner" {
  name                            = var.vm_name
  location                        = azurerm_resource_group.runner.location
  resource_group_name             = azurerm_resource_group.runner.name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.runner.id]
  tags                            = local.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 128
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # The runner authenticates to Azure through the workflow's OIDC federated
  # credential, so the VM needs no managed identity and holds no credentials.
}
