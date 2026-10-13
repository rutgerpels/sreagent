# Scenario D — payments fail, checkout fails with them

> **Status: live-deployed and alert-verified, rehearsal in progress.** In the
> first rehearsal the payment alert fired about 2 minutes after the fault was
> armed and the checkout alert about 1.5 minutes after that. Observability Agent
> pickup, SRE pickup, proposal, approval and recovery times are not measured yet;
> the timing table in [Rehearsal log](#rehearsal-log) is for you to fill in.

Scenario D pairs the Azure Copilot Observability Agent with the Azure SRE Agent
on a private-network deployment, separate from Scenarios A, B and C. This page
is the operator script: follow it top to bottom during a rehearsal or a demo.

## The story in one minute

```text
traffic running -> fault armed -> payment returns 503 -> checkout returns 502
 -> payment + checkout alerts fire
 -> Observability Agent investigates and opens an issue (read-only)
 -> operator pastes the evidence into the SRE Agent thread
 -> SRE Agent verifies, proposes PAYMENT_FAILURE_MODE=off
 -> human approves -> fresh healthy revision -> alerts resolve
```

| Agent | Role | Writes? |
| --- | --- | --- |
| Observability Agent | Investigates the alerts, shows that checkout failures are a symptom of the payment failure, opens an issue. | No |
| SRE Agent (Review mode) | Verifies the evidence itself, proposes the smallest fix, applies it after approval. | Only after approval |

The handoff is manual: you paste the findings into the SRE thread. It is not
native agent-to-agent communication, and you should say so on stage.

## What the fault is

`payment-service` reads `PAYMENT_FAILURE_MODE` (`off` or `unavailable`). When
`unavailable`, `POST /pay` returns 503 and `checkout-api` maps that to 502 for
the frontend. Health and readiness probes stay green, so the app looks "up"
while every order fails. Terraform's desired state is always `off`; the trigger
is a temporary live deviation.

## Environment reference

Replace the names below if the deployment suffix changed. Deployment suffixes
are random per deploy.

| Item | Value |
| --- | --- |
| Subscription | `ME-MngEnv224247-rutgerpels-1` (select by name, never commit the ID) |
| Region | `swedencentral` |
| Resource group | `rg-payd-demo-d-<suffix>` |
| Frontend (public) | `ca-frontend-d-<suffix>` |
| Checkout API (internal) | `ca-checkout-d-<suffix>` |
| Payment service (internal) | `ca-payment-d-<suffix>` |
| Alerts | `alert-payment-failures-d-<suffix>`, `alert-checkout-failures-d-<suffix>` |
| SRE Agent | `sre-payd-d-<suffix>` (High access, Contributor, Review mode) |
| Runner | `vm-payd-runner` in `agentrg-d` (private runner, stays outside Terraform) |

## Part 0 — Preflight (before the clock)

1. **Select the subscription and find the names.**

   ```powershell
   $id = az account list --query "[?name=='ME-MngEnv224247-rutgerpels-1'].id | [0]" -o tsv
   az account set -s $id
   $rg = 'rg-payd-demo-d-<suffix>'
   az containerapp list -g $rg --query "[].name" -o tsv
   ```

2. **Check the frontend answers and the fault is off.**

   ```powershell
   $fe = az containerapp show -g $rg -n ca-frontend-d-<suffix> --query "properties.configuration.ingress.fqdn" -o tsv
   (Invoke-WebRequest "https://$fe" -UseBasicParsing).StatusCode   # expect 200
   az containerapp show -g $rg -n ca-payment-d-<suffix> --query "properties.template.containers[0].env[?name=='PAYMENT_FAILURE_MODE']" -o json   # expect "off"
   ```

3. **Check both alerts exist** in the portal under the resource group
   (Alerts, Alert rules), or with `az resource list -g $rg`.
4. **Open the SRE Agent thread** at <https://sre.azure.com>, select
   `sre-payd-d-<suffix>`, and confirm Review mode. Start a new thread for this
   run so the evidence stays clean.
5. **Open the Observability Agent** in the Azure portal (Azure Copilot,
   Observability Agent, preview) and confirm it is onboarded with the dedicated
   identity and instructions (see
   [Observability Agent onboarding](#observability-agent-onboarding)).
6. **Keep these tabs open:** Azure portal alert list, Application Insights Live
   Metrics or Failures blade, the SRE Agent thread, the Observability Agent
   issue list.

## Part 1 — Start healthy traffic

Traffic must be flowing **before** the clock starts, so the alerts have data
and the baseline is visible. The script needs the frontend URL.

```powershell
pwsh ./scripts/generate-checkout-traffic.ps1 -FrontendUrl "https://$fe" -DurationSeconds 1200
```

```bash
./scripts/generate-checkout-traffic.sh --url "https://$FE" --duration 1200
```

Leave it running in its own terminal. Wait about 2 minutes and show that the
success rate is healthy (0 failures) in Application Insights.

**Say:** "ContosoPay checkout is healthy. Frontend is the only public endpoint;
checkout and payment are internal."

## Part 2 — Trigger the incident (T0)

Arm the fault on the live payment app. Note the time.

```powershell
az containerapp update -g $rg -n ca-payment-d-<suffix> --set-env-vars PAYMENT_FAILURE_MODE=unavailable
Get-Date -Format "HH:mm:ss"   # write down as T0
```

Why not `trigger-incident-payments`? The script reads Terraform state, which
lives in private storage and is only reachable from the runner VNet. From a
laptop, use the `az` command above. The script is for use on the runner.

**Say:** "A dependency change just broke payments. Health checks are still
green, but every order will fail."

## Part 3 — Alerts fire

Expected from the first rehearsal (5-minute evaluation frequency):

| Moment | What you see |
| --- | --- |
| T0 + about 2 min | `alert-payment-failures-d-<suffix>` fires |
| T0 + about 3.5 min | `alert-checkout-failures-d-<suffix>` fires |

Watch the alert list in the portal. The D response plan
`contosopay-payment-failures` is scoped to the payment alert, so the SRE Agent
may begin its own investigation when that alert fires. That is fine; it is the
parallel path.

**Say:** "Two alerts, one cause. The checkout alert is a downstream symptom of
the payment alert."

## Part 4 — Observability Agent investigates

1. In the Azure portal open the Observability Agent and find the new issue,
   titled with `[OPS-REVIEW]`.
2. Show what it did: correlated both alerts, identified `payment-service` as
   the source, called checkout a downstream symptom, and listed the affected
   resources and time window.
3. Copy these from the issue: the issue URL, the time window (UTC), the
   affected resources, and the summary.

**Say:** "The Observability Agent is read-only. It explains what is happening
and why. It does not fix anything."

If no issue appears within 5 minutes after the second alert, see
[If something goes wrong](#if-something-goes-wrong).

## Part 5 — Hand over to the SRE Agent

In the SRE Agent thread, paste the handoff prompt from
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
4. Confirm the alerts resolve in the portal (resolution follows the next
   evaluation, up to about 5 minutes).

```powershell
az containerapp show -g $rg -n ca-payment-d-<suffix> --query "properties.template.containers[0].env[?name=='PAYMENT_FAILURE_MODE']" -o json   # expect "off"
```

**Say:** "From alert to approved fix, with the evidence from two agents and one
human decision."

## Part 8 — Reset for the next rehearsal

Recovery already sets the flag to `off`. To reset manually (for example if you
stopped before approving):

```powershell
az containerapp update -g $rg -n ca-payment-d-<suffix> --set-env-vars PAYMENT_FAILURE_MODE=off
```

Stop the traffic script. Close the old SRE thread and start a new one for the
next run. Wait for the alerts to resolve before arming again.

A later `terraform apply` does not rearm the fault because desired state is
`off`.

## If something goes wrong

| Symptom | Check |
| --- | --- |
| No payment alert after 6 minutes | Is traffic running? The alert needs 3 or more failed `/pay` calls in the window. Check `PAYMENT_FAILURE_MODE` really is `unavailable`. |
| Alert fired but SRE Agent did nothing | Confirm the response plan `contosopay-payment-failures` is enabled in the D agent. You can still paste the handoff prompt, or ask the agent to investigate the alert. |
| No Observability Agent issue | Preview feature, portal only. Confirm onboarding, the dedicated identity and its Monitoring Reader role. Fall back to describing the issue verbally and continue at Part 5. |
| SRE thread shows no tool output | The SRE data plane cannot be read programmatically from here (403). Use <https://sre.azure.com> only. |
| Frontend returns errors before the trigger | Wait for the latest revision to be ready; re-run Part 0. |

## Observability Agent onboarding

The Observability Agent is a preview with portal-only onboarding; Terraform
cannot create it. Use the Terraform output `observability_agent_onboarding`
(dedicated identity, resource group, instructions with the real suffix) and the
reference file
[`agent/scenario-d/observability-agent.instructions.md`](../agent/scenario-d/observability-agent.instructions.md).
Terraform assigns the identity Monitoring Reader on the subscription and Issue
Contributor.

## Deploy, restart and teardown

The SRE Agent is configured automatically by the Deploy workflow from
[`agent/scenario-d/`](../agent/scenario-d/): the payment-recovery subagent, the
`contosopay-payment-failures` response plan (Review mode, D payment alert only),
a daily health task and the D tool policy. No portal steps and no GitHub
connector.

**Deploy** (about 10 minutes, mostly the image build):

1. Start the runner and wait until it shows online in GitHub:

   ```powershell
   az vm start -g agentrg-d -n vm-payd-runner
   ```

2. Run the **Deploy** workflow manually with `scenario = D`, prefix `payd`,
   environment `demo`, location `swedencentral`. State storage is bootstrapped
   automatically. D is manual-only and rejects ephemeral mode.
3. If a run is cancelled right after Terraform init, re-run it.

**Teardown** (more than 30 minutes, the Terraform destroy step is slow):

1. Make sure the runner is running.
2. Run the **Destroy** workflow with `scenario = D`, prefix `payd`,
   environment `demo`, `delete_state_storage = false`.
3. The runner VM and its network (`agentrg-d`) are outside the Terraform
   destroy and are kept. Stop it afterwards:

   ```powershell
   az vm deallocate -g agentrg-d -n vm-payd-runner
   ```

Known limitation: the force-delete recovery path does not remove the
subscription-scope Monitoring Reader assignment for the Observability identity.
A normal Terraform destroy does.

## One-time setup (operator)

1. **Policy check.** Inherited policies may disable key auth. D uses Entra and
   RBAC only. Do not disable policies or add exemptions; report real conflicts as
   blockers.
2. **Separate identity.** Use the GitHub Environment `scenario-d` and its own
   OIDC federated credential. Do not reuse another scenario's.
3. **Runner.** Create the private runner with `scripts\deploy-runner-d.ps1`
   (`-SubscriptionName` is required; PowerShell 7). It builds the VNet and VM
   from `infra/runner-d` with labels `self-hosted, Linux, X64, azure-private-d,
   contosopay`.
4. **Repository variables** (defaults in brackets):
   `D_RUNNER_NETWORK_RG` [`agentrg-d`], `D_RUNNER_VNET_NAME` [`agent-vnet-d`],
   `D_RUNNER_PE_SUBNET_NAME` [`private-endpoints`],
   `D_APP_VNET_ADDRESS_SPACE` [`10.101.0.0/16`],
   `D_APP_PE_SUBNET_PREFIX` [`10.101.0.0/27`],
   `D_CONTAINER_APPS_SUBNET_PREFIX` [`10.101.0.64/27`],
   `D_SRE_AGENT_SUBNET_PREFIX` [`10.101.0.96/27`].
5. **No real tfvars in git.** The workflow supplies values; never commit a real
   tfvars file.

Other workflows (`apply-infra.yml`, `deploy-apps.yml`, `dev-test.yml`,
`validate.yml`) reject D by design: D is manual-only and never triggered by
pushes.

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

- Observability Agent pickup time and issue quality.
- SRE Agent pickup, proposal and recovery times.
- Whether the SRE Agent starts on the alert alone or only after the handoff.
- Three consecutive clean paired rehearsals.
