# Customer setup: from a new repository to a complete demo

This is the starting point for running ContosoPay in **your own GitHub
repository, Azure tenant and subscription**. Read it before dispatching a
workflow. Commands below are instructions for you to run deliberately; this
documentation audit did not deploy or verify a customer tenant.

The implementation targets **Azure public cloud** and preview agent APIs.
It is not a promise of sovereign-cloud support, regional capacity or preview
access in every tenant. Do not schedule a live demonstration before rehearsal.

## 1. Choose a scenario and ownership boundary

| Scenario | Recommended use | Additional preparation |
| --- | --- | --- |
| [B: GitOps](scenario-b-gitops.md) | Simplest first customer deployment; one agent proposes a PR, a human merges | OAuth Code Access to your repository; activate push deployment after bootstrap |
| [A: direct recovery](scenario-a-direct.md) | Direct Azure recovery after approval | Portal-owned Observability Agent onboarding and preview rehearsal; memory response plan must be Review |
| [C: private GitOps](scenario-c-private-gitops.md) | Private endpoints and governed PR recovery | Existing private Linux runner/VNet, address planning/DNS, GitHub App or documented OAuth alternative |
| [D: private payments](scenario-d-private-payments.md) | Payment failure, on-demand Observability investigation and approved SRE recovery | Retained Terraform runner foundation; separate Bicep workload, ownership ledger and what-if gates |

Start with B or A unless private networking is the purpose of the exercise.
Use a dedicated nonproduction subscription and an approved resource budget.
Only frontend application ingress is public. Azure management and managed-agent
service endpoints are separate from application ingress.

A/B/C use Terraform and allow only one active push profile per repository.
Do not change `scenario` in existing state. D is a separate **Bicep-only**
workload; `infra/runner-d` remains Terraform. Never give D workload resources a
second Terraform owner. D deployment must remain healthy and must not arm a fault.

## 2. Create and select your own repository

1. Fork the reviewed source, or create a new repository from an approved clean
   snapshot. A fork retains upstream history; a fresh snapshot does not. Keep
   required license/attribution files. See [distribution checks](#11-distribute-a-customer-neutral-copy).
2. Make your operational default branch `main`, as expected by the push
   workflows. Put the reviewed workflows on that branch before bootstrap.
3. Open **Actions** and explicitly enable workflows in your copy. Check
   organization restrictions allow the pinned actions and OIDC. For B/C, enable
   **Settings → Actions → General → Allow GitHub Actions to create and approve
   pull requests** if using the workflow incident-PR option. Human review and
   merge are still required; this is not permission for agents to approve.
4. Configure branch protection and reviewers. Do not give untrusted pull
   requests access to self-hosted runners or deployment environments.

In a Bash terminal, replace the example repository with **your** owner/name:

```bash
export DEMO_REPOSITORY="your-org/your-demo"
gh auth login
git clone "https://github.com/${DEMO_REPOSITORY}.git"
cd your-demo
git remote -v
gh repo set-default "$DEMO_REPOSITORY"
gh repo view "$DEMO_REPOSITORY" --json nameWithOwner,url
```

For PowerShell, use `$env:DEMO_REPOSITORY = 'your-org/your-demo'` and
`gh repo set-default $env:DEMO_REPOSITORY` in your cloned repository.
Confirm `origin` points to your copy. A fork can otherwise direct `gh`
operations to its upstream. Use explicit `--repo "$DEMO_REPOSITORY"` on
workflow/PR commands and verify the destination before creating or merging a PR.
Do not dispatch workflows, open incident PRs, or select Code Access against the
original author's repository. Use only your copy for all later instructions
that say "this repository."

## 3. Install tools for your deployment path

| Where | Needed tools |
| --- | --- |
| Local operator using Actions | Git; GitHub CLI (`gh`) if using CLI workflow/PR commands; Azure CLI for login, role grants and checks; Bash for `.sh` examples **or PowerShell 7+** for `.ps1` examples |
| Local A/B deployment wrapper | Above, Terraform **1.9+**, Node.js **20**, a running Docker engine with Linux containers; Bash path also needs `jq` and standard GNU utilities such as `sha256sum`; use WSL on Windows for Bash wrappers |
| Local app/reconciler tests | Node.js **20** and npm; Python 3 and Terraform for the network regression test |
| C private runner | Linux x64, Bash, Git, Docker, Azure CLI, `jq`, Python 3; workflows set up Terraform 1.9.8 and Node 20; runner service must actually access the Docker daemon |
| D private runner | Linux x64, Bash, Git, Docker, Azure CLI, Node 20, Python 3 and `jq`; workflow installs pinned Bicep v0.48.1; bootstrap also needs local PowerShell 7+, Terraform, `ssh-keygen`, `gh` and Azure CLI |

GitHub-hosted A/B jobs install their Terraform/Node dependencies and use runner
Docker tooling; you do not need local Docker or Node just to dispatch them.
Do not mix Bash variable syntax with PowerShell. Shell examples in scenario
walkthroughs are labeled accordingly. In PowerShell use paths such as
`.\scripts\deploy.ps1`; in WSL/Bash use `./scripts/deploy.sh`.

Check only the tools required for your chosen path, for example `az version`,
`gh --version`, `terraform version`, `docker info`, `node --version`,
`pwsh --version` and `bash --version`. Docker must be running, not just installed.
Install/enable the Azure CLI `containerapp` extension if your CLI lacks the
`az containerapp` commands. No deployment requires an Azure client secret.

## 4. Select your Azure tenant and clear prerequisites

Sign in interactively with your tenant and select your subscription explicitly:

```bash
az login --tenant "<your-tenant-id>"
az account list --output table
az account set --subscription "<your-subscription-id>"
az account show --query '{subscription:name,subscriptionId:id,tenantId:tenantId}' --output table
```

The placeholders above are not literal values. Do not save real IDs in tracked
files. Repeat `az account show` before deployment, incident mutation or teardown.
See Microsoft's [Manage Azure subscriptions with the Azure CLI](https://learn.microsoft.com/cli/azure/manage-azure-subscriptions-azure-cli).

Have your Azure administrator review:

- **Permissions:** the human bootstrap operator and workflow deployment
  identity are different principals. Both need the applicable resource-creation
  and role-assignment rights. Owner, or Contributor plus User Access
  Administrator at the required scopes, is the documented bootstrap pattern,
  not a recommendation to grant production subscription Owner permanently.
  Workflows create resource groups and subscription-scoped monitoring grants.
  See the [scope details](deployment-reference.md#clean-fork-identity-bootstrap).
- **Providers:** AzureRM disables automatic provider registration. Ensure the
  selected services' providers are registered before bootstrap: `Microsoft.App`,
  `Microsoft.ContainerRegistry`, `Microsoft.KeyVault`, `Microsoft.ManagedIdentity`,
  `Microsoft.Network`, `Microsoft.Storage`, `Microsoft.OperationalInsights`,
  `Microsoft.Insights`; also `Microsoft.Monitor` for A/D,
  `Microsoft.Dashboard` if Grafana is enabled, and `Microsoft.Compute` for the
  runner VM. An authorized administrator can inspect each with
  `az provider show --namespace Microsoft.App --query registrationState -o tsv`
  and register missing providers with `az provider register --namespace <namespace> --wait`.
  Provider registration alone does not grant preview access.
- **Preview, region and quota:** check [SRE Agent supported regions](https://learn.microsoft.com/azure/sre-agent/supported-regions)
  and permission to create the preview resource in your selected subscription.
  A/D Observability also needs its supported workspace/agent region; the current
  setup uses West Europe. Verify Container Apps capacity, VM quota for a private
  runner and any required service registration before a live demo.
- **Policy:** review allowed regions/SKUs, tags, public access, local-auth
  restrictions, private endpoints, role-assignment constraints and resource
  locks. Do not bypass policy, enable keys or widen endpoints to make a demo pass.
  A/B control-plane/data-service exposure may not satisfy a private-only policy;
  choose C/D or obtain a reviewed design rather than disabling controls.
- **Network:** allow required outbound GitHub, package registry and Azure
  endpoints. For C/D, plan nonoverlapping CIDRs across every runner, application
  and peered VNet; confirm private DNS and subnet capacity/delegations.
- **Budget and lifecycle:** account for agents, ingestion, registry, optional
  Grafana, private networking and retained infrastructure. Purge-protected Key
  Vault names can remain unavailable after deletion.

## 5. Bootstrap OIDC and Actions configuration

Follow [Clean-fork identity bootstrap](deployment-reference.md#clean-fork-identity-bootstrap)
in order. Create a deployment managed identity outside the disposable workload
group, configure its federated credential for **your** repository, and grant
its deployment scopes. No bootstrap script or preexisting identity from the
author's tenant is needed.

The trust uses issuer `https://token.actions.githubusercontent.com`, audience
`api://AzureADTokenExchange`, and your actual assertion subject. Production
normally uses `repo:<owner>/<repo>:ref:refs/heads/main`; immutable-ID subjects
must match the assertion actually emitted by your repository. Do not trust an
upstream repository or arbitrary branches. D instead uses the **scenario-d**
GitHub environment subject; dev-test uses **dev-test**, if you choose to use it.
Create those environments and apply branch/reviewer restrictions before use.
See [Connect GitHub Actions to Azure using OIDC](https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect).
The workflows request `id-token: write`; they do not use a stored Azure password.

### Required and optional values

Set values under **Settings → Secrets and variables → Actions → Variables**.
Use your deployment outputs/identities, never values from screenshots or old runs.

| Variable | When / source |
| --- | --- |
| `AZURE_CLIENT_ID` | Required: deployment identity **client** ID, not principal/object ID |
| `AZURE_TENANT_ID` | Required: your Entra tenant |
| `AZURE_SUBSCRIPTION_ID` | Required: your target subscription |
| `TF_PREFIX`, `TF_ENVIRONMENT`, `DEPLOYMENT_SCENARIO` | A/B/C only, **after** successful bootstrap; set scenario last |
| `SRE_AGENT_MODEL_PROVIDER`, `SRE_AGENT_MODEL_NAME` | Optional model overrides; normally leave unset to use `MicrosoftFoundry` / `Automatic` |
| `RUNNER_NETWORK_RG`, `RUNNER_VNET_NAME`, `RUNNER_PE_SUBNET_NAME` | C: your existing runner network and private-endpoint subnet |
| `PRIVATE_RUNNER_LABELS_JSON` | Optional C runner label array matching your registration; otherwise use the walkthrough's standard labels |
| `APP_VNET_ADDRESS_SPACE`, `APP_PE_SUBNET_PREFIX`, `CONTAINER_APPS_SUBNET_PREFIX`, `SRE_AGENT_SUBNET_PREFIX` | C address plan; defaults are examples, not proof of no overlap |
| `D_RUNNER_NETWORK_RG`, `D_RUNNER_VNET_NAME` | D: explicit retained runner network from `infra/runner-d` outputs |
| `D_PRIVATE_RUNNER_LABELS_JSON` | Optional D runner label array matching your registration |
| `SRE_CODE_ACCESS_ENABLED` | C GitHub App path: `true` when fully configured; otherwise leave unset/`false` |
| `SRE_CODE_ACCESS_GITHUB_APP_CLIENT_ID` | C App path: your App's client ID |
| `SRE_CODE_ACCESS_GITHUB_APP_PRIVATE_KEY_NAME` | C App path: name of the imported Key Vault **key**, e.g. `sre-code-access-github-app-key` |

D reads the Azure values in the `scenario-d` environment/repository context;
check environment overrides do not target another tenant. D is not a
`DEPLOYMENT_SCENARIO` value. Keep its prefix separate from active A/B/C.

**Secrets:** A/B and D need no stored Azure credential. C's optional GitHub App
path accepts the Actions secret `SRE_CODE_ACCESS_GITHUB_APP_PRIVATE_KEY_PEM`
only to import your downloaded App key into Key Vault. Alternatively import
the key yourself and leave that Actions secret unset, following C's walkthrough.
Remove an import secret once no longer needed; revoke the App key at cleanup.
Never store it in a repository variable, tracked file or workflow log.
`GITHUB_TOKEN` is provided by GitHub at run time; do not create a PAT for Azure
deployment. OAuth Code Access still grants GitHub access and should be
disconnected/revoked when the demo is over.

Actions derives Code Access repository context from the running repository.
For manual C reconciliation outside Actions, explicitly supply
`SRE_CODE_ACCESS_REPOSITORY=owner/repo` and the matching
`SRE_CODE_ACCESS_REPOSITORY_URL=https://github.com/owner/repo`.
Do not reuse a manifest's historical repository alias.

### Additional C/D runner bootstrap

C requires an existing Linux runner and VNet; follow
[C's runner preparation](scenario-c-private-gitops.md#phase-1--prepare-the-private-runner-and-network).
D can bootstrap its separate retained foundation with:

```powershell
pwsh .\scripts\deploy-runner-d.ps1 `
  -SubscriptionName '<your exact subscription display name>' `
  -Repository 'your-org/your-demo' `
  -ResourceGroupName '<your retained runner resource group>' `
  -VnetName '<your retained runner VNet name>' `
  -VmName '<your retained runner VM name>'
terraform -chdir=infra/runner-d output
```

This is an intentional infrastructure mutation, not a prerequisite check.
First verify the selected subscription, provider registrations and budget.
Keep its local git-ignored Terraform state securely; do not delete it or commit
it. Set D network variables from `resource_group_name` and `vnet_name` outputs.
Confirm the runner is Online in **your** repository and the service account
can run Docker and reach required endpoints. D workload operations must not
destroy or deallocate their own runner.

## 6. Deploy a healthy baseline

For an initial B deployment, use **Actions → deploy → Run workflow** on your
own `main`, scenario `B`, prefix `pay`, environment `demo`, a currently
supported region, and **Open incident PR = false**. Equivalent Bash:

```bash
gh workflow run deploy.yml --repo "$DEMO_REPOSITORY" --ref main \
  -f scenario=B -f prefix=pay -f environment=demo \
  -f location="<chosen-supported-region>" -f open_incident_pr=false
gh run list --repo "$DEMO_REPOSITORY" --workflow deploy.yml --limit 5
```

Watch the run in your repository. Save its scenario, prefix, environment,
resource group, frontend URL and backend details in your private operator
notes. Do not guess names or recreate another deployment's suffix.

For local A/B deployment, the wrappers bootstrap the remote LRS state backend,
apply infrastructure, build/push full-SHA images and deploy exact digests:

```bash
export TF_VAR_enable_sre_agents=true
./scripts/deploy.sh --scenario B --prefix pay --env demo --location "<chosen-supported-region>"
```

For PowerShell, set `$env:TF_VAR_enable_sre_agents = 'true'` first. The mirror is
`pwsh .\scripts\deploy.ps1 -Scenario B -Prefix pay -Environment demo -Location '<chosen-supported-region>'`.
Unlike the workflow, the local Terraform path defaults agent provisioning to
disabled unless you enable it. Preserve this setting for later applies; the
wrappers do not complete the manual A/B agent builder onboarding for you.
Use one deployment owner/path at a time and the same backend identity on retries.
Do not bypass the wrappers with an unconfigured Terraform backend or assume
a root example tfvars file automatically configures workflow inputs.

**Fresh-deployment default versus existing state:** `pay` is the new default,
not a rename or migration instruction. For any existing deployment, explicitly
pass its original prefix/environment and preserve its stored `TF_PREFIX`.
Do not accept the new default when updating or destroying an older stack.
Local wrappers reconfigure the checkout for the selected backend and validate
the state scenario, prefix and environment before applying; they do not
implicitly migrate cached state. If validation fails, stop and verify the
original target and backend. Do not copy state between profiles or clear state
to bypass the check. The D walkthrough deliberately uses a distinct explicit
prefix so its workload cannot collide with an active A/B/C deployment.

For C follow its private workflow bootstrap. For D follow
[D deployment and teardown](scenario-d-private-payments.md#deploy-restart-and-teardown):
`deploy.yml` with scenario D delegates to `scenario-d-bicep.yml` and skips
Terraform workload jobs. Preserve the stable lifecycle generation and ownership
ledger. **Every Bicep create, including safe ledger snapshot updates, requires
a successful matching what-if first.** Never skip that gate or enable the
incident during deployment.

After successful **A/B/C** deploy, set `TF_PREFIX`, then `TF_ENVIRONMENT`, then
`DEPLOYMENT_SCENARIO` (`A`, `B` or `C`) last. Before activation, push deployments
intentionally do nothing. For B/C, this activation is required for a merged
incident/remediation PR to deploy.

## 7. Verify health and onboard the agents

Before injecting a fault:

1. Open the output frontend URL; place a real order. A healthy `/health`
   response alone is insufficient. Confirm a successful checkout and approved
   payment.
2. Confirm all app revisions are ready, images use digests, only frontend has
   external HTTPS ingress, and memory fault is disabled. D also requires
   `PAYMENT_FAILURE_MODE=off`.
3. Start the frontend's steady-traffic option or the documented traffic script.
   Confirm telemetry arrives in the deployed Application Insights resource;
   show a stable baseline and no active incident.
4. Open the deployed SRE Agent at <https://sre.azure.com>. Grant the browsing
   operator **SRE Agent Administrator at that agent's scope** as described in
   [operator access](sre-agent-setup.md#operator-access-to-the-agent).
   Subscription Owner alone does not grant agent data-plane access.
5. Follow the selected scenario's builder setup. A/B have manual portal
   configuration; C/D use manifests and reconciliation. Confirm connectors,
   resource scope, response plan, tool policy and review/approval behavior.
   B/C must retain workload Reader plus deny-write tool policy and must not
   use on-behalf-of elevation. Subscription Monitoring Contributor is a
   documented monitoring exception, not an entirely read-only identity.
6. B/C: connect/index **your** repository through Code Access. Verify App/OAuth
   permissions and branch policy allow a proposed PR but still require human
   review/merge. Never grant access to upstream to make the demo work.
7. A: onboard the portal-owned Observability Agent using Terraform onboarding
   outputs and rehearse the exact memory-alert scope. D: retain paused
   autonomous Observability; use on-demand investigation → save issue to the
   deployed AMW → manual handoff. D's automatic SRE diagnosis remains **Review**
   and matches **only the exact deployed payment-failure alert** via
   `titleContains`, not every subscription Sev2.

## 8. Rehearse the incident and approved recovery

Use the chosen walkthrough, not a command copied from another deployment.
Confirm target account, resource group and repository immediately before arming.

- A: use `trigger-incident-direct.sh` or its PowerShell mirror for your exact
  deployment; approve the proposed direct recovery in the SRE thread.
- B/C: use `./scripts/trigger-incident-gitops.sh --repo "your-org/your-demo"`
  or `pwsh .\scripts\trigger-incident-gitops.ps1 -Repository 'your-org/your-demo'`
  against your own copy, review the flag-on PR,
  then merge it intentionally. Confirm `apply-infra` actually ran. Inspect the
  agent's flag-off PR and let a human merge it; do not approve your own agent PR.
- D: discover names from the ownership outputs and use the walkthrough's
  explicit live flag update. Do not use legacy Terraform payments-trigger
  wrappers. Save the on-demand Observability issue, paste evidence into the SRE
  thread, and approve recovery separately.

Verify successful orders, fresh healthy revision, flattened memory or stopped
payment errors, and resolved alerts. Record actual timings; historical
8–12-minute memory trends or a ten-minute D target are not service guarantees.
Reset to healthy before a second rehearsal. Do not broaden an incident filter
or silently switch from Review to Autonomous to force a result.

## 9. Troubleshoot without weakening controls

| Symptom | Check |
| --- | --- |
| OIDC login fails | Own repository/ref or environment subject, issuer/audience, immutable subject configuration, client versus object ID, environment variable overrides |
| Authorization or backend 403 | Correct principal and scope; role-assignment rights and Blob data role propagation; do not enable storage keys |
| Provider/policy/capacity failure | Provider registration, preview eligibility, supported region, quota, policy deny/modify details; retain state until actual cleanup is verified before choosing a new region |
| Workflow queues indefinitely | Online runner in your repository and matching label array; D environment reviewer approval; do not route private jobs to a public runner |
| C/D private service timeout | Runner DNS resolves the intended private IP, peering/routes, permitted outbound paths, subnet/address overlap; never temporarily expose ACR/Key Vault |
| Agent UI looks like a network error | Exact agent-scoped data-plane role, sign-in account and RBAC propagation, then networking |
| PR merge does not deploy | `DEPLOYMENT_SCENARIO`, prefix/environment markers, own default branch, workflow enabled and actual run result |
| Agent only describes a PR | Code Access indexing, own-repository write permission, tool policy allowing `RunInTerminal`; retain deny rules for direct workload writes |
| D automatic issue never appears | Autonomous Observability is paused/unproven; use the required on-demand saved-issue/manual-handoff flow |
| D ownership/what-if check fails | Stop and inspect exact ledger, subscription, prefix/environment/generation and runner network; do not force-delete or take over foreign resources |

For more detail use the scenario-specific troubleshooting sections. Retain
sanitized error messages privately; never paste tokens, PEMs, connection
strings or full secret-bearing outputs into public issues.

## 10. Tear down safely

1. Stop traffic and restore the healthy flag through the scenario's approved
   path. Delete A's portal-owned Observability Agent before its Terraform-owned
   workspace/identity. Disconnect OAuth/App Code Access and revoke demo-only
   GitHub App keys/installations as appropriate.
2. A/B/C: run **destroy** in **your repository** with the exact scenario,
   prefix and environment from deploy. C requires the private runner. For a
   local A/B deployment created with the new defaults use
   `./scripts/teardown.sh --scenario B --prefix pay --env demo`.
   Older deployments must use their original prefix/environment instead.
   Recovery force deletion is exceptional; review its verified-state scope first.
3. Verify actual workload resource-group removal, including any failed-provider
   orphan resources. Only then clear `DEPLOYMENT_SCENARIO`, `TF_PREFIX` and
   `TF_ENVIRONMENT`. Do not erase state just to make a failed destroy look clean.
4. D: use the Bicep destroy route with the exact ownership confirmation; preserve
   what-if/ledger checks. It removes only its owned workload and exact owned
   external links/grants. It must retain shared DNS, shared state and the runner
   VM/disk/VNet/NAT. Never use A/B/C Terraform destroy for the D workload.
5. The runner foundation and backend can continue billing. Only after all
   dependent jobs finish may an operator separately deallocate the retained VM.
   Foundation deletion is a separately approved operation, using its retained
   Terraform state and dependency inventory, never part of D workload teardown.
6. Keep shared state accounts, other profiles' blobs and bootstrap identities
   until their consumers are accounted for. Remove demo-only federation and
   permissions deliberately when no longer needed. Check remaining resources
   and charges in your own subscription.

## 11. Distribute a customer-neutral copy

Before sharing, audit the **current tracked tree** for real tenant/subscription
IDs, personal repository URLs, live frontend endpoints, resource names,
screenshots and exported reports. Scan for secrets using your approved tooling.
Built-in Azure role-definition IDs, public Azure DNS suffixes and generic
sample prefixes are not customer credentials or deployment bindings.

This is separate from auditing **Git history**, branches/tags, releases,
workflow logs/artifacts, GitHub repository/environment variables and secrets,
App installations, OIDC credentials and Azure resources. A source edit does not
sanitize those surfaces. Historical review records in this copy are anonymized
and do not certify fresh-customer deployment.

For external distribution, prefer a reviewed **clean source snapshot in a new
customer-owned repository** if preserving old history is unnecessary. Verify
ignored state/tfvars, `.env`, credentials and local artifacts are not included.
No history rewriting is required or performed by this guide. If an actual
credential is found in any history or log, revoke/rotate it and follow your
organization's incident process; deleting a line is not remediation.
