# Scenario A: autonomous direct remediation

Scenario A is the shortest route to the "detect, explain, and fix" moment. The
Azure SRE Agent uses the Terraform-derived **High / Contributor / Autonomous**
profile and can remediate the demo resource group directly. It does not use a
GitOps write connector or remediation broker.

## Security and operating model

| Concern | Scenario A behavior |
| --- | --- |
| Terraform profile | `scenario = "A"` |
| SRE Agent access | High; Contributor on the demo resource group |
| Run mode | Autonomous |
| Endpoints | Public deployment control endpoints, protected by Azure RBAC and TLS |
| Runner | GitHub-hosted workflow jobs or local deploy wrapper |
| Code Access | Read context and change correlation only |
| GitHub write connector | None |
| Broker | None |
| Incident trigger | Direct update of the running payment-service |
| Remediation | Direct Azure action |

The default public endpoint posture is intentional for the rapid demo. ACR admin
and anonymous access remain disabled, Key Vault still uses RBAC and purge
protection, applications use managed identity, and only the frontend application
has public business ingress.

## Before you begin

You need:

- an Azure subscription and enough access to deploy resources and role
  assignments;
- a clone of the repository;
- either GitHub Actions OIDC configured or Azure CLI, Terraform 1.9+, Docker, and
  Bash/PowerShell for local deployment;
- permission to create or configure an Azure SRE Agent.

Keep `infra/leak.auto.tfvars` at `enable_slow_leak = false` for deployment.

## 1. Deploy an isolated Scenario A environment

The `scenario` variable selects an immutable profile. Its scenario is included in
resource names, the state account hash, and the state key. Do not convert a B or
C state to A. Deploy A as a new isolated environment, then destroy the old
profile separately.

### Option 1: GitHub Actions

Set these nonsecret repository variables:

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`
- `DEPLOYMENT_SCENARIO=A`
- `SRE_AGENT_SPONSOR_GROUP_ID`

CI authentication is OIDC only. Do not configure an Azure client secret or a
credentials JSON blob.

Run the manual **deploy** workflow with:

- **Scenario:** `A`
- **Open incident PR:** `false`

The deploy job uses `ubuntu-latest`. The workflow builds immutable images tagged
with the full `github.sha`, creates the scenario-specific state, and verifies
that state reports Scenario A.

### Option 2: local wrapper

Sign in; the wrapper publishes the current full commit SHA once and deploys its
locked manifest digest:

```bash
az login
./scripts/deploy.sh --scenario A
```

```powershell
az login
pwsh ./scripts/deploy.ps1 -Scenario A
```

The local path uses your interactive Azure identity and Azure AD authentication
for state. It is not a substitute for OIDC in CI.

### Verify the baseline

1. Record the `frontend_url` and `resource_group_name` outputs.
2. Open the frontend and place a test order.
3. Enable steady traffic.
4. Confirm payment-service memory is stable.
5. Confirm `terraform output -raw scenario` returns `A` when using the local
   workspace, or inspect the workflow summary.

## 2. Verify and configure the matching SRE Agent

The GitHub deployment workflow provisions the selected Terraform agent resource.
Open it at <https://sre.azure.com> and complete the manual portal connections.
For direct Terraform or local-wrapper usage, enable that resource explicitly or
create the matching agent in the portal.

The effective profile must be:

| Setting | Value |
| --- | --- |
| Access level | **High** |
| Resource-group role | **Contributor** |
| Mode | **Autonomous** |
| Managed resource | Only the Scenario A demo resource group |
| Incident platform | Azure Monitor |

The SRE Agent also needs its documented monitoring roles to investigate and
manage the alert lifecycle. Keep workload Contributor scope limited to the demo
resource group.

See [Azure SRE Agent permissions](https://learn.microsoft.com/azure/sre-agent/permissions)
and [run modes](https://learn.microsoft.com/azure/sre-agent/run-modes).

## 3. Connect evidence sources

### Code Access

Add this repository under **Builder > Code Access**. Code Access is used for
source indexing and commit correlation only. Do not add the GitHub MCP write
connector and do not configure a broker for Scenario A.

### Logs

Add the Scenario A Log Analytics workspace and Application Insights resource.
This gives the investigation access to the payment-service memory trend.

### Azure resources and incidents

1. Add only the Scenario A resource group as a managed resource.
2. Connect **Azure Monitor** as the incident platform.
3. Include the Sev2 payment memory alert in the incident response plan.
4. Use the default agent in **Autonomous** mode.

If the demo requires a visible human gate, configure the portal's approval policy
for the direct mutation tools before the presentation and verify it with a safe
test. The profile remains Autonomous; do not change it to Review. The live
talk-track should clearly identify whether the current portal policy will pause
for approval or execute the allowed action automatically.

## 4. Arm the direct incident

Use the direct script, not a Pull Request:

```bash
./scripts/trigger-incident-direct.sh
```

```powershell
pwsh ./scripts/trigger-incident-direct.ps1
```

The script updates the running payment-service revision and sets
`ENABLE_SLOW_LEAK=true`. Memory rises deterministically. The five-minute average
crosses the alert threshold after approximately 8–12 minutes.

During the wait, show:

- frontend as the only public business service;
- internal checkout and payment ingress;
- managed identities for ACR and Key Vault;
- the Scenario A state and resource suffix;
- stable-to-rising memory in Application Insights or Grafana.

## 5. Investigate and remediate

The agent should correlate:

- the fired Azure Monitor alert;
- the payment-service working-set trend;
- the current revision and feature flag;
- the recent direct configuration change;
- source and runbook context.

Valid direct mitigations include:

- disable the leak flag and roll a healthy revision;
- restart the affected revision to clear retained memory;
- adjust the scale rule as a temporary capacity mitigation.

The durable fix is to disable the planted fault. A restart alone is recoverable
but does not remove the trigger if the flag remains enabled.

After remediation, confirm:

1. a healthy revision is serving traffic;
2. memory returns to baseline;
3. the alert resolves;
4. the agent records its evidence and action.

## 6. Reset and repeat

Reset without removing the environment:

```bash
./scripts/trigger-incident-direct.sh --reset
```

```powershell
pwsh ./scripts/trigger-incident-direct.ps1 -Reset
```

Re-arm the leak to demonstrate pattern recognition. A scheduled health check can
report current memory, active alerts, revision health, and the feature-flag state.

## 7. Destroy Scenario A

Use the **destroy** workflow with Scenario `A` and confirmation
`<prefix>-A-<environment>`, or:

```bash
./scripts/teardown.sh --scenario A
```

Teardown verifies that the selected state reports Scenario A. If you are moving
to B or C, deploy and validate that new isolated environment first; never reuse
or migrate the A state.

Remove a portal-created SRE Agent separately. A Terraform-provisioned agent is
destroyed with its Scenario A state.

## References

- [Azure SRE Agent setup reference](sre-agent-setup.md)
- [Azure SRE Agent permissions](https://learn.microsoft.com/azure/sre-agent/permissions)
- [Azure SRE Agent run modes](https://learn.microsoft.com/azure/sre-agent/run-modes)
- [Container Apps ingress](https://learn.microsoft.com/azure/container-apps/ingress-overview)
- [Key Vault RBAC](https://learn.microsoft.com/azure/key-vault/general/rbac-guide)
