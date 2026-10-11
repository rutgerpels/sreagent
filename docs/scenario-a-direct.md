# Scenario A: autonomous investigation, approved direct remediation

**The story you tell.** A payment service starts leaking memory. Azure Monitor
fires an alert. The Azure Copilot Observability Agent automatically creates an
Azure Monitor issue from that individual alert and starts an investigation.
You hand its evidence to the Azure SRE Agent, which checks the revision,
configuration change and source, proposes a durable fix, and applies it
directly to Azure only after you approve. Nobody opens a terminal to fix it.

This is one incident, using the existing slow memory leak. Only Scenario A
includes the Observability Agent flow; B and C remain GitOps demonstrations.
The evidence handoff is explicit and operator-mediated, not a claimed native
agent-to-agent integration.

**Who this is for.** Audiences who want to see the agent *act*: platform teams,
operations leadership, and anyone evaluating "can it actually fix things?"

**Time budget.**

| Phase | What you do | Duration |
| --- | --- | --- |
| 1 | Prepare the repository | ~5 minutes |
| 2 | Deploy the environment | ~20 minutes (mostly unattended) |
| 3 | Configure both agents and rehearse the approval boundary | Allow extra preparation time for preview onboarding and a full incident rehearsal |
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
4. Without anyone selecting **Investigate**, the Observability Agent creates an
   Azure Monitor issue and starts investigating the memory trend and impact.
5. You hand the findings to SRE Agent in its existing incident thread. It checks
   the running revision, feature flag, recent change and source.
6. SRE Agent proposes a mitigation. A human approves the infrastructure write.
7. Memory stays stable, the alert resolves, and both investigation and action
   evidence are recorded. A human resolves the Azure Monitor issue.

> **Preview acceptance, not a claim of live verification.** Rehearse automatic
> promotion of this Container Apps memory alert into an issue against the
> monitored Application Insights topology before presenting. An on-demand
> investigation or manually created issue does not prove autonomous operation.

---

## Before you start

Confirm all of the following. Missing any one of them will stop you mid-demo.

| Requirement | How to check |
| --- | --- |
| An Azure subscription where you can create resources **and role assignments** | You need Owner or User Access Administrator on the target scope |
| A GitHub OIDC deployment identity federated to this repository | See [deployment reference](deployment-reference.md#github-actions-oidc) |
| Permission to create an Azure SRE Agent | The SRE Agent preview must be available in your tenant and region |
| Azure Copilot access and Observability Agent preview availability | Confirm the **Observability Agents** portal experience is available in West Europe |
| Permission to onboard the Observability Agent | Monitoring Contributor on its resource group; Terraform prepares the identity and its roles |
| Subscription-level monitoring bootstrap permissions | The deployment identity must be able to assign Monitoring Reader at subscription scope and register Microsoft.Monitor if needed |
| Permission to set repository Actions variables | Repository admin |
| A local clone of this repository | `git clone` |
| Azure CLI, Terraform 1.9+, and Bash or PowerShell locally | Used for Terraform outputs and the incident trigger |

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
- the Scenario A Azure Monitor workspace name and its West Europe location;
- the exact `TF_PREFIX`, `TF_ENVIRONMENT`, and `DEPLOYMENT_SCENARIO` values to
  set next.

Copy the resource group name and frontend URL — you need both later.

Terraform also creates the Observability Agent's user-assigned identity and
roles. The **Observability Agent itself is not provisioned**: current preview
onboarding is a separate portal step, because Terraform provisioning is not
supported. The Azure Monitor workspace stores issues; it does not replace the
Log Analytics workspace or move application telemetry.

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

## Phase 3 — Configure both agents

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

Allow about a minute for propagation. Use **SRE Agent Administrator** for the
operator who will approve infrastructure actions; Standard User is not enough
to approve them. See
[operator access](sre-agent-setup.md#operator-access-to-the-agent).

> **If the agent site later fails to load**, the portal reports a timeout or a
> refused connection and suggests allowing `*.azuresre.ai` — which points at
> networking. The API is actually returning `403 Forbidden: Access denied by
> PDP`: a missing role, not a blocked port. Check this assignment before you
> investigate anything else.

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
| Agent-level fallback mode | **Autonomous**, as provisioned by the profile |
| Memory-incident response plan autonomy level | **Review**; required for this paired-agent demo |
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

### Step 10. Require approval for SRE infrastructure writes

**Do.** Edit the response plan that handles the Sev2 payment memory alert.
Set its **Agent autonomy level** to **Review**, save it, and confirm that no
other matching response plan handles this alert in Autonomous mode. Keep the
Terraform-provisioned agent-level fallback unchanged; the response plan's
per-incident mode is the approval boundary for this demonstration.

**Expect.** SRE can investigate automatically, but an Azure infrastructure write
shows **Approve** and **Deny**. Do not rely on a prompt such as "ask first" as a
substitute for Review mode. Do not approve a mitigation before the Observability
Agent's investigation has been shown and handed over.

During rehearsal, confirm the resulting incident thread is in Review mode.
Continue the evidence handoff in that thread, not in a new chat that could use
the Autonomous fallback. If the write runs without approval, reset the demo and
correct the response plan before presenting.

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

### Step 12. Enable autonomous Observability Agent operations

**Do.** Read the nonsecret onboarding details from the initialized Scenario A
state:

```bash
terraform -chdir=infra output -json observability_agent_onboarding
```

The same command works in PowerShell. Keep the output local; it contains your
deployment's resource IDs, not values to commit into this public repository.

**Expect.** The output identifies the Azure Monitor workspace, user-assigned
identity, Application Insights resource, exact memory alert name, and
environment-specific custom instructions.

Terraform owns these prerequisites:

| Resource or permission | Purpose |
| --- | --- |
| Azure Monitor workspace in **West Europe** | Durable Azure Monitor issue container, separate from Log Analytics |
| User-assigned Observability Agent identity | Dedicated identity for background operations, not the SRE identity |
| **Issue Contributor** on that workspace | Create and update issues without workload write access |
| **Monitoring Reader** on the subscription | Documented preview requirement for alert discovery and telemetry reads |

Subscription-wide monitoring reads are a documented preview requirement, not
subscription-wide workload Contributor. Do not substitute the broader
subscription Monitoring Contributor shortcut when these narrower roles work.
Scenario A's workspace uses a public, Azure-RBAC-protected monitoring endpoint
because the agent and operator have no private-link path. No new application
ingress is exposed.

**Do in the Azure portal.**

1. Search for **Observability Agents**, then select **Create**.
2. Select the Scenario A subscription and resource group from the output.
3. Choose **West Europe** and the Terraform-created Azure Monitor workspace.
   The workspace and agent must share a region. The application can remain in
   its existing region; the monitored Application Insights resource must be in
   the agent's subscription.
4. Select **User-assigned managed identity**, then choose the exact identity
   from `managed_identity_resource_id`. Do not reuse the SRE identity or choose
   System-assigned: the preassigned roles belong to this user-assigned identity.
5. On **Operations**, choose `application_insights_name` as **Monitored application**.
6. Set **Allow the agent to run autonomously** to **On**. Enable both
   **Correlation + issue creation** and **Investigation**. Investigation is
   required for this demo, even though the product permits opting out.
7. Paste the plain-text `custom_instructions` value from the output, with actual
   line breaks rather than JSON quotes or escaped `\n`. It promotes the exact
   individual memory alert into an issue even when nothing else is firing,
   identifies the service chain, and keeps other demo resource groups separate.
   These instructions guide issue creation; the Investigation setting is what
   starts investigations automatically.
8. Review and create the resource. Verify its settings after creation and allow
   role assignments and topology discovery to settle before rehearsal.

**Optional notifications.** Configure issue action groups on this Azure Monitor
workspace if the audience needs an on-call notification. The existing
Terraform action group has no receivers; merely selecting it does not deliver
an email. Neither notifications nor an action-group receiver start the agent's
autonomous investigation.

**Rehearsal gate.** Run phase 4 once before the live presentation. Record the
fired alert, agent-created issue provenance, automatic investigation, SRE
approval prompt, and recovery. If the Container Apps alert is not promoted,
check identity permissions, monitored-application topology and the exact alert
name. Do not replace a failed autonomous run with a manual **Investigate**
click and call it autonomous. Reset the fault while resolving the preview
limitation; do not present the paired-agent flow as verified.

---

## Phase 4 — Run the demo live

### Step 13. Establish the healthy baseline (about 2 minutes)

**Say and show.**

- The public checkout page — "this is the only thing on the internet."
- `checkout-api` and `payment-service` in the portal — "internal ingress only,
  no public FQDN, reached over TLS through the environment."
- Managed identities pulling from ACR and reading Key Vault — "no keys, no
  admin credentials, no connection strings in the app."
- The flat memory chart — "this is healthy."
- Both agents' boundaries: "Observability can read monitoring data and write
  issues. SRE can change this resource group, but this incident requires human
  approval."

### Step 14. Arm the incident

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

### Step 15. Narrate while memory climbs (8–12 minutes)

This wait is the most useful part of the demo. Use it.

**Say and show.**

- The rising working-set chart in Application Insights.
- The alert rule — "it averages over five minutes, so it will not fire on a
  spike; it fires on a trend."
- The security boundary — "SRE has workload Contributor on this resource group;
  Observability has monitoring reads and issue creation, not workload writes."
- The state isolation — "this environment has its own Terraform state, keyed by
  subscription, prefix, scenario, and environment."

**Expect.** When the five-minute average crosses the threshold, a Sev2 Azure
Monitor alert fires and appears in the agent as an incident.

### Step 16. Show the automatically created issue and investigation

**Do.** Open **Azure Monitor → Issues**, scoped to the Scenario A workspace.
Open the issue generated from the payment memory alert. Do not select
**Investigate** or manually create an issue.

**Expect.**

- The issue links the exact fired memory alert.
- Its title has the agent-generated application prefix and `[OPS-REVIEW]`.
- Its Background begins with **Observability Agent created this issue for**.
- An investigation has started automatically on that issue.
- Findings link to the signals and time window that support the hypothesis.

Show what the evidence actually establishes: the payment memory trend, observed
checkout latency/failures, and any alternative explanations considered. RSS
and heap gauges can help distinguish off-heap growth; they do not by themselves
prove a leaking code path. A healthy `/health` response does not rule out the
leak, and high memory alone does not prove customer requests have failed.

**Say.** "One important alert was enough. Nobody asked the agent to investigate;
the incident record and investigation were prepared in the background."

### Step 17. Hand evidence to SRE Agent

**Do.** In the existing, **Review-mode** SRE incident thread, paste the
Observability issue URL and its findings, resource IDs, UTC time window and
supporting queries. A URL alone does not guarantee SRE can read issue contents.
Use this handoff:

```text
The Observability Agent created this issue and investigated it autonomously.
Here are its issue URL, findings, affected resources, UTC time window and
supporting queries: <paste the evidence>.
Check this evidence against the active payment-service revision, recent
configuration changes and repository source. Explain the durable fix and why
restarting or scaling alone would not remove this timer-driven leak.
Propose the direct Azure remediation in this Review-mode incident thread.
```

**Expect.** SRE checks the alert and trend, active revision, `ENABLE_SLOW_LEAK`,
the direct configuration change, and source context from Code Access. It may
already have investigated the same alert independently; the handoff adds
shared context, not an automatic agent-to-agent dependency.

If memory approaches the container limit before the investigation completes,
use the documented `--reset` / `-Reset` trigger as an operator safety action,
record the intervention, and rehearse again. Do not describe that reset as
agent remediation.

### Step 18. Approve the remediation

**Expect** the agent to propose one or more of:

| Mitigation | Effect |
| --- | --- |
| Disable the leak flag and roll a healthy revision | **Durable** — removes the trigger |
| Restart the affected revision | Recoverable, but the fault returns while the flag is on |
| Increase the scale rule | Does not stop this timer-driven leak; each replica leaks independently |

**Do.** Review the proposed change and approve the durable fix: disabling the
flag and rolling a healthy revision. The Review-mode incident must show the
human approval gate before the Azure write. Do not approve a restart-only or
scale-only action as the durable remedy.

**Say.** "A restart clears the symptom. Turning the flag off removes the cause.
The agent distinguishes between the two."

### Step 19. Verify recovery

**Expect**, within a few minutes:

1. a new healthy revision is serving traffic;
2. memory returns to the baseline you screenshotted in step 6;
3. the Azure Monitor alert resolves;
4. the agent's incident record shows the evidence it used and the action it
   took.

Show all four. The recorded evidence trail is what makes this auditable rather
than magical.

Keep the same steady checkout traffic running and observe memory for at least
five minutes: it should remain near the healthy baseline, not resume its prior
upward slope. Check successful orders and observed latency/failure telemetry.
Add the SRE action/thread link and before/after evidence to the Azure Monitor
issue, then have a human resolve it. Alert auto-resolution does not imply the
Observability Agent resolves the issue automatically.

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
pattern it has already seen. Compare recorded results rather than promising
faster resolution or cross-agent memory sharing. Confirm that new alert
activity receives the expected issue/investigation treatment; do not assume
that the agent will always create a new issue rather than reuse related context.

---

## Phase 6 — Tear down

**First:** delete the portal-created Observability Agent, after recording any
issue evidence you want to retain. This stops background runs before removing
its prerequisites. If you created additional portal-owned action groups or
role assignments, remove those explicitly; do not delete shared monitoring
resources or the whole subscription's role assignments.

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

Terraform removes Scenario A's Azure Monitor workspace, dedicated identity and
its issue/monitoring role assignments. The workspace is the issue container;
export any required evidence before destroying it. The Observability Agent is
portal-owned and must not be left behind after its identity/workspace disappear.

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
| Alert fires but no Observability issue appears | Wrong monitored application/identity, permissions still propagating, disabled issue creation, or alert not associated with the discovered topology | Verify step 12 and exact alert-name instructions; reset and stop the paired-agent demo if autonomous promotion cannot be established |
| Issue exists but no automatic investigation starts | Investigation is disabled or preview execution failed | Enable Investigation, inspect the agent's reported failure, reset and rehearse; a manual investigation is not equivalent |
| Workspace cannot be selected | Wrong subscription or agent region | Select the output's workspace and West Europe; the agent and workspace must share a region |
| SRE writes without an approval prompt | Incident uses Autonomous mode or another matching response plan | Reset, set the memory response plan to Review, and verify the incident mode before continuing |
| Agent has no telemetry to reason about | Logs connector missing | Redo [step 9](#step-9-connect-the-evidence-sources), item 2 |
| Agent proposes nothing | Response plan does not include the Sev2 alert | Redo [step 9](#step-9-connect-the-evidence-sources), item 4 |
| Push to `main` deploys nothing | `DEPLOYMENT_SCENARIO` is unset | Expected — this is the safe no-op state. Complete [step 5](#step-5-activate-push-deployment) |

---

## Reference: security and operating model

| Concern | Scenario A behaviour |
| --- | --- |
| Terraform profile | `scenario = "A"` |
| SRE Agent access | High; Contributor on the demo resource group only |
| SRE agent-level fallback | Autonomous |
| SRE memory-incident response plan | Review; human approval required for infrastructure writes |
| Observability Agent | Portal-owned; autonomous issue creation and Investigation enabled |
| Observability Agent scope | Scenario A Application Insights topology; Monitoring Reader on the subscription |
| Azure Monitor issue permissions | Issue Contributor on the dedicated Scenario A workspace |
| Deployment control endpoints | Public, protected by Azure RBAC and TLS |
| Deployment runner | GitHub-hosted, or the local wrapper |
| Code Access | Read-only source and commit correlation |
| GitHub write connector | None |
| Incident trigger | Direct update of the running `payment-service` |
| Evidence handoff | Operator copies issue findings into the Review-mode SRE incident |
| Remediation path | Direct Azure action after human approval |

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

- [Demo overview and scenario chooser](../README.md)
- [Deployment and state reference](deployment-reference.md)
- [Azure SRE Agent setup reference](sre-agent-setup.md)
- [Azure SRE Agent permissions](https://learn.microsoft.com/azure/sre-agent/permissions)
- [Azure SRE Agent run modes](https://learn.microsoft.com/azure/sre-agent/run-modes)
- [Create an Observability Agent in the portal](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-resource-create-portal)
- [Autonomous Observability Agent operations](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-autonomous-operations)
- [Observability Agent custom instructions](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-custom-instructions)
- [Azure Monitor issues](https://learn.microsoft.com/azure/azure-monitor/aiops/issues-overview)
- [Observability Agent preview regions and Terraform limitations](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-resource)
- [Container Apps ingress](https://learn.microsoft.com/azure/container-apps/ingress-overview)
- [Key Vault RBAC](https://learn.microsoft.com/azure/key-vault/general/rbac-guide)
