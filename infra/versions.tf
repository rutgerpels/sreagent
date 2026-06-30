terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      # Used only for the optional Microsoft.App/agents (SRE Agent) resources,
      # which the azurerm provider does not yet expose. Gated behind
      # var.enable_sre_agents (default false), so it is a no-op otherwise.
      source  = "azure/azapi"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  # Remote state on an azurerm backend so CI (apply-infra.yml) can apply the
  # same state the operator deploys. This is a *partial* configuration: the
  # storage account / resource group / key are supplied at init time via
  # -backend-config flags. scripts/deploy.* bootstraps the LRS state storage
  # account and passes those flags, so the single-command deploy still works.
  #
  # To deploy with purely local state instead (no CI), comment this block out.
  backend "azurerm" {
    use_azuread_auth = true # auth via the signed-in identity / OIDC, no keys
  }
}

provider "azurerm" {
  # subscription_id falls back to the ARM_SUBSCRIPTION_ID environment variable
  # (set by scripts/deploy.*) when var.subscription_id is null.
  subscription_id = var.subscription_id

  # Skip the resource-provider listing/registration the provider does at startup.
  # The demo's resource providers are already registered on the subscription, and
  # that startup call intermittently fails in CI with "populating Resource
  # Provider cache: ... unexpected end of JSON input". Skipping it is faster and
  # removes that flaky failure mode.
  resource_provider_registrations = "none"

  features {
    key_vault {
      # Purge protection is enabled on the vault, so it cannot be purged on
      # destroy; recover any soft-deleted vault of the same name instead.
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "azapi" {}
