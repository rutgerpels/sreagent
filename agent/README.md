# Azure SRE Agent — GitOps remediation config

These are the **committable artifacts** that turn the demo's SRE Agent into a
GitOps-only operator: it investigates and **proposes a fix as a GitHub Pull
Request**, but is **structurally unable to modify the live Azure resources**.

Apply them once, after the agent is created and connected (see
[`../docs/sre-agent-setup.md`](../docs/sre-agent-setup.md) §9).

| File | What it is | Where it goes |
| --- | --- | --- |
| [`tool-access-policy.json`](tool-access-policy.json) | **Hard enforcement.** Global Tool Access Policy that **denies** Azure CLI write commands (and the terminal). Only the *global* scope can deny, so nothing — no custom agent, response plan, or user prompt — can override it. | Agent **global settings** (Builder → Settings → Tool access policies, or the agent settings API). |
| [`gitops-remediation-agent.md`](gitops-remediation-agent.md) | **Behavioural steering.** The custom-agent system prompt that tells the agent to remediate via a PR against `infra/leak.auto.tfvars` instead of acting directly. | A **custom agent** (Builder → Custom agents → New). |
| [`knowledge/gitops-runbook.md`](knowledge/gitops-runbook.md) | **Reference context.** A runbook the agent reads during investigations so it knows the exact GitOps fix for the planted leak. | A **knowledge file** (Builder → Knowledge → Add). |

## Why both a policy *and* a prompt?

- The **system prompt** makes the agent *want* to open a PR — but an LLM
  instruction can't *guarantee* it won't try a direct write.
- The **Tool Access Policy `deny`** makes the direct write *impossible*: even if
  the model attempts `az containerapp update`, the call is blocked before it runs.

Together they give a defence-in-depth, DevOps-correct remediation flow:

```text
incident -> agent diagnoses -> opens PR setting enable_slow_leak=false
        -> human reviews + merges -> apply-infra.yml terraform apply -> fixed
```

See [`../docs/sre-agent-setup.md`](../docs/sre-agent-setup.md) §9 for the
click-by-click apply steps and the supported `accessLevel` / run-mode settings.
