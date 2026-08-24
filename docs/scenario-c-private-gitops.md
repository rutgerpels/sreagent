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

**Set expectations up front.** In the current preview, Scenario C's agent is
**Reader-only and has no supported write path to GitHub**. It investigates and
proposes the exact one-file fix; a human then opens the remediation pull
request. This is a deliberate design decision, not a gap in the demo — see
[the remote MCP limitation](#reference-the-remote-mcp-preview-limitation). Say
this to the audience before the demo, not after they notice.

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
5. The agent identifying the precise one-line fix — and stopping there, because
   Reader access and the tool policy forbid it from acting.
6. A human opening, reviewing, and merging the remediation pull request through
   the private pipeline.

---

## Before you start

| Requirement | How to check |
| --- | --- |
| An Azure subscription where you can create resources **and role assignments** | Owner or User Access Administrator on the target scope |
| An existing runner VNet you can peer to | You supply its resource group, VNet, and private-endpoint subnet |
| A Linux x64 self-hosted runner you can register | Provisioned in phase 1 |
| A GitHub OIDC deployment identity federated to this repository | See [deployment reference](deployment-reference.md#github-actions-oidc) |
| Permission to create an Azure SRE Agent | The SRE Agent preview must be available in your tenant and region |
| Permission to create and install a GitHub App | Only if you want Code Access (phase 2) |
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

## Phase 2 — Prepare Code Access (optional but recommended)

Code Access is how the agent correlates an incident to a commit. Without it, the
demo still works but loses its most persuasive evidence. It is a **read-only**
path — not a write connector.

Skip to phase 3 if you want to run without repository context; leave
`SRE_CODE_ACCESS_ENABLED=false` in that case. Partial configuration fails closed.

### Step 4. Create the Code Access GitHub App

**Do.** Create a dedicated GitHub App with **only**:

| Permission | Level |
| --- | --- |
| Metadata | Read |
| Contents | Read |

No Issues, Pull requests, Actions, Administration, Secrets, or Workflows
permissions. Install it on **this repository only**.

**Expect.** An App with a client ID and a downloaded private key (PEM). Keep it
strictly separate from the future remediation App described in the
[reference](#reference-the-dormant-remediation-broker).

### Step 5. Store the PEM in Key Vault

**Do.** From a host that can reach the private Key Vault endpoint:

```bash
az keyvault secret set \
  --vault-name "<scenario-c-vault>" \
  --name "sre-code-access-github-app-pem" \
  --file "./code-access-app.pem" \
  --output none
```

Then securely remove the local PEM according to your key-custody process.

**Expect.** The secret exists in the vault. Terraform attaches a dedicated Code
Access identity and grants it `Key Vault Secrets User` **only at that secret's
scope**. The agent's action identity gets no secret-read role, and the workflow
passes only the secret URI — it never reads or logs the value.

### Step 6. Enable Code Access

**Do.** Set these nonsecret repository variables:

| Variable | Value |
| --- | --- |
| `SRE_CODE_ACCESS_ENABLED` | `true` |
| `SRE_CODE_ACCESS_GITHUB_APP_CLIENT_ID` | The App's client ID |
| `SRE_CODE_ACCESS_GITHUB_APP_PRIVATE_KEY_SECRET_NAME` | `sre-code-access-github-app-pem` |

**Expect.** All three set together. Set `SRE_CODE_ACCESS_ENABLED=true` only once
the App exists, the PEM is in Key Vault, and the other two variables are
populated.

---

## Phase 3 — Deploy and reconcile

### Step 7. Run the deploy workflow

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
5. reconciles the global tool policy, the `gitops-remediation` custom agent, the
   response plan, the scheduled health check, knowledge, and optional Code
   Access from `agent/scenario-c/manifest.json`;
6. **verifies** the resulting agent state.

**Expect on success.** The workflow summary lists the resource group, ACR,
frontend URL, the activation variables, and a Scenario C bootstrap note
confirming that the broker and remote MCP connector were **not** deployed.

**If the job never starts**, your runner labels do not match step 2.

### Step 8. Activate push deployment

**Do.** Under **Actions → Variables**, add these **in this order**:

1. `TF_PREFIX` = the prefix you deployed
2. `TF_ENVIRONMENT` = the environment you deployed
3. `DEPLOYMENT_SCENARIO` = `C` — **set this one last**

**Expect.** Merging a change to `infra/leak.auto.tfvars` now triggers
`apply-infra` on the private runner. Until the marker exists, push workflows are
safe no-ops. The state blob is `<prefix>-C-<environment>.tfstate`.

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
3. Chart `payment-service` process working-set memory in Application Insights.

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
- The three-part boundary: Reader RBAC, the reconciled global deny policy, and
  the absence of any agent-held GitHub write credential.
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

### Step 15. Perform the human GitOps step

**Say.** "This is where Scenario C deliberately stops. The agent has Reader
access and no supported write path to GitHub in this preview, so it does not act
— it hands a precise, reviewable instruction to a human."

**Do.**

```bash
./scripts/trigger-incident-gitops.sh --reset
```

```powershell
pwsh ./scripts/trigger-incident-gitops.ps1 -Reset
```

**Expect.** An unmerged one-file pull request setting the flag back to `false`.

**Do not** use `az containerapp update` to fix this. It would create drift from
Terraform and be reversed by the next apply — and it would contradict the entire
scenario.

### Step 16. Review, merge, and verify

**Do.** Review the pull request — one file, one line, no workflow or secret
changes — and merge it.

**Expect.** `apply-infra` applies the healthy flag through the private runner,
its Scenario C reconciliation step confirms the agent configuration has not
drifted, a new revision starts, memory flattens, and the alert resolves.

**Say.** "The fix travelled the same private, reviewed, audited path as every
other change in this environment. Nothing reached Azure outside the pipeline."

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
| Code Access reconciliation fails | Partial configuration — App, PEM secret, or variables missing | Set all three variables together, or set `SRE_CODE_ACCESS_ENABLED=false` |
| Reconcile fails with a connector error | `SRE_REMEDIATION_CONNECTOR_ENABLED` is `true` | It must stay `false`; see [the preview limitation](#reference-the-remote-mcp-preview-limitation) |
| The agent proposes nothing | Response plan or logs connector missing | Re-run `reconcile-sre-agent` with `--mode apply`, then `--mode verify` |
| Memory climbs but no alert fires | Fewer than ~8 minutes elapsed, or the wrong app is charted | The rule uses a five-minute average; confirm you are charting `payment-service` |
| Merging a PR deploys nothing | The activation marker is unset | Complete [step 8](#step-8-activate-push-deployment) |

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
| Code context | Optional read-only bring-your-own GitHub App |
| GitHub mutation | No supported agent-initiated write path in the current preview |
| Incident trigger | Pull request setting `enable_slow_leak = true` |
| Durable remediation | Human-reviewed pull request setting the flag to `false` |

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
| Remote remediation MCP connector | Disabled | Supported remote HTTP managed-identity authentication is not documented |

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

## Reference: the remote MCP preview limitation

Current remote Streamable-HTTP connector documentation exposes bearer-token and
custom-header authentication. Managed identity is documented for supported
Azure-backed stdio connectors, not for arbitrary remote HTTP MCP endpoints.

The remediation broker expects an Entra token for a dedicated audience and
validates the exact agent principal. Connecting it with a static bearer secret,
a PAT, anonymous access, or network-only trust would weaken the design.
Therefore:

- `SRE_REMEDIATION_CONNECTOR_ENABLED` must remain `false`;
- the reconciler rejects `true` with an actionable error;
- the agent stays Reader-only and cannot mutate Azure;
- the response plan investigates and explains the one-file fix, but a human
  opens the remediation pull request.

Re-enable this path only after Microsoft documents a supported managed-identity
authentication flow for remote Streamable-HTTP MCP, or after the broker is
redesigned around another supported nonsecret mechanism.

## Reference: the dormant remediation broker

The constrained broker implementation is retained in source so the architecture
can be enabled when the authentication gap closes. **No broker identity,
Container App, public ingress, RBAC, or auth configuration is deployed.** Do not
perform this bootstrap for a current preview demo.

Future enablement would require a **separate** GitHub App with Metadata read and
Issues read/write only, no webhook, plus dedicated Entra application metadata
(`SRE_REMEDIATION_ENTRA_API_CLIENT_ID`, `SRE_REMEDIATION_ENTRA_TOKEN_AUDIENCE`,
`SRE_REMEDIATION_ENTRA_TOKEN_SCOPE`, `SRE_GITHUB_APP_ID`,
`SRE_GITHUB_APP_INSTALLATION_ID`, `SRE_GITHUB_APP_BOT_LOGIN`,
`SRE_GITHUB_APP_PRIVATE_KEY_NAME`).

Only then would its PEM be imported once as a non-exportable, sign-only Key
Vault RSA key:

```bash
./scripts/configure-github-app-key.sh \
  --vault-name "<scenario-c-vault>" \
  --private-key "./remediation-app.pem" \
  --key-name "github-app-signing-key"
```

```powershell
pwsh ./scripts/configure-github-app-key.ps1 `
  -VaultName "<scenario-c-vault>" `
  -PrivateKeyPath "./remediation-app.pem" `
  -KeyName "github-app-signing-key"
```

The script never opens public Key Vault access: it temporarily grants the
signed-in operator Key Vault Crypto Officer, imports the key, and removes that
assignment. The broker would receive only key metadata read and sign operations
on that key, and would ask Key Vault to perform RS256 signing rather than ever
reading the private key.

The Code Access PEM **secret** and the broker signing **key** are deliberately
different objects with different custody models. Never reuse one App or
credential for both responsibilities.

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
