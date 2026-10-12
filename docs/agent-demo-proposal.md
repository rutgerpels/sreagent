# Proposal: Observability Agent and SRE Agent in one incident demo

**Research date: 12 October 2026. Status: proposal, not an implemented or
live-verified ten-minute demo.**

**Selected direction after this proposal:** build the payment-failure demo as
a separate Scenario D alongside A/B/C, with its own private PaaS networking,
runner and DNS. Public Azure monitoring endpoints are permitted without AMPLS;
RBAC and existing Azure Policy constraints apply. The
[Scenario D plan](scenario-d-private-payments-plan.md) supersedes the reuse-A
deployment recommendation below. Implementation has not been authorized.

## Recommendation

Keep ContosoPay and its three Container Apps. Use the existing Scenario A
foundation, but make the main demonstration a **payment failure with visible
checkout impact**, rather than waiting for the current slow memory leak.

Position the agents as complementary operational roles:

> **Observability Agent turns symptoms into an evidence-backed incident story.
> SRE Agent investigates the operational cause, proposes a change, and performs
> the approved recovery.**

That is a division of responsibilities for this demo, not a strict product
boundary: both agents can investigate and recommend next steps. SRE Agent does
not require Observability Agent to work.

Recommend four failure scenarios, detailed below. Start with the payment
failure for the strongest combined story, or the incorrect payment route for
the smallest implementation effort. Keep latency and memory as alternatives,
not additional incidents to run in the same short presentation.

**The main qualification:** a 5-10-minute trigger-to-action run is a design and
rehearsal target, not a documented Microsoft timing guarantee. The current
repository does not meet it: its memory alert alone is designed to take
8-12 minutes. A fully automatic, sequential Observability-to-SRE handoff is
also not established by the documentation reviewed.

## 1. How Microsoft positions the agents

### Different emphasis, overlapping investigation capabilities

| Responsibility | Azure Copilot Observability Agent | Azure SRE Agent |
| --- | --- | --- |
| Main emphasis | Understand what happened across monitoring signals and preserve the investigation | Investigate and carry out governed operational response |
| Evidence | Logs, metrics, traces, dependency topology, alerts, resource health and change history | Monitoring evidence plus connected source repositories, deployment context, runbooks and previous investigations |
| Background work | With autonomous operations enabled, correlate alerts into Azure Monitor issues and investigate agent-created issues | Start incident response from supported incident platforms, including Azure Monitor Alerts |
| Recommendations | Explain likely causes, affected components, alternatives considered and recommended mitigations | Validate possible fixes, propose an operational change and explain its consequences |
| Workload changes | Does not restart resources or change workload configuration | Can execute permitted changes, with human approval in Review mode |
| Persistent output | Azure Monitor issue containing investigation context and supporting evidence | Incident thread, action history and, where configured, a remediation pull request |

Microsoft's [Observability overview][obs-overview] and
[deep-investigation documentation][obs-investigation] describe movement from
signals to explanation and recommended next steps. The
[SRE overview][sre-overview] extends investigation into governed execution.
It would therefore be inaccurate to say that Observability only displays
dashboards, or that SRE only executes a fix supplied by another agent.

Microsoft announced the core Observability Agent's general availability on
23 June 2026. **Autonomous operations and the associated agent resource remain
public preview** in the documentation reviewed. Core availability must not be
presented as general availability of every background workflow.
[Sources: announcement][obs-customers], [autonomous operations][obs-autonomous].

### Why use them together?

The strongest reason is **shared incident understanding followed by controlled
action**. Observability gives the on-call team a durable, reviewable explanation
of related symptoms and their impact. SRE then validates the operational
diagnosis and owns the change-and-recovery loop.

This is particularly useful when several services alert about one underlying
problem. The audience sees why three symptoms should not lead to three
unrelated fixes.

The pairing is optional. A team that only wants investigation can use
Observability Agent without automated remediation. A team that primarily wants
automated incident response can use SRE Agent directly with Azure Monitor and
Application Insights. Using both adds another investigation surface, possible
duplicate work and an evidence-handoff step; it is worthwhile only if the demo
shows what that extra incident context contributes.

### What is documented, and what is not established?

**Documented:** Observability Agent can correlate multiple alerts, promote an
individual important alert into an issue when instructed, and automatically
investigate the issues it creates. SRE Agent can independently start from
Azure Monitor alerts and perform approved Azure changes.
[Sources: autonomous operations][obs-autonomous], [SRE overview][sre-overview],
[run modes][sre-modes].

**Not established in the sources reviewed:** a built-in transfer that
automatically sends an Observability issue and its complete findings into
SRE Agent, or shared conversational memory between the products. Do not assume
that an Azure Monitor *issue* is an SRE incident trigger simply because Azure
Monitor *alerts* are supported.

For this proposal, the integration boundary is an explicit **operator-mediated
evidence handoff**. A future automated bridge would be separate integration
work requiring supported interfaces and its own validation, not something to
imply already exists.

## 2. What public customer evidence supports

The following are named customer references, not fictional examples. They
support adoption of the individual capabilities; they do not establish a
joint deployment of both agents.

| Customer | Publicly described use | What we can conclude |
| --- | --- | --- |
| Ecolab | Microsoft's SRE Agent customer-story summary describes an SRE team handling about 30 daily performance alerts and manually navigating dashboards to find causes | A named SRE Agent reference focused on investigation and operational effort; the public summary does not establish an Observability Agent pairing |
| KPMG | Microsoft's June 2026 announcement describes Observability Agent investigations, remediation recommendations and an estimated 250 engineering hours reclaimed monthly | Evidence of customer-reported Observability value; neither an SRE integration claim nor a timing promise for our demo |
| PolicyVault | The same announcement describes combining service telemetry with Azure resource health to identify likely causes and actionable next steps | Evidence of using Observability for incident understanding and recommended follow-up |
| Ontinue | The announcement describes bringing telemetry together and guiding teams toward likely causes | Evidence of investigation assistance; it does not document who executes remediation |

Sources: [Ecolab public Microsoft summary][ecolab-summary] and
[Microsoft's announcement with the three Observability customer accounts][obs-customers].
The Ecolab summary is narrower evidence than a full implementation case study;
no additional performance claim is inferred from it.

**Do customers use the agents together?** The reviewed public references show
customers using each product, but do not verify a named customer running this
specific two-agent handoff. This is not evidence that nobody does. It means we
should describe our proposal as a complementary demo pattern, not an
established customer-standard architecture.

Microsoft's broader [agentic cloud operations positioning][agentic-operations]
connects observability, governance and action. That supports the overall
story, but a platform vision is not proof of a shipped point-to-point
integration or a particular customer's deployment.

## 3. What the repository already gives us

| Existing capability | Implication for this proposal |
| --- | --- |
| Public frontend, internal checkout API and internal payment service | A small, understandable dependency chain; no need to add AKS, a database or a queue |
| Application Insights, Log Analytics and OpenTelemetry bootstraps across the services | A foundation for correlating request symptoms and service dependencies; confirm that the expected linked traces are actually arriving before the demo |
| Scenario A's Observability workspace, dedicated identity and portal onboarding guide | Reuse the existing paired-agent setup rather than introduce a second architecture |
| An explicit evidence handoff and Review-mode incident instructions in Scenario A | The repository already avoids claiming native agent-to-agent orchestration |
| A deterministic, feature-flagged memory leak and direct trigger/reset scripts | A reusable fault, but its timing must change for a short demonstration |
| Digest-pinned application images and revision-based changes | Prebuild the demo images and recover without a live compilation or image build |
| GitOps scenarios B/C | Useful longer governance demonstrations, not the preferred path for a short direct-recovery demo |

These findings are grounded in [the README](../README.md),
[Scenario A](scenario-a-direct.md),
[Container Apps configuration](../infra/containerapps.tf),
[observability resources](../infra/observability.tf), and the
[payment](../src/payment-service/src/server.ts),
[checkout](../src/checkout-api/src/server.ts) and
[telemetry](../src/payment-service/src/telemetry.ts) code.

### Important gaps and corrections

**The existing fault is intentionally slow.** The
[leak implementation](../src/payment-service/src/leak.ts) calibrates allocations
to reach the raw memory threshold in six minutes by default. The
[alert](../infra/alerts.tf) evaluates a five-minute average every minute.
Together with rollout and telemetry delays, the walkthrough expects
8-12 minutes just to alert. One-minute evaluation does not mean one-minute
detection.

**The leak is not a checkout outage by itself.** Payment requests and health
checks can remain successful while memory grows. Increasing replica count
does not remove this timer-driven leak: every replica leaks independently.
A restart clears accumulated memory only temporarily. Disabling the flag and
starting a healthy revision removes the cause.

**Only memory alerting exists today.** The proposed error and latency scenarios
need their own alerts. Payment error and delay switches are also new work;
they are not currently available trigger options.

**The paired path is not yet proven live.** The README explicitly labels
Scenario A's autonomous Observability issue/investigation flow as an acceptance
target. Scenario C records an alert-triggered SRE remediation PR, but that is
not proof of the paired path. Its recorded alert-to-PR time was approximately
4 minutes 47 seconds, excluding fault buildup, approval and deployment.
[Source: Scenario C](scenario-c-private-gitops.md#step-15-watch-the-agent-open-the-remediation-pull-request).

**Monitoring can lag recovery.** Scenario C records delayed Container Apps
metric rendering, including backfilled recovery data. Application telemetry
can also arrive after the actual requests. A new revision proves a change
occurred, not that the incident is solved; fresh end-to-end requests and
cause-specific measurements must establish recovery.

## 4. The proposed incident flow

### One incident, parallel investigation, one approved recovery

```text
Trigger a controlled fault
          |
          v
Azure Monitor alert(s)
          |
          +--> Observability Agent
          |      Correlates symptoms -> creates issue -> investigates
          |      Produces impact, likely cause and supporting evidence
          |                          |
          |                  Operator hands over evidence
          |                          |
          +--> SRE Agent <-----------+
                 Starts its own incident investigation
                 Checks configuration, revision and source
                 Proposes a specific recovery
                          |
                    Human approves
                          |
                 SRE executes the change
                          |
                 Verify service recovery
                          |
                 Record outcome; human resolves Observability issue
```

This preserves the requested story:
**trigger incident -> alert/issue -> investigation -> proposed fix ->
approved agent remediation**. There are two explicit human actions: passing
the Observability evidence and approving the Azure change. The presenter does
not manually execute the fix.

The agents should start in parallel from the alert. Making SRE wait for a
complete Observability deep investigation before it can start would add
unnecessary serial delay. The audience can still see the explanation first
and the recovery second.

To avoid duplicate SRE incident threads in a multi-alert demonstration, select
one primary symptom alert for the SRE response plan. Let Observability see
the related alert set. Matching the correct response plan and its Review mode
is a preparation requirement for each new fault, not something inherited
automatically from the existing memory plan.

### What exactly does Observability contribute?

Its contribution is the **incident explanation and evidence package**:
which services are affected, when the problem began, how their symptoms relate,
what likely failed, which alternatives were ruled out, and which telemetry
supports those conclusions.

For the payment-failure demo, the desired conclusion is: "Checkout failures
are downstream of payment failures, rather than evidence that the frontend,
checkout and payment services all need separate repairs." That is a hypothesis
for the agent to establish from real evidence, not a scripted answer to inject
into its findings.

The operator passes the issue link **and its relevant findings**, affected
resources, incident time window and evidence references into the existing SRE
incident thread. A link alone does not guarantee SRE can retrieve its content.
SRE validates those findings and owns the proposed change.

After recovery, the team adds the SRE action and fresh recovery evidence to
the issue. Observability can assist with a follow-up comparison when fresh
data is available, but it neither executes the workload fix nor independently
closes the issue. Alert resolution, workload recovery and issue closure are
separate events.

## 5. Four manageable scenarios

These are **failure choices within the paired Scenario A design**, not four new
Terraform deployment profiles. All timing ranges below are proposed rehearsal
targets measured from the trigger command, including revision rollout. They
are not observed benchmarks.

| Priority | Scenario | Why choose it | Alert target | Approved action target | Relative work |
| --- | --- | --- | --- | --- | --- |
| 1 | Payments fail; checkout fails with them | Strongest explanation of the value of both agents | 1-3 minutes | 5-10 minutes | Moderate |
| 2 | Checkout points at the wrong payment route | Smallest application change and a clear configuration recovery | 1-3 minutes | 5-10 minutes | Low |
| 3 | Payments become slow, but still succeed | Shows diagnosis of degraded customer experience rather than an outage | 2-4 minutes | 5-10 minutes | Moderate |
| 4 | Memory growth detected before exhaustion | Reuses the existing fault and demonstrates preventive intervention | 3-5 minutes after retuning | 7-10 minutes | Moderate, primarily timing and safety work |

### Scenario 1: One payment failure, several symptoms

**Story:** A payment-service configuration change causes transactions to fail.
Customers see checkout failures, although the containers are still running.

**Trigger:** Enable a demo-only switch that makes payment requests return a
predictable error. The capable image is deployed beforehand. Keep a small,
steady stream of synthetic checkout requests running.

**Alert and investigation:** Prepare a payment failure alert and a related
checkout failure alert. Observability correlates them into an incident story
and investigates the downstream/upstream relationship. SRE starts from the
selected primary alert, checks the active configuration and recent change,
and evaluates the handed-over findings.

**Proposed fix and action:** SRE proposes disabling the payment-failure switch
and deploying the healthy configuration. The human approves; SRE performs
the change. Fresh orders succeed through the same frontend path that failed.

**Reset:** Restore the healthy switch value and confirm that alerts and issue
state are ready for another run.

**Why it works:** It makes Observability's correlation role visible while
giving SRE one small, reversible change. It needs a new error switch and
error alerts. If the alerts are not actually grouped during rehearsal, do not
claim automatic deduplication; a single-alert investigation is a different,
more limited result.

### Scenario 2: Healthy services, incorrect payment route

**Story:** An operator changes checkout's internal payment address incorrectly.
Every service still passes its local health check, but orders fail.

**Trigger:** Change the existing internal payment URL to use a nonexistent
path on the correct payment host. This produces an immediate route error,
rather than an unpredictable DNS or connection timeout.

**Alert and investigation:** An end-to-end checkout failure alert fires.
Observability follows the failed dependency calls and identifies the affected
transaction path, distinguishing routing/configuration failure from resource
exhaustion. SRE compares the current setting with the known-good configuration
and checks the recent change.

**Proposed fix and action:** SRE proposes restoring the known-good internal
payment URL. After approval, it updates checkout's configuration. Fresh orders
confirm that connectivity and application behavior have recovered.

**Reset:** Restore the saved baseline value; do not leave the invalid address
in Terraform or a later deployment.

**Why it works:** It uses existing application behavior and avoids new Azure
services. It still needs alerting, a guarded trigger/reset and a response plan.
It overlaps with scenario 1's failed-order symptoms, so choose between them
for a short session rather than presenting both back-to-back.

### Scenario 3: Slow payment dependency

**Story:** Customers can check out, but payment processing becomes noticeably
slow after a configuration change.

**Trigger:** Enable a fixed, bounded payment delay, such as two additional
seconds, using a predeployed demo switch. Keep traffic volume controlled.

**Alert and investigation:** A sustained checkout-latency alert fires.
Observability traces the delay to the payment dependency and compares it with
healthy behavior. Successful response codes are part of the evidence:
this is a performance regression, not a complete outage.

**Proposed fix and action:** SRE checks the changed configuration, proposes
removing the artificial delay and, after approval, applies the healthy
configuration. Recovery means end-to-end latency returns near its measured
baseline, not simply that requests return success.

**Reset:** Disable the delay and continue baseline traffic until the latency
alert has cleared.

**Why it works:** The audience can feel the slowdown and see the recovery.
It needs a bounded delay switch and latency alerting. Do not use uncontrolled
load or accumulation of delayed requests; that could turn a clear latency
demo into an unrelated resource-exhaustion incident. Scaling is not a fix for
a fixed per-request artificial delay.

### Scenario 4: Stop a memory incident before checkout fails

**Story:** Payment memory starts rising abnormally. The agents investigate and
remove the cause before customers lose the ability to check out.

**Trigger:** Reuse the existing memory-leak flag, with an explicit short-demo
calibration established during preparation.

**Alert and investigation:** Use an earlier warning condition above the
measured healthy range and a shorter averaging window. Recalibrate the leak's
time-to-threshold as well: simply lowering its threshold does not necessarily
make the current calibrated implementation cross sooner. Observability
investigates the memory trend and whether requests are affected; SRE checks
the flag, revision change and source.

**Proposed fix and action:** SRE proposes disabling the leak and starting a
healthy revision. After approval, it executes that change. Memory should
return to a stable range, not merely drop and begin rising again.

**Reset:** Use the existing reset path, verify the healthy revision and allow
the previous alert state to clear before rearming.

**Why it works:** It retains the repository's original story. However, it is
less immediately visible than failed or slow orders. Preserve enough memory
headroom for the entire investigation and approval budget; do not accelerate
allocations until the process crashes. An operator safety reset is a safety
intervention, not evidence that SRE solved the incident.

## 6. Making the short format credible

### Define the clock precisely

The clock starts when the presenter triggers the fault, not when an alert
finally appears. It includes rollout, telemetry arrival, alert evaluation,
investigation, handoff and approval.

| Elapsed time target | What the audience should see |
| --- | --- |
| 0-1 minute | The controlled fault becomes visible |
| 1-3 minutes | A real alert fires; error scenarios should be the fastest |
| By 5 minutes | Agent investigation is visibly underway, with Observability issue creation and useful evidence appearing |
| 5-8 minutes | SRE presents a specific, evidence-backed fix |
| By 10 minutes | The human has approved and SRE has executed the recovery change |

These are design budgets, not independent promises that can simply be added
together. Memory is expected to use more of the early budget. Successful
requests may demonstrate recovery within the same ten minutes, but final
metric stabilization, alert auto-resolution and issue closure can take longer.
Do not label a proposed action as an executed fix, or a completed configuration
update as verified recovery.

**A hard guarantee that both agents finish and the incident is fully closed
within ten minutes is not supportable from the evidence reviewed.** Preview
correlation, deep investigation, telemetry latency and Azure rollout time are
not bounded by this repository. If ten minutes is an absolute event-slot limit,
keep a clearly labelled recording of a real rehearsed run rather than promising
deterministic live completion.

### Preparation that keeps the live flow simple

Build images, deploy resources, onboard the agents, grant permissions, index
source and establish healthy traffic before the audience arrives. Keep the
apps warm. No builds, new identity assignments or private-network setup
belong in the live incident clock.

Use one isolated demo environment, one active fault and reversible
configuration switches. Keep the internal services internal. Retain existing
state/resource guardrails in any new trigger/reset path; do not introduce a
public fault-injection endpoint.

Prepare short-window, static demo alerts from measured baseline behavior.
Do not rely on a newly trained dynamic baseline or merely on a failed health
probe. Prefer a fast supported metric where it represents the actual symptom;
if request evidence requires log-based alerting, include measured ingestion
delay in the rehearsal budget.

Configure Observability to investigate the relevant named alerts, including
single-alert promotion where needed. Confirm that Application Insights
topology associates the affected Container Apps with the monitored application.
Do not assume that selecting the workspace makes every platform alert visible
to this application-scoped autonomous workflow.

Require Review mode on **every matching SRE response plan** and confirm the
actual incident thread has the approval boundary. The current Scenario A
configuration has an Autonomous fallback; an unconfigured new alert must not
silently take that path. Keep the authorized approver signed in.

### Rehearsal acceptance

Before presenting a scenario, record at least three consecutive runs from
the healthy state. Capture trigger time, fault visibility, alert firing,
Observability issue creation, useful findings, SRE proposal, approval,
executed action and observable recovery. Preserve the evidence links.

The short-demo acceptance condition is that **all three rehearsals execute
the approved action within ten minutes**, with automatic investigation start
and an actual Observability evidence contribution before approval. This is
a proposed acceptance gate, not a current test result or statistical SLA.
Record recovery and closure times separately even when they exceed the slot.

If the paired run misses the budget, say so. An on-demand Observability
investigation is a valid assisted demonstration but does not prove autonomous
issue creation. SRE acting independently is valid incident automation but
does not prove that it consumed Observability findings. Neither should be
quietly substituted for the claimed two-agent flow.

## 7. Recommended scope and delivery order

The following was the initial low-change recommendation. For the selected
separate private deployment, use the [Scenario D plan](scenario-d-private-payments-plan.md)
and its policy, coexistence and private-runner prerequisites instead.

First establish the shared Scenario A setup and a measured timing baseline
using the smallest configuration-failure option. Then make the controlled
payment-error scenario the flagship once alert correlation is demonstrated.
Add the latency option if the audience needs a performance story; retain the
retuned memory incident for preventive reliability.

Keep B/C as a separate governance presentation. They currently lack the
Observability prerequisites, and their PR review, merge and pipeline path
introduces timing that is not compatible with promising a short live recovery.
A remediation PR is a proposed change, not a solved incident.

Do not switch A/B/C profiles during the presentation: the repository deliberately
requires teardown between them. Do not add a queue, database, private runner,
AKS cluster, simulated regional outage or permission-propagation failure just
to produce more scenarios. Those add moving parts without clarifying the two
agents' respective roles.

**The intended audience takeaway:** "Observability explained the incident and
its impact. SRE validated the cause and carried out the approved recovery.
We can see the evidence, the decision and the outcome."

## Sources

Microsoft documentation and public customer material were reviewed on
12 October 2026. The feature descriptions above use current Microsoft Learn
pages; customer outcomes remain attributed reports, not independent benchmarks.
Neither cloud changes nor live incident rehearsals were performed for this
proposal.

- [Azure Copilot Observability Agent overview][obs-overview]
- [Autonomous operations in the Azure Copilot Observability Agent][obs-autonomous]
- [Deep investigations in the Azure Copilot Observability Agent][obs-investigation]
- [Overview of Azure SRE Agent][sre-overview]
- [Run modes in Azure SRE Agent][sre-modes]
- [Rethinking cloud operations with agentic observability: GA announcement and customer accounts][obs-customers]
- [From insight to action: the next phase of agentic cloud operations][agentic-operations]
- [Ecolab and Azure SRE Agent: public Microsoft customer-story summary][ecolab-summary]

[obs-overview]: https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-overview
[obs-autonomous]: https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-autonomous-operations
[obs-investigation]: https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-deep-investigations
[sre-overview]: https://learn.microsoft.com/azure/sre-agent/overview
[sre-modes]: https://learn.microsoft.com/azure/sre-agent/run-modes
[obs-customers]: https://blogs.microsoft.com/blog/2026/06/23/rethinking-cloud-operations-with-agentic-observability/
[agentic-operations]: https://azure.microsoft.com/en-us/blog/from-insight-to-action-the-next-phase-of-agentic-cloud-operations/
[ecolab-summary]: https://www.microsoft.com/en-us/thesource-developer/Event/469/ecolab-embraces-agentic-ai-and-streamlines-root-cause-analysis-with-azure-sre-agent
