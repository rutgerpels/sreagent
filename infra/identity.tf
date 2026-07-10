###############################################################################
# User-assigned managed identities (one per app) + least-privilege roles.
# No service principals, no client secrets (security rules §6 R6/R7).
###############################################################################

resource "azurerm_user_assigned_identity" "app" {
  for_each            = toset(local.app_keys)
  name                = "id-${each.key}-${local.suffix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

# AcrPull scoped to the registry only — each app pulls its own image via MI.
resource "azurerm_role_assignment" "acr_pull" {
  for_each                         = azurerm_user_assigned_identity.app
  scope                            = azurerm_container_registry.this.id
  role_definition_name             = "AcrPull"
  principal_id                     = each.value.principal_id
  skip_service_principal_aad_check = true
}

# Key Vault Secrets User scoped to the vault only — read secrets via MI.
resource "azurerm_role_assignment" "kv_secrets" {
  for_each                         = azurerm_user_assigned_identity.app
  scope                            = azurerm_key_vault.this.id
  role_definition_name             = "Key Vault Secrets User"
  principal_id                     = each.value.principal_id
  skip_service_principal_aad_check = true
}

# Give private DNS/endpoint provisioning and app-identity RBAC time to converge
# before the first Container App revision pulls an image and resolves secrets.
resource "time_sleep" "wait_app_dependencies" {
  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.kv_secrets,
    azurerm_private_dns_zone_virtual_network_link.acr,
    azurerm_private_dns_zone_virtual_network_link.key_vault,
    azurerm_private_endpoint.acr,
    azurerm_private_endpoint.key_vault,
  ]
  create_duration = "60s"
}
