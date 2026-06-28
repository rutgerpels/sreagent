# ContosoPay — Azure SRE Agent Demo (cloud-native)

A self-contained, reproducible demo that showcases the **Azure SRE Agent** on a realistic
cloud-native checkout app running on **Azure Container Apps**, with GitHub Actions CI/CD (OIDC),
Application Insights telemetry, Azure Monitor alerting, and Azure Managed Grafana.

The app (**ContosoPay**) is three tiny Node.js/TypeScript microservices. `payment-service`
contains a **feature-flagged, recoverable memory leak** so the SRE Agent has a real incident to
detect, correlate to a GitHub change, explain, and remediate — **the GitOps way, by opening a Pull
Request** rather than touching the live Azure resources, deployed only after a human merges.

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
   Azure Monitor alert ──► (SRE Agent scanner polls the Alerts API every ~1 min)
   Azure Managed Grafana ──► dashboards over App Insights / Log Analytics

   GitHub PR ──merge──► apply-infra.yml (OIDC, terraform apply, remote state) ──► deploy
```

Only **frontend** is publicly reachable. Everything else uses internal ingress. Terraform state is
stored remotely in an **LRS storage account** (bootstrapped by the deploy script) so the
`apply-infra` CI workflow can apply changes the GitOps way.

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

## Triggering the demo incident (GitOps)

```bash
./scripts/trigger-incident.sh   # opens a PR setting enable_slow_leak=true in infra/leak.auto.tfvars
# or: pwsh ./scripts/trigger-incident.ps1
```

The script opens a **Pull Request** flipping the planted-fault flag. **Merging it** runs the
`apply-infra` GitHub Actions workflow, which `terraform apply`s the change (remote state) and
deploys the leak — no one edits the live app by hand. Memory in `payment-service` then climbs over
~30–40 minutes, the Azure Monitor alert fires, and the SRE Agent correlates the trend back to the
triggering PR.

**Remediation is GitOps too:** the agent is configured **read-only on Azure** (Reader RBAC + a
global Tool Access Policy that denies Azure CLI writes), so it fixes the incident by **opening a PR**
that sets `enable_slow_leak=false`. A human merges it, CI redeploys, memory recovers. See
[`agent/`](agent/) for the committable agent config and
[`docs/sre-agent-setup.md`](docs/sre-agent-setup.md) §6.

## Repository layout

| Path | Purpose |
|------|---------|
| `infra/` | All Terraform (`azurerm`) — RG, identities, ACR, Key Vault, observability, ACA, alerts, Grafana |
| `infra/leak.auto.tfvars` | **GitOps source of truth** for the planted-leak flag (committed, non-secret) |
| `src/frontend` | Public SPA + Node server |
| `src/checkout-api` | Internal API (orders) |
| `src/payment-service` | Internal API with the planted, flag-gated memory leak |
| `scripts/` | `deploy`, `teardown`, `trigger-incident` (opens a PR) |
| `agent/` | Committable SRE Agent GitOps config (tool-access policy, custom agent, runbook) |
| `docs/run-of-show.md` | Live demo talk track + SRE Agent wiring steps |
| `docs/sre-agent-setup.md` | Step-by-step Azure SRE Agent configuration manual |
| `docs/aks-variant.md` | Optional AKS deployment notes |
| `.github/workflows/deploy-apps.yml` | OIDC build + push + revision update (on `src/**`) |
| `.github/workflows/apply-infra.yml` | OIDC `terraform apply` on merge (deploys flag/IaC changes) |

## Security

- No secrets in source. All secrets live in **Azure Key Vault**; apps read them via **managed
  identity**. CI/CD uses **OIDC federation**, never stored credentials.
- ACR admin user disabled · Key Vault RBAC + purge protection · TLS-only ingress · least-privilege
  role assignments · diagnostic settings to Log Analytics.

## Connecting the Azure SRE Agent

The SRE Agent is a **managed service provisioned separately** at <https://sre.azure.com> — it is not
part of this Terraform. See [`docs/sre-agent-setup.md`](docs/sre-agent-setup.md) for the full
step-by-step configuration manual (prerequisites, region/model choice, RBAC, GitHub Code Access +
Connector, incident platform, and the **GitOps enforcement** in §6), or
[`docs/run-of-show.md`](docs/run-of-show.md) for the condensed live-demo version. The committable
agent config (deny-Azure-writes policy, GitOps custom agent, runbook) lives in [`agent/`](agent/).
