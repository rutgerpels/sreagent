# Scenario A — On-the-spot fix

This guide takes you from an empty subscription to a working demo where the
**Azure SRE Agent detects an incident and fixes it directly** after you approve.
Follow it from top to bottom; everything you need is here. For deeper background
on any agent step, see the [Azure SRE Agent reference](sre-agent-setup.md).

**The story this scenario tells:** a risky change is made directly to a running
service, memory starts leaking, an alert fires, and the SRE Agent — which has
permission to act on your Azure resources — investigates, proposes a fix, and
applies it the moment a human approves.

You will work through six parts:

1. [Deploy the ContosoPay application](#part-1--deploy-the-application)
2. [Create the SRE Agent](#part-2--create-the-sre-agent)
3. [Connect the agent to your code and resources](#part-3--connect-the-agent)
4. [Set up the response plan](#part-4--set-up-the-response-plan)
5. [Run the incident and watch the fix](#part-5--run-the-incident)
6. [Reset and clean up](#part-6--reset-and-clean-up)

---

## Before you begin

You will need:

- An Azure subscription where you have **Contributor** plus **Owner** or
  **User Access Administrator** (so the agent can be granted access later).
- The [Azure CLI](https://learn.microsoft.com/cli/azure/),
  [Terraform](https://developer.hashicorp.com/terraform) 1.9 or later, and
  [Docker](https://www.docker.com/) (with the daemon running).
- A Bash shell or PowerShell 7+.
- A clone of this repository.

---

## Part 1 — Deploy the application

**What you will do:** deploy ContosoPay and all its supporting Azure services
with a single command.

1. Sign in to Azure and select your subscription:

   ```bash
   az login
   az account set --subscription "<your-subscription>"
   ```

2. Create your variables file from the example (no secrets — placeholders only):

   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

   The defaults deploy to **Sweden Central** and enable Grafana. You can edit the
   region or prefix if you like.

3. Run the deployment:

   ```bash
   ./scripts/deploy.sh                 # Bash
   # or
   pwsh ./scripts/deploy.ps1           # PowerShell
   ```

   The script provisions the platform, builds and pushes the three container
   images, and then deploys the application.

**What is happening:** Terraform creates the resource group, container registry,
Key Vault, Application Insights, Log Analytics, the Container Apps environment,
the Azure Monitor memory alert, and Grafana. The three services are then built
and deployed. Secrets stay in Key Vault and are read by the apps through a
managed identity.

**Expected outcome:** when the script finishes it prints a summary similar to:

```
ContosoPay demo deployed
  Frontend URL : https://frontend.<region>.azurecontainerapps.io
  Resource grp : rg-contosopay-demo-<suffix>
  Grafana      : https://graf-<suffix>.<region>.grafana.azure.com
```

Note the **Frontend URL** and **Resource group** — you will use them throughout.

4. Open the **Frontend URL** in a browser, place a test order, and tick
   **"Generate steady traffic"**. This produces a steady stream of telemetry into
   Application Insights so the agent has a healthy baseline to compare against.

---

## Part 2 — Create the SRE Agent

**What you will do:** create the managed SRE Agent that will watch this
environment.

1. Go to <https://sre.azure.com> and sign in with your Azure account.
2. Start the create-agent wizard and fill in the **Basics**:

   | Field | Value |
   | --- | --- |
   | **Subscription** | The subscription that owns `rg-contosopay-demo-<suffix>`. |
   | **Resource group** | Create a new, dedicated group such as `rg-sre-agent` (keep it separate from the demo resources). |
   | **Agent name** | A name of your choice, for example `contosopay-sre-agent`. |
   | **Region** | **Sweden Central**, to match the demo and stay inside the EU Data Boundary. |
   | **Application Insights** | Create new (this is the agent's own telemetry). |

3. Review and create. Provisioning takes a few minutes.

**Expected outcome:** the agent's status becomes **Succeeded**. The wizard
creates the agent, a managed identity, and a Log Analytics workspace and
Application Insights instance for the agent itself.

---

## Part 3 — Connect the agent

The agent now exists but cannot yet see your code, your resources, or your
alerts. You will connect all three.

### 3a. Connect your source code

**What you will do:** let the agent read this repository so it can link the
incident to the change that caused it.

1. On the agent setup page, find the **Code** card and select **+**.
2. Choose **GitHub**, sign in, and approve access.
3. Select the **`rutgerpels/sreagent`** repository and add it.

**Expected outcome:** the **Code** card shows the repository with a green check
and begins indexing.

### 3b. Grant access to the demo resources

**What you will do:** give the agent permission to investigate **and act on** the
demo resource group. In this scenario the agent is allowed to make changes, so it
needs write-level access.

1. On the setup page, find the **Azure Resources** card and select **+**.
2. Choose **Resource groups** and select **`rg-contosopay-demo-<suffix>`**.
3. Grant it **Privileged** access (this allows the agent to apply fixes) **and**
   **Monitoring Contributor** (this allows the alert scanner to read fired
   alerts).

**Expected outcome:** the **Azure Resources** card lists the demo resource group.
The matching role assignments are created automatically within a few seconds.

### 3c. Connect Azure Monitor

**What you will do:** tell the agent to watch Azure Monitor for incidents.

1. In the agent, open **Builder → Incident platform**.
2. Choose **Azure Monitor** and save.

**What is happening:** the agent begins polling the Azure Monitor Alerts API
about once a minute for fired alerts in the resource group it can read.

**Expected outcome:** Azure Monitor shows as **Connected**.

---

## Part 4 — Set up the response plan

**What you will do:** create the rule that tells the agent how to respond when
the memory alert fires.

1. From the incident platform page, select **Create a response plan**.
2. Configure it:

   | Setting | Value |
   | --- | --- |
   | **Severity filter** | Include **Sev2 / Warning** (the demo's memory alert is severity 2). |
   | **Response agent** | **Default agent**. |
   | **Autonomy level** | **Review** — the agent diagnoses the problem and **proposes** a fix, then waits for your approval before acting. |

**What is happening:** because the agent has Privileged access and Review
autonomy, when the incident fires it will propose a concrete Azure action (such
as switching the fault off or restarting the affected revision) and pause for a
human decision.

**Expected outcome:** the response plan is saved and active. Your environment is
now fully wired.

---

## Part 5 — Run the incident

**What you will do:** switch the planted fault on and watch the agent handle the
incident end to end.

### 5a. Switch the fault on

Run the trigger script from the repository root:

```bash
./scripts/trigger-incident-direct.sh           # Bash
# or
pwsh ./scripts/trigger-incident-direct.ps1     # PowerShell
```

**What is happening:** the script makes a single change to the running
payment-service, turning the memory-leak feature flag on. The change takes effect
immediately on the live service.

**Expected outcome:** the script confirms the flag is set. From this point the
payment-service's memory begins to climb.

### 5b. Watch the memory climb and the alert fire

Open **Application Insights** (or the **Grafana** dashboard) for the demo and look
at the payment-service's memory. Over roughly 30–40 minutes it trends steadily
upward. When it crosses the threshold, the **Azure Monitor alert**
(`alert-payment-memory-<suffix>`) fires.

This is a good moment to take a short break or walk through the architecture.

**Expected outcome:** the alert moves to a fired state, and within about a minute
the agent opens an investigation for it.

### 5c. Watch the investigation and root cause

Open the investigation in the agent. The agent correlates the rising memory with
the recent change and produces a clear root-cause explanation: memory began
growing right after the leak feature flag was switched on for the payment
service.

**Expected outcome:** the agent presents an explainable hypothesis rather than a
generic alert.

### 5d. Approve the fix

The agent proposes a remediation — switching the fault off and/or restarting the
affected revision — and waits.

**Approve it** in the agent. The agent applies the change directly (it has
Privileged access), a fresh revision rolls out, and memory returns to normal.

**Expected outcome:** the agent reports the action it took, the alert resolves,
and payment-service memory flattens back to the baseline.

### 5e. (Optional) Show it again

Run the trigger script a second time to show the agent recognising the now
familiar pattern and resolving it faster.

---

## Part 6 — Reset and clean up

**Reset the fault** (return the service to a healthy state without removing the
environment):

```bash
./scripts/trigger-incident-direct.sh --reset
# or
pwsh ./scripts/trigger-incident-direct.ps1 -Reset
```

**Remove the ContosoPay environment** when you are finished:

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
| 5b | Detects an incident from an Azure Monitor alert. |
| 5c | Correlates telemetry with the change that caused it and explains the root cause. |
| 5d | Applies a fix to the Azure resource directly, after human approval. |
| 5e | Recognises a repeated pattern and resolves it faster. |
