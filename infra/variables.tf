###############################################################################
# Input variables. Real values live in a git-ignored terraform.tfvars
# (copy terraform.tfvars.example). No secrets are ever defined here.
###############################################################################

variable "prefix" {
  description = "Short, non-identifying, alphanumeric prefix for resource names."
  type        = string
  default     = "contosopay"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,16}$", var.prefix))
    error_message = "prefix must be 2-17 chars, lowercase letters/digits, starting with a letter."
  }
}

variable "environment" {
  description = "Environment label applied as a tag and used in resource naming."
  type        = string
  default     = "demo"
}

variable "location" {
  description = "Azure region. Co-locate with an SRE Agent region where possible."
  type        = string
  default     = "swedencentral"
}

variable "runner_vnet_resource_group" {
  description = "Resource group containing the self-hosted runner VNet."
  type        = string
  default     = "agentrg"
}

variable "runner_vnet_name" {
  description = "Existing VNet used by the self-hosted GitHub Actions runner."
  type        = string
  default     = "agent-vnet"
}

variable "runner_private_endpoint_subnet_name" {
  description = "Existing runner-VNet subnet used to bootstrap the Terraform state Blob private endpoint."
  type        = string
  default     = "private-endpoints"
}

variable "app_vnet_address_space" {
  description = "Address space for the regional application VNet. Must not overlap the runner VNet."
  type        = string
  default     = "10.100.0.0/16"

  validation {
    condition     = can(cidrhost(var.app_vnet_address_space, 0))
    error_message = "app_vnet_address_space must be a valid CIDR prefix."
  }
}

variable "app_private_endpoint_subnet_address_prefix" {
  description = "Subnet prefix for Key Vault and ACR private endpoints in the regional application VNet."
  type        = string
  default     = "10.100.0.0/27"

  validation {
    condition     = can(cidrhost(var.app_private_endpoint_subnet_address_prefix, 0))
    error_message = "app_private_endpoint_subnet_address_prefix must be a valid CIDR prefix."
  }
}

variable "container_apps_subnet_address_prefix" {
  description = "Dedicated /27-or-larger subnet prefix for the workload-profiles Container Apps environment."
  type        = string
  default     = "10.100.0.64/27"

  validation {
    condition = (
      can(cidrhost(var.container_apps_subnet_address_prefix, 0)) &&
      can(tonumber(split("/", var.container_apps_subnet_address_prefix)[1])) &&
      tonumber(split("/", var.container_apps_subnet_address_prefix)[1]) <= 27
    )
    error_message = "container_apps_subnet_address_prefix must be a valid /27-or-larger CIDR prefix."
  }
}

variable "subscription_id" {
  description = "Target subscription ID. If null, ARM_SUBSCRIPTION_ID env var is used."
  type        = string
  default     = null
}

variable "enable_grafana" {
  description = "Deploy Azure Managed Grafana for dashboards."
  type        = bool
  default     = true
}

variable "deploy_apps" {
  description = <<-EOT
    Whether to create the three Container Apps. The deploy script applies once
    with this false (to create the ACR/Key Vault/identities/env), pushes the
    images, then applies again with this true. Defaults to true so a normal
    re-apply is idempotent.
  EOT
  type        = bool
  default     = true
}

variable "image_tag" {
  description = "Container image tag pulled from ACR for the three apps."
  type        = string
  default     = "latest"
}

variable "container_cpu" {
  description = "vCPU per container (must pair validly with container_memory)."
  type        = number
  default     = 0.25
}

variable "container_memory" {
  description = "Memory per container (valid ACA pair, e.g. 0.5Gi with 0.25 vCPU)."
  type        = string
  default     = "0.5Gi"
}

variable "payment_container_cpu" {
  description = "vCPU for payment-service; paired with payment_container_memory."
  type        = number
  default     = 0.5
}

variable "payment_container_memory" {
  description = "Memory for payment-service, including post-alert investigation headroom."
  type        = string
  default     = "1Gi"
}

variable "payment_max_replicas" {
  description = "Max replicas for payment-service (scale-out mitigation headroom)."
  type        = number
  default     = 3
}

variable "payment_scale_concurrent_requests" {
  description = "HTTP concurrent-requests threshold for the payment-service scale rule."
  type        = number
  default     = 50
}

variable "enable_slow_leak" {
  description = "Default state of the planted memory leak in payment-service."
  type        = bool
  default     = false
}

variable "leak_interval_ms" {
  description = "Background leak interval (ms) when the leak flag is on."
  type        = number
  default     = 2000
}

variable "leak_chunk_kb" {
  description = "Fallback leaked allocation size (KB) if timing calibration is unavailable."
  type        = number
  default     = 1024
}

variable "leak_target_crossing_seconds" {
  description = "Target time for working-set memory to reach the alert threshold after the leak starts."
  type        = number
  default     = 360
}

variable "memory_alert_threshold_bytes" {
  description = "Five-minute average working-set threshold (bytes) that fires the Monitor alert."
  type        = number
  default     = 390000000
}

variable "frontend_allowed_ips" {
  description = "Optional CIDR allow-list for the public frontend ingress. Empty = allow all."
  type        = list(string)
  default     = []
}

###############################################################################
# Optional: provision the two Azure SRE Agents (Microsoft.App/agents) in code.
# Off by default — the agent resource is preview, requires a sponsor group, and
# the GitHub OAuth / tool-policy / response-plan steps remain manual (see docs).
###############################################################################

variable "enable_sre_agents" {
  description = "Provision the two SRE Agents (Scenario A=High, B=Low) via azapi. Requires sre_agent_sponsor_group_id."
  type        = bool
  default     = false
}

variable "sre_agent_sponsor_group_id" {
  description = "Entra group object ID that sponsors the agents' identities (required by Microsoft.App/agents). Not committed; supply via tfvars/env."
  type        = string
  default     = null
}

variable "sre_agent_model_provider" {
  description = "Default model provider for the agents (e.g. MicrosoftFoundry in Sweden Central / EU; Anthropic elsewhere)."
  type        = string
  default     = "MicrosoftFoundry"
}

variable "sre_agent_model_name" {
  description = "Default model name for the agents."
  type        = string
  default     = "gpt-5"
}
