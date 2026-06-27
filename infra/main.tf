###############################################################################
# Provider data, naming, tags, and the resource group.
###############################################################################

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  suffix = random_string.suffix.result

  # Consistent tags on every resource (Terraform convention §7).
  tags = {
    project    = "sre-agent-demo"
    env        = var.environment
    managed_by = "terraform"
  }

  # Globally-unique, non-identifying names derived from prefix + random suffix.
  acr_name = substr(lower("acr${var.prefix}${local.suffix}"), 0, 50)
  kv_name  = substr("kv-${var.prefix}-${local.suffix}", 0, 24)

  app_keys = ["frontend", "checkout-api", "payment-service"]

  app_names = {
    "frontend"        = "ca-frontend-${local.suffix}"
    "checkout-api"    = "ca-checkout-${local.suffix}"
    "payment-service" = "ca-payment-${local.suffix}"
  }

  # Internal ingress FQDNs are deterministic from the app name + environment
  # default domain, so we can wire service-to-service URLs without creating a
  # dependency cycle between the apps.
  env_domain   = azurerm_container_app_environment.this.default_domain
  payment_url  = "https://${local.app_names["payment-service"]}.internal.${local.env_domain}"
  checkout_url = "https://${local.app_names["checkout-api"]}.internal.${local.env_domain}"
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.prefix}-${var.environment}-${local.suffix}"
  location = var.location
  tags     = local.tags
}
