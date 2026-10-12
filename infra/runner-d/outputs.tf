output "resource_group_name" {
  value = azurerm_resource_group.runner.name
}

output "vnet_name" {
  value = azurerm_virtual_network.runner.name
}

output "private_endpoint_subnet_name" {
  value = azurerm_subnet.private_endpoints.name
}

output "vm_name" {
  value = azurerm_linux_virtual_machine.runner.name
}

output "nat_public_ip" {
  description = "Outbound address of the runner (informational)."
  value       = azurerm_public_ip.nat.ip_address
}
