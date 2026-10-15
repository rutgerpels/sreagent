# Scenario D — opt-in autonomous Observability acceptance

This is an **opt-in, default-off** addition to the healthy Bicep baseline.
The first live test verified deployment and ordinary alert email, but failed
autonomous issue/investigation acceptance; see the dated evidence below.
It is not hybrid/country functionality. Legacy D deployment entry
points keep OBA paused; A/B/C, the retained runner, SRE Review mode, global
write-tool `ask`, exact payment-alert filter and no schedules are unchanged.

In this separate test OBA is expected to independently correlate alerts, create
an issue, and automatically deep-investigate **its own agent-created issue**. There is
**no Observability-to-SRE handoff**, no handoff title marker and no OBA workload
mitigation. SRE remains a genuinely human-approved repair agent, not an
automatically approved fallback. Stop SRE separately for isolated OBA acceptance.

## Invocation contract

Use the explicit `Scenario D Bicep` workflow (`scenario-d-bicep.yml`), dispatch
on the reviewed implementation ref, with `action=deploy`,
`observability_autonomous=true`, and a **fresh generation**, for example
`observe01`. Do not reuse a deleted purge-protected vault generation. The
workflow uses `environment: scenario-d`, existing private-runner labels,
pinned actions and the existing global D concurrency lock.

- Supply the private environment secret **`OBA_NOTIFICATION_EMAIL`**. Never use
  a dispatch string, source file, command-line literal or workflow output for it.
- The workflow exposes it as **`D_NOTIFICATION_EMAIL`** only to request
  validation and lifecycle steps, only on opted-in deploy. Reusable calls can
  pass the optional secret; environment secrets follow GitHub environment
  precedence. Do not shadow the repository Azure subscription variable in the
  environment: use the intended inherited `vars.AZURE_SUBSCRIPTION_ID`.
- The Boolean dispatch/call input maps to **`D_OBSERVABILITY_AUTONOMOUS`**.
  The local environment accepts only literal `true` or `false` (default false).
  Autonomous deploy rejects a missing/malformed/multiple recipient before any
  writes; default deploy ignores it. Down never requires the recipient.
- Autonomous deploy requires the derived ownership deployment name to be at
  most **51 characters**, so its `-oba-settings` deployment stays within ARM's
  64-character limit. Validation runs before Azure access; names are not
  truncated or rehashed. Default version-1 deploy and ledger-driven Down are
  not subject to this new limit.
- The private-runner wrapper remains `bash scripts/scenario-d-bicep.sh` with
  `SCENARIO_D_PRIVATE_RUNNER=true`, `D_ACTION`, `D_PREFIX`, `D_ENVIRONMENT`,
  `D_GENERATION`, `AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID` and full checkout
  `GITHUB_SHA`; local deploy requires a clean checkout with that exact SHA.
  Existing region and optional DNS environment inputs are unchanged.
- Down: `action=destroy`, same prefix/environment/generation, and
  `confirm_destroy=scenario-d-payd-demo-d-observe01` for the example profile.
  Leave the opt-in false and omit the recipient; **the validated ledger**, not
  current flags, determines exact cleanup.

Do not invoke individual templates to bypass lifecycle preflight. Deployment
builds healthy revisions and configures services; it does not trigger a fault,
send a test email, stop SRE, start an investigation, or run an observation loop.

## Ownership and least privilege

Default owners remain **version 1**, exactly the existing two subscription
SRE Monitoring Contributor grants. Old version-1 cleanup remains supported.
Opt-in owners use **version 2**, adding exactly one deterministic subscription
**Monitoring Reader** grant for the **OBA UAMI**, never a SRE principal and
never subscription Contributor/Monitoring Contributor for OBA. The existing
OBA Monitoring Contributor grant stays on the exact AMW and Monitoring Reader
stays on exact App Insights. Lifecycle identity/role/count checks reject
changed roles, identities, scopes or extra grants. The mode is immutable:
finish Down before switching; no silent rehash/adoption of an existing owner.

Version 2 also records the exact
`Microsoft.Monitor/settings/default` -> owned AMW binding and both external
`-oba-role` / `-oba-settings` deployment metadata IDs **before creation**.
For a fresh owner an independent GET must find the singleton absent; an
existing association (even one that looks reusable) is not adopted. On resume,
a ledger-owned exact binding is only read, not rewritten. A missing owned
binding may be created after another absence check, successful what-if, and
an immediate pre-create absence check. Any conflict stops the lifecycle.
ARM deployment PUT has no atomic create-if-absent guarantee: operators must
exclude other subscription-settings writers for the bounded acceptance window;
the workflow lock serializes this repository's D runs, not external writers.

Down validates current binding and all external ownership before mutations,
saves fresh principals in the durable cleanup snapshot, rechecks the binding,
and removes the owned setting before grants/AMW deletion. It refuses a changed
binding. Absent resources are resumable; failed reads are not absence. It
removes exact auxiliary deployment metadata and the ledger **last**, only
after verified absence. It never removes a preexisting shared default,
retained runner, shared DNS zone or shared state resource.

## Notification and configuration gates

Foundations owns the **only** `ag-sre-<stem>` declaration, with one secure
recipient and common alert schema in opt-in mode (no receivers by default).
The alert rules only reference it; redeploying them cannot clear receivers.
AMW `properties.actions.defaultActionGroups = [{ id: actionGroupId }]` is the
separate **issue-notification** association. Ordinary payment/checkout alert
email and OBA issue email are **different acceptance claims**.

The recipient is an `@secure()` Bicep parameter, not an output or ledger field;
CLI parameters use a removed-after-use private temporary file. It is not
passed to unrelated child-process environments, and exact recipient values
are redacted from CLI errors. Azure necessarily stores the receiver on the
action-group resource; authorized resource readers can see it. Do not publish
raw action-group GET bodies. The native action-group declaration is deliberate:
the current AVM module's receiver parameter is not secure and would expose the
recipient in nested deployment history. Existing compatible AVM modules remain
version-pinned.

Supported APIs: AMW **2026-04-03-preview**, OBA/target **2026-05-01-preview**,
settings **2025-06-03-preview**. Do not use the unsupported future AMW API.
Narrow `BCP081` suppressions cover only missing compiler types for AMW/settings;
AMW still supplies its location, tags and public-network property. The required
subscription-to-AMW association is now safe, owned configuration, **not evidence
that it fixes the previous autonomous failure**.

Before enabling OBA, lifecycle reads its fresh UAMI, verifies the exact
subscription grant and verifies the default AMW binding. After deployment,
independent GETs verify OBA parent enablement, exactly two Auto operations,
exact payment/checkout instructions, the sole autonomous App Insights target,
sole UAMI, all three exact OBA role grants, regions, workspace bindings,
ownership tags, AMW default group, and private recipient/common schema.
Mismatches fail; the verifier does not retry writes to conceal errors.
**Ready means configuration verified, not autonomous issue creation,
investigation completion or email delivery.**

## One bounded runtime acceptance (operator-owned, separate from deployment)

1. Confirm configuration gate and healthy real checkout; confirm SRE is stopped
   independently. Do not auto-approve any SRE repair. Ensure the operator has
   a direct reset path independent of SRE before arming anything.
2. Produce **one** payment incident with synthetic checkout traffic and retain
   the new exact payment/checkout alert IDs and timestamps. Do not replay faults
   or invoke a manual investigation to turn a failed autonomous gate green.
3. Observe until an **absolute deadline 20 minutes after the first new alert**.
   Subtract elapsed time when switching observers; do not start another full
   twenty-minute timer after discovering the alerts. Require an
   **agent-created** issue correlating payment cause and cascading checkout,
   followed by its automatic deep investigation. Record source evidence,
   issue/investigation IDs and times using private operator tooling.
4. Verify receipt privately, distinguishing ordinary alert email from the OBA
   issue notification. Receiver configuration alone is not delivery evidence.
5. At success **or timeout**, operator resets the fault directly, stops traffic,
   verifies fresh healthy checkout, and ends autonomous operation/tears down
   the owned acceptance environment. SRE repair testing is separate and still
   requires genuine approval. No second incident or hybrid work is implied.

**Historical evidence is unchanged:** previous automated issue attempts failed
even after the AMW notification action-group association was verified. See the
[historical Scenario D evidence](scenario-d-private-payments.md). Configuration
alone establishes neither autonomous execution nor email delivery.
Parent/operator tooling owns the live reads, fault/reset controls and bounded
observation; deployment does not execute them.

## Live acceptance evidence: 2026-10-15

**Result: the autonomous gate failed; hybrid implementation remains deferred.**
This is an observed bounded failure, not a confirmed product defect or proof
that autonomous Observability never works. The action-required escalation or
fallback decision is tracked in [#90](https://github.com/rutgerpels/sreagent/issues/90).

The fresh Bicep baseline deployed successfully from
`6b95dabed97920adab50a0ea6be6bd009089f5af` in
[workflow run 38743885660](https://github.com/rutgerpels/sreagent/actions/runs/38743885660).
The newly deployed SRE Agent was stopped for isolation. Independent reads
confirmed the enabled OBA parent, both Auto operations, autonomous App Insights
target, exact three OBA grants, subscription default workspace binding, AMW
notification group and requested private recipient.

All times below are UTC. Resource IDs, identities, recipient, mailbox content
and raw observations remain in private operator evidence, not this repository.

| Gate | Observed result |
| --- | --- |
| Healthy preparation | 106 successful synthetic checkouts, zero failures/unexpected responses, no initial alerts or issues. Dependency/request joins proved both frontend-to-checkout and checkout-to-payment hops. |
| One deliberate fault | Requested at 14:10:07. Payment alert fired at 14:14:41; cascading checkout alert at 14:15:39. Both were New/Fired and unsuppressed. |
| Ordinary alert email | Actual mailbox receipt at 14:14:52 and 14:15:56, independently confirmed through a narrowly scoped read. |
| Autonomous issue/deep investigation | Observer ran 14:16:38-14:36:41. All 18 snapshots contained **zero issues and zero investigation results**, while 213 checkouts failed and none returned an unexpected response. |
| Failure telemetry | 269 failing joined operations on each dependency hop; telemetry connected the payment failure and downstream checkout symptom. This is operator evidence, not an OBA diagnosis. |
| OBA issue-notification email | **Not exercised or verified**: no agent-created issue existed. Ordinary alert email does not satisfy this gate. |
| Operator recovery | One explicit flag-off reset requested at 14:37:29. The reset revision settled; the subsequent ten-minute observation confirmed 109 successful checkouts and zero failures/unexpected responses. Fresh request telemetry from all three roles showed no failures. |
| Alert recovery | Both alerts still showed Fired in the 14:48:40 snapshot. Healthy application recovery is verified; natural alert resolution was not yet verified at that observation. |

These stateful log alerts evaluate every five minutes. Azure Monitor documents
resolution after three clear frequency periods for this cadence, so a healthy
reset does not immediately clear the alert. Keep the [alert state and health
checks separate](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-overview#stateful-alerts);
do not manually close an alert to manufacture monitor-condition recovery.

The runtime observer used a twenty-minute relative timer after launch, ending
about **22 minutes after the first alert**, rather than the intended absolute
alert-anchored deadline. The invocation procedure above now makes that boundary
explicit. No additional incident or sliding retry window was started.

OBA was paused after the test using the documented partial-update operation
with `properties.enabled=false`; an independent GET confirmed it, with the
workspace and operation configuration preserved. SRE remained stopped.
Synthetic test traffic stopped. The healthy test infrastructure and retained
private runner were retained, not destroyed. This operational pause is recorded
separately from the immutable version-2 ownership mode; redeploying that owner
with `observability_autonomous=false` is not the pause/reset mechanism.

No manual issue, manual deep investigation, SRE repair approval, broad extra
permissions or repeat fault was used to manufacture autonomous success. The
private record preserves the fault/reset intents, healthy/fault/recovery traces,
issue/alert snapshots, identity grants and configuration before pausing.
Recommended next action is provider-side diagnosis using that evidence, or
explicit approval of an on-demand Observability fallback before hybrid work.

## Official references

- [Autonomous operations](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-autonomous-operations)
- [Bicep resource creation and identity requirements](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-resource-create-template)
- [Issue creation and subscription association](https://learn.microsoft.com/azure/azure-monitor/aiops/issues-how-to)
- [Portal notifications](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-resource-create-portal)
- [Published OBA partial-update contract](https://github.com/Azure/azure-rest-api-specs/blob/main/specification/monitoringservice/resource-manager/Microsoft.Monitor/Agents/preview/2026-05-01-preview/agents.json)
- [Published AMW action shape](https://github.com/Azure/azure-rest-api-specs/blob/main/specification/monitoringservice/resource-manager/Microsoft.Monitor/Accounts/preview/2026-09-03-preview/examples/AzureMonitorWorkspaces_CreateOrUpdate_MaximumSet_Gen.json)
  (shape reference only; the implementation uses live-supported 2026-04-03-preview).
