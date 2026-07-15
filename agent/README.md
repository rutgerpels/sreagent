# Azure SRE Agent — GitOps remediation config (Scenario B)

These are the **committable artifacts** that turn the demo's SRE Agent into a
GitOps-only operator: it investigates, opens a constrained GitHub issue, and
lets the repository workflow **propose a fix as a Pull Request**, but is
**structurally unable to modify the live Azure resources**.

> These artifacts are used **only in Scenario B (Full GitOps)**. Scenario A
> (on-the-spot, direct remediation) does **not** use them — see
> [`../docs/scenario-a-direct.md`](../docs/scenario-a-direct.md).

Apply them once, after the agent is created and connected (see
[`../docs/scenario-b-gitops.md`](../docs/scenario-b-gitops.md) §B2–§B5).

| File | What it is | Where it goes |
| --- | --- | --- |
| [`tool-access-policy.portal.json`](tool-access-policy.portal.json) | **Portal-shaped hard enforcement.** Denies terminal fallback and direct Azure/Kubernetes/Terraform writes; GitHub issue creation triggers the repository's fixed remediation workflow. | Paste into **Settings → Permissions → Advanced permissions → JSON**. This editor accepts only `allow`, `ask`, and `deny` at the root. |
| [`tool-access-policy.api.json`](tool-access-policy.api.json) | **API-shaped hard enforcement.** The same policy wrapped in the `permissions` object required by the global-settings API. | Send as the request body to the agent settings API. Do **not** paste this file into the portal editor. |
| [`gitops-remediation-agent.md`](gitops-remediation-agent.md) | **Behavioural steering.** The custom-agent system prompt that tells the agent to remediate via a PR against `infra/leak.auto.tfvars` instead of acting directly. | A **custom agent** (Builder → Custom agents → New). |
| [`knowledge/gitops-runbook.md`](knowledge/gitops-runbook.md) | **Reference context.** A runbook the agent reads during investigations so it knows the exact GitOps fix for the planted leak. | A **knowledge file** (Builder → Knowledge → Add). |

## Why both a policy *and* a prompt?

- The **system prompt** makes the agent *want* to open a PR — but an LLM
  instruction can't *guarantee* it won't try a direct write.
- The **Tool Access Policy `deny`** makes the direct write *impossible*: even if
  the model attempts `az containerapp update`, the call is blocked before it runs.

Together they give a defence-in-depth, DevOps-correct remediation flow:

```text
incident -> agent diagnoses -> creates constrained issue -> workflow opens PR
        -> human reviews + merges -> apply-infra.yml terraform apply -> fixed
```

See [`../docs/scenario-b-gitops.md`](../docs/scenario-b-gitops.md) §B1–§B6 for
the click-by-click apply steps and the supported `accessLevel` / run-mode
settings.
