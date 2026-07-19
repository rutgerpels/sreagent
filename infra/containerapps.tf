###############################################################################
# Container Apps environment + ContosoPay apps and dormant Scenario C broker.
# The frontend is external; all other deployed applications are internal. The
# broker resources remain in source for future product support but are disabled
# by the immutable Scenario C profile.
###############################################################################

resource "azurerm_container_app_environment" "this" {
  name                       = "cae-${local.suffix}"
  resource_group_name        = azurerm_resource_group.this.name
  location                   = azurerm_resource_group.this.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  infrastructure_subnet_id   = local.profile.private_network_enabled ? azurerm_subnet.container_apps[0].id : null
  public_network_access      = "Enabled"
  tags                       = local.tags

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

locals {
  # Per-app configuration. Service-to-service URLs use the deterministic
  # internal FQDNs computed in main.tf.
  apps = {
    "frontend" = {
      external     = true
      min_replicas = 1
      max_replicas = 3
      cpu          = var.container_cpu
      memory       = var.container_memory
      env = [
        { name = "SERVICE_NAME", value = "frontend" },
        { name = "PORT", value = "8080" },
        { name = "CHECKOUT_API_URL", value = local.checkout_url },
      ]
    }
    "checkout-api" = {
      external     = false
      min_replicas = 1
      max_replicas = 3
      cpu          = var.container_cpu
      memory       = var.container_memory
      env = [
        { name = "SERVICE_NAME", value = "checkout-api" },
        { name = "PORT", value = "8080" },
        { name = "PAYMENT_SERVICE_URL", value = local.payment_url },
      ]
    }
    "payment-service" = {
      external     = false
      min_replicas = 1
      max_replicas = var.payment_max_replicas
      cpu          = var.payment_container_cpu
      memory       = var.payment_container_memory
      env = [
        { name = "SERVICE_NAME", value = "payment-service" },
        { name = "PORT", value = "8080" },
        { name = "ENABLE_SLOW_LEAK", value = tostring(var.enable_slow_leak) },
        { name = "LEAK_INTERVAL_MS", value = tostring(var.leak_interval_ms) },
        { name = "LEAK_CHUNK_KB", value = tostring(var.leak_chunk_kb) },
        { name = "LEAK_TARGET_CROSSING_SECONDS", value = tostring(var.leak_target_crossing_seconds) },
        { name = "MEMORY_ALERT_THRESHOLD_BYTES", value = tostring(var.memory_alert_threshold_bytes) },
      ]
    }
  }
}

resource "azurerm_container_app" "app" {
  for_each = var.deploy_apps ? local.apps : {}

  name                         = local.app_names[each.key]
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.this.name
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app[each.key].id]
  }

  # Pull from ACR using the app's managed identity (no admin keys).
  registry {
    server   = azurerm_container_registry.this.login_server
    identity = azurerm_user_assigned_identity.app[each.key].id
  }

  # App Insights connection string sourced from Key Vault via managed identity.
  secret {
    name                = "appinsights-connection-string"
    key_vault_secret_id = azurerm_key_vault_secret.appinsights_connection.versionless_id
    identity            = azurerm_user_assigned_identity.app[each.key].id
  }

  ingress {
    external_enabled           = each.value.external
    target_port                = 8080
    transport                  = "auto"
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }

    # Optional CIDR allow-list on the public frontend only.
    dynamic "ip_security_restriction" {
      for_each = each.value.external ? var.frontend_allowed_ips : []
      content {
        name             = "allow-${ip_security_restriction.key}"
        action           = "Allow"
        ip_address_range = ip_security_restriction.value
      }
    }
  }

  template {
    min_replicas = each.value.min_replicas
    max_replicas = each.value.max_replicas

    container {
      name   = each.key
      image  = "${azurerm_container_registry.this.login_server}/${each.key}@${var.image_digests[each.key]}"
      cpu    = each.value.cpu
      memory = each.value.memory

      dynamic "env" {
        for_each = each.value.env
        content {
          name  = env.value.name
          value = env.value.value
        }
      }

      env {
        name        = "APPLICATIONINSIGHTS_CONNECTION_STRING"
        secret_name = "appinsights-connection-string"
      }

      liveness_probe {
        transport        = "HTTP"
        port             = 8080
        path             = "/health"
        initial_delay    = 10
        interval_seconds = 30
      }

      readiness_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/ready"
        interval_seconds        = 15
        success_count_threshold = 1
        failure_count_threshold = 3
      }
    }

    # Scale rule on payment-service so the agent can demo the "raise scale
    # rule" mitigation.
    dynamic "http_scale_rule" {
      for_each = each.key == "payment-service" ? [1] : []
      content {
        name                = "http-concurrency"
        concurrent_requests = tostring(var.payment_scale_concurrent_requests)
      }
    }
  }

  depends_on = [
    azurerm_key_vault_secret.appinsights_connection,
    time_sleep.wait_app_dependencies,
  ]
}

###############################################################################
# Scenario C Streamable-HTTP broker. Azure Container Apps does not support a
# per-app private endpoint, and making the entire environment internal would
# also remove the required public frontend. The supported narrow design is an
# external HTTPS ingress protected by Easy Auth. Easy Auth restricts the token
# to the exact SRE Agent principal and the service independently verifies the
# Entra JWT signature, issuer, audience, expiry, and object ID.
###############################################################################

resource "azurerm_container_app" "sre_remediation_broker" {
  count = var.deploy_apps && local.profile.broker_enabled ? 1 : 0

  name                         = "ca-sre-remediation-${local.suffix}"
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.this.name
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.sre_remediation_broker[0].id]
  }

  registry {
    server   = azurerm_container_registry.this.login_server
    identity = azurerm_user_assigned_identity.sre_remediation_broker[0].id
  }

  ingress {
    external_enabled           = true
    target_port                = 8080
    transport                  = "auto"
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    # Process-local issue-creation coalescing is authoritative at one replica.
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "sre-remediation-mcp"
      image  = "${azurerm_container_registry.this.login_server}/sre-remediation-mcp@${var.image_digests["sre-remediation-mcp"]}"
      cpu    = var.container_cpu
      memory = var.container_memory

      env {
        name  = "PORT"
        value = "8080"
      }
      env {
        name  = "ALLOWED_CALLER_PRINCIPAL_ID"
        value = local.sre_remediation_allowed_caller_principal_id
      }
      env {
        name  = "ENTRA_TENANT_ID"
        value = data.azurerm_client_config.current.tenant_id
      }
      env {
        name  = "ENTRA_TOKEN_AUDIENCE"
        value = var.sre_remediation_entra_token_audience
      }
      # Nonsecret, unversioned key URI only. The RSA key is imported manually;
      # Terraform neither creates nor reads private key material.
      env {
        name  = "GITHUB_APP_PRIVATE_KEY_KEY_URI"
        value = "${azurerm_key_vault.this.vault_uri}keys/${var.sre_remediation_github_app_private_key_name}"
      }
      env {
        name  = "GITHUB_APP_ID"
        value = var.sre_remediation_github_app_id
      }
      env {
        name  = "GITHUB_APP_INSTALLATION_ID"
        value = var.sre_remediation_github_app_installation_id
      }
      env {
        name  = "GITHUB_APP_BOT_LOGIN"
        value = var.sre_remediation_github_app_bot_login
      }
      env {
        name  = "GITHUB_REPOSITORY_OWNER"
        value = var.sre_remediation_github_repository_owner
      }
      env {
        name  = "GITHUB_REPOSITORY_NAME"
        value = var.sre_remediation_github_repository_name
      }

      # Select the sole user-assigned identity explicitly for DefaultAzureCredential.
      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.sre_remediation_broker[0].client_id
      }

      liveness_probe {
        transport        = "HTTP"
        port             = 8080
        path             = "/health"
        initial_delay    = 10
        interval_seconds = 30
      }

      readiness_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/health"
        interval_seconds        = 15
        success_count_threshold = 1
        failure_count_threshold = 3
      }
    }
  }

  depends_on = [
    time_sleep.wait_sre_remediation_broker_dependencies,
  ]
}

resource "azapi_resource" "sre_remediation_broker_auth" {
  count = var.deploy_apps && local.profile.broker_enabled ? 1 : 0

  type      = "Microsoft.App/containerApps/authConfigs@2024-03-01"
  name      = "current"
  parent_id = azurerm_container_app.sre_remediation_broker[0].id

  # The body follows the published Container Apps authConfig resource schema.
  schema_validation_enabled = false

  body = {
    properties = {
      platform = {
        enabled = true
      }
      globalValidation = {
        unauthenticatedClientAction = "Return401"
        # ACA health probes do not carry Entra credentials. This endpoint returns
        # only a static liveness value and is the sole unauthenticated path.
        excludedPaths = ["/health"]
      }
      httpSettings = {
        requireHttps = true
      }
      login = {
        tokenStore = {
          enabled = true
        }
      }
      identityProviders = {
        azureActiveDirectory = {
          enabled           = true
          isAutoProvisioned = false
          registration = {
            clientId     = var.sre_remediation_entra_api_client_id
            openIdIssuer = "https://login.microsoftonline.com/${data.azurerm_client_config.current.tenant_id}/v2.0"
          }
          validation = {
            allowedAudiences = [var.sre_remediation_entra_token_audience]
            defaultAuthorizationPolicy = {
              allowedPrincipals = {
                identities = [local.sre_remediation_allowed_caller_principal_id]
              }
            }
          }
        }
      }
    }
  }
}
