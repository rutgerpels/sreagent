# AKS variant (optional)

The implemented default is Azure Container Apps. This document is an
architecture mapping for a future Azure Kubernetes Service variant; the
repository's Terraform, deployment workflows, and trigger scripts do not deploy
AKS.

## Why Container Apps is the default

- Built-in external and internal ingress with managed TLS.
- First-class KEDA scale rules for the scale-mitigation demonstration.
- Consumption pricing and scale-to-zero.
- Built-in authentication for the Scenario C broker.
- A smaller operational footprint for a one-command demo.

## Service mapping

| Concern | Container Apps implementation | AKS equivalent |
| --- | --- | --- |
| Compute | `azurerm_container_app` | `azurerm_kubernetes_cluster` and Deployments |
| Public entry | External frontend ingress | One public ingress for frontend |
| Internal services | Internal app ingress | `ClusterIP` Services for checkout and payment |
| Identity | User-assigned managed identity per app | Microsoft Entra Workload ID per service account |
| ACR pull | `AcrPull` on app identity | `AcrPull` on kubelet identity or workload identity |
| Key Vault | Managed-identity Key Vault references | Secrets Store CSI Driver with Key Vault provider |
| Scale | Container Apps KEDA rule | HPA or KEDA |
| Telemetry | OpenTelemetry to Application Insights | Same app instrumentation plus Container Insights |
| Broker authentication | Container Apps Easy Auth plus principal validation | Entra-aware ingress/proxy plus exact principal validation |

Only frontend is public. Checkout, payment, and any cluster management endpoints
remain private.

## Preserve the scenario profiles

An AKS implementation must retain the same immutable `scenario` contract:

| Scenario | Agent and remediation | Network and runner |
| --- | --- | --- |
| A | High / Contributor / Autonomous; direct AKS remediation; no write connector or broker | Public authenticated control endpoints; GitHub-hosted or local deployment |
| B | Low / Reader / Review; built-in GitHub MCP writes the remediation Pull Request; no broker | Public authenticated control endpoints; GitHub-hosted deployment |
| C | Low / Reader / Review; read-only Code Access and human-triggered remediation PR | Private registry, vault, state, and cluster API paths; labeled private runner |

State-account naming and blob keys must include the scenario. Never convert one
scenario's AKS state in place. Deploy a new isolated profile, validate it, then
destroy the previous state explicitly.

## Incident mapping

The application images and `ENABLE_SLOW_LEAK` behavior are reusable, but the
current trigger scripts call Azure Container Apps APIs and therefore need AKS
counterparts.

- **Scenario A trigger:** patch the payment Deployment's feature-flag environment
  value and roll a new ReplicaSet.
- **Scenario B/C trigger:** merge the same
  `infra/leak.auto.tfvars` Pull Request, with AKS Terraform translating it into
  the Deployment environment value.
- **Restart mitigation:** `kubectl rollout restart
  deployment/payment-service`.
- **Scale mitigation:** raise HPA/KEDA capacity.
- **Durable fix:** set the GitOps flag to `false` and roll a healthy Deployment.

The Azure Monitor alert would use Container Insights or managed Prometheus memory
telemetry for the `payment-service` workload rather than the Container Apps
`WorkingSetBytes` metric.

## Scenario C broker on AKS

Preserve the same security model:

- two separate GitHub Apps;
- no PAT for writes;
- remediation App private key imported as a non-exportable, sign-only Key Vault
  RSA key;
- broker workload identity has only key metadata read and sign data actions;
- broker calls Key Vault cryptography and never downloads the key;
- Entra authentication and exact SRE Agent principal validation;
- only the fixed remediation issue and status tools;
- Scenario C-only issue-to-Pull Request workflow.

The broker path remains disabled until remote Streamable-HTTP MCP documents the
required managed-identity authentication. Do not expose the broker, Kubernetes
API, checkout, or payment services to work around that limitation.

## Security requirements

- Terraform only for infrastructure.
- GitHub Actions OIDC only; no stored Azure credentials.
- Full commit-SHA publication tags, locked in ACR and deployed by manifest digest.
- Workload identity and least-privilege RBAC.
- Key Vault RBAC and purge protection.
- ACR admin and anonymous access disabled.
- TLS for every ingress.
- Private cluster and data-plane endpoints for Scenario C.
- No committed PAT, PEM, kubeconfig, subscription ID, or tenant ID.

## References

- [Microsoft Entra Workload ID on AKS](https://learn.microsoft.com/azure/aks/workload-identity-overview)
- [Secrets Store CSI Driver for AKS](https://learn.microsoft.com/azure/aks/csi-secrets-store-driver)
- [Azure Monitor Container Insights](https://learn.microsoft.com/azure/azure-monitor/containers/container-insights-overview)
- [Azure SRE Agent network integration](https://learn.microsoft.com/azure/sre-agent/network-integration)
- [GitHub App permissions](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app)
