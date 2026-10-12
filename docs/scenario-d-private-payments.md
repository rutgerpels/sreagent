# Scenario D — payments fail, checkout fails with them

> **Status: built, not yet live-verified.** Everything below is designed from the
> [plan](scenario-d-private-payments-plan.md) and checked offline only. The
> 10-minute target is an unmeasured rehearsal goal. Run three consecutive paired
> rehearsals before presenting.

Scenario D pairs the Azure Copilot Observability Agent with the Azure SRE Agent
on a private-network deployment, separate from Scenarios A, B and C.

## Flow

```text
traffic running -> trigger script -> payment returns 503 -> checkout returns 502
 -> payment-failure alert -> Observability Agent issue
 -> operator pastes evidence into the SRE thread
 -> SRE verifies, proposes PAYMENT_FAILURE_MODE=off -> human approves
 -> fresh healthy revision -> alert resolves
```

| Agent | Role | Writes? |
| --- | --- | --- |
| Observability Agent | Investigates the alert, correlates payment and checkout failures, opens an issue. | No |
| SRE Agent (Review mode) | Verifies the evidence, proposes the flag change, applies it after approval. | Only after approval |

The handoff is manual: the operator pastes the issue link and findings into the
existing SRE thread using [`agent/scenario-d/handoff-prompt.md`](../agent/scenario-d/handoff-prompt.md).
It is not native agent-to-agent communication.

## The fault

`payment-service` reads `PAYMENT_FAILURE_MODE` (`off` or `unavailable`). When
`unavailable`, `POST /pay` returns 503 and `checkout-api` maps that to 502 for
the frontend. Health and readiness probes stay green, so the app is still
"up". Terraform desired state is always `off`; the trigger is a live deviation.

## One-time setup (operator)

1. **Policy check (Gate 0).** Inherited policies may disable key auth. D uses
   Entra and RBAC only. Do not disable policies, add exemptions or re-enable keys;
   report real conflicts as blockers.
2. **Separate identity.** Create the GitHub Environment `scenario-d` with its
   own OIDC federated credential. Do not reuse another scenario's.
3. **Repository variables** (defaults in brackets):
   `D_RUNNER_NETWORK_RG` [`agentrg-d`], `D_RUNNER_VNET_NAME` [`agent-vnet-d`],
   `D_RUNNER_PE_SUBNET_NAME` [`private-endpoints`],
   `D_APP_VNET_ADDRESS_SPACE` [`10.101.0.0/16`],
   `D_APP_PE_SUBNET_PREFIX` [`10.101.0.0/27`],
   `D_CONTAINER_APPS_SUBNET_PREFIX` [`10.101.0.64/27`],
   `D_SRE_AGENT_SUBNET_PREFIX` [`10.101.0.96/27`].
4. **Runner and state.** Provision the self-hosted runner with labels
   `self-hosted, Linux, X64, azure-private-d, contosopay` in the D runner VNet, and
   the private state storage, from an operator context. The private runner cannot
   bootstrap its own state endpoint.
5. **Variables file.** Copy `scenario-d.tfvars.example` locally for reference.
   The workflow supplies values; never commit a real tfvars file.

## Deploy

1. Run the **Deploy** workflow manually with `scenario = D` and the D prefix
   (`payd`). D is manual-only, rejects ephemeral mode and refuses a prefix equal to
   the repository's active prefix.
2. Note the outputs: `frontend_url`, `payment_failure_alert_name`,
   `checkout_failure_alert_name`, `observability_agent_onboarding`.
3. **Onboard the Observability Agent** in the portal using the output values and
   [`agent/scenario-d/observability-agent.instructions.md`](../agent/scenario-d/observability-agent.instructions.md).
4. **Create the SRE Agent configuration** in the portal: Review mode on every
   response plan and the fallback, target only the D payment-failure alert, paste
   [`agent/scenario-d/sre-agent.instructions.md`](../agent/scenario-d/sre-agent.instructions.md).
   No GitHub connector. The reconciler does not manage D.
5. Confirm alert isolation both ways: A/B/C agents must not respond to D, and the
   D agent must not respond to A/B/C.

## Run the demo

Start traffic **before** the clock; it must be flowing so alerts have data.

```bash
./scripts/generate-checkout-traffic.sh --duration 900
```

```powershell
pwsh ./scripts/generate-checkout-traffic.ps1 -DurationSeconds 900
```

Trigger the incident (refuses unless the target is the D deployment):

```bash
./scripts/trigger-incident-payments.sh
```

```powershell
pwsh ./scripts/trigger-incident-payments.ps1
```

Then:

1. The payment-failure alert fires (3 or more failed `/pay` in the window).
2. The Observability Agent opens an issue.
3. Paste the handoff prompt into the SRE thread.
4. Review the SRE proposal, approve the flag change, and check the recovery.

## Reset

```bash
./scripts/trigger-incident-payments.sh --reset
```

```powershell
pwsh ./scripts/trigger-incident-payments.ps1 -Reset
```

Reset also rolls a fresh revision. A later `terraform apply` will not rearm the
fault because desired state is `off`.

## Teardown

Run the **Destroy** workflow with `scenario = D`. It destroys the workload first,
then runner, network and state. Ephemeral teardown is rejected.

Known limitation: the force-delete path does not remove the subscription-scope
Monitoring Reader assignment for the Observability identity. A normal Terraform
destroy does.

## Other workflows

`apply-infra.yml`, `deploy-apps.yml`, `dev-test.yml` and `validate.yml` reject D
by design: D is manual-only and never triggered by pushes.

## Not verified yet

- Policy compliance with the live inherited policies.
- Private connectivity from the runner, ACR and Key Vault.
- Role propagation and agent onboarding.
- Alert latency and the end-to-end timing.
