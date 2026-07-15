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

1. Create a GitHub issue with the exact title
   `[SRE] Remediate ContosoPay slow memory leak`, label `sre-remediation`, and
   body marker `<!-- sre-remediation:payment-slow-leak -->`.
2. The issue triggers `.github/workflows/sre-remediation-pr.yml`. The workflow
   creates a branch and changes only `infra/leak.auto.tfvars`:

   ```hcl
   enable_slow_leak = false
   ```

3. The workflow commits and opens an unmerged Pull Request into `main` with its
   short-lived `GITHUB_TOKEN`.
4. A human reviews and merges. Merging runs `.github/workflows/apply-infra.yml`,
   which `terraform apply`s the change and rolls a fresh `ca-payment-<suffix>`
   revision — clearing the leaked memory.

Never use generic workflow dispatch, terminal `git`/`gh`, GitHub MCP, a PAT, or
direct GitHub API calls for this remediation.

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
