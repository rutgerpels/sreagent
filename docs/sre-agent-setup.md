# Azure SRE Agent — Configuration Manual (common setup)

Step-by-step guide to provision the **Azure SRE Agent** and connect it to the
ContosoPay demo environment created by `scripts/deploy.ps1` / `scripts/deploy.sh`.

The SRE Agent is a managed service provisioned **separately** from this repo's
Terraform (it is the consumer of the environment, not part of it).

> **This manual covers the steps that are common to both demo scenarios.**
> Do §1–§5 here, then continue with the **one scenario doc** you want to run:
>
> | Scenario | What it shows | Setup doc |
> | --- | --- | --- |
> | **A — On-the-spot (script)** | Trigger via a script that pokes the live app; the agent has **Privileged** access and **mitigates directly** (restart/scale) after you approve. Fastest, most self-contained. | [`scenario-a-direct.md`](scenario-a-direct.md) |
> | **B — Full GitOps (CI/CD)** | Trigger via a **Pull Request + CI**; the agent is **read-only on Azure** and **remediates by opening a PR** with review gates. The realistic DevOps story. | [`scenario-b-gitops.md`](scenario-b-gitops.md) |
>
> Pick one per run — they configure the agent's access level differently. Switching
> scenarios just means re-running §4 with the other access level.

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

> **Provision in Terraform instead (optional).** Steps §2, §4 (access level + RBAC)
> and §5 (Azure Monitor + monitored RG) can be created in code — set
> `enable_sre_agents = true` and a sponsor group id in `terraform.tfvars` to
> deploy **two agents** (`agent-a` = High, `agent-b` = Low). You still do the
> GitHub OAuth (§3), the response plan (§5.4), and the Scenario B tool policy /
> custom agent / knowledge in the portal — they have no ARM property.

---

## 3. Connect the GitHub repository (Code Access)

This is what lets the agent correlate the memory-leak incident back to the
triggering change — the commit (Scenario A) or Pull Request (Scenario B) that
shipped `enable_slow_leak = true`.

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

> **Scenario B also needs the GitHub _Connector_** (write access, for opening
> PRs) — that is a separate connection covered in
> [`scenario-b-gitops.md`](scenario-b-gitops.md). Scenario A needs only this
> read-only Code Access.

---

## 4. Grant access to the demo Azure resources

The agent needs at least **Reader** on the demo resource group to query metrics,
logs, and resource configuration during investigations. **How much more it gets
depends on your scenario:**

| Scenario | Access level | Effect |
| --- | --- | --- |
| **A — On-the-spot** | **Privileged** (`accessLevel: "High"`) | Grants contributor roles so the agent can execute Azure mitigations (restart revision / set the env var back) **directly** after approval. |
| **B — Full GitOps** | **Reader** (`accessLevel: "Low"`) | Read-only. The agent **cannot** modify Azure; it remediates by opening a PR. |

In **both** scenarios also grant **Monitoring Contributor** on the demo RG so the
Azure Monitor incident scanner can read fired alerts (see §5).

1. On the setup page, switch to the **Full setup** tab and find the
   **Azure Resources** card; select **+**.
2. Choose **Resource groups**, then **Next**.
3. Filter by the demo subscription, search for
   **`rg-contosopay-demo-<suffix>`**, and select it.
4. Select **Next** to review permissions, then choose the level your scenario
   calls for (table above) **plus Monitoring Contributor**.
5. Select **Add resource group**.

**Checkpoint:** the **Azure Resources** card lists
`rg-contosopay-demo-<suffix>`. The managed identity's role assignment is created
automatically (takes a few seconds).

> **Least privilege:** scope every grant to the single demo resource group, never
> the whole subscription.

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
   - **Response custom agent** and **autonomy level:** **scenario-specific** —
     set these per your scenario doc (Scenario A uses the default agent; Scenario
     B routes to the `gitops-remediation` custom agent). Both use **Review** mode
     so a human approves.

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
> `scripts/deploy.ps1`.

---

## 6. Continue with your scenario

The agent is now created, reads your code, can see the demo RG, and is watching
Azure Monitor. **Finish the wiring and run the demo from your scenario doc:**

- **Scenario A — On-the-spot (script):** [`scenario-a-direct.md`](scenario-a-direct.md)
- **Scenario B — Full GitOps (CI/CD):** [`scenario-b-gitops.md`](scenario-b-gitops.md)

---

## 7. Troubleshooting (common)

| Symptom | Cause / fix |
| --- | --- |
| Wizard won't load or sign-in loops | Enterprise firewall is blocking `*.azuresre.ai` / `sre.azure.com`. Allowlist both. |
| "Insufficient privileges" granting resource access | You lack **Owner**/**User Access Administrator** on the subscription or RG. Ask an admin to add the role assignment, or use a PIM just-in-time activation. |
| Alert fired but the agent never opens an investigation | **Most common.** (a) Azure Monitor isn't the active **incident platform** — connect it under **Builder → Incident platform** (§5). (b) The agent identity lacks **Monitoring Contributor** on the scope — the scanner can't read alerts with Reader only. The action group is irrelevant; the agent does not subscribe to it. |
| No alert exists at all | The memory alert only exists after a **phase-2** deploy (`deploy_apps=true`). Confirm `az monitor metrics alert list -g <rg>` returns `alert-payment-memory-<suffix>`. |
| GitHub repo not listed | The signed-in GitHub identity lacks access to `rutgerpels/sreagent`, or the GitHub App wasn't approved. Re-authenticate (§3). |
| Anthropic unavailable in EU | Expected — Anthropic is outside the EU Data Boundary. Use **Azure OpenAI** in Sweden Central. |

Scenario-specific troubleshooting lives in each scenario doc.

---

## 8. Teardown

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
- [Tool access policies][tap] — the Scenario B hard guardrail
- [GitHub connector][ghc] and [connect source code][csc]
- [Scenario A — On-the-spot](scenario-a-direct.md) · [Scenario B — Full GitOps](scenario-b-gitops.md)
- [AKS variant](aks-variant.md) — Kubernetes-native deployment notes

[create]: https://learn.microsoft.com/en-us/azure/sre-agent/create-and-set-up
[complete]: https://learn.microsoft.com/en-us/azure/sre-agent/complete-setup
[perms]: https://learn.microsoft.com/en-us/azure/sre-agent/permissions
[modes]: https://learn.microsoft.com/en-us/azure/sre-agent/run-modes
[tap]: https://learn.microsoft.com/en-us/azure/sre-agent/tool-access-policies
[ghc]: https://learn.microsoft.com/en-us/azure/sre-agent/github-connector
[csc]: https://learn.microsoft.com/en-us/azure/sre-agent/connect-source-code
