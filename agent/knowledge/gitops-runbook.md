# Runbook — ContosoPay payment-service memory leak (GitOps remediation)

> Connect this file as a **knowledge file** (Builder → Knowledge → Add) so the
> agent has the exact fix on hand during an investigation. Knowledge files are
> reference-only context; the hard guardrail is the Tool Access Policy.

## Symptom

`payment-service` (Azure Container App `ca-payment-<suffix>`) **working-set
memory climbs steadily** over roughly 8–12 minutes and its five-minute average
fires the Azure Monitor metric alert `alert-payment-memory-<suffix>` (severity 2 /
Warning).

## Root cause

A **planted slow memory leak**, gated by the `ENABLE_SLOW_LEAK` environment
variable on the container. Its desired state is defined as code in
**`infra/leak.auto.tfvars`**:

```hcl
enable_slow_leak = true   # leak armed  -> incident
enable_slow_leak = false  # healthy     -> fixed
```

The flag is deployed by Terraform (`infra/containerapps.tf` maps
`var.enable_slow_leak` to the container's `ENABLE_SLOW_LEAK`). The incident was
introduced by a Pull Request that set the flag to `true` and was applied by the
`apply-infra` GitHub Actions workflow.

## Correct remediation (GitOps only — do NOT touch Azure directly)

1. Scenario B path: use only the configured GitHub MCP tools to create a branch,
   edit `infra/leak.auto.tfvars`, commit that one-file change, and open an
   unmerged Pull Request.
2. The Pull Request changes only `infra/leak.auto.tfvars`:

   ```hcl
   enable_slow_leak = false
   ```

3. A human reviews and merges. Merging runs `.github/workflows/apply-infra.yml`,
   which `terraform apply`s the change and rolls a fresh `ca-payment-<suffix>`
   revision — clearing the leaked memory.

Scenario C currently has no agent-initiated GitHub write path. The remote
Streamable-HTTP MCP connector is intentionally disabled because its documented
authentication methods do not include the managed-identity flow required by the
broker. Explain the exact one-file change, then require a human to run
`scripts/trigger-incident-gitops.sh --reset` (or the PowerShell equivalent) and
review the resulting Pull Request.

Do not replace the disabled connector with a static bearer secret, PAT,
anonymous access, or network-only trust. When a supported managed-identity flow
becomes available, the broker may create the fixed issue shape and
`.github/workflows/sre-remediation-pr.yml` may convert it into the same one-file
Pull Request.

Never use generic workflow dispatch, terminal `git`/`gh`, broader token
discovery, or direct GitHub API calls for this remediation.

## Why not `az containerapp update`?

A direct `az containerapp update --set-env-vars ENABLE_SLOW_LEAK=false` would
"fix" the symptom but **drift from IaC**: the next `terraform apply` (or any
redeploy) would reintroduce whatever `infra/leak.auto.tfvars` says. The agent is
also denied Azure CLI write commands by a global Tool Access Policy, so the only
durable, allowed fix is the Pull Request above.

## Verification after merge

- The `apply-infra` workflow run is green.
- `ca-payment-<suffix>` shows a new active revision.
- Working-set memory drops back to baseline and `alert-payment-memory-<suffix>`
  resolves.
