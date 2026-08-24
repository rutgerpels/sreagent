# Choose your demo scenario

All three scenarios use the same application, the same planted memory leak, and
the same Azure Monitor alert. What changes is **how much the Azure SRE Agent is
allowed to do, and through which path**.

Pick one, then follow its step-by-step guide from start to finish.

---

## The three scenarios

### Scenario A — the agent fixes it

> "Detect, explain, fix." The agent holds Contributor on one resource group and
> remediates Azure directly after you approve.

Best for showing capability quickly. Shortest setup, most dramatic moment.

**→ [Scenario A walkthrough](scenario-a-direct.md)** · ~35 min prep, ~20 min live

### Scenario B — the agent opens a pull request

> "It found the bug and raised the PR." The agent holds only Reader, refuses to
> touch Azure, and remediates by proposing a one-line change that a human merges.

Best for enterprises with change management. Usually the most convincing
scenario for an operations or security audience.

**→ [Scenario B walkthrough](scenario-b-gitops.md)** · ~45 min prep, ~25 min live

### Scenario C — the same, inside your network

> Private endpoints, a self-hosted runner, a bring-your-own GitHub App, and an
> agent configured entirely from a committed manifest. In the current preview
> the agent proposes the fix and a human opens the pull request.

Best for regulated industries and security architects who need to see the
network and configuration posture before they care about the agent's behaviour.

**→ [Scenario C walkthrough](scenario-c-private-gitops.md)** · ~100 min prep, ~25 min live

---

## Side-by-side comparison

| | Scenario A | Scenario B | Scenario C |
| --- | --- | --- | --- |
| Story | Autonomous direct recovery | Enterprise GitOps | Private-network enterprise GitOps |
| Agent profile | High / Contributor / Autonomous | Low / Reader / Review | Low / Reader / Review |
| Control endpoints | Public | Public, RBAC and TLS protected | Private state, ACR, and Key Vault |
| Deployment runner | GitHub-hosted or local wrapper | GitHub-hosted or local wrapper | Private self-hosted runner |
| Code context | Code Access | Code Access | Read-only bring-your-own GitHub App |
| Write path | Direct Azure action | Built-in GitHub MCP connector with a short-lived fine-grained PAT | None in the current preview; a human opens the remediation pull request |
| Agent configuration | Portal | Portal | Terraform plus an idempotent REST reconciler |
| Credential to revoke afterwards | None | The fine-grained PAT | The GitHub App key, if you used Code Access |

**Code Access and GitHub writes are different capabilities.** Code Access
indexes and correlates source. Only Scenario B adds a write connector. Scenario
C prepares a broker and a separate remediation App but does not connect them
while remote Streamable-HTTP managed-identity authentication is undocumented.
Scenario A has no GitHub write path at all.

---

## Before you pick

**One scenario at a time.** Terraform takes a single `scenario` value and
derives the whole profile from it. Resource names, the state account, and the
state blob key all include the scenario. In-place conversion is unsupported and
rejected by every deployment path.

To switch scenarios: destroy the active one, delete the `DEPLOYMENT_SCENARIO`,
`TF_PREFIX`, and `TF_ENVIRONMENT` repository variables, and only then deploy the
next one. Details in the
[deployment and state reference](deployment-reference.md#profile-and-state-safety).

**Every scenario shares the same five-act structure.** If you know one, you know
the shape of the others:

1. Establish a healthy baseline.
2. Arm the fault.
3. Wait 8–12 minutes while memory climbs and the alert fires.
4. Let the agent investigate and explain.
5. Remediate through that scenario's boundary, then verify recovery.

---

## Further reading

- [Deployment and state reference](deployment-reference.md) — OIDC setup,
  activation markers, state isolation, local wrapper, teardown
- [Azure SRE Agent setup reference](sre-agent-setup.md) — the shared agent model
  across all three scenarios
- [AKS variant notes](aks-variant.md)
- [Azure SRE Agent run modes](https://learn.microsoft.com/azure/sre-agent/run-modes)
- [Azure SRE Agent permissions](https://learn.microsoft.com/azure/sre-agent/permissions)
