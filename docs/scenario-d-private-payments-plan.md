# Plan: Scenario D - private paired-agent payment failure

**Status:** Planning complete, with network and ownership decisions confirmed
on 12 October 2026. Implementation and live feasibility checks are not authorized
or performed; the build-time gates below remain to be satisfied.

## Confirmed direction

Add a separate deployment alongside the existing scenarios, rather than reuse
Scenario A or replace its memory incident. The selected incident is
**"Payments fail; checkout fails with them."** Private networking is required.
The current assignment is to create the plan only.

Use the paired-agent flow from the
[original proposal](agent-demo-proposal.md): both agents investigate in
parallel, an operator pastes Observability findings into the existing SRE
incident chat, and SRE executes the proposed recovery after human approval.

"Scenario D" is the proposed name. It does not exist in the deployment code yet.

### Confirmed network and ownership decisions

The owner selected private networking primarily for PaaS resources, while
allowing documented Azure monitoring and managed-agent service endpoints.
Application telemetry may use Azure Monitor without private endpoints or an
Azure Monitor Private Link Scope (AMPLS). The existing public HTTPS frontend
exception is retained; checkout and payment remain internal.

**Azure Policy is an implementation constraint, not an afterthought.** The
target environment has policies affecting most PaaS platforms, including Modify
policies for key-based authentication. RBAC is required. A successful resource
deployment must not be mistaken for working identity-based data access.

D will own its runner, networking and private DNS. It will not borrow resources
whose lifecycle belongs to A/B/C. These decisions replace the unresolved
network-boundary and runner-ownership questions in the earlier draft.

## Intended incident

1. Start with healthy synthetic checkout traffic and the payment fault disabled.
2. An authorized operator enables a demo-only payment-failure setting.
3. Payment requests return a predictable 503; the existing checkout code
   propagates a 502, which reaches the frontend.
4. Payment and checkout failure alerts fire. Observability correlates the
   symptoms, creates an issue and investigates automatically.
5. SRE starts from D's payment-failure alert, independently investigates the
   configuration change, and receives the operator's evidence handoff.
6. SRE proposes disabling the failure setting. A human approves the Azure write.
7. SRE applies the healthy configuration. Fresh end-to-end requests demonstrate
   recovery; monitoring and issue closure follow.

The target remains 5-10 minutes from trigger to approved, executed action,
including rollout, alerting, investigation, handoff and approval. This is a
rehearsal target, not a guaranteed cloud deadline.

### What each agent contributes

| Participant | Role in this incident | Visible result |
| --- | --- | --- |
| Observability Agent | Connect the payment errors with checkout impact, examine traces and changes, and distinguish a downstream symptom from the likely originating failure | One evidence-backed Azure Monitor issue and an investigation with supporting links |
| SRE Agent | Investigate the primary alert, validate the configuration cause and Observability evidence, propose the narrow recovery, then execute it after approval | One incident thread containing the hypothesis, approval, action and recovery checks |
| Operator | Trigger the controlled failure, transfer relevant evidence and explicitly approve the proposed change | A transparent handoff and an auditable approval, not a hidden integration |

Observability does not change the application, and SRE does not simply trust
another agent's recommendation. Their investigations overlap deliberately.
The combined value is a clearer account of the impact followed by a governed
change. Neither product requires the other to operate.

Both start from monitoring, not from an operator asking them to investigate.
The human handoff is a prompt in the **same SRE incident thread**, containing
the Observability issue URL, a short evidence summary, affected resources and
time window. Include the relevant findings themselves: pasting a URL does not
prove that SRE can retrieve its contents. Request validation and a proposed
recovery; give approval separately through Review mode.

## Proposed deployment boundary

Give D its own application resource group, prefix, VNet, state, application
telemetry, alerts, agent identities and agent instances. Do not share the
existing scenarios' application resources or change their permissions.

Reuse the three-service application and Scenario C's private data-plane
patterns: private registry, Key Vault and Terraform state, a private deployment
runner, and SRE VNet integration. Unlike C, D uses approved direct remediation,
not a pull request and deployment pipeline during the incident.

Keep A/B/C behavior unchanged. No profile conversion, replacement of their
memory fault, or teardown of an existing environment is part of this plan.

### Networking requirements

| Surface | Planned requirement |
| --- | --- |
| Frontend | Public HTTPS entry point; only public application ingress |
| Checkout and payment | Internal ingress only |
| ACR | Private endpoint, public data-plane access disabled; reuse the private profile's Premium SKU |
| Key Vault | Private endpoint, public data-plane access disabled, managed identity and RBAC |
| Terraform state | Dedicated LRS Blob storage, private endpoint, identity authentication, no storage keys |
| Deployment runner | D-owned runner and network, no public inbound administration; access to D's private endpoints and explicitly permitted outbound dependencies |
| SRE workspace | Dedicated delegated subnet, Azure VNet egress and private DNS; current Microsoft guidance requires at least /27 |
| App Insights, Log Analytics and issue workspace | Public Azure monitoring endpoints permitted; Entra authentication and required RBAC, no AMPLS requirement |
| Managed agents, Azure management and identity endpoints | Documented service paths permitted, with effective policy compatibility checked before provisioning |

Microsoft documents
that SRE VNet integration is outbound-only, connector traffic uses the public
internet, and platform traffic stays on Microsoft-managed infrastructure.
Inbound private endpoints for SRE are not supported in the reviewed guidance.
These limitations fit the selected boundary; D must not be described as an
entirely private agent platform.

Public monitoring access is an approved network choice, not permission for
anonymous ingestion, local authentication or broad workload access. Do not add
unrelated public PaaS endpoints or enable ACR, Key Vault or state public access
as a deployment workaround.

### Gate 0: effective policy and identity compatibility

Before building, inspect the actual policy assignments and inherited initiatives
at the chosen management-group, subscription and resource-group scopes. Record
their parameters, enforcement effects and any existing exemptions. The exact
assignments are not known from this repository and have not been inspected in
this planning task.

Check the planned resources against public-network restrictions, local/shared-key
authentication restrictions, allowed locations/SKUs, mandatory diagnostics and
tagging. Inspect the managed agents' generated resources too: a product-owned
dependency can violate policy even when the application resources comply.

Configure the compliant settings explicitly rather than depend on a Modify
policy to repair them after deployment. Read back the effective configuration,
verify data-plane operations and check for unexpected Terraform drift after
policy evaluation. Do not disable a policy, request broad Contributor access,
re-enable keys or introduce a lifecycle-ignore workaround to make a test pass.
A genuine conflict is a reported blocker requiring an explicit owner decision.

| Access path | Required authentication and scope | Build-time proof |
| --- | --- | --- |
| CI and Terraform | GitHub OIDC for the D deployment identity; operator Entra sign-in for authorized bootstrap; scoped provisioning/RBAC rights | D deploy and plan succeed without stored Azure credentials or key retrieval |
| State storage | Entra data-plane RBAC and a private Blob endpoint | Backend read/write works with shared-key access disabled |
| ACR build/push/pull | Entra-authorized push from the D runner and managed-identity pull by the apps; admin account disabled | Private push and pull succeed; no registry admin credential is requested |
| Key Vault | App managed identities with scoped secrets-read RBAC | References resolve privately with access policies and key-based fallbacks absent |
| Application telemetry | Each app's user-assigned identity authenticates the exporter; Monitoring Metrics Publisher scoped to D's Application Insights | All three server-side roles produce fresh telemetry with local ingestion authentication disabled |
| Platform logs and diagnostics | Supported Azure Monitor diagnostic-settings path, without distributing Log Analytics shared keys | ACA system/console logs and ACR/Key Vault diagnostics arrive under the effective policies |
| Agent queries, issues and changes | Dedicated managed identities and the documented minimum roles, with approved exceptions only where the service requires broader monitoring scope | Both agents can read evidence; Observability can create issues; SRE cannot write outside its approved workload scope |

There is a concrete repository gap: the current Node telemetry bootstrap passes
only the Application Insights connection string to the exporter. Managed
identity used to **retrieve** that string from Key Vault does not authenticate
telemetry **ingestion**. Plan explicit managed-identity exporter authentication
in all three services for D, with no fallback to connection-string-only
ingestion when token acquisition fails. Keep the connection string in the
existing Key Vault reference for destination configuration.

Microsoft's [Application Insights Entra guidance][entra-telemetry] documents
this Node.js exporter path and the Monitoring Metrics Publisher role. Validate
it with the repository's actual package versions before implementation; do not
assume App Service no-code authentication settings apply to these containers.
Keep this server-side: do not add browser SDK ingestion that depends on local
authentication.

Also review the existing ACA environment's direct Log Analytics integration.
Prefer the documented [Azure Monitor logs destination with diagnostic
settings][aca-logging] for D rather than a configuration that needs workspace
shared keys. Verify provider support, resulting tables and successful delivery
under the actual policies; merely creating a diagnostic setting is not proof
that it receives logs. Missing telemetry or authentication failures must fail
the readiness check explicitly, not leave a green demo with no evidence.

## Coexistence: work needed beyond adding a profile

The current workflows accept only A/B/C and deliberately enforce one persistent
repository deployment target through `DEPLOYMENT_SCENARIO`, `TF_PREFIX` and
`TF_ENVIRONMENT`. Existing per-scenario state naming is not enough to permit
a persistent D deployment alongside the active scenario.

Use an explicit, manually selected D deployment target backed by a dedicated
GitHub Environment and independently scoped configuration. Preserve the
current A/B/C repository-default push target and mismatch guards. Do not use
the ephemeral dev/test bypass as a persistent deployment mechanism.

| Entry point | Planned target behavior |
| --- | --- |
| Existing push-driven app/infra workflows | Continue resolving the existing A/B/C repository target; do not fan out to D |
| D deployment or image update | Explicit manual target D; load its Environment-bound identity/configuration and run on its dedicated private runner |
| D trigger/reset | Select and validate only D's application; no repository-default inference |
| D destroy | Explicit D target and ownership checks; do not clear A/B/C repository configuration |
| Concurrent work | One D-specific deployment/lifecycle concurrency group, separate from A/B/C; no deployment or teardown during an active rehearsal |

Bind D's OIDC trust and runner access to the intended GitHub Environment and
trusted workflows. Untrusted pull-request jobs must not gain access to its
private runner or Azure identity. Record non-secret deployment identifiers in
operator-configured Environment variables, not committed files.

D deploy, update, trigger, reset and destroy operations must identify D
explicitly and verify the selected subscription, state, resource identity and
scenario tags. Give D a distinct prefix to avoid sharing the state resource
group. Isolate concurrency and local Terraform backend metadata as well as
the state blob.

Use nonoverlapping address ranges and D-owned runner networking and DNS, as
selected by the owner. Do not reuse C-owned private DNS zones through the
existing discovery mechanism, or link two same-namespace private zones to one
VNet. D's application and runner networks must resolve D's endpoints without
moving or taking ownership of existing scenario resources.

Bootstrap the D runner/network/private state prerequisites from an authorized
operator context before expecting a private-runner job to use them. Creation
through the Azure control plane does not require temporarily opening the
storage or registry data plane; backend initialization and image pushes must
wait until the private runner is available. Track this foundation's ownership
and state separately from the workload it enables, and retain the runner,
DNS and state until dependent resources are removed. Do not make a runner
destroy the infrastructure or backend it still needs to finish its own job.

Validate alert isolation in both directions. SRE monitoring roles can have
subscription scope, and a severity-only response rule is not sufficient proof
of separation. D must not respond to A/B/C alerts, and existing agents must not
attempt to fix D. If approved filtering cannot enforce that boundary, consider
a separate subscription rather than claim isolation from resource names alone.

## Planned application and monitoring changes

Add one payment-failure setting, default off, with a deterministic and
non-sensitive error response. Treat it as non-secret demo configuration, not
a credential. Keep health and readiness healthy so the demo shows a failed
transaction path rather than a container crash. Reject invalid configuration
explicitly instead of silently activating or ignoring it.

Keep the existing memory leak unchanged for A/B/C. D must explicitly keep it
off even when the shared `leak.auto.tfvars` file is armed for another scenario.
D's effective configuration must not depend on changing that file back to
healthy and thereby interfering with a concurrent demonstration.

Provide guarded trigger/reset scripts in Bash and PowerShell. Use authenticated
configuration changes, not a public fault-control endpoint. Prebuild the
fault-capable images and use bounded synthetic traffic with a finite stop time.
Use generated test orders only, not real customer or payment data. Start traffic
before the clock and maintain it through recovery, so errors and later success
are observable without audience clicks. No image build, agent onboarding or
role propagation belongs inside the timed incident.

Terraform's desired D state is healthy. The operator trigger is a temporary,
audited live deviation; SRE's approved fix returns it to that desired state.
Reset must be repeatable, and the next plan must not re-enable the fault.
The normal demo recovery is flag-off plus a fresh healthy revision, not a
restart or scale-out that leaves the configured cause active.

Create two D-scoped alerts: payment failures and checkout failures. Use the
payment-failure alert as the sole SRE trigger; let Observability see both.
The checkout alert supplies impact evidence, not a second remediation thread.
Choose supported
request signals and short static windows based on measured baseline behavior.
Do not assume exporter or log-ingestion latency fits the timing target.

Verify linked traces across the real frontend, checkout and payment HTTP
calls, including Node `fetch`. Separate metrics from each service are not proof
that dependency correlation works.
Keep low-volume demo traces complete enough to prove the dependency chain;
confirm sampling, role names and failure classification before selecting alert
thresholds. Scope every signal to D and exclude healthy probes from transaction
failure calculations.

## Planned agent configuration

### Observability Agent

Use a dedicated D identity, D Application Insights scope and D issue workspace.
Enable correlation, issue creation and automatic investigation. Instructions
describe the service dependency chain and distinguish D from other demos,
without prescribing fabricated findings.

The portal onboarding guide specifies Issue Contributor on the workspace and
Monitoring Reader on relevant subscriptions. Other overview material describes
broader monitoring roles. Start from the narrower onboarding guidance and
verify the required operations; do not silently broaden permissions on failure.

### SRE Agent

Use dedicated identities with required monitoring reads and the narrowest
verified write scope sufficient to update D's payment application. Resource
write permission does not, by itself, restrict changes to one feature flag.
Enforce the remaining action boundary through tool policy, Review mode and
human review of the proposed change.

Set Review mode on all applicable incident response plans and on the fallback
from the start. Do not inherit A's Autonomous fallback or C's deny-all-workload-
writes policy. The D plan must target D's payment-failure alert, not every Sev2
alert.

Supply a small runbook explaining the flag, durable fix and recovery checks.
No GitHub write credentials or remediation PR are needed. Read-only source
context is optional and must use an approved network path.

The operator hands over the issue URL, relevant findings, affected resources,
time window and evidence references in the existing Review-mode incident chat.
SRE validates that evidence before proposing a change. Human approval remains
a separate enforced step.
The proposed action must preserve unrelated environment variables, secrets,
image digest, ingress and identity settings. Reject a broad redeployment or
permission change offered as a shortcut. Review mode is not a blanket approval
guarantee for external tools, so keep unnecessary write-capable connectors out
of D.

### Provisioning boundary

Use the approved AzureRM Terraform approach for supported infrastructure.
The existing SRE implementation uses AzAPI, which differs from the standing
AzureRM-only requirement; this plan does not authorize extending that exception
or refactoring existing scenarios.

Where the approved provider does not support an agent resource, use documented
portal onboarding after infrastructure deployment, subject to the network gate.
The Observability preview documentation explicitly states Terraform provisioning
is not supported. Do not introduce Bicep/ARM templates to bypass repository
requirements. Record portal-owned resources and their cleanup ownership.
The one-command goal therefore applies to the infrastructure/application
deployment after its documented private-runner bootstrap; it must not be
advertised as unattended creation of both managed agents. Their documented
one-time onboarding and readiness checks happen before any timed rehearsal.

## Proposed implementation sequence

| Phase | Scope | Completion condition |
| --- | --- | --- |
| 0. Policy and support preflight | Inspect inherited policies; verify the confirmed endpoint boundary, keyless paths, managed-agent dependencies, regional availability and provider/onboarding boundary | Effective policies and required access documented; incompatibilities resolved explicitly or implementation blocked |
| 1. Isolated deployment | Bootstrap D-owned runner/network/private state/DNS; add D profile, Environment target resolution and lifecycle guards | D can coexist with the active scenario without retargeting it |
| 2. Controlled failure | Add default-off failure setting and guarded trigger/reset; keep D's memory leak off | Predictable payment and checkout failures, followed by reliable reset |
| 3. Evidence and alerts | Enable Entra-authenticated telemetry, verify policy-compatible diagnostics and linked traces, and add two scoped failure alerts | Both symptoms visible under enforced authentication policies, one intended SRE incident, no cross-scenario handling |
| 4. Agent onboarding and policy | Configure dedicated agents, Review mode, runbook and operator handoff | Investigation automatic; workload changes blocked until approval |
| 5. Rehearsal and documentation | Measure timing, recovery, repeatability and independent teardown | Three consecutive paired runs meet the action target; A/B/C remain unaffected |

Phase 0 precedes all provisioning. Phases 2 and 3 can be developed after the
target/configuration contract is settled, but both must pass before a paired
rehearsal. Timing acceptance depends on completed onboarding, not just deployed
containers.

### Change boundaries

| Area | Planned changes | Preserve |
| --- | --- | --- |
| Terraform profiles and outputs | D validation/profile, names, private networking, healthy defaults, monitoring, identities/RBAC and onboarding outputs | Existing A/B/C resource addresses, effective settings and state |
| Deployment lifecycle | Explicit D Environment/target, private foundation bootstrap, backend and concurrency isolation, teardown order | A/B/C push routing, persistent-target guards and ephemeral test semantics |
| Application | Payment failure flag; D-opt-in identity-based telemetry across all three services; trace fixes if required | Existing checkout error propagation, health behavior and A/B/C memory fault |
| Operator controls | Guarded Bash/PowerShell trigger/reset and finite synthetic traffic | Authenticated access; no public fault endpoint or incident-time PR/build |
| Agents and documentation | Dedicated D instructions, scoped primary alert, Review policy, evidence handoff and one walkthrough | Existing agents' configurations and ownership |
| Regression coverage | Extend profile/network/Observability tests and add D target, authentication, failure/reset and isolation checks | Existing regression cases and expected A/B/C behavior |

Likely files include the existing `infra` profile, network, container-app,
observability, alert, identity and output definitions; deployment/apply/destroy
workflows and backend bootstrap; the three server-side telemetry bootstraps;
payment server code; and new D-specific operator/agent documentation. These are
future implementation surfaces, not files changed by this planning task.

Any reuse of the reconciler must address its current Scenario C-specific
identity, configuration and ownership assumptions. Do not apply C's manifest
or policy unchanged to D.

Out of scope: changing organization policy, adding AMPLS, moving existing DNS,
converting A/B/C, redesigning their authentication, introducing another failure
scenario, automating an undocumented agent-to-agent bridge, or provisioning
new databases/queues/AKS. Shared source changes must keep existing defaults
unchanged and enable the new behavior explicitly for D.

## Rehearsal timing and failure handling

Prepare the agents, permissions, image digests, private paths and synthetic
traffic in advance. Confirm a healthy baseline and clear the previous run's
active fault/incident state before starting a new clock.

| Elapsed target | Milestone |
| --- | --- |
| 0-1 minute | Authenticated trigger accepted; failing revision serves payment errors and checkout failures |
| 1-3 minutes | Scoped alerts fire and each agent starts automatically |
| 3-6 minutes | Parallel investigations produce useful evidence; Observability groups the symptoms into an issue |
| 6-8 minutes | Operator transfers evidence; SRE validates and proposes recovery; human approves |
| By 10 minutes | SRE's approved configuration change has executed successfully |

These are planning budgets, not observed measurements. Time starts when the
operator starts the trigger, not when the alert eventually fires. Capture
trigger, first failed request, both alerts, issue creation, both investigation
starts, useful findings, evidence handoff, proposal, approval, executed action,
first sustained successful requests and closure as separate timestamps.

Require an actual Observability evidence contribution before approval in each
paired acceptance run. Record recovery separately and aim to show it in the
same presentation; an accepted configuration write is not yet a solved incident.
Use fresh end-to-end orders and a sustained healthy interval covering the alert
window as recovery evidence, then let alerts resolve and close/update the issue
through the documented human or service workflow. Do not claim Observability
has remediated or independently closed the incident.

If ingestion or either agent misses the budget, keep the measured result and
mark the rehearsal unsuccessful. Do not substitute a manual Investigate click,
an operator-issued fix or an SRE-only run and call it the autonomous paired flow.
An authorized operator can use reset as the recovery escape hatch if SRE stalls;
label that run assisted and unsuccessful against the agent-action target.
Wait for fresh healthy telemetry before retrying, rather than overlapping runs.

## Acceptance criteria

- Given an active existing scenario, deploying D leaves its resources,
  repository-default target and agent policies unchanged.
- Given inherited Azure Policy, D deploys with compliant effective settings
  and no unapproved exemption, local-auth fallback or Modify-induced drift.
- Given disabled local/shared-key authentication, state, image transfer,
  secrets access, telemetry ingestion and agent operations still work using
  the required identities/RBAC. No application health endpoint alone can
  satisfy this criterion.
- Given either environment's alerts, only its intended agent response plans
  act on them.
- Given the approved network design, registry, secrets and state are reachable
  through private paths and cannot fall back to public data-plane access.
- Given D's owned runner and DNS, no deployment or reset depends on an A/B/C
  resource; public telemetry works without requiring AMPLS.
- Given another scenario's enabled shared memory-leak setting, D keeps its own
  memory leak off without editing that scenario's desired state.
- Given healthy D traffic, enabling the fault produces payment errors and
  corresponding checkout failures with linked evidence.
- Given both alerts, Observability creates an issue and investigates without
  an operator selecting Investigate; SRE receives one intended incident.
- Given the evidence handoff, SRE proposes a scoped configuration recovery
  and makes no workload change before approval.
- Given approval, SRE disables the fault and fresh orders recover. Revision
  creation alone is not accepted as proof of recovery.
- Given three successive rehearsals, each approved action executes within ten
  minutes of the trigger. Record recovery and closure times separately.
- Given a reset, the fault stays off and a later Terraform apply does not
  unexpectedly rearm it; no permanent lifecycle-ignore shortcut hides drift.
- Given D teardown, only D-owned resources and role assignments are removed.
  Its runner/network/state are removed last through a supported bootstrap
  cleanup path, portal-owned agents are accounted for, and existing scenarios
  remain functional. Report any policy/retention-protected residue explicitly.

### Planned validation during implementation

Run the repository's existing focused checks and extend them for D. The
commands below are examples from the repository root in PowerShell; they are
not results from this planning task. Run backend-free Terraform checks in an
isolated validation directory, not against a live deployment's backend.

```powershell
terraform fmt -check -recursive infra
python scripts\tests\terraform-network-dependencies.test.py
node --test scripts\tests\sre-agent-reconciler.test.mjs
npm --prefix src\frontend run build
npm --prefix src\checkout-api run build
npm --prefix src\payment-service run build
```

After backend-free initialization in that isolated validation copy, run
`terraform -chdir=infra validate` and the mocked Observability prerequisite
test with `terraform -chdir=infra test -filter=tests/observability-agent.tftest.hcl`.
Extend its A/B/C assertions with D, rather than treating Scenario A's public
workspace configuration as D's complete identity/policy test. Update the
network fixture's explicit expected test count when adding D cases.

Add focused tests for default-off/invalid/enabled/reset fault behavior,
checkout propagation, healthy probes, identity-only telemetry configuration
and preservation of unrelated app settings. These application and D-target
tests do not exist yet; define their smallest test command during implementation
and wire it into validation. Test wrong-target rejection, separate concurrency,
default push routing and teardown ownership without accessing production state.

Offline checks cannot prove policy compliance, private connectivity, identity
propagation or agent behavior. The deployment gate additionally requires actual
private DNS/data-plane checks, Entra-only ingestion with local authentication
disabled, policy/configuration readback, a clean healthy-state Terraform plan,
cross-scenario negative alert tests, approval enforcement and three measured
paired rehearsals. Preserve evidence without publishing credentials or real
deployment identifiers into the public repository.

## Readiness and authorization

The scenario, network boundary and independent ownership are decided. The
remaining unknowns are build-time verification gates: effective policy details,
provider and managed-agent compatibility, region/preview availability, correct
alert isolation and measured signal/agent latency.

This document completes the requested plan. It does not authorize
implementation, deployment, policy exceptions, backlog creation, commits or
pull requests. No application, infrastructure or workflow behavior has changed.

## Sources checked

- [Azure SRE Agent network integration](https://learn.microsoft.com/azure/sre-agent/network-integration): outbound-only VNet support, public connector paths, platform exceptions and subnet requirements.
- [Observability Agent resource](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-resource): scoped identity, provisioning limitations and preview constraints.
- [Observability Agent portal onboarding](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-resource-create-portal): narrower identity roles, regional workspace association and automatic investigation settings.
- [Observability governance FAQ](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-governance-faq): autonomous versus interactive identity and issue governance.
- [Microsoft Entra authentication for Application Insights][entra-telemetry]: exporter credentials, scoped Monitoring Metrics Publisher and disabling local authentication.
- [Log storage and monitoring options in Azure Container Apps][aca-logging]: Azure Monitor destination, diagnostic settings and ingestion-delay caveats.
- [Existing private scenario](scenario-c-private-gitops.md), [profile definitions](../infra/main.tf), [network configuration](../infra/network.tf) and [deployment workflow](../.github/workflows/deploy.yml): repository baseline and current coexistence restrictions.

[entra-telemetry]: https://learn.microsoft.com/azure/azure-monitor/app/azure-ad-authentication
[aca-logging]: https://learn.microsoft.com/azure/container-apps/log-options
