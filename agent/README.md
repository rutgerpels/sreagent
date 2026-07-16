# Azure SRE Agent — GitOps remediation config

These are the **committable artifacts** that turn the demo's SRE Agent into a
GitOps-only operator. Scenario B uses the PAT-based GitHub MCP connector for the
fast public-endpoint demo. Scenario C uses SRE Agent's native BYO GitHub App
connector with a Key Vault key URI and Azure VNet integration. An advanced
hardening option can instead invoke a managed-identity broker that opens a
constrained GitHub issue; the repository workflow then proposes the PR. In all
paths the agent is **structurally unable to modify the live Azure resources**
when the tool access policy is applied.

> These artifacts are used **only in the GitOps scenarios**: Scenario B and
> Scenario C. Scenario A (autonomous direct remediation) does **not** use them — see
> [`../docs/scenario-a-direct.md`](../docs/scenario-a-direct.md).

Apply them once, after the agent is created and connected (see
[`../docs/scenario-b-gitops.md`](../docs/scenario-b-gitops.md) or
[`../docs/scenario-c-private-gitops.md`](../docs/scenario-c-private-gitops.md)).

| File | What it is | Where it goes |
| --- | --- | --- |
| [`tool-access-policy.portal.json`](tool-access-policy.portal.json) | **Portal-shaped hard enforcement.** Denies terminal fallback and direct Azure/Kubernetes/Terraform writes; GitHub issue creation triggers the repository's fixed remediation workflow. | Paste into **Capabilities → Tools → Advanced permissions → JSON**. This editor accepts only `allow`, `ask`, and `deny` at the root. |
| [`tool-access-policy.api.json`](tool-access-policy.api.json) | **API-shaped hard enforcement.** The same policy wrapped in the `permissions` object required by the global-settings API. | Send as the request body to the agent settings API. Do **not** paste this file into the portal editor. |
| [`gitops-remediation-agent-github.md`](gitops-remediation-agent-github.md) | **Default behavioural steering.** Prompt for Scenario B's PAT connector or Scenario C's BYO GitHub App path. It tells the agent to remediate via a PR against `infra/leak.auto.tfvars` instead of acting directly. | **Builder → Agent Canvas → Create subagent**; paste it into **Create a custom agent → Instructions**. |
| [`gitops-remediation-agent.md`](gitops-remediation-agent.md) | **Hardened broker steering.** Alternate prompt for the custom MCP broker path. | Use instead of `gitops-remediation-agent-github.md` only when following the advanced broker hardening option. |
| [`knowledge/gitops-runbook.md`](knowledge/gitops-runbook.md) | **Reference context.** A runbook the agent reads during investigations so it knows the exact GitOps fix for the planted leak. | Attach as knowledge/skill context to the `gitops-remediation` custom agent. |

## Why both a policy *and* a prompt?

- The **system prompt** makes the agent *want* to open a PR — but an LLM
  instruction can't *guarantee* it won't try a direct write.
- The **Tool Access Policy `deny`** makes the direct write *impossible*: even if
  the model attempts `az containerapp update`, the call is blocked before it runs.
- `RunInTerminal` is intentionally denied. PR creation must come from the
  selected GitHub connector tools on the `gitops-remediation` custom agent, not
  from shell, `git`, or `gh`.

Together they give a defence-in-depth, DevOps-correct remediation flow:

```text
incident -> agent diagnoses -> GitHub connector opens PR
        -> human reviews + merges -> apply-infra.yml terraform apply -> fixed
```

With the broker hardening option, the middle step is
`agent diagnoses -> creates constrained issue -> workflow opens PR`; the PR
still requires human review and the live fix still happens through
`apply-infra.yml`.

See [`../docs/scenario-b-gitops.md`](../docs/scenario-b-gitops.md) and
[`../docs/scenario-c-private-gitops.md`](../docs/scenario-c-private-gitops.md)
for the click-by-click apply steps and the supported `accessLevel` / run-mode
settings.
