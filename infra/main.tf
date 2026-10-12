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
  # Security-sensitive choices are immutable profiles rather than independent
  # toggles, preventing unsupported privilege/network combinations.
  scenario_profiles = {
    A = {
      private_network_enabled = false
      control_endpoint_access = "Public"
      github_integration      = "Manual Code Access; no GitHub write path"
      agent_key               = "a-autonomous"
      agent = {
        access = "High"
        role   = "Contributor"
        mode   = "Autonomous"
      }
    }
    B = {
      private_network_enabled = false
      control_endpoint_access = "Public"
      github_integration      = "Manual built-in GitHub MCP with a short-lived fine-grained PAT"
      agent_key               = "b-github-mcp"
      agent = {
        access = "Low"
        role   = "Reader"
        mode   = "Review"
      }
    }
    C = {
      private_network_enabled = true
      control_endpoint_access = "Private ACR/Key Vault; public frontend only"
      # The agent authors its remediation pull request through Code Access. It
      # holds workload Reader access; tool policy denies direct workload writes.
      # Subscription-level Monitoring Contributor remains an exception.
      github_integration = "API-managed Code Access; agent-authored remediation pull requests"
      agent_key          = "c-private-gitops"
      agent = {
        access = "Low"
        role   = "Reader"
        mode   = "Review"
      }
    }
    # D is a separate private deployment for the paired Observability Agent +
    # SRE Agent payment-outage demo. Recovery is a direct, human-approved
    # change to the live app; there is no GitHub write path.
    D = {
      private_network_enabled = true
      control_endpoint_access = "Private ACR/Key Vault; public frontend only"
      github_integration      = "No GitHub write path; direct approved recovery"
      agent_key               = "d-private-payments"
      agent = {
        access = "Low"
        role   = "Reader"
        mode   = "Review"
      }
    }
  }

  # Scenarios that provision the portal-onboarded Observability Agent prerequisites.
  observability_agent_enabled = contains(["A", "D"], var.scenario)

  profile = local.scenario_profiles[var.scenario]
  suffix  = "${lower(var.scenario)}-${random_string.suffix.result}"

  tags = {
    project    = "sre-agent-demo"
    env        = var.environment
    scenario   = var.scenario
    managed_by = "terraform"
  }

  # Globally unique names include the scenario to avoid cross-profile collisions.
  acr_name = substr(lower("acr${var.prefix}${lower(var.scenario)}${random_string.suffix.result}"), 0, 50)
  # Truncate only the human-readable prefix so the scenario and full random
  # suffix always survive Key Vault's 24-character name limit.
  kv_name = "kv-${substr(var.prefix, 0, 12)}-${local.suffix}"

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
