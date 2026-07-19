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

variable "scenario" {
  description = "Deployment security profile: A (autonomous/public), B (review/public GitHub MCP), or C (review/private code-first GitOps)."
  type        = string
  default     = "A"

  validation {
    condition     = contains(["A", "B", "C"], var.scenario)
    error_message = "scenario must be exactly one of A, B, or C."
  }
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

variable "sre_agent_subnet_address_prefix" {
  description = "Dedicated /28-or-larger subnet prefix for Scenario C SRE Agent Azure VNet integration."
  type        = string
  default     = "10.100.0.96/27"

  validation {
    condition = (
      can(cidrhost(var.sre_agent_subnet_address_prefix, 0)) &&
      can(tonumber(split("/", var.sre_agent_subnet_address_prefix)[1])) &&
      tonumber(split("/", var.sre_agent_subnet_address_prefix)[1]) <= 28
    )
    error_message = "sre_agent_subnet_address_prefix must be a valid /28-or-larger CIDR prefix."
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
    Whether to create the application Container Apps. The deploy script applies
    once with this false to create the platform/identities, pushes images, then
    applies again with this true. Defaults to true so a normal re-apply is
    idempotent.
  EOT
  type        = bool
  default     = true
}

variable "image_tag" {
  description = "Immutable container image tag pulled from ACR for application images."
  type        = string
  default     = "0000000000000000000000000000000000000000"

  validation {
    condition     = !var.deploy_apps || can(regex("^[0-9a-f]{40}$", var.image_tag))
    error_message = "image_tag must be a full lowercase 40-character Git commit SHA when deploy_apps is true."
  }
}

variable "image_digests" {
  description = "Exact ACR manifest digests keyed by service. Application revisions deploy these digests; image_tag is traceability metadata only."
  type        = map(string)
  default     = {}

  validation {
    condition = !var.deploy_apps || (
      length(setsubtract(
        toset(["frontend", "checkout-api", "payment-service"]),
        toset(keys(var.image_digests)),
      )) == 0 &&
      alltrue([
        for digest in values(var.image_digests) :
        can(regex("^sha256:[0-9a-f]{64}$", digest))
      ])
    )
    error_message = "image_digests must contain a sha256 manifest digest for every service required by the selected scenario when deploy_apps is true."
  }
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
# Dormant Entra-protected SRE remediation MCP broker metadata.
# The Scenario C profile keeps this broker disabled until remote Streamable-HTTP
# MCP documents the required managed-identity authentication flow.
###############################################################################

variable "sre_remediation_allowed_caller_principal_id" {
  description = "Fallback exact Scenario C SRE Agent principal ID for direct Terraform use without the managed agent resource. Deployment workflows derive this from the provisioned agent identity."
  type        = string
  default     = null
}

variable "sre_remediation_entra_api_client_id" {
  description = "Client ID of the dedicated Microsoft Entra API application protecting the broker. This is nonsecret metadata."
  type        = string
  default     = null
}

variable "sre_remediation_entra_token_audience" {
  description = "Allowed v2 access-token audience for the broker API. This must be the Entra API application client ID GUID."
  type        = string
  default     = null
}

variable "sre_remediation_entra_token_scope" {
  description = "Client-credentials token scope for callers. For Scenario C, use api://<sre_remediation_entra_api_client_id>/.default."
  type        = string
  default     = null
}

variable "sre_remediation_github_app_id" {
  description = "GitHub App numeric ID reserved for the dormant broker. Nonsecret metadata."
  type        = string
  default     = null
}

variable "sre_remediation_github_app_installation_id" {
  description = "GitHub App numeric installation ID reserved for the dormant broker. Nonsecret metadata."
  type        = string
  default     = null
}

variable "sre_remediation_github_app_bot_login" {
  description = "GitHub App bot login that must author broker-created remediation issues, including the [bot] suffix."
  type        = string
  default     = null
}

variable "sre_remediation_github_repository_owner" {
  description = "GitHub repository owner on which the dormant broker may operate."
  type        = string
  default     = null
}

variable "sre_remediation_github_repository_name" {
  description = "GitHub repository name on which the dormant broker may operate."
  type        = string
  default     = null
}

variable "sre_remediation_github_app_private_key_name" {
  description = "Name of the existing Key Vault RSA key imported out of band for broker signing. Terraform only derives its unversioned URI and never creates or reads key material."
  type        = string
  default     = "github-app-signing-key"

  validation {
    condition     = can(regex("^[0-9A-Za-z-]{1,127}$", var.sre_remediation_github_app_private_key_name))
    error_message = "sre_remediation_github_app_private_key_name must be a valid Key Vault key name."
  }
}

###############################################################################
# Optional: provision the selected scenario's one SRE Agent preview resource.
# Terraform owns its control plane; GitHub App credentials and data-plane policy
# remain an explicit external bootstrap.
###############################################################################

variable "enable_sre_agents" {
  description = "Provision exactly one SRE Agent using the selected scenario profile. Requires sre_agent_sponsor_group_id."
  type        = bool
  default     = false
}

variable "sre_agent_sponsor_group_id" {
  description = "Entra group object ID that sponsors the selected agent identity (required by Microsoft.App/agents)."
  type        = string
  default     = null

  validation {
    condition = var.sre_agent_sponsor_group_id == null ? !var.enable_sre_agents : can(
      regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.sre_agent_sponsor_group_id)
    )
    error_message = "sre_agent_sponsor_group_id must be null when unused or a valid Entra object ID; it is required when enable_sre_agents is true."
  }
}

variable "sre_agent_model_provider" {
  description = "Default documented SRE Agent model provider: MicrosoftFoundry or Anthropic."
  type        = string
  default     = "MicrosoftFoundry"

  validation {
    condition     = contains(["MicrosoftFoundry", "Anthropic"], var.sre_agent_model_provider)
    error_message = "sre_agent_model_provider must be exactly MicrosoftFoundry or Anthropic."
  }
}

variable "sre_agent_model_name" {
  description = "Default model name supported by the selected SRE Agent provider and region."
  type        = string
  default     = "gpt-5"

  validation {
    condition     = length(trimspace(var.sre_agent_model_name)) > 0 && trimspace(var.sre_agent_model_name) == var.sre_agent_model_name
    error_message = "sre_agent_model_name must be a nonempty model name without leading or trailing whitespace."
  }
}

variable "sre_agent_monthly_agent_unit_limit" {
  description = "Positive whole-number monthly active-flow Azure Agent Unit cap for the Terraform-managed SRE Agent."
  type        = number
  default     = 10000

  validation {
    condition     = var.sre_agent_monthly_agent_unit_limit >= 1 && floor(var.sre_agent_monthly_agent_unit_limit) == var.sre_agent_monthly_agent_unit_limit
    error_message = "sre_agent_monthly_agent_unit_limit must be a positive whole number."
  }
}

variable "enable_sre_code_access" {
  description = "Attach a dedicated secret-scoped identity for Scenario C GitHub App Code Access."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_sre_code_access || (var.scenario == "C" && var.enable_sre_agents)
    error_message = "enable_sre_code_access can be true only for Scenario C with enable_sre_agents=true."
  }
}

variable "sre_code_access_private_key_secret_name" {
  description = "Name of the existing Key Vault secret containing the read-only Code Access GitHub App PEM."
  type        = string
  default     = null

  validation {
    condition = var.sre_code_access_private_key_secret_name == null ? !var.enable_sre_code_access : can(
      regex("^[0-9A-Za-z-]{1,127}$", var.sre_code_access_private_key_secret_name)
    )
    error_message = "sre_code_access_private_key_secret_name is required when Code Access is enabled and must be a valid Key Vault secret name."
  }
}
