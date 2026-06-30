###############################################################################
# Container Apps environment + the three ContosoPay apps.
# Only `frontend` has external ingress (R4). checkout-api and payment-service
# are internal-only. TLS enforced (allow_insecure_connections = false).
###############################################################################

resource "azurerm_container_app_environment" "this" {
  name                       = "cae-${local.suffix}"
  resource_group_name        = azurerm_resource_group.this.name
  location                   = azurerm_resource_group.this.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  tags                       = local.tags
}

locals {
  # Per-app configuration. Service-to-service URLs use the deterministic
  # internal FQDNs computed in main.tf.
  apps = {
    "frontend" = {
      external     = true
      min_replicas = 1
      max_replicas = 3
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
      env = [
        { name = "SERVICE_NAME", value = "payment-service" },
        { name = "PORT", value = "8080" },
        { name = "ENABLE_SLOW_LEAK", value = tostring(var.enable_slow_leak) },
        { name = "LEAK_INTERVAL_MS", value = tostring(var.leak_interval_ms) },
        { name = "LEAK_CHUNK_KB", value = tostring(var.leak_chunk_kb) },
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
      image  = "${azurerm_container_registry.this.login_server}/${each.key}:${var.image_tag}"
      cpu    = var.container_cpu
      memory = var.container_memory

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
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.kv_secrets,
    azurerm_key_vault_secret.appinsights_connection,
  ]
}
