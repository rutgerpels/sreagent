# Scenario A: autonomous direct remediation

**The story you tell.** A payment service starts leaking memory. Azure Monitor
raises an incident. The Azure SRE Agent investigates on its own, explains what
broke and why, proposes a fix, and — after you approve — applies that fix
directly to Azure. Nobody opens a terminal.

**Who this is for.** Audiences who want to see the agent *act*: platform teams,
operations leadership, and anyone evaluating "can it actually fix things?"

**Time budget.**

| Phase | What you do | Duration |
| --- | --- | --- |
| 1 | Prepare the repository | ~5 minutes |
| 2 | Deploy the environment | ~20 minutes (mostly unattended) |
| 3 | Configure the SRE Agent | ~10 minutes |
| 4 | Run the demo live | ~20 minutes |
| 5 | Reset and repeat | ~5 minutes |
| 6 | Tear down | ~15 minutes (unattended) |

Phases 1–3 are preparation and can be done the day before. Only phase 4 happens
in front of the audience.

---

## What the audience will see

1. A healthy checkout application, with only the frontend reachable from the
   internet.
2. You arm a fault. Memory on `payment-service` starts climbing.
3. Azure Monitor fires a Sev2 alert roughly 8–12 minutes later.
4. The SRE Agent correlates the alert with telemetry, the running revision, the
   feature flag, and the recent change — and explains its reasoning.
5. The agent proposes a mitigation. You approve it. Azure changes.
6. Memory flattens, the alert resolves, and the agent records what it did.

---

## Before you start

Confirm all of the following. Missing any one of them will stop you mid-demo.

| Requirement | How to check |
| --- | --- |
| An Azure subscription where you can create resources **and role assignments** | You need Owner or User Access Administrator on the target scope |
| A GitHub OIDC deployment identity federated to this repository | See [deployment reference](deployment-reference.md#github-actions-oidc) |
| Permission to create an Azure SRE Agent | The SRE Agent preview must be available in your tenant and region |
| Permission to set repository Actions variables | Repository admin |
| A local clone of this repository | `git clone` |
| Azure CLI, Terraform 1.9+, and Bash or PowerShell locally | Only needed for the incident trigger in phase 3 |

> **Scenario A is a single, immutable profile.** If another scenario (B or C) is
> currently active in this repository, you must destroy it before deploying A.
> See [step 2](#step-2-confirm-no-other-scenario-is-active).

---

## Phase 1 — Prepare the repository

### Step 1. Confirm the healthy baseline

**Do.** Open `infra/leak.auto.tfvars` on `main` and confirm it reads:

```hcl
enable_slow_leak = false
```

**Expect.** The value is `false`. If it is `true`, a previous demo was left
armed — reset it before deploying, or your environment will start unhealthy and
the "before" half of the story disappears.

### Step 2. Confirm no other scenario is active

**Do.** Go to **Settings → Secrets and variables → Actions → Variables** and
look for `DEPLOYMENT_SCENARIO`.

**Expect.** It is either **absent** (nothing has been deployed yet) or set to
**`A`** (Scenario A is already active).

**If it says `B` or `C`:** stop. Deploy will refuse. Destroy that profile first
using its own guide, then delete `DEPLOYMENT_SCENARIO`, `TF_PREFIX`, and
`TF_ENVIRONMENT`. Scenario state is never converted in place — see
[profile and state safety](deployment-reference.md#profile-and-state-safety).

### Step 3. Set the Azure OIDC variables

**Do.** Under the same **Actions → Variables** page, set these three nonsecret
repository variables:

| Variable | Value |
| --- | --- |
| `AZURE_CLIENT_ID` | Client ID of the federated deployment identity |
| `AZURE_TENANT_ID` | Your Entra tenant ID |
| `AZURE_SUBSCRIPTION_ID` | The target subscription ID |

**Expect.** Three variables listed. **Do not** create an Azure client secret or
a credentials JSON secret — deployment authenticates with OIDC only.

---

## Phase 2 — Deploy the environment

### Step 4. Run the deploy workflow

**Do.** Go to **Actions → deploy → Run workflow** and set:

| Input | Value | Note |
| --- | --- | --- |
| Scenario | `A` | Selects the High / Contributor / Autonomous profile |
| Resource name prefix | `contosopay` | Any short lowercase prefix works |
| Environment label | `demo` | Appears in names and the state key |
| Azure region | `swedencentral` | Any region where SRE Agent is available |
| Open incident PR | `false` | Scenario A arms the incident directly, not by PR |

**Expect.** The run takes roughly 15–25 minutes. It bootstraps isolated remote
state, applies the platform, builds three images tagged with the full commit
SHA, pins them to digests, applies the Container Apps and the alert rule, and
provisions the Scenario A SRE Agent.

**Expect on success.** The workflow summary shows a block containing:

- the resource group name;
- the ACR name;
- the public frontend URL;
- the exact `TF_PREFIX`, `TF_ENVIRONMENT`, and `DEPLOYMENT_SCENARIO` values to
  set next.

Copy the resource group name and frontend URL — you need both later.

### Step 5. Activate push deployment

Only after the deploy run has succeeded and you have read its summary.

**Do.** Under **Actions → Variables**, add these three variables **in this
order**:

1. `TF_PREFIX` = the prefix you deployed (for example `contosopay`)
2. `TF_ENVIRONMENT` = the environment you deployed (for example `demo`)
3. `DEPLOYMENT_SCENARIO` = `A` — **set this one last**

**Expect.** `DEPLOYMENT_SCENARIO` is the activation marker. Until it exists,
push-triggered workflows stay safe no-ops. Setting it last guarantees a push can
never run against a half-configured target.

### Step 6. Verify the healthy baseline

**Do.**

1. Open the frontend URL from the workflow summary.
2. Place a test order.
3. Tick **Generate steady traffic (auto-order every 2s)** and leave it running.
4. Chart the `payment-service` memory trend in Application Insights.

   The services publish an OpenTelemetry gauge named
   `process_memory_rss_bytes`. On Linux the resident set size *is* the working
   set, but nothing in the portal is labelled "working set", so search for the
   gauge name rather than the concept. Open the Application Insights resource
   (`terraform output -raw app_insights_name`, or the only `appi-*` resource in
   the demo resource group), then **Logs**, and run:

   ```kusto
   customMetrics
   | where name == "process_memory_rss_bytes"
   | where tostring(customDimensions.service) == "payment-service"
   | summarize rssMB = round(avg(value) / 1048576, 1) by bin(timestamp, 1m)
   | render timechart
   ```

   The container app behind this metric is the one whose name contains
   `payment`; list them with `az containerapp list -g <resource-group> -o table`.
   Keep this chart open — it is the same view you narrate while memory climbs.

**Expect.**

- The order succeeds end to end (frontend → checkout-api → payment-service).
- Memory is flat. That flat line is your "before" picture — take a screenshot.
- `checkout-api` and `payment-service` have **no** public FQDN. Only the
  frontend does.

---

## Phase 3 — Configure the SRE Agent

### Step 7. Open the agent

**Grant yourself access first.** The deploy gives the *deployment identity* an
agent role, not you. Subscription Owner does not reach the agent's data plane, so
without this the agent site refuses to load and reports a misleading network
error:

> **Run this from any signed-in shell — Azure Cloud Shell is fine.** Role
> assignment is an ARM control-plane call, so it needs no special network
> access. Sign in as the account you will browse the agent with.

```bash
RG=<your demo resource group>
AGENT_ID=$(az resource list -g "$RG" \
  --resource-type Microsoft.App/agents --query "[0].id" -o tsv)

az role assignment create \
  --assignee-object-id "$(az ad signed-in-user show --query id -o tsv)" \
  --assignee-principal-type User \
  --role "SRE Agent Administrator" \
  --scope "$AGENT_ID"
```

Allow about a minute for propagation. Scenario A is autonomous, so
`SRE Agent Standard User` is also sufficient here; see
[operator access](sre-agent-setup.md#operator-access-to-the-agent).

**Do.** Go to <https://sre.azure.com> and open the agent that the deploy
workflow created in your demo resource group.

**Expect.** The agent exists and is enabled. If you deployed with the local
wrapper instead of the workflow, enable it explicitly or create a matching agent
in the portal.

### Step 8. Confirm the operating profile

**Do.** Check the agent's settings against this table and correct anything that
differs.

| Setting | Required value |
| --- | --- |
| Access level | **High** |
| Role on the demo resource group | **Contributor** |
| Mode | **Autonomous** |
| Managed resource | Only the Scenario A demo resource group |
| Incident platform | Azure Monitor |

**Expect.** Contributor is scoped to the demo resource group only. The managed
service may additionally hold monitoring-reader roles for alert lifecycle
operations; that is expected and is not general workload access.

### Step 9. Connect the evidence sources

The agent can only explain what it can see. Connect all four.

**Do.**

1. **Builder → Code Access:** add this repository. Wait for indexing to start.
   This gives source and commit correlation. It is *not* a write credential.
2. **Logs:** add the Scenario A Log Analytics workspace and Application Insights
   resource. This is where the memory trend comes from.
3. **Azure resources:** add only the Scenario A demo resource group.
4. **Incidents:** connect **Azure Monitor** as the incident platform and include
   the Sev2 payment memory alert in the response plan.

**Expect.** Code Access shows an indexing status, and the resource group, logs,
and incident platform all appear as connected.

> Do **not** give this agent a GitHub write path. Scenario A remediates Azure
> directly; the GitOps write path belongs to B and C, which use Code Access.

### Step 10. Decide your approval story

Autonomous mode means the agent may act without pausing. That is a strong demo
moment — but only if you know in advance what will happen on stage.

**Do.** Decide one of:

- **Let it act.** Leave the portal approval policy as is and narrate "the agent
  is authorised to act inside this resource group."
- **Show a human gate.** Configure the portal approval policy for the direct
  mutation tools, then test it once with a harmless action before the demo.

**Expect.** You can state, out loud and correctly, whether the next action will
pause for your approval or execute immediately. Keep the profile on
**Autonomous** either way; do not switch it to Review.

### Step 11. Prepare the incident trigger

The Scenario A trigger talks to the live Container App and reads Terraform
outputs, so your local checkout must point at the same remote state the workflow
created. Do this **before** the demo, not during it.

**Do (Bash).**

```bash
az login

export ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
export ARM_USE_AZUREAD=true

PREFIX=contosopay
SCENARIO=A
ENVIRONMENT=demo
STATE_SA="sttf$(printf '%s\0%s\0%s' "${ARM_SUBSCRIPTION_ID}" "${PREFIX}" "${SCENARIO}" | sha256sum | cut -c1-16)"

terraform -chdir=infra init -input=false \
  -backend-config="resource_group_name=rg-${PREFIX}-tfstate" \
  -backend-config="storage_account_name=${STATE_SA}" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=${PREFIX}-${SCENARIO}-${ENVIRONMENT}.tfstate"

terraform -chdir=infra output -raw scenario
```

**Do (PowerShell).**

```powershell
az login

$env:ARM_SUBSCRIPTION_ID = (az account show --query id -o tsv)
$env:ARM_USE_AZUREAD = 'true'

$prefix = 'contosopay'; $scenario = 'A'; $environment = 'demo'
$sha = [System.Security.Cryptography.SHA256]::Create()
$bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$($env:ARM_SUBSCRIPTION_ID)$([char]0)$prefix$([char]0)$scenario"))
$stateSa = 'sttf' + ([BitConverter]::ToString($bytes) -replace '-', '').ToLower().Substring(0, 16)

terraform -chdir=infra init -input=false `
  -backend-config="resource_group_name=rg-$prefix-tfstate" `
  -backend-config="storage_account_name=$stateSa" `
  -backend-config="container_name=tfstate" `
  -backend-config="key=$prefix-$scenario-$environment.tfstate"

terraform -chdir=infra output -raw scenario
```

**Expect.** The last command prints `A`. If it prints anything else, or init
fails, you are pointed at the wrong state — do not continue, and re-check the
prefix, scenario, and environment values from step 5.

---

## Phase 4 — Run the demo live

### Step 12. Establish the healthy baseline (about 2 minutes)

**Say and show.**

- The public checkout page — "this is the only thing on the internet."
- `checkout-api` and `payment-service` in the portal — "internal ingress only,
  no public FQDN, reached over TLS through the environment."
- Managed identities pulling from ACR and reading Key Vault — "no keys, no
  admin credentials, no connection strings in the app."
- The flat memory chart — "this is healthy."

### Step 13. Arm the incident

**Do.**

```bash
./scripts/trigger-incident-direct.sh
```

```powershell
pwsh ./scripts/trigger-incident-direct.ps1
```

**Expect.** The script verifies the state is Scenario A, then updates the
running `payment-service` app to set `ENABLE_SLOW_LEAK=true`. A new revision
starts. Memory begins climbing immediately and deterministically — the leak is
driven by a background timer, not by request volume, so it climbs whether or not
traffic is running.

**If the script refuses**, it is protecting you: it will not mutate a resource
group or app that does not match Terraform state, and it will not run against a
B or C state. Re-check step 11.

### Step 14. Narrate while memory climbs (8–12 minutes)

This wait is the most useful part of the demo. Use it.

**Say and show.**

- The rising working-set chart in Application Insights.
- The alert rule — "it averages over five minutes, so it will not fire on a
  spike; it fires on a trend."
- The security boundary — "the agent holds Contributor on this one resource
  group. Nothing else."
- The state isolation — "this environment has its own Terraform state, keyed by
  subscription, prefix, scenario, and environment."

**Expect.** When the five-minute average crosses the threshold, a Sev2 Azure
Monitor alert fires and appears in the agent as an incident.

### Step 15. Walk the investigation

**Do.** Open the incident in the SRE Agent and read its findings out loud.

**Expect** the agent to have correlated:

- the fired alert and the working-set trend;
- the affected `payment-service` revision;
- the `ENABLE_SLOW_LEAK` feature flag;
- the recent configuration change that set it;
- source and runbook context from Code Access.

The point to make: this is not a dashboard telling you memory is high. It is an
explanation of *why*, assembled from telemetry plus your code.

### Step 16. Approve the remediation

**Expect** the agent to propose one or more of:

| Mitigation | Effect |
| --- | --- |
| Disable the leak flag and roll a healthy revision | **Durable** — removes the trigger |
| Restart the affected revision | Recoverable, but the fault returns while the flag is on |
| Increase the scale rule | Temporary capacity relief only |

**Do.** Approve the durable fix — disabling the flag. If your portal policy is
configured for approval, this is where the human gate appears; if not, narrate
that the agent is acting under its Autonomous policy.

**Say.** "A restart clears the symptom. Turning the flag off removes the cause.
The agent distinguishes between the two."

### Step 17. Verify recovery

**Expect**, within a few minutes:

1. a new healthy revision is serving traffic;
2. memory returns to the baseline you screenshotted in step 6;
3. the Azure Monitor alert resolves;
4. the agent's incident record shows the evidence it used and the action it
   took.

Show all four. The recorded evidence trail is what makes this auditable rather
than magical.

---

## Phase 5 — Reset and repeat

**Do.** Return the environment to healthy without destroying it:

```bash
./scripts/trigger-incident-direct.sh --reset
```

```powershell
pwsh ./scripts/trigger-incident-direct.ps1 -Reset
```

**Expect.** `ENABLE_SLOW_LEAK` returns to `false` and a fresh revision starts.

**Optional second run.** Re-arm the incident to show the agent recognising a
pattern it has already seen and reaching the same conclusion faster. You can
also add a scheduled health check that reports current memory, active alerts,
revision health, and the feature-flag state.

---

## Phase 6 — Tear down

**Do.** Go to **Actions → destroy → Run workflow** and set:

| Input | Value |
| --- | --- |
| Scenario | `A` |
| Resource name prefix | the prefix you deployed |
| Environment label | the environment you deployed |
| Delete state blob after destroy | `true` if you are finished with this profile |

Or, for a locally deployed environment:

```bash
./scripts/teardown.sh --scenario A --prefix contosopay --env demo
```

**Expect.** Teardown verifies that the selected state actually records Scenario
A before destroying anything. A Terraform-provisioned agent is destroyed with
the environment; an agent you created by hand in the portal must be removed
separately.

**If you plan to move to Scenario B or C:** finish this destroy first, then
delete `DEPLOYMENT_SCENARIO`, `TF_PREFIX`, and `TF_ENVIRONMENT`. Never reuse or
migrate Scenario A state.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Deploy fails in preflight with a scenario mismatch | `DEPLOYMENT_SCENARIO` is set to B or C | Destroy that profile, then delete all three profile variables |
| The agent site will not load, or chat returns `unauthorized` | No SRE Agent data-plane role — subscription Owner is not enough | Grant a role at agent scope; see [operator access](sre-agent-setup.md#operator-access-to-the-agent) |
| Trigger script exits with "restricted to Scenario A" | Local Terraform state points at another profile | Redo [step 11](#step-11-prepare-the-incident-trigger) with the correct prefix, scenario, and environment |
| `terraform init` fails on the state account | Wrong subscription selected, or Azure AD data-plane auth not enabled | `az account set --subscription <id>` and export `ARM_USE_AZUREAD=true` |
| Memory climbs but no alert fires | Fewer than ~8 minutes have passed, or you are charting the wrong app | The rule uses a five-minute average; confirm you are charting `payment-service` |
| Agent has no telemetry to reason about | Logs connector missing | Redo [step 9](#step-9-connect-the-evidence-sources), item 2 |
| Agent proposes nothing | Response plan does not include the Sev2 alert | Redo [step 9](#step-9-connect-the-evidence-sources), item 4 |
| Push to `main` deploys nothing | `DEPLOYMENT_SCENARIO` is unset | Expected — this is the safe no-op state. Complete [step 5](#step-5-activate-push-deployment) |

---

## Reference: security and operating model

| Concern | Scenario A behaviour |
| --- | --- |
| Terraform profile | `scenario = "A"` |
| SRE Agent access | High; Contributor on the demo resource group only |
| Run mode | Autonomous |
| Deployment control endpoints | Public, protected by Azure RBAC and TLS |
| Deployment runner | GitHub-hosted, or the local wrapper |
| Code Access | Read-only source and commit correlation |
| GitHub write connector | None |
| Incident trigger | Direct update of the running `payment-service` |
| Remediation path | Direct Azure action |

The public deployment endpoints are a deliberate trade for demo speed. The
security invariants still hold: ACR admin and anonymous access are disabled,
Key Vault uses RBAC with purge protection, applications authenticate with
managed identity, ingress is TLS-only, and the frontend is the only public
application.

Scenario A deliberately has **no** GitHub write path. If your audience asks
"but I do not want an agent with Contributor" — that is exactly the question
[Scenario B](scenario-b-gitops.md) answers.

---

## References

- [Scenario chooser](run-of-show.md)
- [Deployment and state reference](deployment-reference.md)
- [Azure SRE Agent setup reference](sre-agent-setup.md)
- [Azure SRE Agent permissions](https://learn.microsoft.com/azure/sre-agent/permissions)
- [Azure SRE Agent run modes](https://learn.microsoft.com/azure/sre-agent/run-modes)
- [Container Apps ingress](https://learn.microsoft.com/azure/container-apps/ingress-overview)
- [Key Vault RBAC](https://learn.microsoft.com/azure/key-vault/general/rbac-guide)
