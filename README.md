# ContosoPay — Azure SRE Agent Demo (cloud-native)

A self-contained, reproducible demo that showcases the **Azure SRE Agent** on a realistic
cloud-native checkout app running on **Azure Container Apps**, with GitHub Actions CI/CD (OIDC),
Application Insights telemetry, Azure Monitor alerting, and Azure Managed Grafana.

The app (**ContosoPay**) is three tiny Node.js/TypeScript microservices. `payment-service`
contains a **feature-flagged, recoverable memory leak** so the SRE Agent has a real incident to
detect, correlate to a GitHub commit, explain, and mitigate — only after human approval.

> Built per [`.github/copilot-instructions.md`](.github/copilot-instructions.md). Terraform-only
> IaC, no secrets in source, managed identity + Key Vault + OIDC throughout.

## Architecture

```
Internet ──TLS──► frontend (public, ACA external ingress)
                      │ internal ingress only
                      ▼
                 checkout-api (internal) ──► payment-service (internal, planted leak)
                      │                          │
          Managed Identity (user-assigned) per app
                      ▼
   Key Vault (RBAC) · App Insights + Log Analytics · ACR (admin disabled)
                      ▼
   Azure Monitor alert ──► Action Group ──► (Azure SRE Agent, onboarded separately)
   Azure Managed Grafana ──► dashboards over App Insights / Log Analytics
```

Only **frontend** is publicly reachable. Everything else uses internal ingress.

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/) (`az login`, contributor on the target sub)
- [Terraform](https://developer.hashicorp.com/terraform) >= 1.9
- [Docker](https://www.docker.com/) (daemon running — builds the three images)
- A Bash shell (Linux/macOS/WSL/Git Bash) **or** PowerShell 7+ on Windows

## Quick start

```bash
# 1. Configure variables (no secrets — placeholders only)
cp terraform.tfvars.example terraform.tfvars   # then edit prefix/location if you like

# 2. Single-command deploy: terraform + build/push images + wire revisions
./scripts/deploy.sh        # bash
# or
pwsh ./scripts/deploy.ps1  # PowerShell
```

The script prints the public **frontend URL** and a "next steps" block for connecting the
Azure SRE Agent.

### Tear down

```bash
./scripts/teardown.sh      # terraform destroy -auto-approve
```

## Triggering the demo incident

```bash
./scripts/trigger-incident.sh   # commits the ENABLE_SLOW_LEAK flag flip and redeploys
```

Memory in `payment-service` climbs over ~30–40 minutes, the Azure Monitor alert fires, and the
SRE Agent can correlate the trend back to the triggering commit. A revision restart or a scale-rule
bump both mitigate it — the two mitigations the agent proposes.

## Repository layout

| Path | Purpose |
|------|---------|
| `infra/` | All Terraform (`azurerm`) — RG, identities, ACR, Key Vault, observability, ACA, alerts, Grafana |
| `src/frontend` | Public SPA + Node server |
| `src/checkout-api` | Internal API (orders) |
| `src/payment-service` | Internal API with the planted, flag-gated memory leak |
| `scripts/` | `deploy`, `teardown`, `trigger-incident` |
| `docs/run-of-show.md` | Live demo talk track + SRE Agent wiring steps |
| `docs/aks-variant.md` | Optional AKS deployment notes |
| `.github/workflows/deploy-apps.yml` | OIDC build + push + revision update |

## Security

- No secrets in source. All secrets live in **Azure Key Vault**; apps read them via **managed
  identity**. CI/CD uses **OIDC federation**, never stored credentials.
- ACR admin user disabled · Key Vault RBAC + purge protection · TLS-only ingress · least-privilege
  role assignments · diagnostic settings to Log Analytics.

## Connecting the Azure SRE Agent

The SRE Agent is a **managed service provisioned separately** at <https://sre.azure.com> — it is not
part of this Terraform. See [`docs/run-of-show.md`](docs/run-of-show.md) for the exact onboarding and
wiring steps (point it at the resource group, the GitHub repo, and the Action Group).
