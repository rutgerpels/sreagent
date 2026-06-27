terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
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

  # Local backend by default for single-command deploys. Uncomment and configure
  # the azurerm backend below if your team wants remote state.
  #
  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate"
  #   storage_account_name = "sttfstateexample"   # must be globally unique, LRS
  #   container_name       = "tfstate"
  #   key                  = "sre-agent-demo.tfstate"
  # }
}

provider "azurerm" {
  # subscription_id falls back to the ARM_SUBSCRIPTION_ID environment variable
  # (set by scripts/deploy.*) when var.subscription_id is null.
  subscription_id = var.subscription_id

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
