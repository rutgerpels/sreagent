# Scenario D — Observability Agent custom instructions

Terraform emits these values in the `observability_agent_onboarding` output
(`custom_instructions`). Paste that output value during portal onboarding so the
names carry the real deployment suffix. This file is the readable reference.

```text
Always create an issue for alert-payment-failures-<suffix> and alert-checkout-failures-<suffix>, even when only one has fired.
ContosoPay call chain: frontend calls checkout-api, which calls payment-service. Checkout failures that follow payment failures are a downstream symptom, not a separate root cause.
The checkout and payment paths are business-critical.
Do not correlate alerts from other demo resource groups with alerts from <resource-group>.
Include [OPS-REVIEW] in every issue title.
```

## Role in the demo

The Observability Agent investigates the alert and produces an issue with
findings. It does not change anything. The operator carries that evidence to the
SRE Agent; see [`handoff-prompt.md`](handoff-prompt.md).

## Prerequisites

- Portal-only onboarding (the preview has no Terraform support).
- Use the dedicated identity from the `observability_agent_onboarding` output.
- Subscription Monitoring Reader and Issue Contributor are assigned by Terraform.
