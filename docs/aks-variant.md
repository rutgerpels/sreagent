# AKS variant (optional)

The default demo runs on **Azure Container Apps** (scale-to-zero, built-in internal
ingress, KEDA scale rules). For a Kubernetes-native audience you can run the same three
ContosoPay images on **AKS**. This document outlines the differences; it is not wired
into the default Terraform.

## Why ACA is the default

- Internal ingress and managed TLS out of the box (no ingress controller to run).
- KEDA scale rules are first-class, which maps cleanly to the "raise the scale rule"
  mitigation the SRE Agent proposes.
- Scale-to-zero keeps demo cost low.

## What changes on AKS

| Concern | Container Apps (default) | AKS variant |
|---------|--------------------------|-------------|
| Compute | `azurerm_container_app` | `azurerm_kubernetes_cluster` + Deployments |
| Ingress | Built-in external/internal ingress | NGINX or Application Gateway Ingress Controller; `ClusterIP` for internal services |
| Identity | User-assigned MI per app | **Workload Identity** (federated) per service account |
| ACR pull | `AcrPull` on the app MI | `AcrPull` on the kubelet identity, or workload identity |
| Key Vault | `secretRef` → Key Vault | **Secret Store CSI driver** with the Key Vault provider |
| Scale | KEDA HTTP scale rule | HPA (CPU/memory) or KEDA add-on |
| Telemetry | OpenTelemetry → App Insights | Same app code; optionally the App Insights / OpenTelemetry add-on |

## Sketch of the AKS resources (not included by default)

```hcl
resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  dns_prefix          = "contosopay"

  default_node_pool {
    name       = "system"
    node_count = 2
    vm_size    = "Standard_B2s"   # local-redundant, cost-conscious (R3)
  }

  identity { type = "SystemAssigned" }

  oidc_issuer_enabled       = true
  workload_identity_enabled = true
  tags                      = local.tags
}
```

Then, per service:

- A `Deployment` + `Service` (`ClusterIP` for `checkout-api` / `payment-service`,
  and an ingress only for `frontend`).
- A `ServiceAccount` federated to a user-assigned identity (workload identity).
- The Secret Store CSI driver to project the App Insights connection string from
  Key Vault.

## Demonstrating the same incident

The application code is identical, so the planted leak, the `ENABLE_SLOW_LEAK` flag,
and `scripts/trigger-incident.sh` behave the same. The two mitigations map to:

- **Restart**: `kubectl rollout restart deployment/payment-service` (or delete the pod).
- **Scale**: raise the HPA `maxReplicas` / KEDA trigger.

The Azure Monitor alert targets the cluster's container insights memory metric for the
`payment-service` workload instead of the Container Apps `WorkingSetBytes` metric.
