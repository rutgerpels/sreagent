###############################################################################
# Azure Key Vault — RBAC authorization, soft-delete + purge protection (R6/R7).
# Stores the App Insights connection string; apps read it via managed identity.
###############################################################################

resource "azurerm_key_vault" "this" {
  name                          = local.kv_name
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  purge_protection_enabled      = true
  soft_delete_retention_days    = 7
  public_network_access_enabled = false
  tags                          = local.tags

  # Data-plane access uses the private endpoint in the runner VNet. Azure RBAC
  # remains the authorization boundary; no access policies or public IP rules.
  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }
}

# The principal running Terraform needs data-plane rights to write the secret.
resource "azurerm_role_assignment" "deployer_kv_secrets_officer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Allow RBAC to propagate before writing the first secret (avoids 403 races).
resource "time_sleep" "wait_kv_rbac" {
  depends_on = [
    azurerm_role_assignment.deployer_kv_secrets_officer,
    azurerm_private_dns_zone_virtual_network_link.key_vault,
    azurerm_private_endpoint.key_vault,
  ]
  create_duration = "60s"
}

resource "azurerm_key_vault_secret" "appinsights_connection" {
  name         = "appinsights-connection-string"
  value        = azurerm_application_insights.this.connection_string
  key_vault_id = azurerm_key_vault.this.id
  tags         = local.tags

  depends_on = [time_sleep.wait_kv_rbac]
}
