# ContosoPay — an Azure SRE Agent demo

A small, reproducible checkout application with a deliberately planted fault,
built so you can show what the **Azure SRE Agent** actually does when something
breaks in production — and, just as importantly, what it is *not allowed* to do.

**New here? Read this page top to bottom.** It covers what the agent is, what
gets deployed, what you need, what it costs, and how to choose a scenario. Then
pick one walkthrough and follow it start to finish. You will not need any other
document to run the demo.

---

## What the Azure SRE Agent is

The Azure SRE Agent is a managed Azure service that watches your resources,
receives incidents from Azure Monitor, and investigates them on its own. It
reads telemetry, correlates it with the deployments and code changes that could
explain it, and produces a root-cause hypothesis in plain language.

What it does *next* depends entirely on how you configure it:

- **Autonomous mode with write permissions** — it can act on Azure directly.
- **Review mode with Reader only** — it cannot touch Azure at all. It proposes
  the fix as a pull request and waits for a human.

That configuration choice is the entire point of this demo. The three scenarios
below are the same incident, resolved through three different boundaries.

---

## What gets deployed

Three Node.js/TypeScript services on Azure Container Apps:

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

## How the demo runs

You deploy a healthy environment. You flip a feature flag that makes
`payment-service` leak memory. Roughly 8–12 minutes later an Azure Monitor alert
fires. The SRE Agent investigates on its own — correlating the memory trend, the
running revision, the feature flag, and the change that introduced it — explains
what it found, and proposes a fix. What happens next is what the scenarios
differ on.

Every scenario shares the same five acts:

1. Establish a healthy baseline.
2. Arm the fault.
3. Wait 8–12 minutes while memory climbs and the alert fires.
4. Let the agent investigate and explain.
5. Remediate through that scenario's boundary, then verify recovery.

---

## What you need before you start

Confirm all of these. Missing any one will stop you mid-demo.

| Requirement | Notes |
| --- | --- |
| An Azure subscription where you can create resources **and role assignments** | Owner or User Access Administrator on the target scope |
| The Azure SRE Agent available in your tenant and region | It is in preview; check availability before scheduling a demo |
| A GitHub repository you administer | You will set Actions variables and run workflows |
| A GitHub OIDC deployment identity federated to that repository | Setup is in the [deployment reference](docs/deployment-reference.md#github-actions-oidc) |
| Azure CLI, Terraform 1.9+, and Bash or PowerShell locally | Only needed for the incident trigger and a few checks |

**Scenario C additionally needs** a self-hosted GitHub Actions runner inside the
virtual network, and a GitHub App you create and later revoke. Budget an extra
hour for those. Its walkthrough covers both.

> **Being subscription Owner is not enough to open the agent's own UI.** The SRE
> Agent has a separate data-plane role. Every walkthrough grants it in its setup
> phase — do not skip that step.

---

## What it costs

The environment bills while it exists. **Tear it down when you are finished** —
every walkthrough ends with a teardown phase.

Retail list prices, Sweden Central, USD, from the Azure Retail Prices API:

| Component | Price | Applies to |
| --- | --- | --- |
| Container Registry, Standard | $0.67 / day | Scenarios A and B |
| Container Registry, Premium | $1.67 / day | Scenario C — private endpoints require Premium |
| Managed Grafana, Standard node | $0.043 / hour (~$1.03 / day) | All, **on by default** |
| Managed Grafana, per active user | $6 / month | All, if Grafana is enabled |
| Log Analytics ingestion | $2.99 / GB | All |
| Container Apps | Consumption metering | All — `payment-service` holds one replica, so it never scales to zero |
| Private endpoints | Hourly, plus data processed | Scenario C only (two) |

As a rough order of magnitude that lands around **$3–5 per day for A or B** and
**$5–8 per day for C**, excluding your self-hosted runner and any charges for
the SRE Agent itself. Check current SRE Agent pricing separately — it is in
preview and not included above. Your negotiated rates and region will differ.

> **Grafana is the easiest saving.** `enable_grafana` defaults to `true` and is
> the largest fixed line item after the registry. If you are not showing
> dashboards, set it to `false` and drop roughly a third of the daily cost.

---

## Choose your scenario

All three use the same application, the same fault, and the same alert. They
differ in **how much the agent is allowed to do, and through which path**.

For most audiences the real choice is between two of them:

### [Scenario A — the agent fixes it](docs/scenario-a-direct.md)

*Show capability.* ~35 min prep, ~20 min live.

The agent holds Contributor on one resource group and remediates Azure
**directly** after you approve. Shortest setup and the most dramatic moment.
Use it when the question in the room is *"can it actually do anything?"*

### [Scenario C — the agent proposes, a human approves, inside your network](docs/scenario-c-private-gitops.md)

*Show governance.* ~100 min prep, ~25 min live.

The agent holds only **Reader**. Asked to restart the service, it refuses —
because Azure RBAC will not let it. Instead it opens a pull request containing
one line of change, which a human reviews and merges through the existing
pipeline. Everything runs against private endpoints on a self-hosted runner,
and the agent's entire configuration is declared in a committed manifest and
verified on every deploy.

Use it when the question is *"how do we let this near production?"* — regulated
industries, security architects, change-management audiences.

### [Scenario B — Scenario C without the network work](docs/scenario-b-gitops.md)

*A lighter-weight variant.* ~45 min prep, ~25 min live.

B tells the **same story as C** — Reader only, refuses to act, opens the pull
request — but over public endpoints, a GitHub-hosted runner, and Code Access
signed in with your own account instead of a GitHub App. It is 55 minutes
cheaper to set up and leaves **no credential to revoke** afterwards.

Choose it over C when you cannot provision a self-hosted runner in the tenant,
or when the audience cares about change management but not about private
networking. If you can afford C's setup, prefer C — it is the stronger version
of the same demo.

### Side by side

| | Scenario A | Scenario B | Scenario C |
| --- | --- | --- | --- |
| Story | Autonomous direct recovery | Enterprise GitOps | Private-network enterprise GitOps |
| Agent profile | High / Contributor / Autonomous | Low / Reader / Review | Low / Reader / Review |
| Control endpoints | Public | Public, RBAC and TLS protected | Private state, ACR, and Key Vault |
| Deployment runner | GitHub-hosted or local wrapper | GitHub-hosted or local wrapper | Private self-hosted runner |
| Code context | Code Access | Code Access, signed in with your account (OAuth) | Code Access via a bring-your-own GitHub App |
| Write path | Direct Azure action | Agent-authored remediation pull request | Agent-authored remediation pull request |
| Agent configuration | Portal | Portal | Terraform plus an idempotent REST reconciler |
| Credential to revoke afterwards | None | None | The GitHub App key |

### Two things worth understanding before you pick

**Code Access is the GitHub write path, not just a read path.** It indexes and
correlates source, and it is also the surface through which B and C open their
remediation pull requests — the agent creates the branch, commits, and raises
the PR itself. Neither needs a separate write connector or a token. Scenario A
has no GitHub write path at all.

**The guarantee is Azure RBAC, not a missing GitHub credential.** In B and C the
agent holds Reader and the tool policy denies Azure writes, so it physically
cannot mutate production. Being able to open a pull request does not weaken
that: a human still reviews and merges, and `apply-infra.yml` performs the
actual change.

> **What is verified.** The full incident-to-pull-request loop is verified end to
> end in Scenario C. An Azure Monitor Sev2 alert opened the thread, and the agent
> investigated, identified `enable_slow_leak`, and opened the remediation pull
> request **unprompted** — no human message in the thread until eleven minutes
> after the PR existed. Merging it ran `apply-infra`, and `payment-service`
> memory fell from 1,033 MB to 125 MB on the new revision.
>
> Scenario B is verified when **prompted interactively** over OAuth-based Code
> Access. Its alert-triggered path is not separately verified, though B and C run
> the same response plan and write path.
>
> Code Access writes through the terminal, so the global tool policy must
> **allow** `RunInTerminal`. Denying it silently removes the agent's only write
> path. Azure remains protected by Reader RBAC and by command-level `bash(...)`
> deny patterns — verified live in the same session.

---

## One scenario at a time

Terraform takes a single `scenario` value (`A`, `B`, or `C`) and derives the
entire profile — networking, agent permissions, runner, and remediation path —
from it. Resource names, the state storage account, and the state blob key all
include the scenario, so each profile is fully isolated.

**In-place conversion between scenarios is unsupported** and is rejected by
every deployment path. To switch: destroy the active profile, delete the
`DEPLOYMENT_SCENARIO`, `TF_PREFIX`, and `TF_ENVIRONMENT` repository variables,
and only then deploy the next one. Each walkthrough covers this, and the
[deployment reference](docs/deployment-reference.md#profile-and-state-safety)
has the detail.

---

## Security posture

This repository is public and contains no secrets. Every scenario holds the same
invariants: OIDC-only CI/CD, Key Vault with RBAC and purge protection, ACR with
admin and anonymous access disabled, managed identities for all application
access, TLS-only ingress, and least-privilege resource-scoped role assignments.
`checkout-api` and `payment-service` are never public.

Full list in the
[deployment reference](docs/deployment-reference.md#security-invariants).

---

## Documentation

The three walkthroughs are self-contained. The rest is reference — consult it
when something breaks, not to run the demo.

| Document | What it is for |
| --- | --- |
| [Scenario A walkthrough](docs/scenario-a-direct.md) | Step-by-step, start to teardown |
| [Scenario B walkthrough](docs/scenario-b-gitops.md) | Step-by-step, start to teardown |
| [Scenario C walkthrough](docs/scenario-c-private-gitops.md) | Step-by-step, start to teardown |
| [Deployment and state reference](docs/deployment-reference.md) | OIDC setup, activation markers, state isolation, teardown, security invariants, repository map |
| [SRE Agent setup reference](docs/sre-agent-setup.md) | Background on the shared agent model across all three scenarios |
| [AKS variant](docs/aks-variant.md) | Notes for a Kubernetes-native deployment |

External: [SRE Agent run modes](https://learn.microsoft.com/azure/sre-agent/run-modes)
· [SRE Agent permissions](https://learn.microsoft.com/azure/sre-agent/permissions)
