variable "subscription_id" {
  description = "Target subscription. Leave null to use ARM_SUBSCRIPTION_ID / the az login context."
  type        = string
  default     = null
}

variable "location" {
  description = "Azure region for the runner foundation."
  type        = string
  default     = "swedencentral"
}

variable "resource_group_name" {
  description = "Runner resource group. Must match the D_RUNNER_NETWORK_RG repo variable (default agentrg-d)."
  type        = string
  default     = "agentrg-d"
}

variable "vnet_name" {
  description = "Runner VNet name. Must match the D_RUNNER_VNET_NAME repo variable (default agent-vnet-d)."
  type        = string
  default     = "agent-vnet-d"
}

variable "vnet_address_space" {
  description = "Runner VNet CIDR. Must not overlap the Scenario D app VNet (default 10.101.0.0/16)."
  type        = string
  default     = "10.102.0.0/16"
}

variable "runner_subnet_prefix" {
  description = "Subnet for the runner VM (outbound via NAT gateway, no public IP)."
  type        = string
  default     = "10.102.0.0/27"
}

variable "private_endpoint_subnet_prefix" {
  description = "Subnet that receives the Terraform state private endpoint (D_RUNNER_PE_SUBNET_NAME, default private-endpoints)."
  type        = string
  default     = "10.102.0.32/27"
}

variable "vm_name" {
  description = "Runner VM name (also its GitHub runner name)."
  type        = string
  default     = "vm-payd-runner"
}

variable "vm_size" {
  description = "Runner VM size. It builds Docker images and runs Terraform, so keep at least 4 vCPUs."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "admin_username" {
  description = "Local admin account name. Password login is disabled."
  type        = string
  default     = "azureuser"
}

variable "admin_ssh_public_key" {
  description = "SSH public key. The VM has no inbound access; the key only satisfies the platform requirement, and the runner is managed through az vm run-command. scripts/deploy-runner-d.ps1 generates a throwaway key and discards the private half."
  type        = string
}

variable "tags" {
  description = "Extra tags."
  type        = map(string)
  default     = {}
}
