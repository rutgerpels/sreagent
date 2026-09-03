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
| Permission to create and install a GitHub App | Only for the GitHub App Code Access path (steps 3-5); the OAuth path needs none |
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

### Step 3. Choose the Code Access path

Code Access is how the agent correlates an incident to a commit, and how it
opens the remediation pull request. Without it the demo still works, but it
loses its most persuasive evidence and the agent cannot propose the fix itself.

**Do.** Pick one path now, before you deploy — the choice changes what you set
in step 5.

| | Bring-your-own GitHub App | OAuth ("Your account") | None |
| --- | --- | --- | --- |
| Configured by | Repository variables and one secret, reconciled from code | Portal, by hand, **after** the deploy | — |
| Deploy runs needed | One | One | One |
| Steps | 4 and 5, then deploy | Step 8, after deploying | Skip 4; leave the variables unset |
| Agent write verified? | **Yes — verified live** | **Yes — verified live** | n/a |
| Survives a later deploy? | Yes, it is reconciled | **No — see the warning in step 8** | n/a |
| Pull request author | The App's bot account | The signed-in user | n/a |

Under both working paths the commit inside the pull request is authored by
`Azure SRE Agent <noreply@microsoft.com>`, so the provenance story lands either
way. They differ only in who opens the pull request: the App's `[bot]` account,
or you.

**The App path is the one that matches Scenario C's story** — configuration from
code rather than portal clicks — and it is the only path that survives a
redeploy. OAuth is a valid fallback at the cost of one manual step and the
reconcile caveat.

Partial configuration fails closed: set all of the Code Access variables or none
of them.

### Step 4. Create the Code Access GitHub App

Skip this step on the OAuth path.

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

Keep the PEM to hand for the next step, then remove it from your machine
according to your key-custody process. It is the one credential Scenario C
creates, and [step 18](#step-18-clean-up-external-material) revokes it.

### Step 5. Set the repository variables and secret

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

The application address space **must not overlap** the runner address space.
Overlapping ranges break peering and are the most common phase-1 failure.

On the **GitHub App path only**, add these three variables as well:

| Variable | Value |
| --- | --- |
| `SRE_CODE_ACCESS_GITHUB_APP_CLIENT_ID` | The App's client ID from step 4 |
| `SRE_CODE_ACCESS_GITHUB_APP_PRIVATE_KEY_NAME` | `sre-code-access-github-app-key` |
| `SRE_CODE_ACCESS_ENABLED` | `true` |

The key name is yours to choose — it is the name the key is given inside Key
Vault, not a fixed convention. The workflow builds the key URI from it, so it
only has to be a valid Key Vault key name.

Then, under **Secrets**, add one repository secret:

| Secret | Value |
| --- | --- |
| `SRE_CODE_ACCESS_GITHUB_APP_PRIVATE_KEY_PEM` | The **entire** contents of the App's `.pem` file, including the `-----BEGIN` and `-----END` lines |

The deploy imports that PEM into Key Vault as a **key** and never writes it to
the repository. GitHub masks it in workflow logs, and the workflow shreds its
temporary copy on the runner whether the import succeeds or fails.

**Expect.** Six required variables, plus three variables and one secret if you
chose the App path.

**Do not** create an Azure client secret, credentials JSON, storage key, or ACR
admin credential. Deployment is OIDC-only. The App PEM is the single stored
credential in Scenario C, and it exists because there is no OIDC path for
handing a GitHub App key to the SRE Agent service.

---

## Phase 2 — Deploy

### Step 6. Run the deploy workflow

**Do.** Go to **Actions → deploy → Run workflow** and set:

| Input | Value | Note |
| --- | --- | --- |
| Scenario | `C` | Selects the private-network profile |
| Resource name prefix | `contosopay` | Any short lowercase prefix works |
| Environment label | `demo` | Appears in names and the state key |
| Azure region | `swedencentral` | Any region where SRE Agent is available |
| Open incident PR | `false` | Leave this off; you arm the incident live in step 12 |

**Expect.** The job is picked up by your labelled private runner and then:

1. creates scenario-isolated remote state behind a private endpoint;
2. provisions the private network, identities, observability, the agent, and the
   ARM connectors;
3. builds and digest-pins all images;
4. applies the applications;
5. **imports the GitHub App key into Key Vault** from the repository secret, if
   Code Access is enabled and the key is not already there;
6. reconciles the global tool policy, the `gitops-remediation` custom agent, the
   response plan, the scheduled health check, knowledge, and Code Access from
   `agent/scenario-c/manifest.json`;
7. **verifies** the resulting agent state.

**This is the only deploy run you need.** Earlier revisions of this runbook
required two — one to create the Key Vault, then a manual key import, then a
second run to connect Code Access. The import now happens between the apply and
the reconcile in the same job, so the chicken-and-egg is gone.

**Expect on success.** The workflow summary lists the resource group, ACR,
frontend URL, the activation variables, and a Scenario C bootstrap note
confirming that the agent holds Reader on Azure and remediates by pull request.

**If the job never starts**, your runner labels do not match step 2.

> **Importing the key by hand instead.** The workflow skips the import if the
> key already exists, so you can still place it yourself — for example if policy
> forbids the PEM in a GitHub secret. Run this from a host on the runner network,
> after the vault exists, and leave
> `SRE_CODE_ACCESS_GITHUB_APP_PRIVATE_KEY_PEM` unset:
>
> ```bash
> az keyvault key import \
>   --vault-name "<key-vault-name>" \
>   --name "sre-code-access-github-app-key" \
>   --pem-file "./code-access-app.pem" \
>   --output none
> ```
>
> That is the old two-run flow: deploy once with `SRE_CODE_ACCESS_ENABLED`
> unset, import, then set the variables and deploy again. The vault name is
> generated as `kv-<prefix>-<scenario>-<random>` and appears in the deploy
> summary as `key_vault_name`.

> **This differs from Microsoft's published guidance.** Those docs describe
> storing the PEM as a Key Vault *secret* and copying the Secret Identifier. The
> service now rejects that and answers:
> *"For improved security, Key Vault secret URIs are no longer supported for
> GitHub App credentials. Use a Key Vault key URI (.../keys/&lt;name&gt;) instead."*
> The App JWT is signed inside Key Vault, so the private key is never read out.
> GitHub issues PKCS#1 PEMs and `az keyvault key import` accepts them directly;
> no `openssl` conversion is needed. Terraform grants a dedicated Code Access
> identity `Key Vault Crypto User` **only at that key's scope**, and the agent's
> action identity gets no Key Vault role at all.

**Grant yourself access to the agent.** The deploy gives the *deployment
identity* an agent role, not you. Subscription Owner does not reach the agent's
data plane, so without this the agent site refuses to load for every account.
Run this once, after the deploy has created the agent:

```bash
AGENT_ID=$(terraform -chdir=infra output -json sre_agent_ids \
  | python -c 'import json,sys; print(next(iter(json.load(sys.stdin).values())))')

az role assignment create \
  --assignee-object-id "$(az ad signed-in-user show --query id -o tsv)" \
  --assignee-principal-type User \
  --role "SRE Agent Administrator" \
  --scope "$AGENT_ID"
```

Allow about a minute for propagation. See
[operator access](sre-agent-setup.md#operator-access-to-the-agent) for the role
comparison and why the portal's error message points at the wrong thing.

### Step 7. Activate push deployment

**Do.** Under **Actions → Variables**, add these **in this order**:

1. `TF_PREFIX` = the prefix you deployed
2. `TF_ENVIRONMENT` = the environment you deployed
3. `DEPLOYMENT_SCENARIO` = `C` — **set this one last**

**Expect.** Merging a change to `infra/leak.auto.tfvars` now triggers
`apply-infra` on the private runner. Until the marker exists, push workflows are
safe no-ops. The state blob is `<prefix>-C-<environment>.tfstate`.

### Step 8. Connect Code Access over OAuth — the OAuth path only

Skip this step on the GitHub App path; the deploy already connected it.

**Do.** In the portal, open the agent, add this repository under Code Access,
and choose **Your account**.

> **The reconciler removes a hand-connected repository.** With
> `SRE_CODE_ACCESS_ENABLED` unset or `false`, the deploy workflow's
> reconciliation step **deletes** the repository connection and the GitHub
> domain, because the manifest is the desired state and an unmanaged connection
> is drift. Connect OAuth **after** your final deploy run, and re-connect it
> after any later deploy. If your demo relies on OAuth, check the connection is
> still present before you start.

---

## Phase 3 — Verify before the demo

### Step 9. Verify the agent configuration

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

### Step 10. Verify the healthy baseline

**Do.**

1. Open the frontend URL and place a test order.
2. Tick **Generate steady traffic (auto-order every 2s)** and leave it running.
3. Chart the `payment-service` memory trend in Application Insights.

   The services publish an OpenTelemetry gauge named
   `process_memory_rss_bytes`. On Linux the resident set size *is* the working
   set, but nothing in the portal is labelled "working set", so search for the
   gauge name rather than the concept. Open the Application Insights resource
   (`terraform output -raw app_insights_name`, or the only `appi-*` resource in
   the demo resource group), then **Logs**, and run:

   ```kusto
   customMetrics
   | where name == "process_memory_rss_bytes"
   | where tostring(customDimensions.service) == "payment-service"
   | summarize rssMB = round(avg(value) / 1048576, 1) by bin(timestamp, 1m)
   | render timechart
   ```

   The container app behind this metric is the one whose name contains
   `payment`; list them with `az containerapp list -g <resource-group> -o table`.
   Keep this chart open — it is the same view you narrate while memory climbs.

**Expect.** The order succeeds, memory is flat, and neither `checkout-api` nor
`payment-service` has a public FQDN. Screenshot the flat memory chart.

---

## Phase 4 — Run the demo live

### Step 11. Establish the healthy baseline (about 4 minutes)

Scenario C's baseline is a bigger part of the story than in A or B — the
network posture *is* the value.

**Say and show.**

- The public checkout page — the only public application.
- ACR, Key Vault, and the state storage account with public network access
  disabled and private endpoints in place.
- The deployment run — executed on a runner inside the network, authenticated
  with OIDC, with no stored Azure credential anywhere.
- The verified agent configuration from step 9.
- The agent's access level — **Reader**.
- The flat memory chart.

**Be precise about the network claim.** VNet integration controls the agent's
*egress*; it does not create inbound private connectivity for the agent, and
during the preview connector traffic is not guaranteed to traverse the attached
VNet. Private endpoints protect state, ACR, and Key Vault. Do not describe the
agent workspace as fully private, and never present network placement as an
authentication boundary.

### Step 12. Arm the incident through a pull request

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

### Step 13. Narrate while memory climbs (8–12 minutes)

**Say and show.**

- The rising working-set chart.
- The alert rule's five-minute average.
- The two-part boundary: Reader RBAC on Azure and the reconciled global deny
  policy. The agent can read every signal in the subscription and change none
  of it.
- The scheduled health check that the reconciler configured.

**Expect.** The Sev2 alert fires and reaches the agent as an incident.

### Step 14. Walk the investigation

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

### Step 15. Watch the agent open the remediation pull request

**Say.** "The agent cannot touch Azure. What it *can* do is propose the fix the
same way any engineer would — as a reviewable pull request."

**Expect.** A pull request against the default branch, opened by the Code Access
GitHub App's `[bot]` account. The diff is one file and one line:

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

### Step 16. Review, merge, and verify

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

## Phase 5 — Tear down

### Step 17. Destroy the environment

**Do.** Go to **Actions → destroy → Run workflow** and set:

| Input | Value |
| --- | --- |
| Scenario | `C` |
| Resource name prefix | the prefix you deployed |
| Environment label | the environment you deployed |
| Delete state blob after destroy | `true` if you are finished with this profile |

**Expect.** The job runs on the private runner and verifies the state profile
before destroying anything.

### Step 18. Clean up external material

**Do.** Remove or rotate, when no longer required:

- the GitHub App installation and its private key;
- the Code Access App key in Key Vault;
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
| The agent site will not load, or chat returns `unauthorized` | No SRE Agent data-plane role — subscription Owner is not enough | Grant a role at agent scope; see [operator access](sre-agent-setup.md#operator-access-to-the-agent) |
| Terraform fails reaching the state account | The runner cannot reach the private endpoint, or peering is missing | Verify `RUNNER_NETWORK_RG`, `RUNNER_VNET_NAME`, `RUNNER_PE_SUBNET_NAME` and runner network reachability |
| Peering or subnet creation fails | Application and runner address spaces overlap | Override `APP_VNET_ADDRESS_SPACE` and the subnet prefixes |
| Code Access reconciliation fails | Partial configuration — App, key, or variables missing | Set all three variables together, or leave `SRE_CODE_ACCESS_ENABLED` unset |
| Reconciliation fails with "Key Vault secret URIs are no longer supported" | The App credential was stored as a Key Vault *secret* | Import it as a **key** instead; see [step 6](#step-6-run-the-deploy-workflow) |
| The Key Vault does not exist yet | The key was imported by hand before the first deploy | Run [step 6](#step-6-run-the-deploy-workflow) first; the vault name is generated during that run |
| Code Access was connected but has disappeared | A later deploy reconciled it away because `SRE_CODE_ACCESS_ENABLED` is unset | Expected for the OAuth path — re-connect it in [step 8](#step-8-connect-code-access-over-oauth--the-oauth-path-only) after the final deploy |
| The agent proposes the fix but opens no pull request | The global tool policy denies `RunInTerminal`, or Code Access is disabled, or the App lacks `Contents: Read/Write` and `Pull requests: Read/Write` | Check the tool policy allows the terminal first — that failure looks like a refusal but is really a missing tool, and the agent's own message names `RunInTerminal`. Then raise the App permissions in [step 4](#step-4-create-the-code-access-github-app) and reinstall |
| The agent proposes nothing | Response plan or logs connector missing | Re-run `reconcile-sre-agent` with `--mode apply`, then `--mode verify` |
| Memory climbs but no alert fires | Fewer than ~8 minutes elapsed, or the wrong app is charted | The rule uses a five-minute average; confirm you are charting `payment-service` |
| Merging a PR deploys nothing | The activation marker is unset | Complete [step 7](#step-7-activate-push-deployment) |

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
