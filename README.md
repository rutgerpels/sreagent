# ContosoPay — Azure SRE Agent Demo (cloud-native)

A self-contained, reproducible demo that showcases the **Azure SRE Agent** on a realistic
cloud-native checkout app running on **Azure Container Apps**, with GitHub Actions CI/CD (OIDC),
Application Insights telemetry, Azure Monitor alerting, and Azure Managed Grafana.

The app (**ContosoPay**) is three tiny Node.js/TypeScript microservices. `payment-service`
contains a **feature-flagged, recoverable memory leak** so the SRE Agent has a real incident to
detect, correlate to a GitHub change, explain, and remediate. The demo ships in **two scenarios** —
a fast "agent fixes it on the spot" version and a realistic "agent fixes it via a Pull Request"
GitOps version (see [Demo scenarios](#demo-scenarios)).

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

## Demo scenarios

The same environment runs **two interchangeable demo experiences**. Pick one per run —
they only differ in how the incident is triggered and how the agent remediates.

| | **Scenario A — On-the-spot** | **Scenario B — Full GitOps** |
|---|---|---|
| **Trigger** | Script pokes the live app | **Pull Request + CI** deploys the change |
| **Command** | `scripts/trigger-incident-direct.*` | `scripts/trigger-incident-gitops.*` |
| **Agent Azure access** | **Privileged** (read/write) | **Reader** (read-only) |
| **Remediation** | Agent **fixes Azure directly** after you approve | Agent **opens a remediation PR**; a human merges it |
| **Best for** | A fast, self-contained "watch it fix" moment | The realistic DevOps / change-management story |
| **Run-of-show + setup** | [`docs/scenario-a-direct.md`](docs/scenario-a-direct.md) | [`docs/scenario-b-gitops.md`](docs/scenario-b-gitops.md) |

Common, scenario-independent agent setup is in
[`docs/sre-agent-setup.md`](docs/sre-agent-setup.md) §1–§5;
[`docs/run-of-show.md`](docs/run-of-show.md) is the one-page chooser.

### Scenario A — trigger on the spot

```bash
./scripts/trigger-incident-direct.sh        # az containerapp update — flips ENABLE_SLOW_LEAK on the live app
# or: pwsh ./scripts/trigger-incident-direct.ps1
```

Memory in `payment-service` climbs over ~30–40 minutes, the Azure Monitor alert fires, and the
SRE Agent (granted **Privileged** access) proposes a direct mitigation you approve in the agent UI.

### Scenario B — trigger via a Pull Request (GitOps)

```bash
./scripts/trigger-incident-gitops.sh        # opens a PR setting enable_slow_leak=true in infra/leak.auto.tfvars
# or: pwsh ./scripts/trigger-incident-gitops.ps1
```

The script opens a **Pull Request** flipping the planted-fault flag. **Merging it** runs the
`apply-infra` GitHub Actions workflow, which `terraform apply`s the change (remote state) and
deploys the leak — no one edits the live app by hand. **Remediation is GitOps too:** the agent is
**read-only on Azure** (Reader RBAC + a global Tool Access Policy that denies Azure CLI writes), so
it fixes the incident by **opening a PR** that sets `enable_slow_leak=false`. A human merges it, CI
redeploys, memory recovers. See [`agent/`](agent/) for the committable agent config.

## Repository layout

| Path | Purpose |
|------|---------|
| `infra/` | All Terraform (`azurerm`) — RG, identities, ACR, Key Vault, observability, ACA, alerts, Grafana |
| `infra/leak.auto.tfvars` | **GitOps source of truth** for the planted-leak flag (committed, non-secret) |
| `src/frontend` | Public SPA + Node server |
| `src/checkout-api` | Internal API (orders) |
| `src/payment-service` | Internal API with the planted, flag-gated memory leak |
| `scripts/` | `deploy`, `teardown`, `trigger-incident-direct` (Scenario A), `trigger-incident-gitops` (Scenario B) |
| `agent/` | Committable SRE Agent **Scenario B** GitOps config (tool-access policy, custom agent, runbook) |
| `docs/run-of-show.md` | One-page scenario chooser |
| `docs/scenario-a-direct.md` | Scenario A — on-the-spot setup + run of show |
| `docs/scenario-b-gitops.md` | Scenario B — full GitOps setup + run of show |
| `docs/sre-agent-setup.md` | Common Azure SRE Agent setup manual (§1–§5) |
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
part of this Terraform. Do the common setup in [`docs/sre-agent-setup.md`](docs/sre-agent-setup.md)
(§1–§5: prerequisites, region/model, RBAC, GitHub Code Access, incident platform), then follow your
chosen scenario doc — [`docs/scenario-a-direct.md`](docs/scenario-a-direct.md) (on-the-spot) or
[`docs/scenario-b-gitops.md`](docs/scenario-b-gitops.md) (full GitOps). The committable Scenario B
agent config (deny-Azure-writes policy, GitOps custom agent, runbook) lives in [`agent/`](agent/).
