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
  default     = 5000
}

variable "leak_chunk_kb" {
  description = "Size (KB) of each leaked allocation when the leak flag is on."
  type        = number
  default     = 256
}

variable "memory_alert_threshold_bytes" {
  description = "Working-set memory threshold (bytes) that fires the Monitor alert."
  type        = number
  default     = 350000000
}

variable "frontend_allowed_ips" {
  description = "Optional CIDR allow-list for the public frontend ingress. Empty = allow all."
  type        = list(string)
  default     = []
}
