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
  the only service reachable from the internet.
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

---

## What the demo shows

When you switch the planted fault on, the payment service's memory slowly climbs
over roughly 30–40 minutes until it crosses a threshold and an **Azure Monitor
alert fires**. The Azure SRE Agent picks up that alert, investigates the
telemetry, connects the memory growth to the change that caused it, and proposes
a fix. You stay in control: the agent only acts after a human approves.

---

## Choose your scenario

The demo runs in **two scenarios**. They use the same application and the same
planted fault; they differ in **how the fault is switched on** and **how the
agent is allowed to fix it**. Pick the one that fits your audience and follow
that guide from top to bottom.

| | **Scenario A — On-the-spot fix** | **Scenario B — GitOps fix** |
| --- | --- | --- |
| **How the incident starts** | You run a small script that switches the fault on directly on the running service. | You open a **Pull Request** that switches the fault on; merging it deploys the change through CI/CD. |
| **How it is deployed** | One command from your machine (`scripts/deploy.*`). | Entirely through **GitHub Actions** — no local Terraform or Docker. |
| **What the agent may do** | The agent has **write access** to the demo resources and **fixes them directly** after you approve. | The agent is **read-only** on Azure and fixes the incident by **opening a Pull Request** that a person reviews and merges. |
| **Best for** | A fast, self-contained "watch the agent fix it" story. | A realistic DevOps / change-management story where every change ships as reviewed code. |
| **Follow this guide** | [`scenario-a-direct.md`](scenario-a-direct.md) | [`scenario-b-gitops.md`](scenario-b-gitops.md) |

Both guides include everything you need: deploying the app, creating and
connecting the SRE Agent, switching the fault on, watching the agent work, and
resetting afterwards.

> **Tip:** the memory leak builds gradually. Switch the fault on, then take a
> short break or walk through the architecture while the alert builds. Come back
> after the alert has fired to watch the agent investigate and remediate.

---

## Reference material

- [`sre-agent-setup.md`](sre-agent-setup.md) — a deeper reference on the Azure
  SRE Agent: prerequisites, regions and models, permissions, and troubleshooting.
  The scenario guides link to it where relevant; you do not need to read it
  separately first.
- [`aks-variant.md`](aks-variant.md) — optional notes for running the same demo
  on Azure Kubernetes Service instead of Azure Container Apps.
