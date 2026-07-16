# ContosoPay — Azure SRE Agent Demo (cloud-native)

A self-contained, reproducible demo that showcases the **Azure SRE Agent** on a realistic
cloud-native checkout app running on **Azure Container Apps**, with GitHub Actions CI/CD (OIDC),
Application Insights telemetry, Azure Monitor alerting, and Azure Managed Grafana.

The app (**ContosoPay**) is three tiny Node.js/TypeScript microservices. `payment-service`
contains a **feature-flagged, recoverable memory leak** so the SRE Agent has a real incident to
detect, correlate to a GitHub change, explain, and remediate. The demo ships in **three scenarios**:
autonomous direct remediation, public-endpoint GitOps, and private-network enterprise GitOps
(see [Demo scenarios](#demo-scenarios)).

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
   Key Vault (RBAC, Private Link) · App Insights + Log Analytics
   Premium ACR (Private Link, admin disabled)
                      ▼
   Azure Monitor alert ──► (SRE Agent scanner polls the Alerts API every ~1 min)
   Azure Managed Grafana ──► dashboards over App Insights / Log Analytics

   Optional hardening ──► remediation MCP broker (public ACA)
                              │ GitHub App installation token
                              ▼
                       fixed remediation issue

   GitHub PR ──merge──► self-hosted runner VNet
                              │ global VNet peering
                              ▼
                       regional application VNet
                              │ OIDC + private endpoints
                              ▼
                       Terraform / ACR / Key Vault
```

By default only **frontend** is publicly reachable. When the optional
remediation broker is enabled, it is the sole exception: its HTTPS endpoint must
be reachable by the managed Azure SRE Agent, but Container Apps authentication
rejects callers without the dedicated Entra audience and the broker allows only
the exact agent managed identity. Application services remain internal. In the
CI/CD path shown above, Terraform state is reached through a private endpoint in
the runner VNet; Key Vault and ACR private endpoints live in the application
VNet and are reachable over global VNet peering. Terraform state remains in an
**LRS storage account** bootstrapped by the deploy workflow.

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/) (`az login`, contributor on the target sub)
- [Terraform](https://developer.hashicorp.com/terraform) >= 1.9
- [Docker](https://www.docker.com/) (daemon running — builds the app images and optional broker)
- A Bash shell (Linux/macOS/WSL/Git Bash) **or** PowerShell 7+ on Windows
- For GitHub CI/CD: a Linux self-hosted runner with the labels `azure-private` and `contosopay`,
  attached to the VNet configured by the runner networking Terraform variables.

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
Azure SRE Agent. This local script is the path used by **Scenario A**.

> **Prefer full CI/CD?** **Scenarios B and C** deploy the same environment
> entirely through GitHub Actions (the **deploy** workflow) with no local
> Terraform or Docker. Start with [`docs/scenario-b-gitops.md`](docs/scenario-b-gitops.md)
> for the public PAT demo or [`docs/scenario-c-private-gitops.md`](docs/scenario-c-private-gitops.md)
> for the private-network enterprise path.

### Tear down

```bash
./scripts/teardown.sh      # terraform destroy -auto-approve
```

## Demo scenarios

The same environment runs **three demo experiences**. Pick one per run — they
only differ in agent autonomy, GitOps guardrails, and network posture.

| | **Scenario A — Autonomous** | **Scenario B — Public GitOps** | **Scenario C — Private GitOps** |
|---|---|---|---|
| **Trigger** | Script pokes the live app | Pull Request + CI deploys the change | Pull Request + CI deploys the change |
| **Command** | `scripts/trigger-incident-direct.*` | `scripts/trigger-incident-gitops.*` | `scripts/trigger-incident-gitops.*` |
| **Agent Azure access** | **Privileged** (read/write) | **Reader** (read-only) | **Reader** (read-only) |
| **GitHub auth** | Code Access context | Short-lived fine-grained PAT via GitHub MCP | BYO GitHub App with Key Vault key URI |
| **Network posture** | Default public control paths | Public GitHub/SRE connector paths | SRE Agent Azure VNet mode + private Key Vault |
| **Remediation** | Agent fixes Azure directly after approval | Agent opens a remediation PR; a human merges it | Agent opens a remediation PR; a human merges it |
| **Best for** | A fast, self-contained "watch it fix" moment | GitOps guardrails with minimal setup | Enterprise private-network setup |
| **Full A-to-Z guide** | [`docs/scenario-a-direct.md`](docs/scenario-a-direct.md) | [`docs/scenario-b-gitops.md`](docs/scenario-b-gitops.md) | [`docs/scenario-c-private-gitops.md`](docs/scenario-c-private-gitops.md) |

New here? Start with [`docs/run-of-show.md`](docs/run-of-show.md) — it explains the
demo and points you to the right scenario guide. Each scenario guide is a complete,
self-contained walkthrough (deploy → create and connect the agent → run the
incident → reset). [`docs/sre-agent-setup.md`](docs/sre-agent-setup.md) is the
agent reference the guides link to for background and troubleshooting.

### Scenario A — trigger on the spot

```bash
./scripts/trigger-incident-direct.sh        # az containerapp update — flips ENABLE_SLOW_LEAK on the live app
# or: pwsh ./scripts/trigger-incident-direct.ps1
```

Memory in `payment-service` climbs for roughly 8–12 minutes, the Azure Monitor alert fires, and the
SRE Agent (granted **Privileged** access) proposes a direct mitigation you approve in the agent UI.

### Scenario B/C — trigger via a Pull Request (GitOps)

When you stand up the environment with the **`deploy` GitHub Actions workflow**, it
**auto-opens the incident PR** (setting `enable_slow_leak=true`) at the end of the run — it waits
in the **Pull requests** tab, ready to merge. To open one manually (or after a reset), run:

```bash
./scripts/trigger-incident-gitops.sh        # opens a PR setting enable_slow_leak=true in infra/leak.auto.tfvars
# or: pwsh ./scripts/trigger-incident-gitops.ps1
```

The deploy workflow (or the script) opens a **Pull Request** flipping the planted-fault flag.
**Merging it** runs the
`apply-infra` GitHub Actions workflow, which `terraform apply`s the change (remote state) and
deploys the leak — no one edits the live app by hand. **Remediation is GitOps
too:** the agent is limited to **Reader-level workload access**, with a required
global Tool Access Policy that denies direct mutation tools. Scenario B uses a
short-lived PAT GitHub MCP connector for demo speed; Scenario C uses SRE Agent
Azure VNet mode and BYO GitHub App credentials backed by a Key Vault key. A
human merges the remediation PR, CI redeploys, and memory recovers. See
[`agent/`](agent/) for the committable agent config.

## Repository layout

| Path | Purpose |
|------|---------|
| `infra/` | All Terraform (`azurerm`) — RG, identities, private networking, ACR, Key Vault, observability, ACA, alerts, Grafana |
| `infra/agents.tf` | **Optional** SRE Agents (`azapi`, autonomous=High / GitOps=Reader) — off unless `enable_sre_agents=true` |
| `infra/leak.auto.tfvars` | **GitOps source of truth** for the planted-leak flag (committed, non-secret) |
| `src/frontend` | Public SPA + Node server |
| `src/checkout-api` | Internal API (orders) |
| `src/payment-service` | Internal API with the planted, flag-gated memory leak |
| `src/sre-remediation-mcp` | Optional Entra-protected two-tool remediation broker; GitHub App key is read from Key Vault via managed identity |
| `scripts/` | `deploy`, `teardown`, `trigger-incident-direct` (Scenario A), `trigger-incident-gitops` (Scenarios B/C) |
| `agent/` | Committable SRE Agent GitOps config (tool-access policy, custom agent, runbook) |
| `docs/run-of-show.md` | Start here — what the demo is and which scenario guide to follow |
| `docs/scenario-a-direct.md` | Scenario A — complete A-to-Z autonomous troubleshooting guide |
| `docs/scenario-b-gitops.md` | Scenario B — public-endpoint GitOps guide with PAT shortcut |
| `docs/scenario-c-private-gitops.md` | Scenario C — enterprise GitOps guide with SRE Agent VNet integration |
| `docs/sre-agent-setup.md` | Azure SRE Agent reference (prerequisites, regions, permissions, troubleshooting) |
| `docs/aks-variant.md` | Optional AKS deployment notes |
| `.github/workflows/deploy.yml` | **Full environment deploy via CI/CD** (`workflow_dispatch`) — state bootstrap, platform, build/push, apps |
| `.github/workflows/deploy-apps.yml` | OIDC build + push + revision update (on `src/**`) |
| `.github/workflows/apply-infra.yml` | OIDC `terraform apply` on merge (deploys flag/IaC changes); computes remote-state backend automatically |
| `.github/workflows/sre-remediation-pr.yml` | Optional broker path: converts a trusted remediation issue into a one-file, unmerged PR |

## Security

- No secrets in source. All secrets live in **Azure Key Vault**; apps and the
  optional broker read them via **managed identity**. The GitHub App key never
  enters Terraform state. CI/CD uses **OIDC federation**, never stored credentials.
- ACR admin user disabled · private endpoints for state, ACR, and Key Vault · Key Vault RBAC +
  purge protection · TLS-only ingress · least-privilege role assignments · diagnostic settings to
  Log Analytics.

## Connecting the Azure SRE Agent

The SRE Agent is a **managed service** configured at <https://sre.azure.com>.
By default you create it in the portal; `infra/agents.tf` can optionally provision
the agent resource and Azure RBAC when `enable_sre_agents = true`. Pick a scenario
and follow its complete A-to-Z guide —
[`docs/scenario-a-direct.md`](docs/scenario-a-direct.md) (autonomous),
[`docs/scenario-b-gitops.md`](docs/scenario-b-gitops.md) (public GitOps), or
[`docs/scenario-c-private-gitops.md`](docs/scenario-c-private-gitops.md)
(private-network GitOps). Each guide covers deploying
the app, creating and connecting the agent, running the incident, and resetting.
[`docs/sre-agent-setup.md`](docs/sre-agent-setup.md) is the agent reference (prerequisites,
regions/models, permissions, troubleshooting). The committable GitOps agent config
(deny-Azure-writes policy, GitOps custom agent, runbook) lives in [`agent/`](agent/).
