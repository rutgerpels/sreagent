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
4. [Connect the agent to your code and resources](#part-4--connect-the-agent)
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
| **One-time bootstrap seed (cannot be GitOps)** | The identity that CI signs in as, the federated credentials that trust this repository, and the GitHub Actions variables that point at them. | Created once by hand (Part 1). This is the classic chicken-and-egg: something has to exist before any pipeline can run. The remote Terraform state storage is *not* in this list — the first pipeline run creates it automatically. |
| **SRE Agent portal-only (no IaC equivalent today)** | The GitHub sign-in for Code Access and the Connector, the tool access policy, the custom agent and its knowledge, and the incident response plan. | Interactive steps in the agent portal (Parts 4 and 5). |

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
- A Bash shell or PowerShell 7+.
- A clone of this repository, and permission to run GitHub Actions and to open and
  merge Pull Requests on it.

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

> **Why two versions?** Bash and PowerShell assign variables differently —
> `SUB=$(az ...)` is Bash syntax and will fail in PowerShell with
> *"is not recognized as a name of a cmdlet"*. In PowerShell you write
> `$SUB = az ...` instead.

> **Git Bash on Windows:** `az ... -o tsv` returns values with a trailing
> carriage return (`\r`). If you do not strip it, scopes such as
> `/subscriptions/$SUB` become invalid and Azure replies *"MissingSubscription"*.
> The Bash block below appends `| tr -d '\r'` to every capture to prevent this; it
> is harmless on macOS/Linux, so you can use the block as-is everywhere.

### Bash / macOS / Linux / WSL / Git Bash

```bash
az login
az account set --subscription "<your-subscription>"

REPO="<your-org>/<your-repo>"
SUB=$(az account show --query id -o tsv | tr -d '\r')
TENANT=$(az account show --query tenantId -o tsv | tr -d '\r')

# App registration + service principal
APP_ID=$(az ad app create --display-name "contosopay-gha-deployer" --query appId -o tsv | tr -d '\r')
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

# GitHub Actions variables the workflows read
gh variable set AZURE_CLIENT_ID       --repo $REPO --body $APP_ID
gh variable set AZURE_TENANT_ID       --repo $REPO --body $TENANT
gh variable set AZURE_SUBSCRIPTION_ID --repo $REPO --body $SUB
```

In both versions, **Contributor** lets the pipeline create and manage the demo
resources, and **Storage Blob Data Contributor** lets it read and write the
Terraform state that the first pipeline run creates.

**Expected outcome:** the repository's **Settings → Secrets and variables →
Actions → Variables** lists `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and
`AZURE_SUBSCRIPTION_ID`. The pipeline can now authenticate to Azure with no stored
credentials.

---

## Part 2 — Deploy the environment with CI/CD

**What you will do:** stand up the entire ContosoPay environment by running a
GitHub Actions workflow — no local Terraform or Docker.

1. In GitHub, open the **Actions** tab, select the **deploy** workflow, and choose
   **Run workflow** (you can keep the default prefix, environment, and region, or
   override them).

**What is happening:** the `deploy` workflow signs in with the identity from
Part 1 and performs the same steps a DevOps team would automate — it creates the
remote Terraform state storage, applies the platform, builds and pushes the three
application images, then deploys the application. No one runs anything against the
live environment by hand.

**Expected outcome:** the workflow finishes green. Open its run summary to find
the deployed environment's details:

| Output | Example |
| --- | --- |
| Frontend URL | `https://frontend.<region>.azurecontainerapps.io` |
| Resource group | `rg-contosopay-demo-<suffix>` |

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
2. Sign in with an identity that has **Pull requests: Read/Write** and
   **Issues: Read/Write** on your repository.

**Expected outcome:** the agent can now create branches, issues, and Pull
Requests.

### 4c. Grant read-only access to the demo resources

**What you will do:** let the agent investigate the demo resource group without
the ability to change it — that is the point of this scenario.

1. On the setup page, find the **Azure Resources** card and select **+**.
2. Choose **Resource groups** and select **`rg-contosopay-demo-<suffix>`**.
3. Grant it **Reader** access **and** **Monitoring Contributor** (so the alert
   scanner can read fired alerts). Do **not** grant write access.

**Expected outcome:** the **Azure Resources** card lists the demo resource group
with read-only access.

### 4d. Connect Azure Monitor

1. Open **Builder → Incident platform**, choose **Azure Monitor**, and save.

**Expected outcome:** Azure Monitor shows as **Connected**, and the agent begins
polling for fired alerts.

---

## Part 5 — Apply the GitOps guardrails

These steps make the agent behave the GitOps way: physically unable to change
Azure, and steered toward fixing incidents through Pull Requests. The supporting
files live in the [`agent/`](../agent/) folder of this repository.

### 5a. Block direct Azure changes (tool access policy)

**What you will do:** apply a global policy that denies Azure write commands, so
the agent cannot change live resources even if asked.

1. Open **Builder → Settings → Tool access policies** (global scope).
2. Apply the policy in
   [`agent/tool-access-policy.json`](../agent/tool-access-policy.json). It allows
   read commands and denies Azure CLI writes, Kubernetes writes, and shell
   commands.

**What is happening:** combined with the Reader access from Part 4c, the agent now
has neither the permission nor the tooling to write to Azure — two independent
guardrails.

### 5b. Add the GitOps behaviour (custom agent)

1. Open **Builder → Custom agents → New**.
2. Name it `gitops-remediation` and paste the instructions from
   [`agent/gitops-remediation-agent.md`](../agent/gitops-remediation-agent.md).
3. Give it the **GitHub Connector** and **Code Access** tools, and save.

**What is happening:** this tells the agent that its remediation is to open a Pull
Request, not to run commands against Azure.

### 5c. Add the runbook (knowledge)

Add [`agent/knowledge/gitops-runbook.md`](../agent/knowledge/gitops-runbook.md)
under **Builder → Knowledge → Add**. This tells the agent that the memory leak is
controlled by the `enable_slow_leak` setting in `infra/leak.auto.tfvars`, so its
Pull Request edits the right file.

### 5d. Create the response plan

1. From the incident platform page, select **Create a response plan**.
2. Configure it:

   | Setting | Value |
   | --- | --- |
   | **Severity filter** | Include **Sev2 / Warning**. |
   | **Response agent** | The **`gitops-remediation`** custom agent from 5b. |
   | **Autonomy level** | **Review**. |

**Expected outcome:** the response plan routes incidents to the GitOps agent. As a
quick check, ask the agent in a chat to "restart the payment-service container" —
it should decline and offer to open a Pull Request instead.

---

## Part 6 — Run the incident

**What you will do:** ship the fault through a Pull Request and watch the agent
remediate it through another Pull Request.

### 6a. Open the Pull Request that switches the fault on

```bash
./scripts/trigger-incident-gitops.sh           # Bash
# or
pwsh ./scripts/trigger-incident-gitops.ps1     # PowerShell
```

**What is happening:** the script opens a Pull Request that sets
`enable_slow_leak = true` in `infra/leak.auto.tfvars`.

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
