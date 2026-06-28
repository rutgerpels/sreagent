# Azure SRE Agent — Configuration Manual

Step-by-step guide to provision the **Azure SRE Agent** and connect it to the
ContosoPay demo environment created by `scripts/deploy.ps1` / `scripts/deploy.sh`.

The SRE Agent is a managed service provisioned **separately** from this repo's
Terraform (it is the consumer of the environment, not part of it). This manual
covers everything needed to wire it to the demo so the
[run of show](run-of-show.md) works end to end.

> Sources: [Create and set up Azure SRE Agent][create] and
> [Complete setup][complete] (Microsoft Learn).

---

## 1. Prerequisites

| Requirement | Why |
| --- | --- |
| The demo is already deployed (`scripts/deploy.ps1`) | The agent needs live resources, alerts, and telemetry to investigate. |
| **Contributor** on the target subscription | Required to register resource providers and create the agent's resources. |
| **Owner** or **User Access Administrator** on the subscription/RG | Required so the agent's managed identity can be granted role assignments. |
| Browser network access to `*.azuresre.ai` and `sre.azure.com` | The onboarding wizard and agent UI are hosted there. |
| A supported region | e.g. **East US 2**. Use **Sweden Central** if you need EU Data Boundary (matches this demo's region). |

Collect these values from the deployed environment before you start. They are
**not** committed to the repo (public-repo policy), so read them live:

```bash
# From the repo root, after a successful deploy:
terraform -chdir=infra output -raw resource_group_name     # e.g. rg-contosopay-demo-<suffix>
terraform -chdir=infra output -raw location                # e.g. swedencentral
terraform -chdir=infra output -raw app_insights_name       # e.g. appi-<suffix>

az account show --query "{subscriptionId:id, tenantId:tenantId, name:name}" -o json
az monitor action-group list -g "$(terraform -chdir=infra output -raw resource_group_name)" \
  --query "[].name" -o tsv                                  # e.g. ag-sre-<suffix>
```

| Environment value | Where it comes from |
| --- | --- |
| Resource group | `terraform output resource_group_name` (e.g. `rg-contosopay-demo-<suffix>`) |
| Region | `terraform output location` (this demo: `swedencentral`) |
| Action group | `ag-sre-<suffix>` (created by `infra/alerts.tf`) |
| Memory alert | `alert-payment-memory-<suffix>` (created once apps are deployed) |
| GitHub repo | `rutgerpels/sreagent` |

---

## 2. Create the agent

1. Go to <https://sre.azure.com> and sign in with your Azure credentials.
2. Open the onboarding wizard: **Basics** → **Review** → **Deploy**.
3. Fill in the **Basics** tab:

   | Field | Value for this demo |
   | --- | --- |
   | **Subscription** | The subscription that owns the demo resource group. |
   | **Resource group** | Create a **dedicated** group for the agent, e.g. `rg-sre-agent`. Keep it separate from `rg-contosopay-demo-<suffix>`. |
   | **Agent name** | A unique name, e.g. `contosopay-sre-agent`. |
   | **Region** | `Sweden Central` (matches the demo and gives EU Data Boundary). |
   | **Model provider** | Auto-selected per region. **Sweden Central → Azure OpenAI** (EU Data Boundary). Other regions default to **Anthropic**. |
   | **Application Insights** | **Create new** (default). This is the agent's *own* telemetry, separate from the app's `appi-<suffix>`. |

4. Select **Next** → **Review** → **Create**.

Provisioning takes ~2–5 minutes and creates: a **managed identity**, a **Log
Analytics workspace**, an **Application Insights** instance, **role
assignments**, and the **SRE Agent** resource itself. Wait for status
**Succeeded**.

> **EU note:** Anthropic (Claude) is excluded from EU Data Boundary commitments
> and requires a direct Anthropic agreement. For this demo in Sweden Central,
> leave the provider on **Azure OpenAI**.

---

## 3. Connect the GitHub repository

This is what lets the agent correlate the memory-leak incident back to the
triggering change — the Pull Request (and its merge commit on `main`) produced
by `scripts/trigger-incident.*`.

1. After deployment, select **Set up your agent**.
2. On the **Quickstart** tab, find the **Code** card and select **+**.
3. Choose **GitHub** as the platform.
4. Choose a sign-in method:
   - **Auth** (recommended): select **Sign in**, authenticate in the browser,
     and approve access.
   - **PAT**: paste a personal access token and select **Connect**.
5. Select **Next**, then pick the **`rutgerpels/sreagent`** repository.
6. Select **Add repository**.

**Checkpoint:** the **Code** card shows a green checkmark listing
`rutgerpels/sreagent`. The agent immediately begins indexing the codebase.

### 3a. Add the GitHub Connector (required for PR remediation)

**Code Access** (above) is read-only — it lets the agent *read* source/IaC. To
let the agent **open Pull Requests** as its remediation (the GitOps flow in §6),
also add the **GitHub Connector**:

1. Go to **Builder → Connectors → Add connector → GitHub**.
2. Authenticate with an identity (OAuth/PAT/GitHub App) that has **Pull
   requests: Read/Write** and **Issues: Read/Write** on `rutgerpels/sreagent`.
3. Select **Add**.

**Checkpoint:** the agent can now create branches, issues, and PRs. (Code Access
and the GitHub Connector are different connections — you want both.)

---

## 4. Grant access to the demo Azure resources

The agent needs at least **Reader** on the demo resource group to query metrics,
logs, and resource configuration during investigations.

1. On the setup page, switch to the **Full setup** tab and find the
   **Azure Resources** card; select **+**.
2. Choose **Resource groups**, then **Next**.
3. Filter by the demo subscription, search for
   **`rg-contosopay-demo-<suffix>`**, and select it.
4. Select **Next** to review permissions.
5. Choose the permission level:
   - **Reader** (`accessLevel: "Low"`) — **recommended for this demo.** Read-only
     access to query metrics, logs, and resource configuration. The agent
     **cannot** modify Azure resources; it remediates via a Pull Request (§6).
   - **Monitoring Contributor** — also grant this (on the demo RG) so the Azure
     Monitor incident scanner can read fired alerts automatically (see §5).
   - **Privileged** (`accessLevel: "High"`) — grants *contributor* roles so the
     agent can execute Azure mitigations (restart/scale) directly. **Not used in
     this demo** — we deliberately keep the agent read-only on Azure and force
     GitOps remediation (§6). Only choose this if you specifically want to demo
     direct Azure mitigation instead.
6. Select **Add resource group**.

**Checkpoint:** the **Azure Resources** card lists
`rg-contosopay-demo-<suffix>`. The managed identity's role assignment is created
automatically (takes a few seconds).

> **Least privilege:** for the GitOps demo, grant **Reader** + **Monitoring
> Contributor** on the single demo resource group — enough to investigate and to
> run the alert scanner, but not to change anything. The agent's *only* way to
> remediate is to open a PR. See §6 for the hard enforcement.

---

## 5. Connect Azure Monitor as the incident platform

This is what makes the agent **proactive** — it picks up the demo's memory alert
automatically. Critically, the agent does **not** subscribe to the action group.
It runs a **scanner that polls the Azure Monitor Alerts API every ~1 minute** for
fired alerts in the resource groups/subscriptions its managed identity can read.

1. Make sure the agent's managed identity has **Monitoring Contributor** on the
   demo subscription (or at least on `rg-contosopay-demo-<suffix>`). Plain
   **Reader** is enough for ad-hoc investigations but **not** for the alert
   scanner. If needed:

   ```bash
   # principalId = the agent's user-assigned identity object id (Portal → agent → Identity)
   az role assignment create \
     --assignee-object-id <agent-uami-principal-id> \
     --assignee-principal-type ServicePrincipal \
     --role "Monitoring Contributor" \
     --scope "/subscriptions/<your-sub-id>/resourceGroups/rg-contosopay-demo-<suffix>"
   ```

2. In the agent UI (<https://sre.azure.com> → your agent), go to
   **Builder → Incident platform**.
3. Select **Azure Monitor** and **Save**. No credentials are required — it uses
   the agent's managed identity.
4. **Set up an incident response plan** (required final step — connecting the
   platform alone does not act on incidents). After Azure Monitor shows
   **Connected**, select **Create a response plan**, then:
   - **Severity filter:** include **Sev2 / Warning** — the demo alert
     `alert-payment-memory-<suffix>` is severity 2, so it must match. (Optionally
     add **Title contains** `memory`.)
   - **Response custom agent:** the default agent is fine.
   - **Agent autonomy level:** choose **Review** — the agent diagnoses and
     **proposes** mitigations (restart revision / raise scale rule) but only acts
     **after you approve**. This matches the demo's human-in-the-loop narrative.
     Do **not** select **Autonomous** (it self-mitigates without prompting).

   > ⚠️ **Quickstart-plan conflict:** connecting an incident platform
   > auto-creates a default **quickstart** response plan. If you also create your
   > own plan, both run and may double-process or misroute the incident. Either
   > keep only the quickstart plan (confirm it's **Review** mode), or create your
   > own and delete the quickstart plan via
   > **Builder → Incident response plans → Table view**.

Only **one** incident platform can be active at a time. The scanner's initial
lookback is **1 day**, so it picks up alerts that *already* fired, and merges
repeated firings of the same rule into a single investigation thread.

**Checkpoint:** within ~1 minute of saving, a fired
`alert-payment-memory-<suffix>` appears as a rich incident card in the agent and
an investigation thread opens automatically.

> **The action group `ag-sre-<suffix>` needs no receiver for the agent.** Add an
> `email_receiver`/webhook to `azurerm_monitor_action_group.this` in
> `infra/alerts.tf` only if you *also* want a human notified, then re-run
> `scripts/deploy.ps1`:
>
> ```hcl
> email_receiver {
>   name          = "oncall"
>   email_address = "oncall@example.com"
> }
> ```

**Troubleshooting — alert not picked up:** verify (a) Azure Monitor is the active
incident platform, (b) the agent identity has **Monitoring Contributor** on the
scope, and (c) the alert actually fired
(`az monitor metrics alert list -g rg-contosopay-demo-<suffix>` and the
Alerts blade show `Fired`).

---

## 6. Enforce GitOps remediation (no direct Azure writes)

This is what makes the agent behave like a disciplined DevOps engineer: when it
fixes the incident, it **opens a Pull Request** that changes the IaC, rather than
mutating the live Azure resources. A human reviews and merges; the
`apply-infra` workflow then `terraform apply`s the fix.

The committable artifacts live in [`../agent/`](../agent/). Apply all three:

### 6a. Hard guardrail — global Tool Access Policy (deny Azure writes)

Only the **global** scope can *deny* a tool, so this can't be overridden by a
custom agent, a response plan, or a chat prompt. It physically blocks
`az containerapp update` and any other Azure CLI write.

1. Open **Builder → Settings → Tool access policies** (global scope).
2. Apply the policy in [`../agent/tool-access-policy.json`](../agent/tool-access-policy.json)
   — it `allow`s read commands and `deny`s `RunAzCliWriteCommands`,
   `RunKubectlWriteCommand`, `RunInTerminal`, and `RunShellCommand`.

   Or via the settings API (replace `<agent-endpoint>` with your agent's data-plane URL):

   ```bash
   curl -X PUT "https://<agent-endpoint>/api/v2/agent/settings/global" \
     -H "Authorization: Bearer $(az account get-access-token --query accessToken -o tsv)" \
     -H "Content-Type: application/json" \
     -d @agent/tool-access-policy.json
   ```

> Combined with the **Reader** (`accessLevel: "Low"`) permission from §4, the
> agent has *neither the RBAC nor the tool permission* to write to Azure — two
> independent guardrails.

### 6b. GitOps custom agent (behavioural steering)

1. Go to **Builder → Custom agents → New**.
2. Name it e.g. `gitops-remediation`, and paste the **Instructions** from
   [`../agent/gitops-remediation-agent.md`](../agent/gitops-remediation-agent.md).
3. Give it the **GitHub Connector** and **Code Access** tools. Save.

### 6c. Knowledge file (the exact fix)

Add [`../agent/knowledge/gitops-runbook.md`](../agent/knowledge/gitops-runbook.md)
under **Builder → Knowledge → Add** so the agent knows the leak maps to
`infra/leak.auto.tfvars`.

### 6d. Route the response plan to the GitOps agent (Review mode)

Edit the response plan from §5: set **Response custom agent** to
`gitops-remediation` and **Agent autonomy level** to **Review**.

> **Run-mode nuance:** Review mode only gates *Azure infrastructure* writes —
> which the agent no longer performs. GitHub PR creation proceeds based on the
> custom-agent instructions and the connector's permissions. That's exactly what
> we want: propose a PR, let a human merge it.

### 6e. Configure the `apply-infra` deploy workflow

So merged PRs actually deploy, set these **GitHub Actions variables**
(Settings → Secrets and variables → Actions → Variables). `scripts/deploy.*`
prints the `TFSTATE_*` values at the end of a deploy:

| Variable | Value |
| --- | --- |
| `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` | The OIDC federated identity (same as `deploy-apps.yml`). |
| `TFSTATE_RG` | `rg-contosopay-tfstate` |
| `TFSTATE_SA` | `sttf<hash>` (printed by the deploy script) |
| `TFSTATE_CONTAINER` | `tfstate` |
| `TFSTATE_KEY` | `contosopay-demo.tfstate` |

The federated identity needs **Contributor** on `rg-contosopay-demo-<suffix>`
and **Storage Blob Data Contributor** on the `TFSTATE_SA` state account, and a
federated credential trusting `repo:rutgerpels/sreagent:ref:refs/heads/main`.

**Checkpoint:** in a chat thread, ask the agent to "restart the payment-service
container" — it should **refuse** (policy/permission) and offer to open a PR
instead.

---

## 7. Verify the wiring

Run a dry-run before the live demo:

1. Open the **frontend URL** (`terraform output frontend_url`) and place an
   order so baseline telemetry flows into `appi-<suffix>`.
2. In the agent, ask a grounding question, e.g.
   *"Which resources are you monitoring in `rg-contosopay-demo-<suffix>`?"* —
   confirm it lists the three Container Apps.
3. Trigger the incident **via a PR** (GitOps):

   ```bash
   ./scripts/trigger-incident.sh            # bash / Git Bash / WSL
   # or, on Windows PowerShell:
   pwsh ./scripts/trigger-incident.ps1
   ```

   This opens a Pull Request setting `enable_slow_leak = true` in
   `infra/leak.auto.tfvars`. **Review and merge it.** Merging runs the
   `apply-infra` workflow, which `terraform apply`s the change and deploys the
   leak (no one touches the live app by hand).

4. After memory climbs (~30–40 min), confirm:
   - `alert-payment-memory-<suffix>` fires.
   - The agent picks it up, **correlates** the trend with the triggering PR, and
     **opens a remediation Pull Request** setting `enable_slow_leak = false`
     (it is denied direct Azure writes — §6).
   - Review and **merge the agent's PR**; the `apply-infra` workflow redeploys
     and `payment-service` memory recovers on the new revision.

Reset manually (if you didn't merge the agent's fix) by opening a reset PR:

```bash
./scripts/trigger-incident.sh --reset       # or: pwsh ./scripts/trigger-incident.ps1 -Reset
```

---

## 8. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Wizard won't load or sign-in loops | Enterprise firewall is blocking `*.azuresre.ai` / `sre.azure.com`. Allowlist both. |
| "Insufficient privileges" granting resource access | You lack **Owner**/**User Access Administrator** on the subscription or RG. Ask an admin to add the role assignment, or use a PIM just-in-time activation. |
| Agent sees the RG but can't run mitigations | It only has Reader/Monitoring Contributor. Re-run step 4 and grant **Contributor** on `rg-contosopay-demo-<suffix>`. |
| Alert fired but the agent never opens an investigation | **Most common.** (a) Azure Monitor isn't the active **incident platform** — connect it under **Builder → Incident platform** (step 5). (b) The agent identity lacks **Monitoring Contributor** on the scope — the scanner can't read alerts with Reader only. The action group is irrelevant; the agent does not subscribe to it. |
| No alert exists at all | The memory alert only exists after a **phase-2** deploy (`deploy_apps=true`). Confirm `az monitor metrics alert list -g <rg>` returns `alert-payment-memory-<suffix>`. |
| GitHub repo not listed | The signed-in GitHub identity lacks access to `rutgerpels/sreagent`, or the GitHub App wasn't approved. Re-authenticate (step 3). |
| Agent tries to run `az containerapp update` instead of opening a PR | The global **Tool Access Policy** (§6a) isn't applied, or it was set at a non-global scope (only *global* can deny). Re-apply `agent/tool-access-policy.json` at global scope, and confirm the response plan routes to the `gitops-remediation` custom agent (§6d). |
| Agent can't open a PR | The **GitHub Connector** (§3a) is missing or lacks **Pull requests: Read/Write**. Add/repair it. |
| Merging a PR doesn't deploy | The `apply-infra` workflow isn't configured. Set the `TFSTATE_*` and `AZURE_*` Actions variables (§6e) and ensure the OIDC identity has Contributor on the demo RG + Storage Blob Data Contributor on the state account. |
| Anthropic unavailable in EU | Expected — Anthropic is outside the EU Data Boundary. Use **Azure OpenAI** in Sweden Central. |

---

## 9. Teardown

The agent and its resource group are **not** managed by this repo's Terraform.
Remove them separately:

1. Delete the SRE Agent resource group (e.g. `rg-sre-agent`) from the portal or:

   ```bash
   az group delete --name rg-sre-agent --yes
   ```

2. Tear down the demo environment:

   ```bash
   ./scripts/teardown.sh -s "<your-subscription>"
   ```

---

## References

- [Create and set up Azure SRE Agent][create]
- [Complete setup for Azure SRE Agent][complete]
- [Agent permissions][perms] and [run modes][modes] — access levels & autonomy
- [Tool access policies][tap] — the hard GitOps guardrail
- [GitHub connector][ghc] and [connect source code][csc] — PR remediation
- [GitOps remediation config](../agent/README.md) — the committable agent artifacts
- [Run of show](run-of-show.md) — the live demo talk track
- [AKS variant](aks-variant.md) — Kubernetes-native deployment notes

[create]: https://learn.microsoft.com/en-us/azure/sre-agent/create-and-set-up
[complete]: https://learn.microsoft.com/en-us/azure/sre-agent/complete-setup
[perms]: https://learn.microsoft.com/en-us/azure/sre-agent/permissions
[modes]: https://learn.microsoft.com/en-us/azure/sre-agent/run-modes
[tap]: https://learn.microsoft.com/en-us/azure/sre-agent/tool-access-policies
[ghc]: https://learn.microsoft.com/en-us/azure/sre-agent/github-connector
[csc]: https://learn.microsoft.com/en-us/azure/sre-agent/connect-source-code
