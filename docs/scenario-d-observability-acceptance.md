# Scenario D — opt-in autonomous Observability acceptance

This is a **configuration-only, default-off** addition to the healthy Bicep
baseline. It is not hybrid/country functionality. Legacy D deployment entry
points keep OBA paused; A/B/C, the retained runner, SRE Review mode, global
write-tool `ask`, exact payment-alert filter and no schedules are unchanged.

In this separate test OBA independently correlates alerts, creates an issue,
and automatically deep-investigates **its own agent-created issue**. There is
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
3. Observe for **at most 20 minutes after the new alerts**. Require an
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
[historical Scenario D evidence](scenario-d-private-payments.md). This change
claims no new runtime or email success. Parent/operator tooling owns the live
reads, fault/reset controls and bounded observation; none is executed here.

## Official references

- [Autonomous operations](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-autonomous-operations)
- [Bicep resource creation and identity requirements](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-resource-create-template)
- [Issue creation and subscription association](https://learn.microsoft.com/azure/azure-monitor/aiops/issues-how-to)
- [Portal notifications](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-resource-create-portal)
- [Published AMW action shape](https://github.com/Azure/azure-rest-api-specs/blob/main/specification/monitoringservice/resource-manager/Microsoft.Monitor/Accounts/preview/2026-09-03-preview/examples/AzureMonitorWorkspaces_CreateOrUpdate_MaximumSet_Gen.json)
  (shape reference only; the implementation uses live-supported 2026-04-03-preview).
