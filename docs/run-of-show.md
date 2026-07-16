# ContosoPay & Azure SRE Agent — Start Here

Welcome. This repository deploys a small, realistic cloud-native application
(**ContosoPay**) and shows how the **Azure SRE Agent** detects a production
incident, explains its root cause, and helps you remediate it.

This page tells you **what the demo is** and **which guide to follow**. You only
need to read one scenario guide end to end — each is a complete A‑to‑Z setup.

---

## What you are deploying

ContosoPay is a checkout application made of three small services running on
**Azure Container Apps**:

- **frontend** — the public web page where a customer places an order. This is
  the only public application service.
- **checkout-api** — receives the order from the frontend. Internal only.
- **payment-service** — processes the payment. Internal only. This service
  contains a **deliberately planted, switchable fault**: a slow memory leak that
  is turned off by default and can be switched on for the demo.

Supporting Azure services are deployed automatically: a container registry,
Key Vault for secrets, Application Insights and Log Analytics for telemetry, an
Azure Monitor alert that watches the payment service's memory, and (optionally)
an Azure Managed Grafana dashboard.

Everything is built with Terraform. No secrets are stored in the code; the
application reads its secrets from Key Vault using a managed identity.

The demo now has three modes. They use the same ContosoPay app and planted fault,
but tell different security and operations stories:

1. **Scenario A — Autonomous troubleshooting:** privileged agent, direct Azure
   remediation after approval. Best for the "wow" moment.
2. **Scenario B — Guarded GitOps with PAT and public endpoints:** Reader-level
   agent, tool policy guardrails, short-lived PAT GitHub MCP connector, and PR
   remediation. Best for a quick GitOps demo.
3. **Scenario C — Private-network GitOps:** Reader-level agent, SRE Agent Azure
   VNet integration, private Key Vault, BYO GitHub App key URI, and PR
   remediation. Best for enterprise/security audiences.

---

## What the demo shows

When you switch the planted fault on, the payment service's memory climbs
predictably for roughly 8–12 minutes until its five-minute average crosses the
threshold and an **Azure Monitor alert fires**. The averaging window filters
ordinary transient spikes. Each leaking revision calibrates its allocation rate
from its startup memory, keeping the timing stable across normal image and
dependency changes. The Azure SRE Agent picks up that alert, investigates the
telemetry, connects the memory growth to the change that caused it, and proposes
a fix. You stay in control: the agent only acts after a human approves.

---

## Choose your scenario

The demo runs in **three scenarios**. Pick the one that fits your audience and
follow that guide from top to bottom.

| | **Scenario A — Autonomous troubleshooting** | **Scenario B — Public GitOps** | **Scenario C — Private-network GitOps** |
| --- | --- | --- | --- |
| **How the incident starts** | You run a small script that switches the fault on directly on the running service. | The incident Pull Request is pre-opened by the deploy workflow; you merge it and CI/CD deploys the change. | Same GitOps incident Pull Request as Scenario B. |
| **How it is deployed** | One command from your machine (`scripts/deploy.*`). | Entirely through GitHub Actions. | Same GitHub Actions baseline as Scenario B, plus SRE Agent Azure VNet mode. |
| **GitHub auth** | Code Access sign-in for context. | Short-lived fine-grained PAT in the GitHub MCP connector. | BYO GitHub App with private key imported as a Key Vault key. |
| **Network posture** | Default/public control-plane paths. | Public GitHub/SRE connector paths for demo speed. | Dedicated delegated SRE Agent subnet and private Key Vault access. |
| **What the agent may do** | Privileged resource access; direct Azure fix after approval. | Reader workload access; opens a remediation Pull Request. | Reader workload access; opens a remediation Pull Request through enterprise network controls. |
| **Best for** | A fast, self-contained "watch the agent fix it" story. | A practical GitOps and guardrails story with minimal setup. | A regulated enterprise story with private networking and stronger identity controls. |
| **Follow this guide** | [`scenario-a-direct.md`](scenario-a-direct.md) | [`scenario-b-gitops.md`](scenario-b-gitops.md) | [`scenario-c-private-gitops.md`](scenario-c-private-gitops.md) |

All guides include everything you need: deploying the app, creating and
connecting the SRE Agent, switching the fault on, watching the agent work, and
resetting afterwards.

> **Tip:** switch the fault on, then use the next few minutes to walk through the
> architecture and alert design before the agent begins its investigation.

---

## Reference material

- [`sre-agent-setup.md`](sre-agent-setup.md) — a deeper reference on the Azure
  SRE Agent: prerequisites, regions and models, permissions, and troubleshooting.
  The scenario guides link to it where relevant; you do not need to read it
  separately first.
- [`aks-variant.md`](aks-variant.md) — optional notes for running the same demo
  on Azure Kubernetes Service instead of Azure Container Apps.
