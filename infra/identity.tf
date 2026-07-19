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
    azurerm_private_dns_zone_virtual_network_link.acr_app,
    azurerm_private_dns_zone_virtual_network_link.key_vault,
    azurerm_private_dns_zone_virtual_network_link.key_vault_app,
    azurerm_private_endpoint.acr,
    azurerm_private_endpoint.key_vault,
  ]
  create_duration = "60s"
}

###############################################################################
# Dormant Scenario C remediation broker identity. The current profile does not
# create it because remote Streamable-HTTP MCP lacks the required managed-
# identity authentication flow.
###############################################################################

locals {
  # Prefer the selected Terraform-managed Scenario C agent identity. The
  # explicit principal input supports preview-disabled/manual agent onboarding.
  sre_remediation_allowed_caller_principal_id = var.enable_sre_agents ? try(
    azurerm_user_assigned_identity.agent[local.profile.agent_key].principal_id,
    var.sre_remediation_allowed_caller_principal_id,
  ) : var.sre_remediation_allowed_caller_principal_id

  sre_remediation_validation = {
    allowed_caller_id = local.sre_remediation_allowed_caller_principal_id == null ? "" : local.sre_remediation_allowed_caller_principal_id
    entra_client_id   = var.sre_remediation_entra_api_client_id == null ? "" : var.sre_remediation_entra_api_client_id
    token_audience    = var.sre_remediation_entra_token_audience == null ? "" : var.sre_remediation_entra_token_audience
    token_scope       = var.sre_remediation_entra_token_scope == null ? "" : var.sre_remediation_entra_token_scope
    github_app_id     = var.sre_remediation_github_app_id == null ? "" : var.sre_remediation_github_app_id
    installation_id   = var.sre_remediation_github_app_installation_id == null ? "" : var.sre_remediation_github_app_installation_id
    github_bot_login  = var.sre_remediation_github_app_bot_login == null ? "" : var.sre_remediation_github_app_bot_login
    repository_owner  = var.sre_remediation_github_repository_owner == null ? "" : var.sre_remediation_github_repository_owner
    repository_name   = var.sre_remediation_github_repository_name == null ? "" : var.sre_remediation_github_repository_name
    private_key_name  = var.sre_remediation_github_app_private_key_name
  }
}

resource "azurerm_user_assigned_identity" "sre_remediation_broker" {
  count = local.profile.broker_enabled ? 1 : 0

  name                = "id-sre-remediation-${local.suffix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  lifecycle {
    precondition {
      condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", local.sre_remediation_validation.allowed_caller_id))
      error_message = "Scenario C requires a valid allowed SRE Agent principal ID, supplied directly or derived from its Terraform-managed identity."
    }
    precondition {
      condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", local.sre_remediation_validation.entra_client_id))
      error_message = "Scenario C requires a valid dedicated Entra broker API application client ID."
    }
    precondition {
      condition     = lower(local.sre_remediation_validation.token_audience) == lower(local.sre_remediation_validation.entra_client_id)
      error_message = "sre_remediation_entra_token_audience must equal sre_remediation_entra_api_client_id for Microsoft Entra v2 access tokens."
    }
    precondition {
      condition     = lower(local.sre_remediation_validation.token_scope) == "api://${lower(local.sre_remediation_validation.entra_client_id)}/.default"
      error_message = "sre_remediation_entra_token_scope must be api://<sre_remediation_entra_api_client_id>/.default."
    }
    precondition {
      condition     = can(regex("^[1-9][0-9]*$", local.sre_remediation_validation.github_app_id))
      error_message = "Scenario C requires a positive numeric remediation GitHub App ID."
    }
    precondition {
      condition     = can(regex("^[1-9][0-9]*$", local.sre_remediation_validation.installation_id))
      error_message = "Scenario C requires a positive numeric remediation GitHub App installation ID."
    }
    precondition {
      condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]{0,38}\\[bot\\]$", local.sre_remediation_validation.github_bot_login))
      error_message = "Scenario C requires the remediation GitHub App bot login, including its [bot] suffix."
    }
    precondition {
      condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$", local.sre_remediation_validation.repository_owner))
      error_message = "Scenario C requires a valid GitHub repository owner."
    }
    precondition {
      condition     = can(regex("^[A-Za-z0-9._-]{1,100}$", local.sre_remediation_validation.repository_name))
      error_message = "Scenario C requires a valid GitHub repository name."
    }
    precondition {
      condition     = can(regex("^[0-9A-Za-z-]{1,127}$", local.sre_remediation_validation.private_key_name))
      error_message = "sre_remediation_github_app_private_key_name must be a valid Key Vault key name."
    }
  }
}

resource "azurerm_role_assignment" "sre_remediation_broker_acr_pull" {
  count = local.profile.broker_enabled ? 1 : 0

  scope                            = azurerm_container_registry.this.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_user_assigned_identity.sre_remediation_broker[0].principal_id
  skip_service_principal_aad_check = true
}

# The imported RSA key remains non-exportable. This custom data-plane role grants
# only key metadata read and sign operations; the broker cannot decrypt, unwrap,
# export, create, rotate, or delete keys and has no secret permissions.
resource "azurerm_role_definition" "sre_remediation_broker_key_signer" {
  count = local.profile.broker_enabled ? 1 : 0

  name        = "SRE Broker Key Signer ${local.suffix}"
  scope       = azurerm_key_vault.this.id
  description = "Read key metadata and sign digests for the Scenario C GitHub App."

  permissions {
    data_actions = [
      "Microsoft.KeyVault/vaults/keys/read",
      "Microsoft.KeyVault/vaults/keys/sign/action",
    ]
  }

  assignable_scopes = [azurerm_key_vault.this.id]
}

resource "azurerm_role_assignment" "sre_remediation_broker_kv_crypto" {
  count = var.deploy_apps && local.profile.broker_enabled ? 1 : 0

  scope                            = "${azurerm_key_vault.this.id}/keys/${var.sre_remediation_github_app_private_key_name}"
  role_definition_id               = azurerm_role_definition.sre_remediation_broker_key_signer[0].role_definition_resource_id
  principal_id                     = azurerm_user_assigned_identity.sre_remediation_broker[0].principal_id
  skip_service_principal_aad_check = true
}

resource "time_sleep" "wait_sre_remediation_broker_dependencies" {
  count = var.deploy_apps && local.profile.broker_enabled ? 1 : 0

  depends_on = [
    azurerm_role_assignment.sre_remediation_broker_acr_pull,
    azurerm_role_assignment.sre_remediation_broker_kv_crypto,
    azurerm_private_dns_zone_virtual_network_link.acr_app,
    azurerm_private_dns_zone_virtual_network_link.key_vault_app,
    azurerm_private_endpoint.acr,
    azurerm_private_endpoint.key_vault,
  ]
  create_duration = "60s"
}
