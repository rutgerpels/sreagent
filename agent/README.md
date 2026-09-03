# Azure SRE Agent — GitOps remediation config

These are the **committable artifacts** that turn the demo's SRE Agent into a
GitOps-only operator. Scenario B uses OAuth Code Access for the fast
public-endpoint demo, with no connector and no token. Scenario C uses BYO GitHub
App Code Access, Azure VNet integration, and API reconciliation. In both, the
agent opens its remediation pull request itself over Code Access.
In all paths the agent is **structurally unable to modify the live Azure
resources** when the tool access policy is applied.

> These artifacts are used **only in the GitOps scenarios**: Scenario B and
> Scenario C. Scenario A (autonomous direct remediation) does **not** use them — see
> [`../docs/scenario-a-direct.md`](../docs/scenario-a-direct.md).

Scenario B artifacts are applied after the agent is created. Scenario C
artifacts are applied and verified by `scripts/reconcile-sre-agent.*` (see
[`../docs/scenario-b-gitops.md`](../docs/scenario-b-gitops.md) or
[`../docs/scenario-c-private-gitops.md`](../docs/scenario-c-private-gitops.md)).

| File | What it is | Where it goes |
| --- | --- | --- |
| [`tool-access-policy.portal.json`](tool-access-policy.portal.json) | **Portal-shaped hard enforcement.** Denies direct Azure/Kubernetes/Terraform writes at command level while leaving the terminal available, because Code Access performs its GitHub writes through it. | Paste into **Capabilities → Tools → Advanced permissions → JSON**. This editor accepts only `allow`, `ask`, and `deny` at the root. |
| [`tool-access-policy.api.json`](tool-access-policy.api.json) | **API-shaped hard enforcement.** The same policy wrapped in the `permissions` object required by the global-settings API. | Send as the request body to the agent settings API. Do **not** paste this file into the portal editor. |
| [`gitops-remediation-agent-github.md`](gitops-remediation-agent-github.md) | **Scenario B steering.** Prompt for the OAuth Code Access path. It tells the agent to remediate via a PR against `infra/leak.auto.tfvars` instead of acting directly. | **Builder → Agent Canvas → Create subagent**; paste it into **Create a custom agent → Instructions**. |
| [`scenario-c/manifest.json`](scenario-c/manifest.json) | **Scenario C desired state.** Connectors, permissions, custom agent, response plan, schedule, knowledge, and optional Code Access. | Reconciled by GitHub Actions after Terraform. |
| [`scenario-c/gitops-remediation.instructions.md`](scenario-c/gitops-remediation.instructions.md) | **Scenario C steering.** Read-only Azure investigation, then an agent-authored remediation pull request. | Uploaded by the reconciler. |
| [`gitops-remediation-agent.md`](gitops-remediation-agent.md) | **Legacy Scenario C portal prompt.** Retained for compatibility and points to the reconciled instructions. | Do not use for new deployments. |
| [`knowledge/gitops-runbook.md`](knowledge/gitops-runbook.md) | **Reference context.** A runbook the agent reads during investigations so it knows the exact GitOps fix for the planted leak. | Attach as knowledge/skill context to the `gitops-remediation` custom agent. |

## Why both a policy *and* a prompt?

- The **system prompt** makes the agent *want* to open a PR — but an LLM
  instruction can't *guarantee* it won't try a direct write.
- The **Tool Access Policy `deny`** makes the direct write *impossible*: even if
  the model attempts `az containerapp update`, the call is blocked before it runs.
- The terminal is **allowed on purpose**. Code Access performs its GitHub writes
  by running `git` and `gh` against the sandboxed clone — there is no separate
  write tool. Denying `RunInTerminal` therefore blocks the remediation pull
  request itself, which is the one thing B and C exist to demonstrate.
- Denying the terminal was never what stopped Azure mutation. Two things do, and
  both are still in force: **Reader RBAC**, and the command-level `bash(...)`
  deny patterns. Verified live — with `RunInTerminal` allowed, the agent opened a
  pull request, and an `az containerapp revision restart` in the same terminal
  was still refused with `Tool 'RunInTerminal' is blocked by a permission rule`.
  Note that the block message names the *tool* even when a `bash(...)` pattern is
  what matched, so it alone will not tell you which rule fired.

Together they give a defence-in-depth, DevOps-correct remediation flow:

```text
incident -> agent diagnoses -> agent opens PR
        -> human reviews + merges -> apply-infra.yml terraform apply -> fixed
```

Both scenarios open that pull request through Code Access; they differ only in
how Code Access is authenticated — a user account (OAuth) in B, a bring-your-own
GitHub App in C. In both, review and merge stay human and the live fix happens
through `apply-infra.yml`.

See [`../docs/scenario-b-gitops.md`](../docs/scenario-b-gitops.md) and
[`../docs/scenario-c-private-gitops.md`](../docs/scenario-c-private-gitops.md)
for the click-by-click apply steps and the supported `accessLevel` / run-mode
settings.
