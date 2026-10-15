# Scenario C clean-fork evidence and review disposition

This is an anonymized historical review record, not a customer setup checklist
or a claim that its entire proposed improvement set has been implemented.
Source repository, author, commit and workflow-run identifiers have been
removed from the distributable copy. Review and offline hardening were
performed on 2026-10-09. No new tenant was exercised by this documentation audit.

## Evidence from 2026-09-23

| Evidence | Classification | Scope |
| --- | --- | --- |
| Historical fork deploy | Previously observed workflow result | Validation and deploy succeeded; incident-arming job was skipped |
| Historical fork destroy | Previously observed workflow result | Destroy succeeded before the subsequent clean deployment |
| Regional capacity failures, HTTP 200 frontend, imported App key, and operator access | Operator-reported in the original review | These claims were not independently reproduced during the offline review |
| Literal app-link zone names allowed links to run before managed zones | Inferred from Terraform graph; consistent with reported failure | Corrected by referencing the managed zone in the managed branch |
| Agent-authored remediation PR, alert correlation, and memory recovery in this fork | Not tested by the cited bootstrap runs | Requires a separate incident-phase exercise |
| Existing enterprise Blob DNS zone in another resource group | Not tested | The test runner network had no foreign Blob zone |
| Scenario A and B deployment and incident flows | Not tested by these fork runs | Offline A/B networking plans only verify private-resource exclusion |

Successful bootstrap is not evidence of the complete incident-to-remediation
loop. Existing upstream incident evidence is separate from this clean-fork
exercise and is not invalidated by its narrower scope.

## Accepted changes

- Keep the targeted Key Vault and ACR app-link dependency fix. Shared-zone
  mode retains the namespace without indexing a managed zone that has count
  zero.
- Replace the permissive text-only test with actual Terraform graph edges,
  comment-only negative controls, and mocked plans for managed/shared/mixed
  zones and A/B disabled networking. Run these checks in unprivileged PR CI.
- Choose regions using current subscription availability and residency needs,
  not the outcome of one historical deployment. Availability is not reserved
  capacity.
- Keep state until cleanup is verified, including provider-created resources
  absent from state. Follow the verified destroy/recovery workflow, then check
  actual resource-group removal before a clean regional redeployment.
- Describe one successful bootstrap run rather than promising every run will
  succeed first time.
- Correct workload Reader claims, Key Vault key terminology, OIDC subject
  variants, runner prerequisites, and the distinction between describing a fix
  and creating a remediation PR.

## Findings that need qualification

The Monitoring Contributor grant is a documented service requirement for alert
lifecycle management, not by itself evidence of a critical exploitable
vulnerability. It does make an absolute read-only claim incorrect.
Both identities receive it in the current Terraform. Do not remove either
grant without investigating the service's identity usage and validating the
incident path.

The production OIDC credential must match the fork's actual assertion.
Name-only subjects and immutable-ID subjects are both supported; the latter
was reported in this fork. Dev/test uses a separate environment subject.
Do not publish raw tokens or real identity IDs in source.

Blocking input validation is required for fail-fast behavior: Terraform
`check` blocks alone are not a substitute for validations or preconditions
that stop resource creation.

## Outstanding follow-up work

These are requirements for later hardening, not behavior delivered here:

The original review grouped follow-ups as fail-fast configuration, Blob DNS
ownership, and incident/identity verification. Check the current implementation
before opening equivalent work in your own repository; historical issue links
are deliberately not operational dependencies. Priorities and estimates require
product-owner review.

- Remove generic runner-network fallbacks consistently across deploy, apply,
  application deployment, and normal destroy, without breaking recovery.
- Validate CIDR containment and overlap as a complete address plan, including
  every runner VNet address range, before backend/resource creation.
- Replace suppressed backend role-assignment errors with explicit idempotency
  and actionable authorization failures.
- Add a service-account runner preflight before Azure mutations.
- Reuse enterprise-managed Blob DNS zones, record ownership, and ensure
  cleanup never deletes shared zones, links, endpoints, or other profile state.
- Investigate whether both identities need Monitoring Contributor, without
  changing role assignments based solely on documentation assumptions.
- Exercise the clean-fork incident, agent-authored PR, human merge, recovery,
  and teardown; verify GitHub App permissions and installation in the UI.

## Sources

- [Terraform references and implicit dependencies](https://developer.hashicorp.com/terraform/language/expressions/references#named-values-and-dependencies)
- [Terraform test provider mocking](https://developer.hashicorp.com/terraform/language/tests/mocking)
- [GitHub OIDC subject formats](https://docs.github.com/en/actions/reference/security/oidc)
- [Azure SRE Agent permissions](https://learn.microsoft.com/azure/sre-agent/permissions)
- [Azure SRE Agent supported regions](https://learn.microsoft.com/azure/sre-agent/supported-regions)
- [Azure Container Apps regional relocation](https://learn.microsoft.com/azure/container-apps/relocate-region)
