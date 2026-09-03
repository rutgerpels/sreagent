# Scenario C: private-network enterprise GitOps

**The story you tell.** Everything Scenario B shows, but under enterprise
network constraints: private endpoints for state, container registry, and Key
Vault; a self-hosted runner inside your network; a bring-your-own GitHub App
instead of a personal token; and an SRE Agent whose entire configuration —
policy, custom agent, response plan, health schedule, knowledge — is declared in
code and reconciled, not clicked together in a portal.

**Who this is for.** Regulated industries, security architects, and platform
teams who will ask "can this run in *our* network, configured from *our*
pipeline?" before they ask what the agent can do.

**Set expectations up front.** Scenario C's agent holds **Reader on Azure** and
**cannot mutate production** — no restarts, no scaling, no `terraform apply`. It
*can* write to GitHub. It investigates, then opens a remediation pull request
itself; a human reviews and merges it, and the pipeline deploys the fix. The
GitOps guarantee comes from Azure RBAC and tool policy, not from denying the
agent GitHub access. Say this to the audience before the demo, not after they
notice.

**Time budget.**

| Phase | What you do | Duration |
| --- | --- | --- |
| 1 | Prepare the private runner and network variables | ~45 minutes (first time) |
| 2 | Prepare optional Code Access | ~20 minutes |
| 3 | Deploy and reconcile | ~35 minutes (mostly unattended) |
| 4 | Run the demo live | ~25 minutes |
| 5 | Tear down | ~25 minutes (unattended) |

Phase 1 is by far the largest first-time cost, and it is entirely reusable
across demos.

---

## What the audience will see

1. A healthy checkout application whose state, registry, and Key Vault have no
   public data-plane endpoints.
2. A deployment that ran on a runner inside the network, authenticated with
   OIDC — no stored Azure credentials anywhere.
3. An agent whose policy, custom agent, response plan, schedule, and knowledge
   were applied and **verified** from a committed manifest.
4. A fault armed by a merged pull request, and an incident correlated back to it.
5. The agent identifying the precise one-line fix — and refusing to apply it
   directly, because Reader access and the tool policy forbid it from touching
   Azure.
6. The agent opening a remediation pull request instead, and a human reviewing
   and merging it through the private pipeline.

---

## Before you start

| Requirement | How to check |
| --- | --- |
| An Azure subscription where you can create resources **and role assignments** | Owner or User Access Administrator on the target scope |
| An existing runner VNet you can peer to | You supply its resource group, VNet, and private-endpoint subnet |
| A Linux x64 self-hosted runner you can register | Provisioned in phase 1 |
| A GitHub OIDC deployment identity federated to this repository | See [deployment reference](deployment-reference.md#github-actions-oidc) |
| Permission to create an Azure SRE Agent | The SRE Agent preview must be available in your tenant and region |
| Permission to create and install a GitHub App | Only for the GitHub App Code Access path (phase 3); the OAuth path needs none |
| Permission to set repository Actions variables | Repository admin |

> **Scenario C is a single, immutable profile.** If A or B is active, destroy it
> and delete `DEPLOYMENT_SCENARIO`, `TF_PREFIX`, and `TF_ENVIRONMENT` first.
> Scenario state is never converted in place.

---

## Phase 1 — Prepare the private runner and network

### Step 1. Confirm the healthy baseline

**Do.** Confirm `infra/leak.auto.tfvars` on `main` reads:

```hcl
enable_slow_leak = false
```

**Expect.** The value is `false`. This file is the GitOps source of truth for
the fault throughout the demo.

### Step 2. Register the self-hosted runner

**Do.** Register a Linux x64 runner with exactly these labels:

```text
self-hosted, Linux, X64, azure-private, contosopay
```

The runner needs:

- Docker;
- Azure CLI;
- outbound HTTPS to GitHub and the Azure control plane;
- network reachability to the runner VNet and its private endpoints.

Terraform and Node.js are installed by the workflow — you do not need to
pre-install them.

**Expect.** The runner appears **Idle** in **Settings → Actions → Runners** with
all five labels. If any label is missing, the deploy job will queue forever.

### Step 3. Set the repository variables

**Do.** Under **Settings → Secrets and variables → Actions → Variables**, set
the required variables:

| Variable | Purpose |
| --- | --- |
| `AZURE_CLIENT_ID` | Federated deployment identity |
| `AZURE_TENANT_ID` | Entra tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Target subscription ID |
| `RUNNER_NETWORK_RG` | Resource group holding the existing runner VNet |
| `RUNNER_VNET_NAME` | The runner VNet name |
| `RUNNER_PE_SUBNET_NAME` | Subnet in that VNet for private endpoints |

Optional address-space overrides, if the defaults collide with your network:

- `APP_VNET_ADDRESS_SPACE`
- `APP_PE_SUBNET_PREFIX`
- `CONTAINER_APPS_SUBNET_PREFIX`
- `SRE_AGENT_SUBNET_PREFIX`

**Expect.** All six required variables are set, and the application address
space **does not overlap** the runner address space. Overlapping ranges break
peering and are the most common phase-1 failure.

**Do not** create an Azure client secret, credentials JSON, storage key, or ACR
admin credential. Deployment is OIDC-only.

---

## Phase 2 — Deploy and reconcile

### Step 4. Run the deploy workflow

**Do.** Go to **Actions → deploy → Run workflow** and set:

| Input | Value | Note |
| --- | --- | --- |
| Scenario | `C` | Selects the private-network profile |
| Resource name prefix | `contosopay` | Any short lowercase prefix works |
| Environment label | `demo` | Appears in names and the state key |
| Azure region | `swedencentral` | Any region where SRE Agent is available |
| Open incident PR | `false` | Leave this off; you arm the incident live in step 13 |

Leave the Code Access variables unset for this run. Code Access is connected in
phase 3, after this deploy has created the Key Vault it depends on.

**Expect.** The job is picked up by your labelled private runner and then:

1. creates scenario-isolated remote state behind a private endpoint;
2. provisions the private network, identities, observability, the agent, and the
   ARM connectors;
3. builds and digest-pins all images;
4. applies the applications;
5. reconciles the global tool policy, the `gitops-remediation` custom agent, the
   response plan, the scheduled health check, knowledge, and optional Code
   Access from `agent/scenario-c/manifest.json`;
6. **verifies** the resulting agent state.

**Expect on success.** The workflow summary lists the resource group, ACR,
frontend URL, the activation variables, and a Scenario C bootstrap note
confirming that the agent holds Reader on Azure and remediates by pull request.

**If the job never starts**, your runner labels do not match step 2.

### Step 5. Activate push deployment

**Do.** Under **Actions → Variables**, add these **in this order**:

1. `TF_PREFIX` = the prefix you deployed
2. `TF_ENVIRONMENT` = the environment you deployed
3. `DEPLOYMENT_SCENARIO` = `C` — **set this one last**

**Expect.** Merging a change to `infra/leak.auto.tfvars` now triggers
`apply-infra` on the private runner. Until the marker exists, push workflows are
safe no-ops. The state blob is `<prefix>-C-<environment>.tfstate`.

---

## Phase 3 — Connect Code Access (optional but recommended)

Code Access is how the agent correlates an incident to a commit, and how it
opens the remediation pull request. Without it, the demo still works but loses
its most persuasive evidence and the agent cannot propose the fix itself.

**This phase comes after the deploy on purpose.** The Key Vault that holds the
GitHub App key does not exist until phase 2 has run, and its name is generated
with a random suffix, so it cannot be known in advance. The App path therefore
takes two deploy runs: the one you have just completed, and a second one in
step 9 that reconciles Code Access.

Skip this phase to run without repository context. Leave the Code Access
variables unset in that case; partial configuration fails closed.

### Step 6. Choose the Code Access path

**Do.** Pick one path and follow only its steps.

| | Bring-your-own GitHub App | OAuth ("Your account") |
| --- | --- | --- |
| Configured by | Repository variables, reconciled from code | Portal, by hand |
| Steps | 7, 8, and 9 | This step only |
| Agent write verified? | **No — untested** | **Yes — verified live** |
| Survives a later deploy? | Yes, it is reconciled | **No — see the warning below** |
| Pull request author | The App | The signed-in user |

Under OAuth, the commit inside the pull request is authored by `Azure SRE Agent
<noreply@microsoft.com>` and the platform prefixes the title with
`[Generated by SRE Agent]`, so the provenance story lands even though the pull
request itself is opened as you. The App path is expected to behave the same
way, but that has not been observed.

**For the OAuth path.** In the portal, open the agent, add this repository under
Code Access, and choose **Your account**. Leave `SRE_CODE_ACCESS_ENABLED` unset.
Then continue at [step 10](#step-10-verify-the-agent-configuration).

> **The reconciler removes a hand-connected repository.** With
> `SRE_CODE_ACCESS_ENABLED` unset or `false`, the deploy workflow's
> reconciliation step **deletes** the repository connection and the GitHub
> domain, because the manifest is the desired state and an unmanaged connection
> is drift. Connect OAuth **after** your final deploy run, and re-connect it
> after any later deploy. If your demo relies on OAuth, check the connection is
> still present before you start.

**For the GitHub App path.** Continue at step 7.

> **Untested path.** Agent-authored pull requests were verified live using
> **OAuth-based Code Access**, where the agent created the branch itself and
> committed as `Azure SRE Agent <noreply@microsoft.com>`. The equivalent flow
> under a bring-your-own GitHub App has **not** been verified. The App is
> documented first because Scenario C's story is configuration from code rather
> than portal clicks. If the agent cannot write with the App, fall back to
> OAuth — that path is proven, at the cost of one manual step and the caveat
> above.

### Step 7. Create the Code Access GitHub App

**Do.** Create a dedicated GitHub App with **only**:

| Permission | Level |
| --- | --- |
| Metadata | Read |
| Contents | Read/Write |
| Pull requests | Read/Write |

`Contents: Read/Write` and `Pull requests: Read/Write` are what let the agent
push a branch and open the remediation pull request. No Issues, Actions,
Administration, Secrets, or Workflows permissions. Install it on **this
repository only**.

**Expect.** An App with a client ID and a downloaded private key (PEM).

### Step 8. Store the PEM in Key Vault

**Do.** First find the vault that phase 2 created. You do not choose its name —
Terraform generates it as `kv-<prefix>-<scenario>-<random>`, truncating the
prefix so the result fits Key Vault's 24-character limit. The deploy summary
lists it as `key_vault_name`, or:

```bash
az keyvault list \
  --resource-group "rg-<prefix>-<environment>-c-<suffix>" \
  --query "[0].name" --output tsv
```

Then, from a host that can reach the private Key Vault endpoint:

```bash
az keyvault secret set \
  --vault-name "<key-vault-name>" \
  --name "sre-code-access-github-app-pem" \
  --file "./code-access-app.pem" \
  --output none
```

Then securely remove the local PEM according to your key-custody process.

**Expect.** The secret exists in the vault. Terraform attaches a dedicated Code
Access identity and grants it `Key Vault Secrets User` **only at that secret's
scope**. The agent's action identity gets no secret-read role, and the workflow
passes only the secret URI — it never reads or logs the value.

**If the command cannot reach the vault**, run it from the same network as the
deploy runner. Scenario C denies public access to Key Vault.

### Step 9. Enable Code Access and re-run the deploy

**Do.** Set these nonsecret repository variables, all three together:

| Variable | Value |
| --- | --- |
| `SRE_CODE_ACCESS_GITHUB_APP_CLIENT_ID` | The App's client ID |
| `SRE_CODE_ACCESS_GITHUB_APP_PRIVATE_KEY_SECRET_NAME` | `sre-code-access-github-app-pem` |
| `SRE_CODE_ACCESS_ENABLED` | `true` — **set this one last** |

Then run **Actions → deploy → Run workflow** again with the same inputs as
step 4. Nothing else changes; this run exists to reconcile Code Access.

**Expect.** The reconciliation step builds the secret URI from the vault name and
the secret name, connects the repository, and its verification confirms the
connection. Setting `SRE_CODE_ACCESS_ENABLED=true` before the App exists and the
PEM is stored fails the run by design.

---

## Phase 4 — Verify before the demo

### Step 10. Verify the agent configuration

**Do.** From an authenticated host that can reach the environment:

```bash
./scripts/reconcile-sre-agent.sh \
  --mode verify \
  --subscription "<subscription-id>" \
  --resource-group "<resource-group>" \
  --agent "<agent-name>"
```

**Expect.** Verification passes, confirming the policy, custom agent, response
plan, schedule, and knowledge match the committed manifest. This is the moment
that proves the "configured from code, not clicked" claim — consider showing it
live.

To inspect the desired state without any Azure access, use `--mode render`.

### Step 11. Verify the healthy baseline

**Do.**

1. Open the frontend URL and place a test order.
2. Tick **Generate steady traffic (auto-order every 2s)** and leave it running.
3. Chart `payment-service` process working-set memory in Application Insights.

**Expect.** The order succeeds, memory is flat, and neither `checkout-api` nor
`payment-service` has a public FQDN. Screenshot the flat memory chart.

---

## Phase 5 — Run the demo live

### Step 12. Establish the healthy baseline (about 4 minutes)

Scenario C's baseline is a bigger part of the story than in A or B — the
network posture *is* the value.

**Say and show.**

- The public checkout page — the only public application.
- ACR, Key Vault, and the state storage account with public network access
  disabled and private endpoints in place.
- The deployment run — executed on a runner inside the network, authenticated
  with OIDC, with no stored Azure credential anywhere.
- The verified agent configuration from step 10.
- The agent's access level — **Reader**.
- The flat memory chart.

**Be precise about the network claim.** VNet integration controls the agent's
*egress*; it does not create inbound private connectivity for the agent, and
during the preview connector traffic is not guaranteed to traverse the attached
VNet. Private endpoints protect state, ACR, and Key Vault. Do not describe the
agent workspace as fully private, and never present network placement as an
authentication boundary.

### Step 13. Arm the incident through a pull request

**Do.**

```bash
./scripts/trigger-incident-gitops.sh
```

```powershell
pwsh ./scripts/trigger-incident-gitops.ps1
```

**Expect.** A one-line pull request setting `enable_slow_leak = true`. Show the
diff, then merge it. `apply-infra` runs on the private runner, verifies the C
state, applies the flag, and rolls a new `payment-service` revision.

### Step 14. Narrate while memory climbs (8–12 minutes)

**Say and show.**

- The rising working-set chart.
- The alert rule's five-minute average.
- The two-part boundary: Reader RBAC on Azure and the reconciled global deny
  policy. The agent can read every signal in the subscription and change none
  of it.
- The scheduled health check that the reconciler configured.

**Expect.** The Sev2 alert fires and reaches the agent as an incident.

### Step 15. Walk the investigation

**Do.** Open the incident and read the agent's evidence.

**Expect** the agent to have correlated the alert, the working-set trend, the
affected revision, the merged pull request, and the exact flag change — and to
identify `infra/leak.auto.tfvars` as the source of truth, proposing exactly:

```hcl
enable_slow_leak = false
```

**Optional, and the strongest moment in the demo.** Ask the agent in the
incident thread to "just restart the container app". It declines: it holds
Reader on the subscription and the tool policy denies Azure writes. It offers
the pull request instead. The guardrail is demonstrated live rather than
described.

### Step 16. Watch the agent open the remediation pull request

**Say.** "The agent cannot touch Azure. What it *can* do is propose the fix the
same way any engineer would — as a reviewable pull request."

**Expect.** A pull request against the default branch, authored by the agent,
whose title the platform prefixes with `[Generated by SRE Agent]`. The diff is
one file and one line:

```hcl
enable_slow_leak = false
```

The body states the root cause with supporting telemetry, why the one-line
change is sufficient, that merging runs `apply-infra`, and how to verify
afterwards. The commit is authored by `Azure SRE Agent <noreply@microsoft.com>`
— a distinct identity in the git history, not a human's.

**If the agent does not open a pull request**, see
[troubleshooting](#troubleshooting). As a fallback that keeps the demo moving,
open the reset pull request yourself:

```bash
./scripts/trigger-incident-gitops.sh --reset
```

```powershell
pwsh ./scripts/trigger-incident-gitops.ps1 -Reset
```

**Do not** use `az containerapp update` to fix this. It would create drift from
Terraform and be reversed by the next apply — and it would contradict the entire
scenario.

### Step 17. Review, merge, and verify

**Do.** Review the agent's pull request — one file, one line, no workflow or
secret changes — and merge it. You are the approver; the agent cannot approve or
merge its own work.

**Expect.** `apply-infra` applies the healthy flag through the private runner,
its Scenario C reconciliation step confirms the agent configuration has not
drifted, a new revision starts, memory flattens, and the alert resolves.

**Say.** "The agent proposed; a human approved; the pipeline deployed. The fix
travelled the same private, reviewed, audited path as every other change in this
environment. Nothing reached Azure outside the pipeline."

---

## Phase 6 — Tear down

### Step 18. Destroy the environment

**Do.** Go to **Actions → destroy → Run workflow** and set:

| Input | Value |
| --- | --- |
| Scenario | `C` |
| Resource name prefix | the prefix you deployed |
| Environment label | the environment you deployed |
| Delete state blob after destroy | `true` if you are finished with this profile |

**Expect.** The job runs on the private runner and verifies the state profile
before destroying anything.

### Step 19. Clean up external material

**Do.** Remove or rotate, when no longer required:

- the GitHub App installation and its private key;
- the Code Access PEM secret in Key Vault;
- any Entra consent granted for the demo.

**Do not** remove pre-existing shared runner-network resources — Terraform does
not own them.

**If you plan to move to Scenario A or B:** finish the destroy, then delete
`DEPLOYMENT_SCENARIO`, `TF_PREFIX`, and `TF_ENVIRONMENT`.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| The deploy job queues forever | Runner labels do not match, or the runner is offline | Re-check [step 2](#step-2-register-the-self-hosted-runner); all five labels are required |
| Terraform fails reaching the state account | The runner cannot reach the private endpoint, or peering is missing | Verify `RUNNER_NETWORK_RG`, `RUNNER_VNET_NAME`, `RUNNER_PE_SUBNET_NAME` and runner network reachability |
| Peering or subnet creation fails | Application and runner address spaces overlap | Override `APP_VNET_ADDRESS_SPACE` and the subnet prefixes |
| Code Access reconciliation fails | Partial configuration — App, PEM secret, or variables missing | Set all three variables together, or leave `SRE_CODE_ACCESS_ENABLED` unset |
| The Key Vault does not exist yet | Phase 3 was attempted before the phase 2 deploy | Run [step 4](#step-4-run-the-deploy-workflow) first; the vault name is generated during that run |
| Code Access was connected but has disappeared | A later deploy reconciled it away because `SRE_CODE_ACCESS_ENABLED` is unset | Expected for the OAuth path — re-connect it in [step 6](#step-6-choose-the-code-access-path) after the final deploy |
| The agent proposes the fix but opens no pull request | Code Access is disabled, or the App lacks `Contents: Read/Write` and `Pull requests: Read/Write` | Raise the App permissions in [step 7](#step-7-create-the-code-access-github-app) and reinstall, or connect Code Access over OAuth — the proven path |
| The agent proposes nothing | Response plan or logs connector missing | Re-run `reconcile-sre-agent` with `--mode apply`, then `--mode verify` |
| Memory climbs but no alert fires | Fewer than ~8 minutes elapsed, or the wrong app is charted | The rule uses a five-minute average; confirm you are charting `payment-service` |
| Merging a PR deploys nothing | The activation marker is unset | Complete [step 5](#step-5-activate-push-deployment) |

---

## Reference: security and networking model

| Concern | Scenario C behaviour |
| --- | --- |
| Terraform profile | `scenario = "C"` |
| SRE Agent workload access | Reader on the demo resource group |
| Run mode | Review |
| Azure data plane | Private state Blob, ACR, and Key Vault endpoints |
| SRE Agent networking | Dedicated delegated subnet, VNet egress |
| Deployment runner | `self-hosted, Linux, X64, azure-private, contosopay` |
| Code context | Bring-your-own GitHub App, or OAuth Code Access |
| Azure mutation | None — Reader RBAC and the global deny policy forbid it |
| GitHub mutation | The agent opens a remediation pull request; it cannot approve or merge |
| Incident trigger | Pull request setting `enable_slow_leak = true` |
| Durable remediation | Agent-authored, human-merged pull request setting the flag to `false` |

The Terraform-created agent subnet is delegated to `Microsoft.App/environments`,
sits in the same region as the agent, is separate from Container Apps, private
endpoints, and runners, and is `/27` or larger in this demo.

The frontend remains the only public application. `checkout-api` and
`payment-service` use internal ingress.

## Reference: the automation boundary

| Surface | Owner | Automated state |
| --- | --- | --- |
| Agent, identities, model, budget, incident platform, telemetry, VNet, sandbox | Terraform/AzAPI | Fully declarative |
| App Insights, Log Analytics, Azure Monitor connectors | Terraform/AzAPI ARM children | Fully declarative |
| Agent and connector RBAC | Terraform | Fully declarative |
| Global tool policy | SRE Agent REST reconciler | Idempotent apply and verify |
| `gitops-remediation` custom agent | SRE Agent REST reconciler | Idempotent apply and verify; ARM extensions are tenant restricted |
| Sev2 memory response plan | SRE Agent REST reconciler | Idempotent apply and verify |
| Scheduled health check | SRE Agent REST reconciler | Idempotent apply and verify |
| GitOps runbook knowledge | SRE Agent REST reconciler | Delete known file, upload, verify indexing |
| GitHub Code Access | SRE Agent REST reconciler | Optional; requires externally issued GitHub App material |
| GitHub App creation and key issuance | GitHub/operator | External bootstrap; GitHub has no noninteractive App-creation API |
| Remediation pull request | SRE Agent over Code Access | Agent-authored at incident time; review and merge stay human |

The reconciler is `scripts/reconcile-sre-agent.sh` / `.ps1`, and its desired
state is `agent/scenario-c/manifest.json`. GitHub Actions runs `apply` and
`verify` after infrastructure deployment, and `verify` again after application
deployment.

The reconciler verifies the effective response contract rather than
request-only fields. In the current preview, `agentType` is not part of the
custom-agent REST envelope, `deepInvestigationEnabled` is not persisted for
incident filters, and scheduled tasks ignore duplicate `name` and `isEnabled`
properties. Those fields are intentionally absent from the desired state so that
API acceptance cannot mask configuration drift. Knowledge upload is verified
through the documented upload response and `AgentMemory` indexer status; the
preview status API exposes no document-list operation, so verify-only runs prove
indexing health but cannot compare file contents byte for byte.

The optional `agentIdentity.initialSponsorGroupId` surface is intentionally not
enabled: Microsoft's current production templates omit it and the underlying
Agent Identity platform is tenant restricted. Scenario C uses the documented
system-assigned and user-assigned managed identities instead, which stay fully
declarative and portable.

The agent uses `Microsoft.App/agents@2025-05-01-preview` because that schema
exposes the required VNet and sandbox properties. Re-evaluate the pinned version
when a stable API exposes the same surface.

## Reference: why Terraform remains the IaC language

SRE Agent templates support both Bicep and Terraform, and Bicep may expose new
preview properties first. The ARM reference lists child types for subagents,
incident filters, and scheduled tasks, but live deployment returns
`Agent Extensions are not available for this tenant` outside internal tenants —
so Microsoft's current Terraform backend also deploys subagents through the data
plane. This repository stays on Terraform because all application, networking,
identity, observability, and lifecycle code is already Terraform, AzAPI can
submit the same preview ARM shape as Bicep, the documented connectors are
Terraform-owned children, and switching languages would add state and pipeline
complexity without removing the REST reconciliation phase.

---

## References

- [Scenario chooser](run-of-show.md)
- [Deployment and state reference](deployment-reference.md)
- [Azure SRE Agent setup reference](sre-agent-setup.md)
- [Deploy Azure SRE Agent with infrastructure as code](https://learn.microsoft.com/azure/sre-agent/deploy-iac)
- [Azure SRE Agent API reference](https://learn.microsoft.com/azure/sre-agent/api-reference)
- [Azure SRE Agent ARM template reference](https://learn.microsoft.com/azure/templates/microsoft.app/agents)
- [Azure SRE Agent network integration](https://learn.microsoft.com/azure/sre-agent/network-integration)
- [Azure SRE Agent MCP connectors](https://learn.microsoft.com/azure/sre-agent/mcp-connectors)
- [Microsoft SRE Agent reference repository](https://github.com/microsoft/sre-agent)
- [Key Vault RBAC](https://learn.microsoft.com/azure/key-vault/general/rbac-guide)
