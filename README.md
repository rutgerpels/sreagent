# ContosoPay — an Azure SRE Agent demo

ContosoPay is a small, reproducible checkout application with a deliberately
planted fault, built so you can show what the **Azure SRE Agent** actually does
when something breaks in production.

Three Node.js/TypeScript services run on Azure Container Apps:

| Service | Exposure | Role |
| --- | --- | --- |
| `frontend` | Public HTTPS | The checkout page — the only public endpoint |
| `checkout-api` | Internal ingress only | Receives orders, calls payments |
| `payment-service` | Internal ingress only | Processes payments — and holds a feature-flagged, recoverable memory leak |

Around them: Azure Container Registry, Key Vault, Application Insights, Log
Analytics, Azure Monitor alerting, and optional Azure Managed Grafana. Terraform
owns every Azure resource. GitHub Actions authenticates with OpenID Connect —
there are no stored Azure credentials.

```text
Internet --TLS--> frontend (external ingress)
                     |
                     | internal HTTPS
                     v
                checkout-api ---> payment-service
                                      |
                                      | feature flag
                                      v
                               deterministic slow leak

Managed identities --> Key Vault (RBAC)
Managed identities --> ACR pull (admin disabled)
OpenTelemetry ------> Application Insights and Log Analytics
Azure Monitor ------> memory alert ------> Azure SRE Agent
```

---

## The demo in one paragraph

You deploy a healthy environment. You flip a feature flag that makes
`payment-service` leak memory. Roughly 8–12 minutes later an Azure Monitor alert
fires. The SRE Agent investigates on its own — correlating the memory trend, the
running revision, the feature flag, and the change that introduced it — explains
what it found, and proposes a fix. What happens next is the interesting part,
and it is what the three scenarios differ on.

---

## Pick a scenario

Each scenario uses the same application and the same fault. They differ in how
much the agent is allowed to do, and through which path.

### [Scenario A — the agent fixes it](docs/scenario-a-direct.md)

The agent holds Contributor on one resource group and remediates Azure
**directly** after you approve. Shortest setup, most dramatic moment. Use it to
show capability.

*~35 minutes preparation, ~20 minutes live.*

### [Scenario B — the agent opens a pull request](docs/scenario-b-gitops.md)

The agent holds only **Reader**. Asked to restart the service, it refuses.
Instead it opens a pull request containing exactly one line of change, which a
human reviews and merges through the existing pipeline. No GitHub secret is
created at any point. Use it for audiences with change management or audit
requirements.

*~45 minutes preparation, ~25 minutes live.*

### [Scenario C — the same, inside your network](docs/scenario-c-private-gitops.md)

Private endpoints for state, registry, and Key Vault; a self-hosted runner
inside your network; a bring-your-own GitHub App; and an agent whose entire
configuration is declared in a committed manifest and verified on every deploy.
The agent holds Reader on Azure, so it cannot mutate production; it opens the
remediation pull request instead, and a human merges it. Use it for regulated
industries and security architects.

*~100 minutes preparation, ~25 minutes live.*

**Not sure which?** Start with the [scenario chooser](docs/run-of-show.md) for a
side-by-side comparison.

---

## One scenario at a time

Terraform takes a single `scenario` value (`A`, `B`, or `C`) and derives the
entire profile — networking, agent permissions, runner, and remediation path —
from it. Resource names, the state storage account, and the state blob key all
include the scenario, so each profile is fully isolated.

**In-place conversion between scenarios is unsupported** and is rejected by
every deployment path. To switch, destroy the active profile first, delete the
`DEPLOYMENT_SCENARIO`, `TF_PREFIX`, and `TF_ENVIRONMENT` repository variables,
and then deploy the next one. Your scenario walkthrough covers this, and the
[deployment and state reference](docs/deployment-reference.md) has the detail.

---

## Documentation

| Document | What it is for |
| --- | --- |
| [Scenario chooser](docs/run-of-show.md) | Side-by-side comparison and how to pick |
| [Scenario A walkthrough](docs/scenario-a-direct.md) | Step-by-step, start to teardown |
| [Scenario B walkthrough](docs/scenario-b-gitops.md) | Step-by-step, start to teardown |
| [Scenario C walkthrough](docs/scenario-c-private-gitops.md) | Step-by-step, start to teardown |
| [Deployment and state reference](docs/deployment-reference.md) | OIDC setup, activation markers, state isolation, teardown, security invariants, repository map |
| [SRE Agent setup reference](docs/sre-agent-setup.md) | The shared agent model across all three scenarios |
| [AKS variant](docs/aks-variant.md) | Notes for a Kubernetes-native deployment |

---

## Security posture

This repository is public and contains no secrets. Every scenario holds the same
invariants: OIDC-only CI/CD, Key Vault with RBAC and purge protection, ACR with
admin and anonymous access disabled, managed identities for all application
access, TLS-only ingress, and least-privilege resource-scoped role assignments.
`checkout-api` and `payment-service` are never public.

Full list in the
[deployment and state reference](docs/deployment-reference.md#security-invariants).
