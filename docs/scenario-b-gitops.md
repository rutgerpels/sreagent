# Scenario B — GitOps fix

This guide takes you from an empty subscription to a working demo where the
**Azure SRE Agent fixes an incident the GitOps way** — by opening a Pull Request
that a person reviews and merges, never by touching the live Azure resources
directly. Follow it from top to bottom; everything you need is here. For deeper
background on any agent step, see the
[Azure SRE Agent reference](sre-agent-setup.md).

**The story this scenario tells:** a change ships through a Pull Request and CI/CD
pipeline — exactly like a real regression. Memory starts leaking, an alert fires,
and the SRE Agent — which is **read-only** on Azure — investigates, finds the
Pull Request that caused it, and remediates by **opening its own Pull Request**.
A human reviews and merges that PR, and the pipeline deploys the fix. Every change
to the system, including the fix, is reviewed code.

You will work through seven parts:

1. [Deploy the ContosoPay application](#part-1--deploy-the-application)
2. [Configure the CI/CD pipeline](#part-2--configure-the-cicd-pipeline)
3. [Create the SRE Agent](#part-3--create-the-sre-agent)
4. [Connect the agent to your code and resources](#part-4--connect-the-agent)
5. [Apply the GitOps guardrails and behaviour](#part-5--apply-the-gitops-guardrails)
6. [Run the incident and watch the fix](#part-6--run-the-incident)
7. [Reset and clean up](#part-7--reset-and-clean-up)

---

## Before you begin

You will need:

- An Azure subscription where you have **Contributor** plus **Owner** or
  **User Access Administrator**.
- The [Azure CLI](https://learn.microsoft.com/cli/azure/),
  [Terraform](https://developer.hashicorp.com/terraform) 1.9 or later, and
  [Docker](https://www.docker.com/) (with the daemon running).
- A Bash shell or PowerShell 7+.
- A clone of this repository, and permission to configure **GitHub Actions** and
  to open and merge Pull Requests on it.

---

## Part 1 — Deploy the application

**What you will do:** deploy ContosoPay and all its supporting Azure services with
a single command.

1. Sign in to Azure and select your subscription:

   ```bash
   az login
   az account set --subscription "<your-subscription>"
   ```

2. Create your variables file from the example (no secrets — placeholders only):

   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

3. Run the deployment:

   ```bash
   ./scripts/deploy.sh                 # Bash
   # or
   pwsh ./scripts/deploy.ps1           # PowerShell
   ```

**What is happening:** Terraform creates the resource group, container registry,
Key Vault, Application Insights, Log Analytics, the Container Apps environment,
the Azure Monitor memory alert, and Grafana, and the three services are built and
deployed. The Terraform state is stored in an Azure storage account so that the
CI/CD pipeline can apply changes later.

**Expected outcome:** the script prints a summary. **Make a note of these values —
you need them in Part 2:**

```
ContosoPay demo deployed
  Frontend URL : https://frontend.<region>.azurecontainerapps.io
  Resource grp : rg-contosopay-demo-<suffix>

Remote Terraform state (set these as GitHub Actions variables for apply-infra.yml):
  TFSTATE_RG        : rg-contosopay-tfstate
  TFSTATE_SA        : sttf<hash>
  TFSTATE_CONTAINER : tfstate
  TFSTATE_KEY       : contosopay-demo.tfstate
```

4. Open the **Frontend URL**, place a test order, and tick **"Generate steady
   traffic"** so Application Insights has a healthy baseline.

---

## Part 2 — Configure the CI/CD pipeline

In this scenario the fault is switched on by merging a Pull Request, and the fix
ships the same way. For that to work, the `apply-infra` GitHub Actions workflow
must be able to sign in to Azure and run Terraform. You configure this once.

**What you will do:** give GitHub Actions passwordless (OIDC) access to Azure and
tell it where the Terraform state lives.

1. Create or reuse an Entra application (or user-assigned managed identity) that
   GitHub Actions will sign in as, and add a **federated credential** that trusts
   `repo:<your-org>/<your-repo>:ref:refs/heads/main`. This lets the workflow
   authenticate without any stored secret.

2. Grant that identity:
   - **Contributor** on `rg-contosopay-demo-<suffix>` (so it can apply changes).
   - **Storage Blob Data Contributor** on the Terraform state storage account
     (the `TFSTATE_SA` value from Part 1).

3. In the GitHub repository, open **Settings → Secrets and variables → Actions →
   Variables** and add:

   | Variable | Value |
   | --- | --- |
   | `AZURE_CLIENT_ID` | The federated identity's client ID. |
   | `AZURE_TENANT_ID` | Your tenant ID. |
   | `AZURE_SUBSCRIPTION_ID` | Your subscription ID. |
   | `TFSTATE_RG` | `rg-contosopay-tfstate` |
   | `TFSTATE_SA` | The `sttf…` value from Part 1. |
   | `TFSTATE_CONTAINER` | `tfstate` |
   | `TFSTATE_KEY` | `contosopay-demo.tfstate` |

**What is happening:** the `apply-infra` workflow runs `terraform apply` whenever
a relevant change is merged to `main`, using these values to find the state and to
sign in to Azure securely.

**Expected outcome:** the configuration is in place. You will confirm it works in
Part 6 when merging a Pull Request triggers a deployment.

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
   **Issues: Read/Write** on this demo's repository.

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

**Remove the ContosoPay environment** when finished:

```bash
./scripts/teardown.sh -s "<your-subscription>"
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
