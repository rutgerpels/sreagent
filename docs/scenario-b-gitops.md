# Scenario B: GitOps remediation by pull request

**The story you tell.** The same memory leak — but this time the agent holds
**Reader** on Azure and cannot change anything. It investigates, reaches the
same conclusion, and then does what a good engineer does: it opens a pull
request containing exactly one line of change. A human reviews and merges it,
and the existing CI/CD pipeline deploys the fix.

**Who this is for.** Enterprises with change management, audit requirements, or
a hard "nothing touches production outside the pipeline" rule. This is usually
the scenario that closes the room.

**Time budget.**

| Phase | What you do | Duration |
| --- | --- | --- |
| 1 | Prepare the repository | ~5 minutes |
| 2 | Deploy the environment | ~20 minutes (mostly unattended) |
| 3 | Configure the SRE Agent | ~20 minutes |
| 4 | Run the demo live | ~25 minutes |
| 5 | Reset, revoke, and tear down | ~20 minutes |

Phases 1–3 are preparation. Only phase 4 happens in front of the audience.

---

## What the audience will see

1. A healthy checkout application, with only the frontend reachable from the
   internet.
2. You merge a pull request that arms the fault — the incident enters the system
   as a reviewable change, exactly like a real regression would.
3. Memory climbs, and Azure Monitor fires a Sev2 alert 8–12 minutes later.
4. The agent correlates the alert with telemetry **and the merge commit that
   caused it**.
5. Someone asks the agent to just restart the service. It **refuses** — the tool
   policy denies Azure mutation.
6. Instead, the agent opens a pull request changing one line.
7. A human reviews and merges. CI deploys. Memory flattens. The alert resolves.

---

## Before you start

| Requirement | How to check |
| --- | --- |
| An Azure subscription where you can create resources **and role assignments** | You need Owner or User Access Administrator on the target scope |
| A GitHub OIDC deployment identity federated to this repository | See [deployment reference](deployment-reference.md#github-actions-oidc) |
| Permission to create an Azure SRE Agent | The SRE Agent preview must be available in your tenant and region |
| Permission to set repository Actions variables | Repository admin |
| Permission to create **and revoke** a fine-grained GitHub PAT | You will create one in step 10 and revoke it in step 21 |
| GitHub CLI (`gh`), authenticated | Needed only if you trigger the incident from your machine |

> **Scenario B is a single, immutable profile.** If another scenario (A or C) is
> currently active in this repository, destroy it before deploying B. See
> [step 2](#step-2-confirm-no-other-scenario-is-active).

---

## Phase 1 — Prepare the repository

### Step 1. Confirm the healthy baseline

**Do.** Open `infra/leak.auto.tfvars` on `main` and confirm it reads:

```hcl
enable_slow_leak = false
```

**Expect.** The value is `false`. In Scenario B this file is the single source
of truth for the fault — it is the file the incident PR flips to `true` and the
file the agent's remediation PR flips back to `false`. Everything in this demo
hinges on it.

### Step 2. Confirm no other scenario is active

**Do.** Go to **Settings → Secrets and variables → Actions → Variables** and
look for `DEPLOYMENT_SCENARIO`.

**Expect.** It is either **absent** or set to **`B`**.

**If it says `A` or `C`:** destroy that profile with its own guide, then delete
`DEPLOYMENT_SCENARIO`, `TF_PREFIX`, and `TF_ENVIRONMENT`. Scenario state is
never converted in place — see
[profile and state safety](deployment-reference.md#profile-and-state-safety).

### Step 3. Set the Azure OIDC variables

**Do.** Under **Actions → Variables**, set:

| Variable | Value |
| --- | --- |
| `AZURE_CLIENT_ID` | Client ID of the federated deployment identity |
| `AZURE_TENANT_ID` | Your Entra tenant ID |
| `AZURE_SUBSCRIPTION_ID` | The target subscription ID |

**Expect.** Three variables listed. **Do not** create an Azure client secret.
The PAT you create later is used only inside the SRE Agent portal and is never
given to any workflow.

---

## Phase 2 — Deploy the environment

### Step 4. Run the deploy workflow

**Do.** Go to **Actions → deploy → Run workflow** and set:

| Input | Value | Note |
| --- | --- | --- |
| Scenario | `B` | Selects the Low / Reader / Review profile |
| Resource name prefix | `contosopay` | Any short lowercase prefix works |
| Environment label | `demo` | Appears in names and the state key |
| Azure region | `swedencentral` | Any region where SRE Agent is available |
| Open incident PR | `false` | Leave this off; you will arm the incident live in step 15 |

**Expect.** The run takes roughly 15–25 minutes and:

1. validates the scenario and OIDC variables;
2. creates the scenario-isolated remote backend;
3. applies the platform resources;
4. builds images tagged with the full 40-character commit SHA;
5. pushes them through authenticated ACR access and pins them to digests;
6. applies the Container Apps and the alert rule;
7. provisions the Scenario B SRE Agent.

**Expect on success.** The workflow summary shows the resource group, ACR name,
public frontend URL, and the exact activation variables to set next. Copy the
resource group name and frontend URL.

### Step 5. Activate push deployment

This step is what makes the GitOps loop work: without it, merging a pull request
deploys nothing.

**Do.** Under **Actions → Variables**, add these **in this order**:

1. `TF_PREFIX` = the prefix you deployed
2. `TF_ENVIRONMENT` = the environment you deployed
3. `DEPLOYMENT_SCENARIO` = `B` — **set this one last**

**Expect.** From now on, merging a change to `infra/leak.auto.tfvars` triggers
`apply-infra`, which applies it to the Scenario B state. Before the marker
exists, push-triggered workflows emit a notice and succeed as no-ops.

### Step 6. Verify the healthy baseline

**Do.**

1. Open the frontend URL and place a test order.
2. Tick **Generate steady traffic (auto-order every 2s)** and leave it running.
3. Chart `payment-service` process working-set memory in Application Insights.

**Expect.** The order succeeds, memory is flat, and neither `checkout-api` nor
`payment-service` has a public FQDN. Screenshot the flat memory chart.

---

## Phase 3 — Configure the SRE Agent

Scenario B is code-led but not code-complete: Terraform and the workflows own
the Azure workload and the GitOps lifecycle, while the agent's builder
configuration is a deliberate manual step, because this profile exists to
demonstrate the current built-in GitHub MCP path. Work through steps 7–14 in
order.

### Step 7. Open the agent and confirm the profile

**Do.** Go to <https://sre.azure.com>, open the agent created in your demo
resource group, and check its settings.

| Setting | Required value |
| --- | --- |
| Access level | **Low** |
| Role on the demo resource group | **Reader** |
| Mode | **Review** |
| Managed resource | Only the Scenario B demo resource group |
| Incident platform | Azure Monitor |

**Expect.** Reader — not Contributor. The managed service may additionally hold
monitoring roles for the alert lifecycle; that is expected. Reader RBAC plus the
tool policy in step 11 form the real enforcement boundary. Review mode alone is
not an authorisation boundary.

### Step 8. Connect Code Access

**Do.** Under **Builder → Code Access**, connect this repository and wait for
indexing to start.

**Expect.** An indexing status appears. Code Access gives the agent source
context and commit correlation. It is **not** a Git write credential — that is a
separate capability you add in step 10, and the distinction is worth calling out
on stage.

### Step 9. Connect logs and incidents

**Do.**

1. Connect the Scenario B Log Analytics workspace and Application Insights
   resource.
2. Connect **Azure Monitor** as the incident platform.

**Expect.** Both appear as connected. Without the logs connector the agent has
no memory trend to reason about.

### Step 10. Create a short-lived fine-grained PAT

This is the only credential in Scenario B, and it is deliberately minimal and
short-lived.

**Do.** Create a **fine-grained** personal access token with:

| Property | Value |
| --- | --- |
| Owner | The account that owns this repository |
| Repository access | **Only this repository** |
| Expiration | Same day, or the shortest practical lifetime |
| Permissions | Metadata: read. Contents: read/write. Pull requests: read/write. Nothing else. |

**Expect.** A token you will paste directly into the SRE Agent portal in the
next step, and revoke in step 21.

> **Never** put this PAT in Terraform, Key Vault, GitHub Actions, repository
> variables, workflow secrets, meeting notes, or shell history.

### Step 11. Add the built-in GitHub MCP connector

**Do.** In the SRE Agent portal:

1. open **Builder → Connectors → Add connector**;
2. select the built-in **GitHub MCP** connector;
3. choose PAT authentication and enter the token interactively;
4. enable **only** the tools needed to read a file, create a branch, commit a
   one-file change, and open an unmerged pull request;
5. explicitly disable merge, approval, workflow administration, repository
   administration, secret management, and unrelated issue tools.

**Expect.** A connector with a deliberately small tool surface. The agent can
propose a change; it cannot merge its own change.

### Step 12. Apply the hard tool policy

**Do.** Apply [`agent/tool-access-policy.portal.json`](../agent/tool-access-policy.portal.json)
at **global** scope, then verify it:

- allows the Azure and Kubernetes read diagnostics the demo needs;
- denies Azure and Kubernetes write tools;
- denies terminal and shell fallback;
- denies Terraform apply and destroy paths.

**Expect.** Policy applied globally.

### Step 13. Test the refusal — do not skip this

**Do.** Ask the agent, in plain language, to restart `payment-service` directly.

**Expect.** It **refuses** the Azure mutation and offers a pull-request path
instead.

This is the single most important rehearsal in Scenario B. If the agent complies
instead of refusing, your policy is not applied — fix it before the demo, and do
not rely on the custom agent's prompt to enforce the boundary.

### Step 14. Configure the GitOps behaviour

**Do.**

1. Create the `gitops-remediation` custom agent from
   [`agent/gitops-remediation-agent-github.md`](../agent/gitops-remediation-agent-github.md).
2. Assign it only Code Access and Azure read tools, plus the minimal GitHub MCP
   branch, file, commit, and pull-request tools.
3. Add [`agent/knowledge/gitops-runbook.md`](../agent/knowledge/gitops-runbook.md)
   as knowledge.
4. Create a response plan for the Sev2 payment-memory alert, route it to
   `gitops-remediation`, and keep **Review** mode.

**Expect.** The response plan explicitly requires:

- evidence before remediation;
- no direct Azure, Kubernetes, terminal, or Terraform mutation;
- exactly one change — `infra/leak.auto.tfvars`, `enable_slow_leak` from `true`
  to `false`;
- an **unmerged** pull request for human review.

---

## Phase 4 — Run the demo live

### Step 15. Establish the healthy baseline (about 2 minutes)

**Say and show.**

- The public checkout page — "the only thing on the internet."
- `checkout-api` and `payment-service` — internal ingress, no public FQDN.
- The agent's access level — "**Reader**. It cannot change this environment even
  if it wants to."
- The flat memory chart.

### Step 16. Arm the incident through a pull request

**Do.** Open the incident pull request:

```bash
./scripts/trigger-incident-gitops.sh
```

```powershell
pwsh ./scripts/trigger-incident-gitops.ps1
```

**Expect.** A branch and an open pull request setting `enable_slow_leak = true`
in `infra/leak.auto.tfvars`. Show the diff — one line.

**Do.** Merge it.

**Expect.** `apply-infra` runs, reads Scenario B from `DEPLOYMENT_SCENARIO`,
verifies the B state, applies the flag, and rolls a new `payment-service`
revision.

**Say.** "The fault entered production the same way every real regression does:
as a reviewed, merged, deployed change. Remember that — the agent is about to
find this exact commit."

### Step 17. Narrate while memory climbs (8–12 minutes)

**Say and show.**

- The rising working-set chart.
- The alert rule's five-minute average — "it fires on a trend, not a spike."
- The boundary — "Reader RBAC, a global deny policy on write tools, and a PAT
  scoped to one repository with two permissions."
- The isolated Terraform state for this scenario.

**Expect.** The Sev2 alert fires and appears in the agent as an incident.

### Step 18. Walk the investigation

**Do.** Open the incident and read the agent's evidence out loud.

**Expect** the agent to have correlated:

- the alert and the working-set trend;
- the affected `payment-service` revision;
- **the incident pull request and its merge commit**;
- the exact feature-flag change;
- source and runbook context.

**Say.** "It did not just find high memory. It found the pull request that
caused it."

### Step 19. Show the refusal, then the pull request

**Do.** Ask the agent live to restart the service or turn the flag off directly
in Azure.

**Expect.** It refuses and explains that Azure mutation is denied, offering the
GitOps path instead. Then let the response plan run.

**Expect.** The agent uses the built-in GitHub MCP tools to create a branch,
change only `infra/leak.auto.tfvars`, and open an **unmerged** pull request.

> In Scenario B the agent acts through the connector directly. It does **not**
> create a remediation issue, call a broker, or trigger the
> `sre-remediation-pr` workflow — those belong only to
> [Scenario C](scenario-c-private-gitops.md).

### Step 20. Review, merge, and verify

**Do.** Review the pull request on screen. Check that:

1. it changes exactly one expected line;
2. no workflow, source, or secret file is touched;
3. the description explains the evidence behind it.

Then merge it.

**Expect.** `apply-infra` applies the healthy flag to the same Scenario B state,
a new `payment-service` revision starts, memory flattens, and the alert
resolves.

**Say.** "Every control your change process depends on stayed intact: branch
protection, review, CI, audit trail. The agent did the analysis and the
paperwork. A human made the decision."

---

## Phase 5 — Reset, revoke, and tear down

### Step 21. Revoke the PAT

**Do.** Revoke the fine-grained PAT immediately after the demonstration.

**Expect.** The connector stops working — which is correct. Recreate a fresh
short-lived token for the next demo.

### Step 22. Reset the fault if needed

If the environment was left armed, open a reset pull request:

```bash
./scripts/trigger-incident-gitops.sh --reset
```

```powershell
pwsh ./scripts/trigger-incident-gitops.ps1 -Reset
```

**Expect.** A one-line pull request setting `enable_slow_leak = false`. Merge it
and let `apply-infra` deploy the healthy state.

### Step 23. Destroy the environment

**Do.** Go to **Actions → destroy → Run workflow** and set:

| Input | Value |
| --- | --- |
| Scenario | `B` |
| Resource name prefix | the prefix you deployed |
| Environment label | the environment you deployed |
| Delete state blob after destroy | `true` if you are finished with this profile |

Or, for a locally deployed environment:

```bash
./scripts/teardown.sh --scenario B --prefix contosopay --env demo
```

**Expect.** Teardown verifies the scenario recorded in state before destroying
anything. Never destroy by guessed resource-name patterns, and never reuse this
state for another profile.

**If you plan to move to Scenario A or C:** finish the destroy, then delete
`DEPLOYMENT_SCENARIO`, `TF_PREFIX`, and `TF_ENVIRONMENT`.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Deploy fails in preflight with a scenario mismatch | `DEPLOYMENT_SCENARIO` is set to A or C | Destroy that profile, then delete all three profile variables |
| Merging the incident PR deploys nothing | The activation marker is unset | Complete [step 5](#step-5-activate-push-deployment) |
| The agent restarts the service instead of refusing | The global tool policy is not applied | Redo [step 12](#step-12-apply-the-hard-tool-policy) and re-test with [step 13](#step-13-test-the-refusal--do-not-skip-this) |
| The agent explains the fix but opens no pull request | GitHub MCP connector missing, PAT expired, or required tools disabled | Re-check steps [10](#step-10-create-a-short-lived-fine-grained-pat) and [11](#step-11-add-the-built-in-github-mcp-connector) |
| The remediation PR touches more than one file | The custom agent or response plan is not scoped | Redo [step 14](#step-14-configure-the-gitops-behaviour); do not merge the PR |
| The agent cannot see the merge commit | Code Access not connected or still indexing | Redo [step 8](#step-8-connect-code-access) and allow indexing to finish |
| Memory climbs but no alert fires | Fewer than ~8 minutes elapsed, or the wrong app is charted | The rule uses a five-minute average; confirm you are charting `payment-service` |
| `trigger-incident-gitops` fails | `gh` is missing or unauthenticated | Install the GitHub CLI and run `gh auth login`, or pass `--no-pr` and open the PR by hand |

---

## Reference: security and operating model

| Concern | Scenario B behaviour |
| --- | --- |
| Terraform profile | `scenario = "B"` |
| SRE Agent access | Low; Reader on the demo resource group |
| Run mode | Review |
| Deployment control endpoints | Public, protected by Azure RBAC and TLS |
| Deployment runner | GitHub-hosted, or the local wrapper |
| Code context | Code Access (read-only) |
| GitHub write path | Built-in GitHub MCP connector with a short-lived fine-grained PAT |
| Remediation broker | None |
| Incident trigger | Pull request setting `enable_slow_leak = true` |
| Remediation path | Agent-authored pull request setting the flag to `false`, merged by a human |

### Who owns what

| Surface | Owner | Automated? |
| --- | --- | --- |
| Resource group, Container Apps, ACR, Key Vault, observability, alerts, identities, RBAC | Terraform | Fully declarative |
| Scenario-isolated Terraform backend | Workflows or local wrapper | Automated creation and validation |
| Images and revisions | Workflows or local wrapper | Automated build, push, digest pinning, and app update |
| Incident and reset triggers | Scripts or the deploy workflow | Idempotent pull requests |
| SRE Agent ARM resource | Terraform | Deploys the Low / Reader / Review profile |
| Code Access, GitHub MCP connector, tool policy, custom agent, knowledge, response plan | Operator, in the SRE portal | Manual, from version-controlled files |
| Remediation pull request | SRE Agent, via GitHub MCP | Automated branch, commit, and unmerged PR; review and merge stay human |
| PAT revocation | Operator | Manual, immediately after the demo |

### Why the boundary holds

Three independent controls, not one:

1. **Reader RBAC** — the agent's Azure identity cannot mutate the workload.
2. **The global tool policy** — write, terminal, shell, and Terraform tools are
   denied outright.
3. **A minimal, short-lived PAT** — one repository, two permissions, expiring
   the same day.

Review mode makes the proposal visible, but it is not an authorisation boundary
on its own. Neither is the custom agent's prompt. Say this explicitly when a
security-minded audience asks.

---

## References

- [Scenario chooser](run-of-show.md)
- [Deployment and state reference](deployment-reference.md)
- [Azure SRE Agent setup reference](sre-agent-setup.md)
- [Azure SRE Agent GitHub connector](https://learn.microsoft.com/azure/sre-agent/github-connector)
- [Azure SRE Agent MCP connectors](https://learn.microsoft.com/azure/sre-agent/mcp-connectors)
- [Azure SRE Agent tool access policies](https://learn.microsoft.com/azure/sre-agent/tool-access-policies)
- [Fine-grained personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
