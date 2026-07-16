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
leaking, an alert fires, and the SRE Agent — which has **Reader-level workload
access** — investigates, finds the Pull Request that caused it, and remediates by
**opening a Pull Request** of its own. A human reviews and merges that PR, and
the pipeline deploys the fix.

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
| **SRE Agent portal-only (no IaC equivalent today)** | GitHub OAuth for repository indexing, the managed-identity custom MCP connection, the tool access policy, the custom agent and its knowledge, and the incident response plan. | Interactive steps in the agent portal (Parts 4 and 5). |

So for the SRE Agent specifically: **the agent resource, its permissions, and its
connection to Azure Monitor can be Infrastructure as Code** (see
[the reference, §6](sre-agent-setup.md#6-optional-provisioning-the-agent-with-terraform)),
while **Code Access OAuth, custom MCP selection, tool policy, custom-agent
behaviour, and the response plan are configured in the portal** because they are
interactive, identity-bound steps.

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

Scenario B has three GitHub connection options. Use **Option 1** unless you
explicitly want the quicker PAT shortcut or the hardened broker pattern.

| Connection | Purpose | Authentication |
| --- | --- | --- |
| **Option 1 — recommended: Builder → Code Access → Bring your own GitHub App** | Connect the repository with app-based GitHub access so operations are attributed to the GitHub App, not a user. | GitHub App private key imported as a Key Vault key and used by the SRE Agent managed identity. |
| **Option 2 — demo shortcut: Builder → Connectors → GitHub MCP** | Let the agent create the branch, file edit, and Pull Request directly. | A short-lived fine-grained GitHub PAT pasted into the connector wizard. |
| **Option 3 — advanced hardening: Builder → Connectors → custom MCP server** | Restrict remediation to two allowlisted issue/status tools. | SRE Agent managed identity calls a broker; the broker uses an issue-only GitHub App. |

The native BYO GitHub App setup is documented by Microsoft at
[Set up GitHub BYO App connector in Azure SRE Agent](https://learn.microsoft.com/azure/sre-agent/setup-github-byo-app).
It uses Key Vault-backed GitHub App credentials directly in **Code Access**. The
custom MCP broker below is separate and optional; keep it only when you want to
show an extra hardening pattern.

Before continuing, confirm `.github/workflows/apply-infra.yml` is present on the
repository's default branch. The advanced broker hardening path also requires
`.github/workflows/sre-remediation-pr.yml`, because issue events load their
workflow definition from that branch.

### 4a. Option 1 — Connect Code Access with BYO GitHub App

This is the recommended demo path: no PAT, no custom broker, and GitHub actions
are attributed to your app identity.

1. In GitHub, open **Settings → Developer settings → GitHub Apps → New GitHub
   App**. For an organisation-owned repository, create it under the
   organisation's settings instead.
2. Set:
   - **GitHub App name:** a unique name, for example
     `contosopay-sre-agent`;
   - **Homepage URL:** `https://sre.azure.com`;
   - **Webhook → Active:** unchecked.
3. Under **Repository permissions**, set:
   - **Contents:** **Read and write**;
   - **Pull requests:** **Read and write**;
   - **Metadata:** **Read-only** (GitHub adds this automatically).

   Leave **Actions**, **Administration**, **Secrets**, and unrelated permissions
   at **No access**.
4. Under **Where can this GitHub App be installed?**, keep it limited to the
   owning account unless broader installation is genuinely required. Select
   **Create GitHub App**.
5. On the app's **General** page, record the **Client ID** that starts with
   `Iv...`. This is different from the numeric App ID.
6. Select **Generate a private key** and keep the downloaded PEM file local.
7. Open **Install App**, install it on the repository owner, choose **Only select
   repositories**, and select this repository only.
8. Import the private key into Key Vault as a **key**, not as a secret. The
   current SRE Agent BYO App wizard rejects `.../secrets/<name>` URIs and expects
   a Key Vault key URI in the form `.../keys/<name>`.

   Run this from a VNet-connected jumpbox, private self-hosted runner, or other
   machine that can reach the private Key Vault endpoint:

   ```bash
   KEY_VAULT_NAME="<demo-key-vault-name>"
   KEY_NAME="sre-agent-github-app-key"
   PEM_FILE="./<downloaded-github-app-key>.pem"

   az keyvault key import \
     --vault-name "$KEY_VAULT_NAME" \
     --name "$KEY_NAME" \
     --pem-file "$PEM_FILE" \
     --ops sign

   KEY_URI="https://${KEY_VAULT_NAME}.vault.azure.net/keys/${KEY_NAME}"
   echo "$KEY_URI"
   ```

   The unversioned key URI is preferred so key rotation works without updating
   the connector. Do not import the PEM as a Key Vault secret and do not put it
   in Terraform state.
9. Grant the SRE Agent managed identity **Key Vault Crypto User** on that Key
   Vault, or on the imported key scope. The identity needs permission to use the
   key for signing GitHub App authentication tokens.
10. In SRE Agent, open **Builder → Code Access → Add repositories**.
11. Choose **GitHub**, enter `github.com`, continue to **Authenticate**, and
    select **Bring your own GitHub App**.
12. Enter:
    - **Client ID:** the `Iv...` Client ID from the GitHub App;
    - **Private key URI:** the Key Vault key URI, for example
      `https://<vault-name>.vault.azure.net/keys/sre-agent-github-app-key`;
    - **Key Vault identity:** the SRE Agent managed identity, if prompted.
13. Select **Connect**, then add this repository and save.

**Expected outcome:** Code Access shows the repository connected with auth type
`GitHubApp`. The SRE Agent can use app-based GitHub access for repository
operations, and no individual user's PAT is involved.

### 4b. Option 2 — demo shortcut: use the PAT-based GitHub MCP connector

Use this only when demo speed matters more than showing the most secure pattern.
It avoids GitHub App and Key Vault setup. The tradeoff is that the SRE Agent
connector holds a GitHub PAT with repository write permissions for the duration
of the demo.

If you choose this shortcut:

1. In GitHub, create a **fine-grained personal access token**:
   - **Resource owner:** the repository owner;
   - **Repository access:** **Only select repositories**, then choose this repo;
   - **Expiration:** as short as possible, ideally same day;
   - **Repository permissions:** **Contents: Read and write**, **Pull requests:
     Read and write**, and **Metadata: Read-only**.
2. Copy the token once. Do not store it in the repository, Terraform variables,
   Key Vault, workflow secrets, shell history, or notes.
3. Open **Builder → Connectors → Add connector → MCP → GitHub**.
4. Use the wizard's default GitHub MCP server URL
   `https://api.githubcopilot.com/mcp/`, select **PAT / API key**
   authentication, and paste the token.
5. Save the connector, then open **Capabilities → Tools → MCP servers +
   services** and expand the GitHub connector.
6. Enable only the minimum GitHub tools needed to read repository content, create
   a branch, update one file, create a commit, and open a Pull Request. Do not
   enable repository administration, workflow dispatch, issue deletion, secret
   management, or merge/approve tools.
7. Continue with [4f. Grant Reader-level workload access](#4f-grant-reader-level-workload-access).
   In Part 5b, use
   [`agent/gitops-remediation-agent-github.md`](../agent/gitops-remediation-agent-github.md).
8. After the demo, revoke the PAT in GitHub under **Settings → Developer
   settings → Personal access tokens → Fine-grained tokens**.

> Keep the global tool access policy in Part 5a even with the PAT shortcut. It
> still blocks terminal fallback and direct Azure/Kubernetes/Terraform writes.

### 4c. Option 3 — advanced hardening: deploy the custom MCP broker

Skip this section unless you explicitly want to showcase the hardened broker
pattern. The broker is useful when you do not want the agent to receive general
repository write tools at all. Instead, the agent can only create a fixed issue;
GitHub Actions then opens the remediation PR.

#### 4c.1. Create the issue-only GitHub App

1. In GitHub, open **Settings → Developer settings → GitHub Apps → New GitHub
   App**. For an organisation-owned repository, create it under the
   organisation's settings instead.
2. Set a unique **GitHub App name** and **Homepage URL** `https://sre.azure.com`.
3. Disable **Webhook → Active**. This flow does not receive webhooks.
4. Under **Repository permissions**, set:
   - **Issues:** **Read and write**;
   - **Metadata:** **Read-only** (GitHub adds this automatically).

   Leave **Contents**, **Pull requests**, **Actions**, **Administration**, and all
   other permissions at **No access**.
5. Under **Where can this GitHub App be installed?**, keep it limited to the
   owning account unless broader installation is genuinely required. Select
   **Create GitHub App**.
6. On the app's **General** page, record the numeric **App ID** and the app slug.
   Select **Generate a private key** and keep the downloaded PEM file local.
7. Open **Install App**, install it on the repository owner, choose **Only select
   repositories**, and select this repository only.
8. Record the numeric installation ID from the installation page URL
   (`.../settings/installations/<installation-id>`).
9. In the repository, create the label:
   - **Name:** `sre-remediation`;
   - **Description:** `Approved trigger for the fixed SRE remediation workflow`.
10. Open **Settings → Actions → General → Workflow permissions**, select **Read
    and write permissions**, and enable **Allow GitHub Actions to create and
    approve pull requests**. The workflow creates a PR but never approves or
    merges it.

#### 4c.2. Register the broker API in Microsoft Entra

The custom MCP wizard needs an Entra token scope. This registration has no
client secret: the SRE Agent authenticates with its managed identity.

1. Record the agent resource group and agent name, then retrieve the exact
   Scenario B managed identity:

   ```bash
   AGENT_RG="<resource-group-containing-the-sre-agent>"
   AGENT_NAME="<sre-agent-name>"

   AGENT_IDENTITY_ID="$(az resource show \
     --resource-group "$AGENT_RG" \
     --name "$AGENT_NAME" \
     --resource-type Microsoft.App/agents \
     --api-version 2026-01-01 \
     --query properties.actionConfiguration.identity -o tsv)"
   SRE_CALLER_PRINCIPAL_ID="$(az identity show \
     --ids "$AGENT_IDENTITY_ID" --query principalId -o tsv)"
   ```

   If the first query is empty, open the agent's **Settings → Azure Settings**
   page, copy its managed identity resource ID, and use that as
   `AGENT_IDENTITY_ID`.
2. Create the dedicated single-tenant API registration:

   ```bash
   BROKER_API_CLIENT_ID="$(az ad app create \
     --display-name "contosopay-sre-remediation-api" \
     --sign-in-audience AzureADMyOrg \
     --query appId -o tsv)"
   BROKER_AUDIENCE="api://${BROKER_API_CLIENT_ID}"
   BROKER_SCOPE="${BROKER_AUDIENCE}/.default"

   az ad app update \
     --id "$BROKER_API_CLIENT_ID" \
     --identifier-uris "$BROKER_AUDIENCE"
   az ad sp create --id "$BROKER_API_CLIENT_ID"
   ```

   No certificate, client secret, or delegated user permission is required.

#### 4c.3. Enable and deploy the broker

1. Set the nonsecret repository variables consumed by both `deploy` and
   `apply-infra`. Replace the placeholders with the values from 4c.1 and 4c.2:

   ```bash
   REPO="<your-org>/<your-repo>"

   gh variable set ENABLE_SRE_REMEDIATION_BROKER \
     --repo "$REPO" --body "true"
   gh variable set SRE_REMEDIATION_CALLER_PRINCIPAL_ID \
     --repo "$REPO" --body "$SRE_CALLER_PRINCIPAL_ID"
   gh variable set SRE_REMEDIATION_ENTRA_API_CLIENT_ID \
     --repo "$REPO" --body "$BROKER_API_CLIENT_ID"
   gh variable set SRE_REMEDIATION_ENTRA_TOKEN_AUDIENCE \
     --repo "$REPO" --body "$BROKER_AUDIENCE"
   gh variable set SRE_REMEDIATION_ENTRA_TOKEN_SCOPE \
     --repo "$REPO" --body "$BROKER_SCOPE"
   gh variable set SRE_GITHUB_APP_ID \
     --repo "$REPO" --body "<numeric-app-id>"
   gh variable set SRE_GITHUB_APP_INSTALLATION_ID \
     --repo "$REPO" --body "<numeric-installation-id>"
   gh variable set SRE_GITHUB_APP_BOT_LOGIN \
     --repo "$REPO" --body "<app-slug>[bot]"
   gh variable set SRE_GITHUB_APP_PRIVATE_KEY_SECRET_NAME \
     --repo "$REPO" --body "github-app-private-key"
   ```

2. In GitHub, open **Actions → deploy → Run workflow** again. Existing app
   revisions remain running; the workflow builds the broker image and adds the
   broker identity, Key Vault/ACR roles, Container App, and Entra authentication.
3. From the run summary, record:
   - `SRE_REMEDIATION_BROKER_APP`;
   - **SRE remediation MCP endpoint**;
   - **Key Vault name**.
   Save the app name for future broker code deployments:

   ```bash
   gh variable set SRE_REMEDIATION_BROKER_APP \
     --repo "$REPO" \
     --body "<SRE_REMEDIATION_BROKER_APP from summary>"
   ```

4. Upload the PEM private key to that existing Key Vault. The preferred path is
   to run this from the private runner network:

   ```bash
   ./scripts/configure-github-app-key.sh \
     --vault-name "<key-vault-name>" \
     --private-key "./<downloaded-key>.pem"
   ```

   From an operator machine outside the VNet, add
   `--operator-cidr "<your-public-ip>/32"`. The script briefly enables the vault's
   public endpoint for only that CIDR and restores private-only access even when
   the upload fails. It also grants the signed-in user **Key Vault Secrets
   Officer** only when needed and removes that temporary role on exit; the user
   therefore needs permission to create role assignments. PowerShell users can run
   `scripts/configure-github-app-key.ps1` with the equivalent parameters.
5. Delete the local PEM copy after confirming the Key Vault secret exists. Never
   put the PEM in a GitHub secret, tfvars file, workflow input, or repository.
6. Confirm the boundary:

   ```bash
   curl -i "<SRE remediation MCP endpoint>"
   ```

   An unauthenticated request must return **401**. The `/health` endpoint is the
   only auth exclusion and returns only `{"status":"ok"}` for platform probes.

> The broker is the only public endpoint besides `frontend`. It is HTTPS-only,
> rejects unauthenticated requests in Container Apps authentication, and then
> checks that `x-ms-client-principal-id` equals this exact SRE Agent identity.
> Its managed identity can pull its image and read Key Vault secrets. The GitHub
> App can read/write issues only on this one repository.

#### 4c.4. Add the custom MCP connector in the current SRE Agent UI

1. Open **Builder → Connectors** and select **Add connector**.
2. In the connector catalog, select **MCP**, then select **MCP server**.

   Do **not** select the preconfigured **GitHub** tile. That wizard currently
   points at `https://api.githubcopilot.com/mcp/` and requires a PAT/API key.
   Use it only for the demo shortcut above.
3. Fill in the custom MCP form:

   | Current wizard field | Value |
   | --- | --- |
   | **Name** | `ContosoPay remediation` |
   | **Connection type** | **Streamable-HTTP** |
   | **Server URL** | The **SRE remediation MCP endpoint** from the deploy summary, including `/mcp` |
   | **Authentication** | **Managed identity** |
   | **Managed identity** | This Scenario B SRE Agent's managed identity |
   | **Azure AD token scope** | The value of `BROKER_SCOPE`, for example `api://<client-id>/.default` |

4. Complete the connector wizard, then open **Capabilities → Tools → MCP servers
   + services** and expand **ContosoPay remediation**. The server must expose
   exactly:
   - `create_slow_leak_remediation_issue`;
   - `get_slow_leak_remediation_status`.
5. Enable only those two tools and save the tool selection.

The workflow runs only when all of these conditions match:

- exact title: `[SRE] Remediate ContosoPay slow memory leak`;
- label: `sre-remediation`;
- body marker: `<!-- sre-remediation:payment-slow-leak -->`; and
- issue author is the configured GitHub App bot (or a trusted owner, member, or
  collaborator for manual recovery).

**Expected outcome:** the agent can create and read the narrowly defined trigger
issue. GitHub Actions performs branch creation, the commit, and PR creation with
a short-lived `GITHUB_TOKEN`.

> If tool discovery fails, first confirm the connector uses the generic **MCP
> server** tile, the URL ends in `/mcp`, authentication is **Managed identity**,
> and the scope ends in `/.default`. A raw browser or `curl` request returning
> `401` is expected; a `404` indicates the wrong URL.

### 4f. Grant Reader-level workload access

**What you will do:** let the agent investigate the demo resource group without
workload contributor roles — that is the point of this scenario.

1. On the setup page, find the **Azure Resources** card and select **+**.
2. Choose **Resource groups** and select **`rg-contosopay-demo-<suffix>`**.
3. Select the **Reader** permission level. Azure SRE Agent assigns its core
   monitoring roles automatically, including **Monitoring Contributor** at
   subscription scope so it can acknowledge and close alerts. Do not select the
   **Privileged** permission level. See
   [Agent permissions in Azure SRE Agent](https://learn.microsoft.com/azure/sre-agent/permissions)
   for the current role list and scopes.

**Expected outcome:** the **Azure Resources** card lists the demo resource group
with Reader-level workload access. Monitoring Contributor can change alert
lifecycle and monitoring settings, so the required tool policy in Part 5a
provides the second boundary against direct Azure mutations.

### 4g. Add logs context (App Insights / Log Analytics)

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

### 4h. Add past-incident context

**What you will do:** let the agent learn from prior investigations so repeat
incidents resolve faster (the "memory" moment in Part 6). On the onboarding
screen this is the **Incidents** card.

1. On the setup page, find the **Incidents** card and select **+**.
2. Connect your incident source (e.g. Azure Monitor / the same subscription).

**Expected outcome:** the **Incidents** card is connected. On a first run it may
be empty — that is fine; after the demo runs once, re-triggering the leak shows
the agent recalling the earlier pattern and resolving it more quickly.

### 4i. Connect Azure Monitor

1. Open **Builder → Incident platform**, choose **Azure Monitor**, and save.

**Expected outcome:** Azure Monitor shows as **Connected**, and the agent begins
polling for fired alerts.

---

## Part 5 — Apply the GitOps guardrails

These steps make the agent behave the GitOps way: no workload contributor roles,
direct Azure mutation tools denied, and remediation routed through a Pull
Request. The supporting files live in the [`agent/`](../agent/) folder.

> **Refresh the agent after the setup wizard first.** When you finish the
> onboarding wizard and land inside the agent, the backend can take a few minutes
> to finish provisioning (settings objects, ETags, tool registry). Editing
> permissions too soon triggers errors like *"Refusing to PUT global settings
> without an If-Match ETag."* Do a **hard refresh (Ctrl+F5)** once you're inside
> the agent before starting Part 5 — it clears most first-run save issues.

### 5a. Block direct Azure changes (required tool access policy)

**What you will do:** apply a global policy that denies Azure write commands, so
the agent cannot change live resources even if asked.

> **Do not skip this step.** Reader-level agents still receive Monitoring
> Contributor for the Azure Monitor alert lifecycle, and an administrator can
> authorize temporary on-behalf-of elevation. The policy below is therefore the
> explicit GitOps boundary that denies direct Azure, Kubernetes, Terraform, and
> terminal mutation paths.
>
> The API method needs a *user* token for the SRE Agent audience. In many tenants
> **Azure Cloud Shell cannot get one** — its Managed Identity rejects the custom
> audience, and the `az login --scope …/.default` fallback uses the device-code
> flow, which **Conditional Access / MFA policies often block** (*"Your sign-in was
> successful but does not meet the criteria to access this resource"*). If you hit
> either, use the portal method below instead. Do not proceed with Scenario B
> until the policy saves successfully.

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
    "deny": ["RunInTerminal", "RunShellCommand", "RunAzCliWriteCommands", "RunKubectlWriteCommand", "bash(az * create *)", "bash(az * update *)", "bash(az * delete *)", "bash(az * set *)", "bash(az * restart *)", "bash(az * start *)", "bash(az * stop *)", "bash(terraform * apply *)", "bash(terraform * destroy *)"]
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
      "deny": ["RunInTerminal", "RunShellCommand", "RunAzCliWriteCommands", "RunKubectlWriteCommand", "bash(az * create *)", "bash(az * update *)", "bash(az * delete *)", "bash(az * set *)", "bash(az * restart *)", "bash(az * start *)", "bash(az * stop *)", "bash(terraform * apply *)", "bash(terraform * destroy *)"]
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

In the current SRE Agent portal, open **Capabilities → Tools**. The page includes
**Built-in tools**, **MCP servers + services**, **Custom tools**, **Advanced
permissions**, and **Approval expiration**. Two tabs are relevant to the global
tool access policy:

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
  "deny": ["RunInTerminal", "RunShellCommand", "RunAzCliWriteCommands", "RunKubectlWriteCommand", "bash(az * create *)", "bash(az * update *)", "bash(az * delete *)", "bash(az * set *)", "bash(az * restart *)", "bash(az * start *)", "bash(az * stop *)", "bash(terraform * apply *)", "bash(terraform * destroy *)"]
}
```

This one paste allows read diagnostics and denies terminal/shell fallback plus
direct Azure/Kubernetes writes and Terraform apply/destroy. GitHub remediation remains available through the connector's two constrained
broker tools. If you chose the PAT shortcut, allow the minimum GitHub
branch/file/Pull Request tools instead.
(Remember: paste the un-wrapped form here, *not* the `permissions`-wrapped API
form, or the box rejects it.)

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

**Step 2 — turn off terminal fallback.**
Set `RunInTerminal` and `RunShellCommand` to **Off**. The agent does not need
either tool: the recommended path creates the constrained remediation issue and
the triggered workflow performs its fixed repository change with GitHub's
short-lived `GITHUB_TOKEN`. The PAT shortcut uses connector tools for the same
one-file PR without terminal fallback.

Keep the targeted deny patterns for direct infrastructure changes too:

```
bash(az * create *)
bash(az * update *)
bash(az * delete *)
bash(terraform * apply *)
bash(terraform * destroy *)
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

> **Do not continue while the policy is unsaved.** Reader-level agents retain
> Monitoring Contributor for alert lifecycle operations and can request
> administrator-authorized OBO elevation. The prompt is behavioral guidance, not
> an enforcement boundary.

> Older builds expose this same global policy under **Capabilities → Tools**
> instead of **Settings → Permissions**. The tabs and toggles are equivalent.

#### Method 2 (fallback): apply the policy with the API (step by step)

Only needed if the Tools UI is unavailable. This path requires a *user* token for
the SRE Agent audience, which **Cloud Shell often cannot obtain** (its Managed
Identity rejects the audience, and the `az login` device-code fallback is
frequently blocked by Conditional Access/MFA). If you hit that, use Method 1 or
ask your SRE Agent administrator to apply the policy. Do not continue Scenario B
without it.

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
   SETTINGS_URL="$AGENT_ENDPOINT/api/v2/agent/settings/global"
   HEADERS=$(mktemp)
   trap 'rm -f "$HEADERS"' EXIT

   curl -fsS -D "$HEADERS" -o /dev/null \
     -H "Authorization: Bearer ${TOKEN}" \
     "$SETTINGS_URL"
   ETAG=$(awk 'tolower($1) == "etag:" { gsub("\r", "", $2); print $2 }' "$HEADERS")
   : "${ETAG:?The settings response did not include an ETag}"

   curl -X PUT "$AGENT_ENDPOINT/api/v2/agent/settings/global" \
     -H "Authorization: Bearer ${TOKEN}" \
     -H "Content-Type: application/json" \
     -H "If-Match: $ETAG" \
     -d '{
       "permissions": {
         "allow": ["RunAzCliReadCommands", "RunKubectlReadCommand(kubectl get *)"],
         "ask": [],
         "deny": ["RunInTerminal", "RunShellCommand", "RunAzCliWriteCommands", "RunKubectlWriteCommand", "bash(az * create *)", "bash(az * update *)", "bash(az * delete *)", "bash(az * set *)", "bash(az * restart *)", "bash(az * start *)", "bash(az * stop *)", "bash(terraform * apply *)", "bash(terraform * destroy *)"]
       }
     }'
   ```

   A `2xx` response (for example `200`) means it was accepted.

5. **Verify** the policy is stored by reading it back:

   ```bash
   curl -s "$AGENT_ENDPOINT/api/v2/agent/settings/global" \
     -H "Authorization: Bearer ${TOKEN}" | jq .
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

**What is happening:** Scenario B has no workload contributor role, and the
global policy denies direct Azure mutation tools even though the agent retains
its core monitoring roles.

### 5b. Add the GitOps behaviour (subagent)

1. Open **Builder → Agent Canvas**, then select **Create subagent**. The form that
   opens is titled **Create a custom agent**.
2. On the **Form** tab, set **Custom agent name** to
   `gitops-remediation`. Open
   [`agent/gitops-remediation-agent-github.md`](../agent/gitops-remediation-agent-github.md)
   and paste **only the fenced prompt block** (the text inside the ` ```text `
   fence, from *"You are the ContosoPay GitOps remediation specialist."* to the
   end) into the **Instructions** field. Do **not** include the file's markdown
   header or the "Paste the block below" note — those are instructions *to you*,
   not part of the agent's prompt.
   If you chose the advanced broker hardening option in Part 4, use
   [`agent/gitops-remediation-agent.md`](../agent/gitops-remediation-agent.md)
   instead.
3. Under **Choose tools**, use an explicit selection rather than leaving the list
   empty. The current **Create a custom agent** form warns that selecting tools
   overrides inherited global tools.

   For the native BYO GitHub App path or PAT shortcut, select the GitHub
   connector tools needed to create a branch, update `infra/leak.auto.tfvars`,
   commit the change, and open a Pull Request. Do not select terminal, workflow
   dispatch, repository administration, secret-management, approval, or merge
   tools.

   For the advanced broker hardening path, select Code Access repository read,
   Azure read tools, `create_slow_leak_remediation_issue`, and
   `get_slow_leak_remediation_status`. Do not select direct Pull Request
   authoring tools for that path.

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

1. Open **Builder → Incident Response Plans** and select **Create incident
   response plan**. The same wizard is available from **Builder → Agent Canvas →
   Create → Trigger → Incident response plan**.
2. On the first page of the current wizard, set:

   | Current wizard field | Value |
   | --- | --- |
   | **Incident response plan name** | `ContosoPay payment memory leak` |
   | **Severity** | **2 / Warning** |
   | **Title contains** | `alert-payment-memory-` |
   | **Title does not contain** | Leave empty |
   | **I want a custom response plan** | Selected |

3. Continue to **Define agent learning**. State that this plan must delegate the
   investigation and remediation to the `gitops-remediation` custom agent, remain
   in review/human-approval mode, and never mutate Azure directly.
4. On **Review custom plan**, confirm the plan invokes
   `gitops-remediation`. For the native BYO GitHub App path or PAT shortcut, it
   should use only the minimum GitHub branch/file/Pull Request tools. For the
   advanced broker hardening path, it should use the two broker tools only for
   remediation. Save the plan.

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
trend upward over roughly 8–12 minutes. The alert evaluates the five-minute
average, so an ordinary one-sample spike does not fire it. When the average
crosses the threshold, the **Azure Monitor alert** fires and the agent opens an
investigation within about a minute.

### 6c. Watch the investigation and root cause

The agent correlates the rising memory with the **Pull Request and merge commit**
from 6a and explains the root cause.

**Expected outcome:** the agent points to the specific change that introduced the
fault, not just a generic alert.

### 6d. Review and merge the agent's fix

Because the agent cannot change Azure directly, it opens the narrowly defined
`sre-remediation` trigger issue. The workflow creates a branch, commits the
one-line change to set `enable_slow_leak = false`, opens an unmerged Pull Request
using the run's short-lived `GITHUB_TOKEN`, and comments the PR URL on the issue.

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

Delete the `contosopay-sre-remediation-api` Entra app registration and uninstall
the repository-scoped GitHub App when you no longer need Scenario B. Deleting
the ContosoPay resource group removes the broker identity, Container App, and
Key Vault copy of the private key.

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
- [MCP connectors](https://learn.microsoft.com/en-us/azure/sre-agent/mcp-connectors)
- [GitHub App installation authentication](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation)
- [The committable agent configuration](../agent/README.md)
