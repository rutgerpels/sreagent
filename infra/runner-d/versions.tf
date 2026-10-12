terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # Deliberately local state: this root only holds the Scenario D runner
  # foundation (VNet, NAT gateway, VM) and has no private-state dependency. The
  # state file is git-ignored; it contains no secrets.
}

provider "azurerm" {
  # subscription_id comes from ARM_SUBSCRIPTION_ID or var.subscription_id.
  subscription_id                 = var.subscription_id
  resource_provider_registrations = "none"

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
