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
| 3 | Configure the SRE Agent | ~15 minutes |
| 4 | Run the demo live | ~25 minutes |
| 5 | Reset and tear down | ~20 minutes |

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
| A GitHub account that can push branches and open pull requests here | You sign in to Code Access with it in [step 8](#step-8-connect-code-access) |
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
Scenario B has no secret of any kind: deployment authenticates through OIDC
federation, and the agent's GitHub write path is an interactive sign-in in the
SRE Agent portal that no workflow ever sees.

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
| Open incident PR | `false` | Leave this off; you will arm the incident live in step 13 |

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
demonstrate how far the portal path gets you with no credential to manage. Work
through steps 7–12 in order.

### Step 7. Open the agent and confirm the profile

**Grant yourself access first.** The deploy gives the *deployment identity* an
agent role, not you. Subscription Owner does not reach the agent's data plane, so
without this the agent site refuses to load and reports a misleading network
error. Scenario B runs in Review mode, so you need the role that can **approve**:

```bash
RG=<your demo resource group>
AGENT_ID=$(az resource list -g "$RG" \
  --resource-type Microsoft.App/agents --query "[0].id" -o tsv)

az role assignment create \
  --assignee-object-id "$(az ad signed-in-user show --query id -o tsv)" \
  --assignee-principal-type User \
  --role "SRE Agent Administrator" \
  --scope "$AGENT_ID"
```

Allow about a minute for propagation. See
[operator access](sre-agent-setup.md#operator-access-to-the-agent) for why
`SRE Agent Standard User` is not enough here.

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
tool policy in step 10 form the real enforcement boundary. Review mode alone is
not an authorisation boundary.

### Step 8. Connect Code Access

This is the most important step in Scenario B. Code Access is both the agent's
source context **and** its GitHub write path — there is no separate connector
and no token anywhere in this scenario.

**Do.** Under **Builder → Code Access → Add repositories**, choose the
**Your account** sign-in method, authorise the OAuth prompt, select this
repository, and wait for indexing to start.

**Expect.** An indexing status appears. Once indexed, the agent can search the
source, correlate a commit to an incident, and — on approval — create a branch,
commit to it, and open a pull request. Commits are authored as
`Azure SRE Agent <noreply@microsoft.com>` and pull-request titles are
auto-prefixed `[Generated by SRE Agent]`.

> **Verified interactively, not yet from an alert.** Branch creation, commit,
> and pull-request opening over OAuth Code Access were confirmed live against
> this repository by prompting the agent in chat. The same actions have **not**
> been verified end-to-end from an alert-triggered response plan invoking tools
> autonomously. Rehearse [step 17](#step-17-show-the-refusal-then-the-pull-request)
> before you present. The same caveat applies to
> [Scenario C](scenario-c-private-gitops.md).

> **Understand what OAuth grants.** Signing in with your account gives the agent
> your GitHub reach, which is broader than a repository-scoped token would be.
> That is a deliberate trade: Scenario B buys away an entire credential
> lifecycle — nothing to mint, paste, store, rotate, or revoke — and rests its
> guarantee on Azure RBAC and the tool policy instead of on GitHub credential
> scope. Use an account whose GitHub reach you are comfortable lending, and say
> so plainly if a security-minded audience asks.

### Step 9. Connect logs and incidents

**Do.**

1. Connect the Scenario B Log Analytics workspace and Application Insights
   resource.
2. Connect **Azure Monitor** as the incident platform.

**Expect.** Both appear as connected. Without the logs connector the agent has
no memory trend to reason about.

### Step 10. Apply the hard tool policy

**Do.** Apply [`agent/tool-access-policy.portal.json`](../agent/tool-access-policy.portal.json)
at **global** scope, then verify it:

- allows the Azure and Kubernetes read diagnostics the demo needs;
- denies Azure and Kubernetes write tools;
- denies Azure and Terraform mutation as `bash(...)` command patterns too, so the
  terminal cannot be used as a fallback;
- **allows** the terminal itself — Code Access opens its pull request by running
  `git` and `gh` there, so denying it breaks the remediation step.

**Expect.** Policy applied globally.

### Step 11. Test the refusal — do not skip this

**Do.** Ask the agent, in plain language, to restart `payment-service` directly.

**Expect.** It **refuses** the Azure mutation and offers a pull-request path
instead.

This is the single most important rehearsal in Scenario B. If the agent complies
instead of refusing, your policy is not applied — fix it before the demo, and do
not rely on the custom agent's prompt to enforce the boundary.

### Step 12. Configure the GitOps behaviour

**Do.**

1. Create the `gitops-remediation` custom agent from
   [`agent/gitops-remediation-agent-github.md`](../agent/gitops-remediation-agent-github.md).
2. Assign it only Code Access and Azure read tools.
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

### Step 13. Establish the healthy baseline (about 2 minutes)

**Say and show.**

- The public checkout page — "the only thing on the internet."
- `checkout-api` and `payment-service` — internal ingress, no public FQDN.
- The agent's access level — "**Reader**. It cannot change this environment even
  if it wants to."
- The flat memory chart.

### Step 14. Arm the incident through a pull request

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

### Step 15. Narrate while memory climbs (8–12 minutes)

**Say and show.**

- The rising working-set chart.
- The alert rule's five-minute average — "it fires on a trend, not a spike."
- The boundary — "Reader RBAC on Azure, a global deny policy on every write
  tool, and no secret anywhere in this scenario. There is nothing here to leak,
  because nothing was ever issued."
- The isolated Terraform state for this scenario.

**Expect.** The Sev2 alert fires and appears in the agent as an incident.

### Step 16. Walk the investigation

**Do.** Open the incident and read the agent's evidence out loud.

**Expect** the agent to have correlated:

- the alert and the working-set trend;
- the affected `payment-service` revision;
- **the incident pull request and its merge commit**;
- the exact feature-flag change;
- source and runbook context.

**Say.** "It did not just find high memory. It found the pull request that
caused it."

### Step 17. Show the refusal, then the pull request

**Do.** Ask the agent live to restart the service or turn the flag off directly
in Azure.

**Expect.** It refuses and explains that Azure mutation is denied, offering the
GitOps path instead. Then let the response plan run.

**Expect.** The agent uses Code Access to create a branch, change only
`infra/leak.auto.tfvars`, and open an **unmerged** pull request titled with the
`[Generated by SRE Agent]` prefix.

> Scenario B and [Scenario C](scenario-c-private-gitops.md) both have the agent
> open the pull request itself over Code Access. What differs is posture, not
> capability: C runs against private endpoints and a self-hosted runner, signs
> in with a bring-your-own GitHub App instead of your account, and reconciles
> its whole agent configuration from a committed manifest.

### Step 18. Review, merge, and verify

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

## Phase 5 — Reset and tear down

### Step 19. Reset the fault if needed

If the environment was left armed, open a reset pull request:

```bash
./scripts/trigger-incident-gitops.sh --reset
```

```powershell
pwsh ./scripts/trigger-incident-gitops.ps1 -Reset
```

**Expect.** A one-line pull request setting `enable_slow_leak = false`. Merge it
and let `apply-infra` deploy the healthy state.

### Step 20. Destroy the environment

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
| The agent site will not load, or chat returns `unauthorized` | No SRE Agent data-plane role — subscription Owner is not enough | Grant a role at agent scope; see [operator access](sre-agent-setup.md#operator-access-to-the-agent) |
| Merging the incident PR deploys nothing | The activation marker is unset | Complete [step 5](#step-5-activate-push-deployment) |
| The agent restarts the service instead of refusing | The global tool policy is not applied | Redo [step 10](#step-10-apply-the-hard-tool-policy) and re-test with [step 11](#step-11-test-the-refusal--do-not-skip-this) |
| The agent explains the fix but opens no pull request | The global tool policy denies `RunInTerminal` — Code Access writes through the terminal, so denying it removes the only write path — or Code Access is not connected, still indexing, or was connected with an account that cannot push to this repository. Note also that agent-authored pull requests are verified interactively but **not** yet from an alert-triggered response plan | Confirm the policy from [step 10](#step-10-apply-the-hard-tool-policy) allows the terminal, then redo [step 8](#step-8-connect-code-access) with the **Your account** method and let indexing finish. If the agent still only describes the fix, ask it in chat to open the pull request — that path is proven — and treat the response plan as unverified |
| The remediation PR touches more than one file | The custom agent or response plan is not scoped | Redo [step 12](#step-12-configure-the-gitops-behaviour); do not merge the PR |
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
| Code context | Code Access, connected with the **Your account** OAuth method |
| GitHub write path | The same Code Access connection; no connector and no token |
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
| Code Access, tool policy, custom agent, knowledge, response plan | Operator, in the SRE portal | Manual, from version-controlled files |
| Remediation pull request | SRE Agent, over Code Access | Automated branch, commit, and unmerged PR; review and merge stay human |

### Why the boundary holds

Two independent controls, and one absence:

1. **Reader RBAC** — the agent's Azure identity cannot mutate the workload.
2. **The global tool policy** — write, terminal, shell, and Terraform tools are
   denied outright.
3. **No secret exists in this scenario at all** — no token is minted, pasted,
   stored, rotated, or revoked, so none can leak or outlive the demo.

**Be honest about what OAuth grants.** Signing in to Code Access with your
account gives the agent the signed-in user's GitHub reach, which is broader than
a repository-scoped fine-grained PAT would be. Scenario B trades that narrower
GitHub scope for the removal of an entire credential lifecycle. The guarantee
that matters is not the GitHub credential's scope — it is that the agent holds
Reader on Azure and every write tool is denied, so it cannot touch production no
matter what its GitHub token could do. State the trade openly; a security
audience will find it anyway, and it is defensible.

Review mode makes the proposal visible, but it is not an authorisation boundary
on its own. Neither is the custom agent's prompt. Say this explicitly when a
security-minded audience asks.

---

## References

- [Scenario chooser](run-of-show.md)
- [Deployment and state reference](deployment-reference.md)
- [Azure SRE Agent setup reference](sre-agent-setup.md)
- [Azure SRE Agent GitHub connector](https://learn.microsoft.com/azure/sre-agent/github-connector)
- [Connect source code to Azure SRE Agent](https://learn.microsoft.com/azure/sre-agent/connect-source-code)
- [Azure SRE Agent tool access policies](https://learn.microsoft.com/azure/sre-agent/tool-access-policies)
