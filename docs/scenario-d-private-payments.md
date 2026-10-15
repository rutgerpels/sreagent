# Scenario D — payments fail, checkout fails with them

> **Current setup: Scenario D uses Bicep; live redesign validation is pending.**
> The approved target is manual Observability investigation → save issue →
> manual handoff → SRE Review-mode recovery after human approval. Autonomous
> issue creation remains **PAUSED / UNPROVEN**. Historical 2026-10-13 results
> below describe the deleted legacy Terraform/portal deployment, not the new
> Bicep environment. No successful new live rehearsal is claimed here.

Scenario D pairs the Azure Copilot Observability Agent with the Azure SRE Agent
on a private-network deployment, separate from Scenarios A, B and C. This page
is the operator script: follow it top to bottom during a rehearsal or a demo.
For the next demo, use the **manually initiated Observability investigation**
below. Autonomous troubleshooting is paused; do not wait for automatic issue
creation.

## The story in one minute

```text
traffic running -> fault armed -> payment returns 503 -> checkout returns 502
 -> payment + checkout alerts fire
 -> operator starts Observability investigation from the fired alert
 -> operator saves the investigation as an issue (no workload changes)
 -> operator pastes the evidence into the SRE Agent thread
 -> SRE Agent verifies, proposes PAYMENT_FAILURE_MODE=off
 -> human approves -> fresh healthy revision -> alerts resolve
```

| Agent | Role | Writes? |
| --- | --- | --- |
| Observability Agent | Investigates the payment-to-checkout failure chain after the operator starts it from an alert. The operator saves the report as an issue. | Issues and investigation records only; no workload changes |
| SRE Agent (Review mode) | Verifies the evidence itself, proposes the smallest fix, applies it after approval. | Only after approval |

The handoff is manual: you paste the findings into the SRE thread. It is not
native agent-to-agent communication, and you should say so on stage.

## What the fault is

`payment-service` reads `PAYMENT_FAILURE_MODE` (`off` or `unavailable`). When
`unavailable`, `POST /pay` returns 503 and `checkout-api` maps that to 502 for
the frontend. Health and readiness probes stay green, so the app looks "up"
while every order fails. Bicep's desired state is always `off`; the trigger
is a temporary live deviation.

## Environment reference

Replace the names below if the deployment suffix changed. The suffix is deterministic for subscription + profile + lifecycle generation.
Use the deployment outputs, not names from a historical rehearsal.

| Item | Value |
| --- | --- |
| Subscription | Operator-selected demo subscription; never commit its ID or identifying name |
| Region | `swedencentral` |
| Resource group | `rg-payd-demo-d-<suffix>` |
| Frontend (public) | `ca-frontend-d-<suffix>` |
| Checkout API (internal) | `ca-checkout-d-<suffix>` |
| Payment service (internal) | `ca-payment-d-<suffix>` |
| Alerts | `alert-payment-failures-d-<suffix>`, `alert-checkout-failures-d-<suffix>` |
| SRE Agent | `sre-payd-d-<suffix>` (High access, Contributor, Review mode) |
| Runner | `vm-payd-runner` in `agentrg-d` (private runner, retained Terraform foundation; outside workload cleanup) |

## Part 0 — Preflight (before the clock)

1. **Select the subscription and find the names.**

   ```powershell
   az account list --output table
   $id = Read-Host -Prompt "Subscription ID for the demo"
   az account set -s $id
   $owner = 'scenario-d-payd-demo-d-bicep1'
   $o = (az deployment sub show -n $owner --query properties.outputs.ownership.value -o json | ConvertFrom-Json)
   $rg = $o.resourceGroupName
   $suffix = $o.stem.Substring(2)
   az containerapp list -g $rg --query "[].name" -o tsv
   ```

2. **Check the frontend answers and the fault is off.**

   ```powershell
   $fe = az containerapp show -g $rg -n "ca-frontend-d-$suffix" --query "properties.configuration.ingress.fqdn" -o tsv
   (Invoke-WebRequest "https://$fe" -UseBasicParsing).StatusCode   # expect 200
   az containerapp show -g $rg -n "ca-payment-d-$suffix" --query "properties.template.containers[0].env[?name=='PAYMENT_FAILURE_MODE']" -o json   # expect "off"
   ```

3. **Check both alerts exist** in the portal under the resource group
   (Alerts, Alert rules), or with `az resource list -g $rg`.
4. **Make sure you can open the SRE Agent.** The portal needs a data-plane role
   that Owner and Contributor do not give. Bicep only grants it to the
   deployer, so assign it to yourself after every deploy:

   ```powershell
   $me = az ad signed-in-user show --query id -o tsv
   $scope = az resource list -g $rg --resource-type Microsoft.App/agents --query "[0].id" -o tsv
   az role assignment create --assignee-object-id $me --assignee-principal-type User --role "SRE Agent Administrator" --scope $scope
   ```

   Sign out and back in, then wait a few minutes for the role to propagate.
5. **Make sure the SRE Agent is running, then open its thread.** If the agent
   is Stopped, start it before the demo clock; no redeployment is needed.
   Open <https://sre.azure.com>, select `sre-payd-d-<suffix>`, and confirm
   Review mode. Start a new thread for this run so the evidence stays clean.
6. **Inspect the Bicep-provisioned Observability resource.** In the portal,
   **Observability Agents** contains `oba-d-<suffix>` in West Europe, attached
   to `amw-observability-d-<suffix>` in that same region. Its operations are
   intentionally disabled (`enabled=false`); the monitored Application Insights
   resource is in Sweden Central, in the same subscription, with
   `isAutonomous=false`. This resource is not the entry point for on-demand
   investigation. Do not create a competing portal-owned agent or enable Auto
   for this dry-run.
7. **Choose the issue workspace explicitly.** Use the deployment output
   `amwId` when saving the on-demand investigation. The lifecycle does **not**
   change `Microsoft.Monitor/settings/default` or overwrite a pre-existing
   subscription association. If the preview UI demonstrably requires a default
   association, stop and document that blocker with the operator; do not
   silently change global settings. AMW is the issue container; LAW is not.
8. **Keep these tabs open:** Azure portal alert list, Application Insights Live
   Metrics or Failures blade, the SRE Agent thread, and **Monitor > Issues**.
   The AMW also shows its own issues; the LAW does not have an Issues blade.

### Optional email notification check

The shared action group `ag-sre-d-<suffix>` can notify the operator when the
payment and checkout alerts fire or resolve. This is a useful visible check
of alert routing. It is not a documented prerequisite or an email-based
trigger for autonomous Observability Agent investigations: the agent monitors
in-scope fired alerts itself.

Keep the recipient out of committed files. With `$rg` and `$suffix` set, add
an email receiver using the common alert schema:

```powershell
$email = Read-Host -Prompt "Operator email for demo alerts"
az monitor action-group update -g $rg -n "ag-sre-d-$suffix" --add-action email demo-email $email usecommonalertschema --output none
```

If `demo-email` already exists, inspect its configuration instead of adding it
again. Confirm that both failure alert rules reference this action group.
Complete any email verification requested by Azure in the portal; an
unverified recipient might not receive alert or test notifications.

Alert notifications and issue notifications are separate configurations:

| Notification | Action-group association | Trigger |
| --- | --- | --- |
| Payment/checkout alert email | Each failure alert rule | The alert fires or resolves. |
| Observability issue email | Default action groups on the agent's Azure Monitor workspace | An issue is created, or its severity/status changes. |

To enable the second path, open the Bicep-provisioned agent's **Operations**
blade. Under **Notifications**, select **Add action group to workspace**,
choose the existing `ag-sre-d-<suffix>` group, and save the association.
Refresh the blade and confirm the group appears instead of **None**.
Adding an email receiver to the group, or attaching the group to alert rules,
does not establish this workspace association.

Microsoft labels workspace issue notifications optional. They are an output
of issue creation and updates, not a documented prerequisite for the agent
to detect alerts or create issues. A missing workspace association does not
explain missing emails from correctly configured failure alert rules.

Use the action group's **Test** feature with **Log Alert V2**, select the email
receiver, and confirm actual test-alert receipt. A receiver-added confirmation
is not proof of alert delivery. Afterward, start the real fault from a healthy
baseline with the previous alert instances Resolved.

This optional CLI change is live configuration, not Bicep desired state.
A later D Bicep deployment can remove it; reconfigure the receiver afterward
if needed. Do not redeploy during an isolated agent comparison. Terraform is
not an owner of the new D workload.

Microsoft references: [Action groups](https://learn.microsoft.com/azure/azure-monitor/alerts/action-groups),
[Observability Agent portal configuration](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-resource-create-portal#configure-agent-operations-operations-tab),
[Azure Monitor issue actions](https://learn.microsoft.com/azure/azure-monitor/aiops/issues-overview#issue-actions),
and [Observability Agent autonomous operations](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-autonomous-operations).

## Part 1 — Start healthy traffic

Traffic must be flowing **before** the clock starts, so the alerts have data
and the baseline is visible. The script needs the frontend URL.

Run this in the same terminal as Part 0, or set `$rg` and `$fe` again first. An
empty `$fe` fails with "Frontend URL must use https."

```powershell
az account list --output table
$id = Read-Host -Prompt "Subscription ID for the demo"
az account set -s $id
$owner = 'scenario-d-payd-demo-d-bicep1'
$o = az deployment sub show -n $owner --query properties.outputs.ownership.value -o json | ConvertFrom-Json
$rg = $o.resourceGroupName
$suffix = $o.stem.Substring(2)
$fe = az containerapp show -g $rg -n "ca-frontend-d-$suffix" --query "properties.configuration.ingress.fqdn" -o tsv
$fe   # must print the frontend host name, not blank
pwsh ./scripts/generate-checkout-traffic.ps1 -FrontendUrl "https://$fe" -DurationSeconds 2700
```

```bash
./scripts/generate-checkout-traffic.sh --url "https://$FE" --duration 2700
```

Leave it running in its own terminal for the whole rehearsal. It stops by itself
after 2700 seconds (45 minutes); if it stops before you arm the fault, the
alerts never fire, so restart it first. Wait about 2 minutes, then show the
healthy baseline:

- **Where:** Azure portal, resource group `rg-payd-demo-d-<suffix>`, Application
  Insights `appi-d-<suffix>`, **Investigate, Failures** (or **Live metrics**).
- **Which app:** the role `checkout-api` (container app `ca-checkout-d-<suffix>`).
  Set the **Roles** filter to `checkout-api`. It is the service the traffic
  script ends up calling through the frontend, and its `/checkout` requests are
  what the checkout alert watches.
- **Healthy looks like:** requests are flowing and failed requests are 0. Later,
  switch the filter to `payment-service` (container app `ca-payment-d-<suffix>`),
  whose `/pay` requests are what the payment alert watches.
- **Not these:** the health and ready probes, which the alerts ignore.

**Say:** "ContosoPay checkout is healthy. Frontend is the only public endpoint;
checkout and payment are internal."

## Part 2 — Trigger the incident (T0)

Arm the fault on the live payment app. Note the time. Use a second terminal (the
first one is running the traffic), so set the variables again.

```powershell
az account list --output table
$id = Read-Host -Prompt "Subscription ID for the demo"
az account set -s $id
$owner = 'scenario-d-payd-demo-d-bicep1'
$o = az deployment sub show -n $owner --query properties.outputs.ownership.value -o json | ConvertFrom-Json
$rg = $o.resourceGroupName
$suffix = $o.stem.Substring(2)
az containerapp update -g $rg -n "ca-payment-d-$suffix" --set-env-vars PAYMENT_FAILURE_MODE=unavailable
Get-Date -Format "HH:mm:ss"   # write down as T0
```

Use the explicit `az` command above for the Bicep environment. The old
`trigger-incident-payments.*` wrappers read legacy Terraform state and must not
be used for this setup. The flag is read at startup, so the environment update
rolls a new revision; wait for that revision before expecting failed orders.
Only arm the incident deliberately after the healthy deployment dry-run.

**Say:** "A dependency change just broke payments. Health checks are still
green, but every order will fail."

## Part 3 — Alerts fire

Historical legacy rehearsal observations (not verified timing for the new Bicep setup; five-minute evaluation frequency):

| Moment | What you see |
| --- | --- |
| T0 + about 2 min | `alert-payment-failures-d-<suffix>` fires |
| T0 + about 3.5 min | `alert-checkout-failures-d-<suffix>` fires |

Watch the alert list in the portal. The enabled D incident filter
`contosopay-payment-failures` matches only the exact deployed
`alert-payment-failures-d-<suffix>` name through `titleContains`, with Sev2 and
**Review** mode. It can automatically start SRE diagnosis for that payment
alert, not for the checkout alert or unrelated subscription incidents. Workload
writes still require human approval. Autonomous **Observability** remains
paused; continue its on-demand investigation and manually paste the evidence
into the SRE payment-alert thread (or a new manual thread if pickup is delayed).

**Say:** "Two alerts, one cause. The checkout alert is a downstream symptom of
the payment alert."

## Part 4 — Observability Agent investigates

1. Open the new **payment-failure alert** in **Monitor > Alerts** and select
   **Investigate**. Confirm the proposed resource scope and UTC impact window,
   then confirm that the investigation should begin.
2. Show the investigation's progress, evidence, hypotheses, and recommended
   next steps. It runs under the signed-in user's permissions. Describe this
   honestly as a **manually initiated investigation**, not autonomous pickup.
3. Save the completed investigation as an Azure Monitor issue in
   `amw-observability-d-<suffix>`. This preserves the report and supporting
   context. Do not use the Log Analytics workspace as the issue container.
4. Open the saved issue in **Monitor > Issues**, or the AMW's **Issues** view,
   and copy its URL, UTC time window, affected resources, and actual findings
   for Part 5. Do not filter for an assumed automatic title prefix.

**Say:** "The Observability Agent writes an investigation record, not a fix.
I started this investigation manually. It explains the evidence and suggests
causes; it does not change the app."

For a short session, keep the previously saved manual investigation available
as a fallback. If you show it, label it as a previous rehearsal and keep its
original time window; do not present it as this run's live result. There is no
verified completion-time guarantee for a fresh investigation.

Microsoft's [deep investigation guide](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-deep-investigations)
documents the alert entry point, scope confirmation, and saving the report as
an issue. Autonomous processing remains a separate, unverified path; see
[Observability diagnostics](#observability-diagnostics).

## Part 5 — Hand over to the SRE Agent

In the SRE payment-alert thread (automatic Review-mode diagnosis), or a new
manual thread if no pickup occurred yet, paste the handoff prompt from
[`agent/scenario-d/handoff-prompt.md`](../agent/scenario-d/handoff-prompt.md)
with the placeholders filled in:

```text
The Azure Copilot Observability Agent investigated this incident and produced
the findings below. Treat them as a hypothesis: verify them before proposing
a change.

Issue: <observability issue URL>
Time window: <start UTC> to <end UTC>
Resources: <payment-service, checkout-api, frontend, resource group>
Findings: <paste the Observability Agent summary>
Impact: <failed /checkout requests and the fired checkout alert>

Please confirm the root cause with your own queries, propose the smallest safe
fix, and wait for my approval before changing anything.
```

Do not paste secrets or subscription IDs.

**Say:** "I carry the evidence across by hand. The SRE Agent does not trust it
blindly; it checks the telemetry itself."

## Part 6 — SRE Agent verifies and proposes

Watch the thread. Expect the SRE Agent to:

1. Query Application Insights and confirm `payment-service` returns 503 on
   `/pay` and `checkout-api` returns 502.
2. Inspect the payment Container App and find `PAYMENT_FAILURE_MODE=unavailable`
   as the deviation from the healthy state.
3. Propose the smallest fix: set `PAYMENT_FAILURE_MODE=off` on the payment app.

Nothing changes yet. In Review mode the write waits for you.

**Say:** "Review mode: the agent can diagnose freely, but any change to
production waits for a human."

## Part 7 — Approve and recover

1. Read the proposed action and confirm it changes only `PAYMENT_FAILURE_MODE`.
2. Approve it in the thread.
3. The Container App rolls a fresh revision. Wait for the new revision to be
   ready and for the traffic script to show successes again.
4. Confirm the alerts resolve in the portal. With the current five-minute
   frequency, stateful log alerts require the condition to remain unmet for
   three frequency periods, not just one evaluation. Allow roughly 15-20
   minutes, including the query window and ingestion delay; the rehearsal
   observed about 18 minutes. This is separate from time to successful
   requests. See [alert resolution semantics](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-overview#alerts-and-state).
   An alert can also resolve after traffic stops, so resolution without fresh
   successful checkout requests is not proof of recovery.

```powershell
az containerapp show -g $rg -n "ca-payment-d-$suffix" --query "properties.template.containers[0].env[?name=='PAYMENT_FAILURE_MODE']" -o json   # expect "off"
```

**Say:** "From alert to approved fix, with the evidence from two agents and one
human decision."

## Part 8 — Reset for the next rehearsal

Recovery already sets the flag to `off`. To reset manually (for example if you
stopped before approving):

```powershell
az containerapp update -g $rg -n "ca-payment-d-$suffix" --set-env-vars PAYMENT_FAILURE_MODE=off
```

Stop the traffic script. Close the old SRE thread and start a new one for the
next run. Wait for the alerts to resolve before arming again.

A later D Bicep deployment restores the healthy flag (`off`); it never rearms
the incident. Do not run Terraform against the D workload.

## If something goes wrong

| Symptom | Check |
| --- | --- |
| No payment alert after 6 minutes | Is traffic running? The alert needs 3 or more failed `/pay` calls in the window. Check `PAYMENT_FAILURE_MODE` really is `unavailable`. |
| Payment alert fired but SRE Agent did nothing | Verify the enabled Review-mode filter has `titleContains` equal to this deployment's exact payment-alert name. Checkout/unrelated Sev2 alerts intentionally do not match. If pickup is delayed, use the manual handoff; never broaden the filter to all subscription incidents. |
| No Observability Agent issue | Follow [Observability diagnostics](#observability-diagnostics). If using an on-demand investigation, label it manual; if skipping Observability, continue as an SRE-only run without claiming a paired handoff. |
| SRE thread shows no tool output | The SRE data plane cannot be read programmatically from here (403). Use <https://sre.azure.com> only. |
| Frontend returns errors before the trigger | Wait for the latest revision to be ready; re-run Part 0. |

## Observability Agent onboarding

`infra/scenario-d/agents.bicep` creates the requested Observability Agent using
Microsoft's `2026-05-01-preview` ARM/Bicep schema and a user-assigned identity.
It follows the supported template's **Monitoring Contributor on the single
AMW**, with **Monitoring Reader on the single Application Insights component**
for telemetry. No OBA subscription-wide grant is introduced. AMW and OBA share
West Europe; monitored Application Insights and SRE/workloads use Sweden
Central in the same subscription. The two location parameters are separate.

`enabled=false` gates the documented `Auto` operations, and the monitored
resource has `isAutonomous=false`. On-demand investigation requires no agent
resource; we nevertheless provision this resource because the user requested
it. Provisioning is not evidence of autonomous processing. Do not invent a
`Manual` enum or weaken RBAC to work around an unverified preview flow.

Sources: [supported template and UAMI/RBAC example](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-resource-create-template),
[portal creation and regional constraints](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-resource-create-portal),
[governance](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-governance-faq).

## Observability diagnostics

There are two separate experiences. **Observability Agents** manages the
autonomous resource and its configuration. Interactive investigation opens from
an alert or an issue; it is not a separate site like `sre.azure.com`.

| Surface | What it proves |
| --- | --- |
| Agent resource and Operations configuration | Identity, target, enabled operations and stored instructions; not successful execution. |
| Monitor > Issues, or the AMW's Issues view | Persisted issue output. Open Background and Investigation to inspect reasoning and progress. |
| Monitor > Alerts > fired alert > Investigate | Starts an on-demand investigation under the signed-in user's permissions, not the autonomous managed identity. |
| Azure Activity Log | Agent configuration changes only. Autonomous correlation and investigation runs are not emitted here in preview. |
| Microsoft Entra managed-identity sign-in logs | Authentication attempts by the agent identity. Success does not prove that correlation ran, telemetry queries were authorized, or an issue write succeeded. |

The live diagnostic-settings API also returned `ResourceTypeNotSupported` for
`Microsoft.Monitor/observabilityAgents`. Do not promise a LAW execution-log
table or a diagnostic setting for this agent.

To distinguish an empty issue store from portal filtering, use this read-only
check after Part 0. An error is a failed check, not an empty result. Follow
`nextLink` if the API returns one.

```powershell
$amwId = az resource show -g $rg -n "amw-observability-d-$suffix" --resource-type Microsoft.Monitor/accounts --query id -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($amwId)) {
    throw 'Could not resolve the Azure Monitor workspace.'
}
az rest --method get --url "https://management.azure.com${amwId}/issues?api-version=2025-10-03-preview"
if ($LASTEXITCODE -ne 0) {
    throw 'Could not read the workspace issue list.'
}
```

> **Historical evidence only — legacy Terraform/portal environment.** All
> comparisons and commands in the dated sections below refer to the old
> deployment deleted before this redesign. Do not replay their permission
> changes, workspace association, portal-agent creation or Terraform commands
> against the new Bicep environment. The active lifecycle follows afterwards.

### Findings from 2026-10-13

All clock times here are local UTC+02:00.

| Check | Observed result |
| --- | --- |
| Fresh fault and alerts after the workspace association was fixed | T0 11:00:13; checkout alert 11:02:31; payment alert 11:03:11. |
| SRE pickup | Confirmed by the operator; precise pickup time and proposal not captured. |
| Issue store | Successful API read at 11:22 returned `value: []` and no next page. Not merely a portal filter problem. |
| Autonomous configuration | Agent enabled; IssueCreation and Investigation both Auto; instructions present; target App Insights enabled and autonomous in the same subscription. |
| Alert targets | Both Log Alerts V2 target the monitored Application Insights resource; both remained Fired during the initial observation. |
| Baseline identity roles | Monitoring Reader on the subscription and Issue Contributor on the AMW, matching the portal and template prerequisite lists. |
| Query networking and data | Public telemetry queries enabled; operator queries read failing requests from all three services. This does not prove the autonomous identity's runtime access. |
| Managed-identity authentication | Ten successful sign-in records and no failures in the queried interval. ARM sign-ins at 10:59:08 and 11:09:04 identified the Observability Agent resource as their source. |
| Query audit evidence | LAW query auditing was not configured and LAQueryLogs contained zero records. This does not establish that the agent made no queries. |
| Manual investigation and issue | The operator saved an issue at 11:38:18. Its investigation result records `origin.addedByType = "Manual"`; this proves the on-demand path, not autonomous operation. |
| Dependency telemetry | Zero dependency records in the preceding 24 hours. A separate one-hour request sample had 1,842 operation IDs and zero spanning multiple service roles. |

The stored prompt follows Microsoft's supported examples: always promote the
named alert rules, explain the checkout/payment relationship, and include
`[OPS-REVIEW]` in titles. Single-alert promotion is explicitly supported; it
does not require the operator to start an investigation. No documented prompt
error was identified. Custom instructions apply to future correlations and
cannot grant permissions.

At the time of these initial checks, the dependency gap prevented us from
demonstrating a complete distributed request chain. The frontend and checkout
use native `fetch`, which uses Undici rather than the Node HTTP module covered
by the Azure Monitor distro's default instrumentation. Missing dependency data
was a correlation-quality problem, not a proven explanation for the lack of
single-alert issues.

Both services now explicitly register
[Undici instrumentation](https://github.com/open-telemetry/opentelemetry-js-contrib/tree/main/packages/instrumentation-undici)
against the existing Azure Monitor tracer provider. This adds outgoing
dependency spans and propagates distributed context without replacing the
exporter or changing managed-identity ingestion. Service images use the
committed lockfiles with `npm ci`. Offline regression checks cover successful
and failed fetches, exact parent-child propagation, and telemetry-disabled
behavior.

For live readiness, verify both `frontend -> checkout-api` and
`checkout-api -> payment-service` in Application Insights. Join a dependency's
`id` to the downstream request's `operation_ParentId` and require the same
`operation_Id`; dependency counts alone do not establish a connected trace.
The updated images produced 31 linked healthy operations on each hop during
the preparation for the final comparison.

Microsoft's RBAC documentation is inconsistent: the portal and template
prerequisites list Issue Contributor on the AMW plus subscription Monitoring
Reader, whereas the resource reference, governance FAQ and template example
also call for Monitoring Contributor on the AMW. No autonomous authorization
error was exposed in these checks. The controlled comparison below did not
establish that the extra role fixes the problem. Do not grant broad
subscription Contributor or weaken telemetry authentication speculatively.

### Controlled workspace-permission comparison

With operator approval, Monitoring Contributor was added directly to the
Observability identity on the demo AMW only. After more than ten minutes for
RBAC propagation, bounded traffic restarted against the still-armed fault.
The prior alert instances were Resolved before this traffic began. The
prompt, target, autonomous operations, existing manual issue and SRE
configuration were not changed.

| Event | Local time (UTC+02:00) / result |
| --- | --- |
| Temporary AMW role added | 12:10:18 |
| Fresh failing traffic started | 12:20:30 |
| New checkout alert fired | 12:22:37 |
| New payment alert fired | 12:23:02 |
| Agent-sourced ARM authentication | 12:24:04; successful |
| Telemetry checkpoint | Fresh payment 503s and checkout 502s confirmed in Application Insights. |
| Traffic completed | 12:35:32; 172 failed frontend requests, zero successes. |
| Final issue API check | 12:35:48; only the original manual issue, unchanged, with its original investigation. No next page. |
| Temporary role removed | 12:36:33; original Monitoring Reader and Issue Contributor assignments verified. |

There was no autonomous issue or new investigation more than twelve minutes
after the later alert. Both new alerts were Fired and Acknowledged. This
missed the demo timing target and showed no benefit from the extra permission
within the observation window; it does not rule out every authorization or
service-side caching problem. The stored prompt was compared before and
after the run and was unchanged. Stopping traffic did not recover the app:
`PAYMENT_FAILURE_MODE` remained `unavailable`.

### Completed isolated portal-agent and alert-email comparison

The final completed comparison used the Bicep-provisioned agent with the
operator's two short custom instructions unchanged and both operations Auto.
The old Terraform agent's monitored target was removed; its parent remained
Manual. Both SRE agents stayed Stopped, so they could not acknowledge the new
alerts or recover the fault during observation.

Before the trigger, live telemetry showed 72 correctly linked operations on
each service hop in the preceding ten minutes. Monitoring Contributor was
temporarily assigned at subscription scope, Microsoft's documented alternative
to separate read and issue permissions. Healthy traffic continued for ten
minutes for propagation and learning. Both latest alerts were stably Resolved,
and the preceding fifteen-minute query contained zero failures.

The operator added an email receiver to the shared action group, using the
common alert schema, and confirmed actual test-alert receipt. Both failure
rules referenced that group. An earlier attempt was interrupted during its
fault update to accommodate this email addition; it was recovered and its
temporary permission removed, and is not counted as a completed trial.

**Times in this table are UTC.**

| Event | Time / result |
| --- | --- |
| Temporary subscription role added | 16:43:23 |
| Single final fault update requested | 16:54:51 |
| First frontend 502 | 16:55:46 |
| Fresh checkout alert | 16:57:35; Fired/New |
| Fresh payment alert | 16:57:57; Fired/New |
| Observation completed | 17:15:59; 139 frontend failures, zero successes during the fault. |
| Issue and investigation comparison | Only the original manual issue, unchanged, with its original single investigation. No autonomous issue or new investigation. |
| Real failure-alert email receipt | Operator reported none by the end-of-run check, despite receiving the earlier test email. |
| Healthy checkout restored; fault flag off | 17:17:27 |
| Temporary subscription role removed | 17:17:35; original Monitoring Reader and workspace Issue Contributor verified. |

Both alert instances were genuinely new and fired after the deliberate
trigger, unlike the earlier timing-anomalous rearm. Application Insights
confirmed sustained payment 503s and checkout/frontend 502s. At the
notification checkpoint, both alerts reported `isSuppressed = false`,
both rules had no mute duration, and the subscription inventory contained no
alert processing rules. Those checks establish configured routing and no
observed suppression, not successful mailbox delivery.

Adding alert-rule email configuration did not restore autonomous issue creation
within this window. The workspace's separate default action-group association
had not been configured: the agent's Notifications panel still showed **None**.
The completed run therefore did not test workspace issue notifications.
Real alert-email delivery is an additional unresolved symptom;
the successful test message does not prove the real-alert dispatch path.
Neither result establishes that email is required by the Observability Agent
or that the two symptoms share a cause. The comparison changed several
preconditions together and cannot isolate a single causal fix.

The trace fix remains deployed, the email receiver remains configured, and
the old monitored target remains absent. Build-only registry permission and
isolated runner authentication artifacts were also removed. The application
is healthy; stateful alert resolution follows its evaluation cadence rather
than the instant the fault flag is cleared. Further investigation should use
backend support tracing, not another speculative retrigger.

### In-place rerun with workspace issue notifications

The operator subsequently associated the same action group with the Azure
Monitor workspace. A live workspace read using `2026-04-03-preview` confirmed
the group under `properties.actions.defaultActionGroups`, and the email
receiver remained enabled. This completed the separate issue-notification
configuration missing from the previous comparison.

The requested rerun did not recreate infrastructure, initialize or apply
Terraform, rebuild images, edit either Observability Agent, or start either
SRE Agent. The same temporary subscription Monitoring Contributor comparison
was repeated, with ten minutes of healthy preparation. Both baseline alerts
were Resolved, recent failure telemetry was empty, and 71 operations were
correctly linked on each service hop before one deliberate flag update.

**Times in this table are UTC.**

| Event | Time / result |
| --- | --- |
| Temporary comparison permission added | 17:46:54 |
| Fault update requested | 17:57:41 |
| First frontend 502 | 17:58:52 |
| Fresh checkout alert | 18:02:38; Fired/New |
| Fresh payment alert | 18:02:58; Fired/New |
| Last uninterrupted issue checkpoint | 18:16:40; no new issue, no new investigation, original manual issue unchanged. |
| Traffic result before interruption | 122 frontend 502s, zero successful requests during the fault. |
| Interruption | Client DNS resolution failed near minute eighteen, before the planned twenty-minute cutoff. |
| Temporary comparison permission removed | 18:17:24; original runtime roles restored. |
| Independent recovery confirmation | Existing runner returned three checkout HTTP 200s at 18:20:55, 18:20:58, and 18:21:01. Payment flag verified off. |
| Final state comparison | 18:23:43; workspace group still associated, portal operations unchanged, both SRE agents Stopped, no new issue. |

Both alert instances postdated the trigger and targeted the expected
Application Insights resource at severity 2. Direct reads of
`properties.essentials.actionStatus.isSuppressed` returned false. The
operator reported no real failure-alert email at the ten-minute checkpoint;
final mailbox delivery was not independently verified.

The DNS error also interrupted the initial local HTTP recovery check,
although the reset command succeeded. Recovery was subsequently verified
from the existing runner without another fault trigger or environment change.
The frontend hostname and revision were unchanged; the cause of the client
DNS failure was not established.

This was an **interrupted, approximately eighteen-minute observation**, not
another completed twenty-minute comparison. It still missed the desired
five-to-ten-minute autonomous-response target. Associating the workspace
group did not produce an observable autonomous issue during this attempt;
it does not establish the underlying cause of missing issue creation or
real-alert email delivery.

**Remaining diagnostic boundary:** sign-in success proves authentication,
not completion of the correlation-to-issue path. The public preview does not
expose its execution history through Activity Log. Escalate to Azure support
with the agent and target resource IDs, fresh alert instance IDs, UTC times,
identity assignments, sign-in evidence and unchanged issue-store results.
Ask whether those alerts entered correlation, whether resource knowledge
initialization completed, and whether any subsequent operation was denied.
Do not assert that alert acknowledgement, missing dependency spans, or a
service defect caused the failure without backend evidence.

Include the provisioning method in that escalation: this repository uses
Terraform AzAPI with the documented preview ARM API, while Microsoft lists
only portal and ARM/Bicep templates as supported provisioning surfaces.
That is a supportability difference, not proof of the runtime cause.
Manual investigation remains a useful fallback but cannot validate the
autonomous flow.

Sources checked:

- [Autonomous operations](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-autonomous-operations)
- [Supported custom instructions](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-custom-instructions)
- [Portal setup and identity requirements](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-resource-create-portal)
- [Template identity requirements and examples](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-resource-create-template)
- [Resource reference and audit limitations](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-resource)
- [Governance FAQ](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-governance-faq)
- [Managed-identity sign-in queries](https://learn.microsoft.com/entra/identity/monitoring-health/howto-analyze-activity-logs-with-microsoft-graph#sample-sign-in-queries)
- [Role-assignment propagation](https://learn.microsoft.com/azure/role-based-access-control/troubleshooting#azure-role-assignments)
- [Deep investigation entry points](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-deep-investigations)
- [Issue workspace association and review](https://learn.microsoft.com/azure/azure-monitor/aiops/issues-how-to)

## Deploy, restart and teardown

### Deployment from the feature branch

D is **Bicep-only**. A/B/C still use Terraform, and `infra/runner-d` remains
Terraform-managed and retained. There is no Terraform state migration: the old
D app RG was deleted, and the old purge-protected vault may remain soft-deleted
until its retention expires. A fresh deterministic Bicep generation avoids
that vault name. Grafana is not provisioned by default.

The already-dispatchable workflows route D to reusable
`scenario-d-bicep.yml`, so the initial run needs no merge to `main`:

```powershell
gh workflow run deploy.yml --ref rutgerpels-scenario-d-bicep-redesign `
  -f scenario=D -f prefix=payd -f environment=demo -f location=swedencentral `
  -f scenario_d_generation=bicep1 -f open_incident_pr=false
```

After the new workflow is on the default branch it can also be dispatched
itself with `action=deploy`, `prefix=payd`, `environment=demo`,
`generation=bicep1`. Optional shared-zone IDs must already be linked to the
retained runner; otherwise the script discovers and reuses those associations.
No shared zone or pre-existing runner DNS link is taken over.

Stages, all on `[self-hosted, Linux, X64, azure-private-d, contosopay]` in the
`scenario-d` GitHub environment with OIDC. Before **every** Bicep deployment
create, the IO runs the matching subscription/group `what-if` with the same
template, parameter file, name, scope and location. Failed/error previews stop
before create. Logs show only change types/resource IDs, never secret-bearing
properties. This also applies to the safe ownership-ledger snapshot update
before cleanup begins. All D profiles share one global retained-runner/VNet
concurrency lock, not a per-prefix lock, because the CIDR and one-D invariant
are runner-wide.

1. Subscription ownership ledger + tagged app RG; foundations: per-app/SRE/OBA
   identities, private Premium ACR, RBAC/purge-protected private KV, VNet,
   private endpoints/DNS and peering, LAW + Entra-only Application Insights,
   AMW, Container Apps environment and platform diagnostics.
2. Probe actual private endpoints with bounded RBAC/DNS retries. Write the AI
   connection string into KV from a mode-0600 temporary file, then remove it;
   no plaintext secret output/artifact or secret app environment variable.
3. Build images from the current checkout on the runner, push full SHA tags,
   lock tags/manifests against writes/deletes and validate exact digests. Then
   run `scripts/tests/scenario-d-container-smoke.sh` against those SHA images:
   healthy checkout through all three containers on a temporary isolated Docker
   network, with no host ports or telemetry. Smoke failure stops before Azure
   app deployment; cleanup belongs to the smoke script. No `latest`, bootstrap
   image, mutable placeholder, or public ACR fallback.
4. Deploy apps with `PAYMENT_FAILURE_MODE=off`, `ENABLE_SLOW_LEAK=false`,
   external HTTPS frontend only and internal backends. Verify real
   `POST /api/checkout` with `amount=42,currency=EUR`, HTTP success and a
   confirmed order containing an approved payment (not merely `/health`).
5. Deploy paused OBA + High/Contributor/Review SRE with an explicit monthly
   agent-unit limit of 500 (the live service rejects nonzero limits below 500);
   exact documented SRE
   Monitoring Contributor subscription exceptions for action/system identities;
   connectors + five-minute failure alerts. Reuse the reconciler to install
   payment-recovery and approval-only write policy. Enable only the D payment
   filter in **Review** mode, binding `titleContains` to `paymentFailureAlertName`
   from the actual connectors/alerts deployment output. Missing/invalid scope
   fails closed; no unrelated Sev2 subscription pickup. No scheduled tasks are
   configured. Verify reconciliation and real checkout again. Deployment never
   triggers the incident; OBA remains disabled.

Before SRE data-plane reconciliation, the GitHub job obtains a fresh OIDC
assertion and signs in again as the **same** deployment principal, then acquires
the SRE audience token. The initial assertion can expire during private
foundation/image/agent provisioning even while ARM's cached access token is
valid. This refresh uses GitHub's existing `id-token: write` permission and
`api://AzureADTokenExchange` audience, never a stored credential; see
[OpenID Connect reference](https://docs.github.com/en/actions/reference/security/oidc).
Missing refresh credentials, failed authentication, or an identity change
stops reconciliation.

The replacement delivery branch supersedes the earlier Scenario D PR without
closing it automatically. It preserves the original private-payments baseline
and native-fetch dependency tracing fixes.

Subscription-level ownership templates pass both the subscription and resource
group explicitly to `resourceId`; see Microsoft's
[Resource functions for Bicep](https://learn.microsoft.com/azure/azure-resource-manager/bicep/bicep-functions-resource#resourceid).
Ownership validation compares the exact ordered resource paths and cardinality,
not Azure CLI's added `resourceGroup` presentation metadata. Neither correction
permits taking over a foreign resource or deleting the retained runner.

Native preview resources avoid Terraform's unsupported OBA read/destroy path.
Pinned AVM modules cover identities, VNet, ACR, KV, private endpoints and apps.
Native LAW/AI/environment declarations avoid the pinned AVM interfaces that
output telemetry credentials or unconditionally call workspace `listKeys`.
There are no Log Analytics shared-key settings and local auth stays disabled.

### Discover outputs (safe to print)

```powershell
$owner = 'scenario-d-payd-demo-d-bicep1'
$o = az deployment sub show -n $owner --query properties.outputs.ownership.value -o json | ConvertFrom-Json
$rg = $o.resourceGroupName
az deployment group show -g $rg -n scenario-d-apps --query properties.outputs.frontendUrl.value -o tsv
az deployment group show -g $rg -n scenario-d-agents --query properties.outputs.agents.value -o json
```

Keep the same prefix/environment/generation across retries. If a cleanup
snapshot exists, finish destroy before redeploy. An interruption after the
ledger/RG exists but before one or both owned DNS runner links exist is
resumable: foundations recreate absent owned zones/links after validating any
existing zone/link owner tags and VNet targets. A foreign association is
rejected; reused external zones must retain their exact existing runner link.
A new generation is for a new
lifecycle **after** complete cleanup, especially while a KV name is retained
by soft deletion. Ordinary incremental Bicep does not delete omitted resources.

### Explicit complete teardown

```powershell
gh workflow run destroy.yml --ref rutgerpels-scenario-d-bicep-redesign `
  -f scenario=D -f prefix=payd -f environment=demo `
  -f scenario_d_generation=bicep1 `
  -f scenario_d_confirm_destroy=scenario-d-payd-demo-d-bicep1 `
  -f force_delete_rg=false -f delete_state_storage=false
```

Direct new-workflow inputs are `action=destroy`, `prefix=payd`,
`environment=demo`, `generation=bicep1`,
`confirm_destroy=scenario-d-payd-demo-d-bicep1`. D rejects legacy Terraform
force/state-deletion, ephemeral and incident-PR flags.

The script checks account subscription/tenant, exact ownership output paths
and RG tags. It reads fresh principal IDs and grants **before any deletion**,
then writes a verified cleanup snapshot back to the subscription deployment.
It removes only deterministic exact external SRE assignments and the owned
runner→app peering, deletes the app RG and verifies actual absence, removes
only its app-VNet links in shared DNS zones, and verifies the platform-managed
infrastructure RG is gone. External deployment records and the ledger are
removed last. A timeout, ownership mismatch or unverifiable orphan fails the
job and retains the Azure ledger for retry after a runner restart; no
force-success orphan tolerance. Shared DNS zones, shared state storage and
all retained runner resources are never deleted. No global workspace setting
is changed, so there is no global association to undo.

The lifecycle **never deallocates its own execution VM**. After the job is
complete, the operator may separately deallocate `vm-payd-runner` in
`agentrg-d`. Do not delete its disk, VNet, NAT or Terraform backend.

### One-time operator setup

- Retain/start the existing runner `vm-payd-runner` in `agentrg-d`. Its VNet is
  `10.102.0.0/16` (`runner=10.102.0.0/27`,
  `private-endpoints=10.102.0.32/27`). The workload VNet is non-overlapping
  `10.101.0.0/16`; private endpoint, Container Apps and SRE subnets remain
  `10.101.0.0/27`, `10.101.0.64/27`, `10.101.0.96/27`.
- Configure `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` as
  environment/repository variables and use the `scenario-d` OIDC federation.
  No client secret or real IDs belong in source.
- The deployer needs workload provisioning + scoped role-assignment rights,
  rights to the exact retained-runner peering and any owned shared-zone links,
  subscription deployment rights and the documented SRE subscription grant
  exception. Do not use policy exemptions/auth fallbacks to make a run pass.
- Ensure Docker, Azure CLI, Node 20, Python 3, jq and git exist on the runner.
  The workflow installs pinned Bicep `v0.48.1` and runs build/lint before work.
- `scenario-d.tfvars.example` is historical reference only, not the active
  deployment path. Push workflows still support only A/B/C; validation includes
  D offline tests and template builds but does not deploy it.

## Rehearsal log

Fill this in while you rehearse. Target: alert to recovery in 10 minutes or less.

| Step | Clock time | Elapsed from T0 |
| --- | --- | --- |
| T0: fault armed | | 0:00 |
| Payment alert fired | | |
| Checkout alert fired | | |
| Observability Agent issue appeared | | |
| Handoff pasted into SRE thread | | |
| SRE Agent proposal shown | | |
| Fix approved | | |
| New revision ready, traffic healthy | | |
| Alerts resolved | | |

## Not verified yet

- Autonomous Observability Agent pickup time and issue quality.
- New Bicep live deployment/teardown and manual paired-agent proposal/recovery times.
- Autonomous issue creation: the workspace-role comparison did not restore
  it; the current root cause is not established.
- Three consecutive clean paired rehearsals.
