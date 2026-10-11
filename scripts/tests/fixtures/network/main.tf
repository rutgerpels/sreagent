terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "scenario" {
  type    = string
  default = "C"
}

variable "key_vault_private_dns_zone_id" {
  type    = string
  default = ""
}

variable "acr_private_dns_zone_id" {
  type    = string
  default = ""
}

locals {
  profile = { private_network_enabled = var.scenario == "C" }
  suffix  = "test"
  tags    = {}
}

variable "prefix" {
  default = "test"
}
variable "environment" {
  default = "test"
}
variable "runner_vnet_name" {
  default = "runner"
}
variable "runner_vnet_resource_group" {
  default = "runner-network"
}
variable "app_vnet_address_space" {
  default = "10.100.0.0/16"
}
variable "app_private_endpoint_subnet_address_prefix" {
  default = "10.100.0.0/27"
}
variable "container_apps_subnet_address_prefix" {
  default = "10.100.0.64/27"
}
variable "sre_agent_subnet_address_prefix" {
  default = "10.100.0.96/27"
}

resource "azurerm_resource_group" "this" {
  name     = "rg-network-test"
  location = "swedencentral"
}

resource "azurerm_key_vault" "this" {
  name                = "kv-network-test"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tenant_id           = uuidv5("dns", "example.invalid")
  sku_name            = "standard"
}

resource "azurerm_container_registry" "this" {
  name                = "acrnetworktest"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Premium"
  admin_enabled       = false
}
