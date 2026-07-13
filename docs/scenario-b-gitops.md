# Scenario B — GitOps fix

This guide takes you from an empty subscription to a working demo that is run
**entirely through CI/CD**, the way a real DevOps organisation operates. The
environment is deployed by a GitHub Actions pipeline, the fault is switched on by
merging a Pull Request, and the **Azure SRE Agent remediates by opening its own
Pull Request** — it never touches the live Azure resources directly. Every change
to the system, including the fix, ships as reviewed code.

Follow it from top to bottom; everything you need is here. For deeper background
on any agent step, see the [Azure SRE Agent reference](sre-agent-setup.md).

**The story this scenario tells:** infrastructure and application both ship
through pipelines. A change enters as a Pull Request, CI deploys it, memory starts
leaking, an alert fires, and the SRE Agent — which is **read-only** on Azure —
investigates, finds the Pull Request that caused it, and remediates by **opening a
Pull Request** of its own. A human reviews and merges that PR, and the pipeline
deploys the fix.

You will work through seven parts:

1. [Bootstrap the pipeline (one-time)](#part-1--bootstrap-the-pipeline-one-time)
2. [Deploy the environment with CI/CD](#part-2--deploy-the-environment-with-cicd)
3. [Create the SRE Agent](#part-3--create-the-sre-agent)
4. [Connect the agent to your code, resources, logs and incidents](#part-4--connect-the-agent)
5. [Apply the GitOps guardrails and behaviour](#part-5--apply-the-gitops-guardrails)
6. [Run the incident and watch the fix](#part-6--run-the-incident)
7. [Reset and clean up](#part-7--reset-and-clean-up)

---

## What is automated, and what is not

A useful part of this scenario is seeing exactly where the GitOps boundary sits —
especially for the SRE Agent. Three categories:

| Category | What it covers | How it is done |
| --- | --- | --- |
| **Automated in CI/CD (GitOps)** | All ContosoPay infrastructure (resource group, registry, Key Vault, telemetry, Container Apps, alert, Grafana), the application images, and the planted-fault flag. Optionally the SRE Agent resource, its access level, and its Azure Monitor wiring. | Terraform + GitHub Actions. Changes ship by merging Pull Requests. |
| **One-time bootstrap seed (cannot be GitOps)** | The private Linux runner and its VNet, the identity that CI signs in as, the federated credentials that trust this repository, and the GitHub Actions variables that point at them. | Created once by hand (Part 1). This is the classic chicken-and-egg: the runner and identity must exist before any pipeline can run. The first deploy creates the remote state account and its private endpoint automatically. |
| **SRE Agent portal-only (no IaC equivalent today)** | The GitHub sign-in for Code Access and the Connector, the tool access policy, the subagent (custom agent) and its knowledge, and the incident response plan. | Interactive steps in the agent portal (Parts 4 and 5). |

So for the SRE Agent specifically: **the agent resource, its permissions, and its
connection to Azure Monitor can be Infrastructure as Code** (see
[the reference, §6](sre-agent-setup.md#6-optional-provisioning-the-agent-with-terraform)),
while **the GitHub OAuth, tool policy, custom-agent behaviour, and response plan
are configured in the portal** because they are interactive, identity-bound steps.

---

## Before you begin

Because the heavy lifting happens in CI, you need very little installed locally:

- An Azure subscription where you have **Owner** (or **Contributor** plus
  **User Access Administrator**), so you can create the deployment identity and
  grant it roles in Part 1.
- The [Azure CLI](https://learn.microsoft.com/cli/azure/) and the
  [GitHub CLI](https://cli.github.com/) (`gh`), both signed in.
- A shell to run the Part 1 commands: **PowerShell 7+** on Windows, or **Bash** on
  macOS, Linux, WSL, or [Azure Cloud Shell](https://shell.azure.com). (On Windows,
  avoid Git Bash for these `az` commands.)
- A clone of this repository, and permission to run GitHub Actions and to open and
  merge Pull Requests on it.
- A persistent Linux self-hosted runner registered to the repository with
  `self-hosted`, `Linux`, `X64`, `azure-private`, and `contosopay` labels. The runner
  must have Docker and Azure CLI installed and outbound HTTPS access to GitHub.
- An Azure VNet for that runner with a dedicated private-endpoint subnet. The defaults
  are resource group `agentrg`, VNet `agent-vnet`, and subnet `private-endpoints`.

You do **not** need Terraform or Docker locally — the pipeline runs those for you.

Throughout this guide, replace `<your-org>/<your-repo>` with your repository.

---

## Part 1 — Bootstrap the pipeline (one-time)

This is the one part that cannot itself be GitOps: before any pipeline can deploy
Azure resources, it needs an identity to sign in as. You create that identity
once, let GitHub Actions authenticate to it with OpenID Connect (so there are no
stored secrets), and record three variables in the repository.

**What you will do:** create a deployment identity, trust this repository, grant
it access, and set the GitHub Actions variables.

Use **one** of the two blocks below depending on your shell. They do the same
thing: sign in, create an app registration, add federated credentials for the
`main` branch and for pull requests, grant the identity access, and record the
three variables the workflows read. Replace `<your-org>/<your-repo>` and
`<your-subscription>` first.

> **Which block do I use?**
> - On **macOS, Linux, WSL, or Azure Cloud Shell**, use the **Bash** block.
> - On **Windows**, use the **PowerShell** block.
>
> Bash and PowerShell assign variables differently — `SUB=$(az ...)` is Bash syntax
> and fails in PowerShell with *"is not recognized as a name of a cmdlet"*; in
> PowerShell you write `$SUB = az ...` instead.
>
> **Windows users:** run these in **PowerShell**, **WSL**, or **Azure Cloud Shell**
> (<https://shell.azure.com>). Avoid Git Bash for this step — it rewrites
> `/subscriptions/...` scopes and mangles `az` output, which produces confusing
> *"MissingSubscription"* errors.

### Bash (macOS / Linux / WSL / Azure Cloud Shell)

```bash
az login
az account set --subscription "<your-subscription>"

REPO="<your-org>/<your-repo>"
SUB=$(az account show --query id -o tsv)
TENANT=$(az account show --query tenantId -o tsv)

# App registration + service principal
APP_ID=$(az ad app create --display-name "contosopay-gha-deployer" --query appId -o tsv)
az ad sp create --id "$APP_ID"

# Federated credentials: main branch (workflow_dispatch) and pull requests
az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name":"main",
  "issuer":"https://token.actions.githubusercontent.com",
  "subject":"repo:'"$REPO"':ref:refs/heads/main",
  "audiences":["api://AzureADTokenExchange"]
}'
az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name":"pull-request",
  "issuer":"https://token.actions.githubusercontent.com",
  "subject":"repo:'"$REPO"':pull_request",
  "audiences":["api://AzureADTokenExchange"]
}'

# Access (subscription scope keeps the demo simple)
az role assignment create --assignee "$APP_ID" --role "Contributor" \
  --scope "/subscriptions/$SUB"
az role assignment create --assignee "$APP_ID" --role "Storage Blob Data Contributor" \
  --scope "/subscriptions/$SUB"
az role assignment create --assignee "$APP_ID" --role "User Access Administrator" \
  --scope "/subscriptions/$SUB"

# GitHub Actions variables the workflows read
gh variable set AZURE_CLIENT_ID       --repo "$REPO" --body "$APP_ID"
gh variable set AZURE_TENANT_ID       --repo "$REPO" --body "$TENANT"
gh variable set AZURE_SUBSCRIPTION_ID --repo "$REPO" --body "$SUB"
```

### PowerShell (Windows)

```powershell
az login
az account set --subscription "<your-subscription>"

$REPO   = "<your-org>/<your-repo>"
$SUB    = az account show --query id -o tsv
$TENANT = az account show --query tenantId -o tsv

# App registration + service principal
$APP_ID = az ad app create --display-name "contosopay-gha-deployer" --query appId -o tsv
az ad sp create --id $APP_ID

# Federated credentials passed as files (avoids cross-shell JSON quoting issues).
# The backtick before ':' stops PowerShell treating it as a scope/drive separator.
@"
{
  "name": "main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:$REPO`:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}
"@ | Set-Content fic-main.json
az ad app federated-credential create --id $APP_ID --parameters '@fic-main.json'

@"
{
  "name": "pull-request",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:$REPO`:pull_request",
  "audiences": ["api://AzureADTokenExchange"]
}
"@ | Set-Content fic-pr.json
az ad app federated-credential create --id $APP_ID --parameters '@fic-pr.json'
Remove-Item fic-main.json, fic-pr.json

# Access (subscription scope keeps the demo simple)
az role assignment create --assignee $APP_ID --role "Contributor" `
  --scope "/subscriptions/$SUB"
az role assignment create --assignee $APP_ID --role "Storage Blob Data Contributor" `
  --scope "/subscriptions/$SUB"
az role assignment create --assignee $APP_ID --role "User Access Administrator" `
  --scope "/subscriptions/$SUB"

# GitHub Actions variables the workflows read
gh variable set AZURE_CLIENT_ID       --repo $REPO --body $APP_ID
gh variable set AZURE_TENANT_ID       --repo $REPO --body $TENANT
gh variable set AZURE_SUBSCRIPTION_ID --repo $REPO --body $SUB
```

In both versions, **Contributor** lets the pipeline create and manage the demo
resources, **Storage Blob Data Contributor** lets it read and write the Terraform
state that the first pipeline run creates, and **User Access Administrator** lets
it assign the managed-identity roles the apps need (for example `AcrPull` and
`Key Vault Secrets User`). Without **User Access Administrator** the deploy fails
partway with *"does not have authorization to perform action
'Microsoft.Authorization/roleAssignments/write'"*.

**Expected outcome:** the repository's **Settings → Secrets and variables →
Actions → Variables** lists `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and
`AZURE_SUBSCRIPTION_ID`. The pipeline can now authenticate to Azure with no stored
credentials.

The workflows also accept these optional repository variables when the shared
runner network uses different names or address space:

| Variable | Default |
| --- | --- |
| `RUNNER_NETWORK_RG` | `agentrg` |
| `RUNNER_VNET_NAME` | `agent-vnet` |
| `RUNNER_PE_SUBNET_NAME` | `private-endpoints` |
| `APP_VNET_ADDRESS_SPACE` | `10.100.0.0/16` |
| `APP_PE_SUBNET_PREFIX` | `10.100.0.0/27` |
| `CONTAINER_APPS_SUBNET_PREFIX` | `10.100.0.64/27` |

The application address space and both subnet prefixes must not overlap the
runner VNet. The deployment identity also needs permission to create the reverse
VNet peering in `RUNNER_NETWORK_RG`; the subscription-scoped **Contributor**
assignment above includes that permission.

Migrating an existing environment from the former single-VNet layout replaces
the Container Apps environment and its private endpoints. Plan for a one-time
deployment outage; subsequent applies use the peered layout in place.

---

## Part 2 — Deploy the environment with CI/CD

**What you will do:** stand up the entire ContosoPay environment by running a
GitHub Actions workflow — no local Terraform or Docker.

1. In GitHub, open the **Actions** tab, select the **deploy** workflow, and choose
   **Run workflow** (you can keep the default prefix, environment, and region, or
   override them).

   For an existing environment, the workflow ignores a conflicting region input
   and reuses the immutable region stored in Terraform state.

**What is happening:** the `deploy` workflow runs on the self-hosted runner and
signs in with the identity from Part 1. It creates the remote Terraform state
storage and Blob private endpoint, then creates a regional application VNet with
global peering to the runner VNet. Private Key Vault and Premium ACR endpoints
live in the application VNet and are reachable from both Container Apps and the
runner. The workflow then builds and pushes the images and deploys the
application. No one runs anything against the live environment by hand.

**Expected outcome:** both the `deploy` and `arm-incident` jobs finish green, and
an incident Pull Request appears in GitHub. Open the run summary to find the
deployed environment's details:

| Output | Example |
| --- | --- |
| Frontend URL | `https://frontend.<region>.azurecontainerapps.io` |
| Resource group | `rg-contosopay-demo-<suffix>` |

> **The demo incident is pre-armed for you.** At the end of a successful `deploy`
> run, a follow-up job automatically opens the **incident Pull Request** that
> switches the memory-leak fault on (`enable_slow_leak = true`). It waits,
> unmerged, in the **Pull requests** tab — the run summary links to it. When you
> reach [Part 6](#part-6--run-the-incident), you just review and merge it. (To opt
> out, run `deploy` with **Open incident PR** set to `false`.)
>
> If `arm-incident` reports that the flag is already `true`, `main` contains an
> armed incident instead of the required healthy baseline. Set
> `enable_slow_leak = false` in `infra/leak.auto.tfvars` through a Pull Request,
> merge it, and rerun `deploy`. New workflow versions fail clearly in this state
> instead of completing green without a Pull Request.

2. The run summary also lists a small set of variables for the **deploy-apps**
   workflow (which ships future application-code changes). Set them once so that
   pipeline is ready too:

   ```bash
   gh variable set AZURE_RESOURCE_GROUP --repo "$REPO" --body "<resource group from summary>"
   gh variable set ACR_NAME --repo "$REPO" --body "<ACR_NAME from summary>"
   gh variable set FRONTEND_APP --repo "$REPO" --body "<FRONTEND_APP from summary>"
   gh variable set CHECKOUT_APP --repo "$REPO" --body "<CHECKOUT_APP from summary>"
   gh variable set PAYMENT_APP --repo "$REPO" --body "<PAYMENT_APP from summary>"
   ```

3. Open the **Frontend URL**, place a test order, and tick **"Generate steady
   traffic"** so Application Insights has a healthy baseline to compare against.

> From now on, infrastructure and flag changes deploy automatically when merged to
> `main`: the **apply-infra** workflow runs `terraform apply`, and the
> **deploy-apps** workflow rebuilds images when application code under `src/`
> changes. The remote-state location is computed automatically, so there is
> nothing else to copy between runs.

---

## Part 3 — Create the SRE Agent

**What you will do:** create the managed SRE Agent that will watch this
environment.

1. Go to <https://sre.azure.com> and sign in with your Azure account.
2. Start the create-agent wizard and fill in the **Basics**:

   | Field | Value |
   | --- | --- |
   | **Subscription** | The subscription that owns `rg-contosopay-demo-<suffix>`. |
   | **Resource group** | Create a new, dedicated group such as `rg-sre-agent`. |
   | **Agent name** | A name of your choice, for example `contosopay-sre-agent`. |
   | **Region** | **Sweden Central**, to match the demo and stay inside the EU Data Boundary. |
   | **Application Insights** | Create new (this is the agent's own telemetry). |

3. Review and create.

**Expected outcome:** the agent's status becomes **Succeeded**.

> Prefer to provision the agent as code? The agent resource, its access level, and
> its Azure Monitor wiring can be created by Terraform instead — set
> `enable_sre_agents = true` in `terraform.tfvars` and let the pipeline apply it.
> The portal steps in Parts 4 and 5 still apply.

---

## Part 4 — Connect the agent

The agent's setup page shows an **Add context** screen with four cards — **Code**,
**Logs**, **Azure resources**, and **Incidents**. Connect **all four**: each one
the agent can see sharpens its root-cause correlation, and for this scenario the
Logs card in particular is what ties the App Insights memory trend back to the
Pull Request. The steps below cover every card (plus the separate GitHub
Connector and Azure Monitor wiring).

### 4a. Connect your source code (read)

1. On the agent setup page, find the **Code** card and select **+**.
2. Choose **GitHub**, sign in, and select this demo's repository
   (`<your-org>/<your-repo>`).

**Expected outcome:** the **Code** card shows the repository and begins indexing.
This lets the agent *read* the code and find the Pull Request behind an incident.

### 4b. Add the GitHub Connector (write)

**What you will do:** allow the agent to *open* Pull Requests as its remediation.
This is a separate connection from Code Access.

1. Open **Builder → Connectors → Add connector → GitHub**.
2. Sign in with an identity (GitHub App or PAT) that has **all three** of these
   permissions on your repository — opening a Pull Request needs the agent to
   push a branch *and* create the PR, so **Contents** write is required, not just
   Pull requests:
   - **Contents: Read/Write** — create the fix branch and commit the file change.
   - **Pull requests: Read/Write** — open the remediation PR.
   - **Issues: Read/Write** — open the tracking issue.

**Expected outcome:** the agent can now create branches, issues, and Pull
Requests.

> **Troubleshooting — the agent opens an *issue* but no *PR*.** Issue creation
> only needs **Issues: Read/Write**, but a Pull Request also needs **Contents:
> Read/Write** (to push the branch) and **Pull requests: Read/Write**. If you see
> an issue appear with no accompanying PR, the connector identity is missing one
> of those two — reconnect it in **Builder → Connectors → GitHub** with all three
> permissions above. Also confirm the `gitops-remediation` subagent isn't
> restricted to issue-only tools (leave its **Tools** selection empty to inherit
> the branch/commit/PR tools — see Part 5b).

### 4c. Grant read-only access to the demo resources

**What you will do:** let the agent investigate the demo resource group without
the ability to change it — that is the point of this scenario.

1. On the setup page, find the **Azure Resources** card and select **+**.
2. Choose **Resource groups** and select **`rg-contosopay-demo-<suffix>`**.
3. Grant it **Reader** access **and** **Monitoring Contributor** (so the alert
   scanner can read fired alerts). Do **not** grant write access.

**Expected outcome:** the **Azure Resources** card lists the demo resource group
with read-only access.

### 4d. Add logs context (App Insights / Log Analytics)

**What you will do:** point the agent at the demo's telemetry so it can read the
memory trend and correlate it with the code and deployment. On the onboarding
screen this is the **Logs** card (marked *Recommended* / *Best with code*) — for
this scenario it is the single most valuable context source after Code.

1. On the setup page, find the **Logs** card and select **+**.
2. Select the demo's **Log Analytics workspace** `law-<suffix>` (and, if offered,
   the **Application Insights** resource `appi-<suffix>`) from
   `rg-contosopay-demo-<suffix>`.

**Expected outcome:** the **Logs** card shows the workspace. The agent can now
query the payment-service memory metric that drives the incident and line it up
against the commit/PR that introduced it.

### 4e. Add past-incident context

**What you will do:** let the agent learn from prior investigations so repeat
incidents resolve faster (the "memory" moment in Part 6). On the onboarding
screen this is the **Incidents** card.

1. On the setup page, find the **Incidents** card and select **+**.
2. Connect your incident source (e.g. Azure Monitor / the same subscription).

**Expected outcome:** the **Incidents** card is connected. On a first run it may
be empty — that is fine; after the demo runs once, re-triggering the leak shows
the agent recalling the earlier pattern and resolving it more quickly.

### 4f. Connect Azure Monitor

1. Open **Builder → Incident platform**, choose **Azure Monitor**, and save.

**Expected outcome:** Azure Monitor shows as **Connected**, and the agent begins
polling for fired alerts.

---

## Part 5 — Apply the GitOps guardrails

These steps make the agent behave the GitOps way: physically unable to change
Azure, and steered toward fixing incidents through Pull Requests. The supporting
files live in the [`agent/`](../agent/) folder of this repository.

> **Refresh the agent after the setup wizard first.** When you finish the
> onboarding wizard and land inside the agent, the backend can take a few minutes
> to finish provisioning (settings objects, ETags, tool registry). Editing
> permissions too soon triggers errors like *"Refusing to PUT global settings
> without an If-Match ETag."* Do a **hard refresh (Ctrl+F5)** once you're inside
> the agent before starting Part 5 — it clears most first-run save issues.

### 5a. Block direct Azure changes (tool access policy) — *optional hardening*

**What you will do:** apply a global policy that denies Azure write commands, so
the agent cannot change live resources even if asked.

> **This step is defense-in-depth, not required — feel free to skip it.** The
> primary write-block is already in place from **Part 4c** (the agent's permission
> level is **Reader**, so it holds no Azure *write* RBAC) plus the **Review** run
> mode (every action waits for approval). The tool access policy below is a second,
> independent guardrail and does **not** change how the demo behaves.
>
> The API method needs a *user* token for the SRE Agent audience. In many tenants
> **Azure Cloud Shell cannot get one** — its Managed Identity rejects the custom
> audience, and the `az login --scope …/.default` fallback uses the device-code
> flow, which **Conditional Access / MFA policies often block** (*"Your sign-in was
> successful but does not meet the criteria to access this resource"*). If you hit
> either, **just skip this step** — Reader + Review already covers you. Only pursue
> the API from a machine with an unrestricted interactive `az login`.

> **Two different "Settings" — don't confuse them.** The **Settings → Azure
> Settings / Managed Resources** page (Basics, Managed Resources, Azure Settings,
> …) is where Part 4c sets the RBAC permission *level* (Reader / Privileged).
> The *tool access policy* here is a separate allow/deny list at the agent's
> **global scope**.

The policy to apply comes in **two shapes** — pick the one for how you apply it:

> **If the portal reports unknown keys `_comment`, `permissions`, or both, you
> opened the API file.** Clear the editor and paste the exact **Portal** JSON
> below. Do not add comments or a `permissions` wrapper.
>
- **Portal (Method 1)** — the **Advanced permissions → JSON** tab wants a
  top-level object with just `allow` / `ask` / `deny` (paste
  [`agent/tool-access-policy.portal.json`](../agent/tool-access-policy.portal.json)):

  ```json
  {
    "allow": ["RunAzCliReadCommands", "RunKubectlReadCommand(kubectl get *)"],
    "ask": [],
    "deny": ["RunAzCliWriteCommands", "RunKubectlWriteCommand", "RunInTerminal", "RunShellCommand"]
  }
  ```

- **API (Method 2)** — the global-settings endpoint wants the same lists wrapped
  in a `permissions` object (see
  [`agent/tool-access-policy.api.json`](../agent/tool-access-policy.api.json)):

  ```json
  {
    "permissions": {
      "allow": ["RunAzCliReadCommands", "RunKubectlReadCommand(kubectl get *)"],
      "ask": [],
      "deny":  ["RunAzCliWriteCommands", "RunKubectlWriteCommand", "RunInTerminal", "RunShellCommand"]
    }
  }
  ```

> **Do not paste the `permissions`-wrapped form into the portal JSON box.** It
> rejects unknown keys with *"Invalid JSON: Unknown key(s): permissions. Only
> allow, ask, and deny are valid."* Use the un-wrapped `.portal.json` there.

Apply it at the **global** scope (only the global scope may *deny*). There are
two ways; **use the portal UI (Method 1) — it needs no API, token, or Cloud
Shell.**

#### Method 1 (recommended): the Permissions UI — no API needed

In the SRE Agent portal, open **Settings → Permissions** (older builds:
**Capabilities → Tools**). Two tabs make up the global tool access policy:

- **Built-in tools** — a grid of per-tool `On/Off` + `Allow/Ask` toggles.
- **Advanced permissions** — a glob-pattern `allow`/`ask`/`deny` editor, with a
  **Form** and a **JSON** sub-tab.

**Fastest path — paste the whole policy as JSON (no per-tool clicking).**
On the **Advanced permissions** tab, switch to the **JSON** sub-tab and replace
the contents with
[`agent/tool-access-policy.portal.json`](../agent/tool-access-policy.portal.json):

```json
{
  "allow": ["RunAzCliReadCommands", "RunKubectlReadCommand(kubectl get *)"],
  "ask": [],
  "deny": ["RunAzCliWriteCommands", "RunKubectlWriteCommand", "RunInTerminal", "RunShellCommand"]
}
```

This one paste sets the entire global policy — allow the read tools, deny the
Azure/Kubernetes writes **and** the shell escape hatches — so you can skip the
manual toggles below. (Remember: paste the un-wrapped form here, *not* the
`permissions`-wrapped API form, or the box rejects it.)

<details>
<summary>Prefer clicking? Do it by hand with the toggles instead.</summary>

**Step 1 — turn off the Azure/Kubernetes *write* tools (Built-in tools tab).**
Search for each and set it to **`Off`** (or **`Ask`** to keep it but force
approval):

- `RunAzCliWriteCommands`
- `RunKubectlWriteCommand`

Keep these **`On` / `Allow`** (safe, read-only):

- `RunAzCliReadCommands`
- `RunKubectlReadCommand`

**Step 2 — neutralize the shell tools (Advanced permissions tab).**
`RunInTerminal` is usually **locked `On`** in the grid (you *cannot* toggle it
off), and `RunShellCommand` may not appear as a built-in at all — both behaviours
are expected and vary by build. The grid toggle is not how you deny them: add
them as **deny patterns** on the **Advanced permissions** tab instead. A global
**deny** is evaluated before everything else, so it holds even for a
locked-`On` tool:

```
RunInTerminal
RunShellCommand
```

If you'd rather keep the shell available for read-only diagnostics, deny only the
dangerous writes instead (the `bash(…)` alias expands to `RunInTerminal`,
`RunShellCommand`, and the az CLI):

```
bash(az * create *)
bash(az * update *)
bash(az * delete *)
```

</details>

That's it — no token, no MFA.

> **Troubleshooting — *"Failed to save tool changes. Refusing to PUT global
> settings without an If-Match ETag."*** This is the portal's optimistic-
> concurrency guard: it won't save because it isn't holding a current ETag —
> usually the global-settings object hasn't been initialized yet, or the page
> loaded without fetching current settings. Fix it in order:
> 1. **Hard-refresh** the Permissions page (Ctrl+F5) so the portal re-fetches
>    settings + their ETag, then re-paste the JSON and **Save**.
> 2. If it still refuses, **initialize the object first**: on the **Built-in
>    tools** tab flip one write tool (e.g. `RunAzCliWriteCommands` → `Off`) and
>    **Save**. That creates the settings object (and its ETag). Then return to
>    **Advanced permissions → JSON**, paste, and **Save**.
> 3. Last resort: apply via **Method 2 (API)** below, which does GET-then-PUT
>    with `If-Match` explicitly.

> **You are already safe without any of Step 1–2.** The real guarantee is the
> **Reader** RBAC from **Part 4c** — with no Azure *write* role, the agent
> physically cannot change Azure regardless of which tools are `On`. Part 5a is
> defense-in-depth, so a locked-`On` `RunInTerminal` (or a missing
> `RunShellCommand`) does **not** compromise the GitOps boundary.

> Older builds expose this same global policy under **Capabilities → Tools**
> instead of **Settings → Permissions**. The tabs and toggles are equivalent.

#### Method 2 (fallback): apply the policy with the API (step by step)

Only needed if the Tools UI is unavailable. This path requires a *user* token for
the SRE Agent audience, which **Cloud Shell often cannot obtain** (its Managed
Identity rejects the audience, and the `az login` device-code fallback is
frequently blocked by Conditional Access/MFA). If you hit that, use Method 1 or
skip 5a entirely.

You will use **Azure Cloud Shell** — a browser terminal that already has the
Azure CLI installed and is already signed in as you, so there is nothing to set
up locally. (This also sidesteps the Windows shell issues in Part 1.)

You need to be an **Administrator** on the SRE Agent (global tool policies are an
admin-only setting).

1. **Open Azure Cloud Shell.** Go to [https://shell.azure.com](https://shell.azure.com)
   (or select the `>_` icon in the top bar of the Azure portal). If prompted,
   choose **Bash**.

2. **Get your agent's API endpoint.** It is stored on the agent resource as
   `properties.agentEndpoint` (a host on `azuresre.ai` — *not* the
   `sre.azure.com` address you see in the browser, which is only the portal UI).
   Read it with the CLI, substituting your resource group and agent name:

   ```bash
   AGENT_ENDPOINT=$(az resource show \
     --resource-group sreagentrg \
     --name contosopay-sre-agent \
     --resource-type Microsoft.App/agents \
     --query properties.agentEndpoint -o tsv)
   echo "$AGENT_ENDPOINT"
   ```

   It prints something like
   `https://contosopay-sre-agent--70b63853.df9bfa8c.swedencentral.azuresre.ai`.

3. **Get an access token** for the SRE Agent API. The `--resource` GUID is the
   fixed SRE Agent application ID (the audience the API expects) — copy it exactly:

   ```bash
   TOKEN=$(az account get-access-token \
     --resource 59f0a04a-b322-4310-adc9-39ac41e9631e \
     --query accessToken -o tsv)
   ```

   (The token lasts about an hour. If a later call returns `401`, just re-run
   this line to get a fresh one.)

   > **Cloud Shell note:** Cloud Shell signs you in with a Managed Identity (MSI),
   > which only issues tokens for a fixed set of audiences and will reject this
   > one with *"Audience … is not a supported MSI token audience."* If you see
   > that, sign in for this scope as a **user** first, then re-run the command above:
   >
   > ```bash
   > az login --scope "59f0a04a-b322-4310-adc9-39ac41e9631e/.default"
   > ```
   >
   > It prints a device-code URL — open it, paste the code, and you are done.
   > (Running this from a local machine where you did an interactive `az login`
   > avoids the MSI limitation entirely.)

4. **Apply the policy** with a `PUT` request:

   ```bash
   curl -X PUT "$AGENT_ENDPOINT/api/v2/agent/settings/global" \
     -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{
       "permissions": {
         "allow": ["RunAzCliReadCommands", "RunKubectlReadCommand(kubectl get *)"],
         "deny":  ["RunAzCliWriteCommands", "RunKubectlWriteCommand", "RunInTerminal", "RunShellCommand"]
       }
     }'
   ```

   A `2xx` response (for example `200`) means it was accepted.

5. **Verify** the policy is stored by reading it back:

   ```bash
   curl -s "$AGENT_ENDPOINT/api/v2/agent/settings/global" \
     -H "Authorization: Bearer $TOKEN" | jq .
   ```

   You should see your `allow` and `deny` lists in the response.

**Troubleshooting:**
- `401 Unauthorized` → token expired or missing; re-run step 3.
- `403 Forbidden` → your account isn't an **Administrator** on the agent.
- `404 Not Found` / connection error → `AGENT_ENDPOINT` is empty or wrong; re-run
  step 2 and confirm it printed an `https://…azuresre.ai` URL (check the resource
  group and agent name).

See [Tool access policies](https://learn.microsoft.com/en-us/azure/sre-agent/tool-access-policies)
for the full API reference.

**What is happening:** combined with the Reader access from Part 4c, the agent now
has neither the permission nor the tooling to write to Azure — two independent
guardrails.

### 5b. Add the GitOps behaviour (subagent)

1. Open **Builder → Agent Canvas**, then select **+ Create subagent**.
   (Recent builds renamed this from **Custom Agent**; the canvas now shows
   **Subagent** nodes. Older builds had **Builder → Custom agents → New**.)
2. Set **Name** to `gitops-remediation`. Open
   [`agent/gitops-remediation-agent.md`](../agent/gitops-remediation-agent.md)
   and paste **only the fenced prompt block** (the text inside the ` ```text `
   fence, from *"You are the ContosoPay GitOps remediation specialist."* to the
   end) into the **Instructions** field. Do **not** include the file's markdown
   header or the "Paste the block below" note — those are instructions *to you*,
   not part of the agent's prompt.
3. **Tools:** the subagent inherits all global tools by default (the panel says
   *"inherits N global tools"*). There is no single "GitHub Connector" toggle
   anymore — GitHub shows up as individual **DevOps** tools when you search
   `github` (e.g. `CreateGithubPullRequest`, `CreateGithubIssue`,
   `FetchGithubIssue`). **Easiest: leave the Tools selection empty** so the
   subagent inherits the GitHub Connector (from Part 4b) and Code Access
   (Part 4a). Only pick tools here if you want to *restrict* the subagent —
   selecting any tool **overrides** the inherited defaults. Save when done.

**What is happening:** this tells the agent that its remediation is to open a Pull
Request, not to run commands against Azure.

### 5c. Add the runbook (knowledge)

Add [`agent/knowledge/gitops-runbook.md`](../agent/knowledge/gitops-runbook.md)
under **Builder → Knowledge Sources → Add** (or attach it directly on the
`gitops-remediation` agent in **Agent Canvas** via its **Knowledge base**
option). This tells the agent that the memory leak is
controlled by the `enable_slow_leak` setting in `infra/leak.auto.tfvars`, so its
Pull Request edits the right file.

### 5d. Create the response plan

1. From the incident platform page, select **Create a response plan**.
2. Configure it:

   | Setting | Value |
   | --- | --- |
   | **Severity filter** | Include **Sev2 / Warning**. |
   | **Response agent** | The **`gitops-remediation`** subagent from 5b. |
   | **Autonomy level** | **Review**. |

**Expected outcome:** the response plan routes incidents to the GitOps agent. As a
quick check, ask the agent in a chat to "restart the payment-service container" —
it should decline and offer to open a Pull Request instead.

---

## Part 6 — Run the incident

**What you will do:** ship the fault through a Pull Request and watch the agent
remediate it through another Pull Request.

### 6a. Open the Pull Request that switches the fault on

If you deployed with the **`deploy` workflow** (Actions tab), an incident Pull
Request has **already been opened for you** at the end of that run — it sets
`enable_slow_leak = true` in `infra/leak.auto.tfvars` and is waiting in the
**Pull requests** tab. (The deploy run's summary links straight to it.) You can
skip ahead and simply review and **merge** it.

> To deploy without auto-opening the PR, run the `deploy` workflow with
> **Open incident PR** set to `false`, then open it yourself with the script below.

To open (or re-open) the incident PR manually instead — for example after a
`--reset`, or when you deployed from your machine with `scripts/deploy.*`:

```bash
./scripts/trigger-incident-gitops.sh           # Bash
# or
pwsh ./scripts/trigger-incident-gitops.ps1     # PowerShell
```

**What is happening:** the deploy workflow (or the script) opens a Pull Request
that sets `enable_slow_leak = true` in `infra/leak.auto.tfvars`.

**Expected outcome:** a Pull Request appears in GitHub. Review the diff, then
**merge it**. Merging runs the `apply-infra` workflow, which applies the change
and switches the fault on. No one edits the live service by hand.

### 6b. Watch the memory climb and the alert fire

Open **Application Insights** or **Grafana** and watch the payment-service memory
trend upward over roughly 30–40 minutes. When it crosses the threshold, the
**Azure Monitor alert** fires and the agent opens an investigation within about a
minute.

### 6c. Watch the investigation and root cause

The agent correlates the rising memory with the **Pull Request and merge commit**
from 6a and explains the root cause.

**Expected outcome:** the agent points to the specific change that introduced the
fault, not just a generic alert.

### 6d. Review and merge the agent's fix

Because the agent cannot change Azure directly, it remediates by **opening a Pull
Request** that sets `enable_slow_leak = false`, with the root cause and supporting
evidence in the description.

Open that Pull Request, review it, and **merge it** — this is the human approval
gate. Merging runs `apply-infra` again, which deploys the fix; a fresh
payment-service revision rolls out and memory returns to normal.

**Expected outcome:** after the workflow completes, the alert resolves and
payment-service memory flattens back to the baseline — and the entire change
history, fault and fix, is recorded as reviewed Pull Requests.

### 6e. (Optional) Show it again

Run the trigger script again to open a fresh Pull Request and show the agent
resolving the now familiar pattern faster.

---

## Part 7 — Reset and clean up

**Reset the fault** through a Pull Request (the same way the agent would):

```bash
./scripts/trigger-incident-gitops.sh --reset
# or
pwsh ./scripts/trigger-incident-gitops.ps1 -Reset
```

Merge the resulting Pull Request to return the service to a healthy state.

**Remove the ContosoPay environment** when finished. The quickest way is to delete
the two resource groups the pipeline created:

```bash
az group delete --name rg-contosopay-demo-<suffix> --yes --no-wait
az group delete --name rg-contosopay-tfstate --yes --no-wait
```

**Remove the SRE Agent** (it is separate from the demo's Terraform):

```bash
az group delete --name rg-sre-agent --yes
```

---

## How this maps to Azure SRE Agent capabilities

| Step | Capability shown |
| --- | --- |
| 6b | Detects an incident from an Azure Monitor alert. |
| 6c | Correlates telemetry with the originating Pull Request and commit, and explains the root cause. |
| 6d | Remediates through a reviewed Pull Request, with no direct access to Azure. |
| 6e | Recognises a repeated pattern and resolves it faster. |

---

## References

- [Agent permissions](https://learn.microsoft.com/en-us/azure/sre-agent/permissions)
  · [Run modes](https://learn.microsoft.com/en-us/azure/sre-agent/run-modes)
- [Tool access policies](https://learn.microsoft.com/en-us/azure/sre-agent/tool-access-policies)
- [GitHub connector](https://learn.microsoft.com/en-us/azure/sre-agent/github-connector)
  · [Connect source code](https://learn.microsoft.com/en-us/azure/sre-agent/connect-source-code)
- [The committable agent configuration](../agent/README.md)
