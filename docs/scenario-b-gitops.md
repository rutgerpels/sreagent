# Scenario B — Full GitOps remediation (CI/CD-gated)

The **realistic DevOps story**. The incident enters the system as a **Pull
Request + CI deploy**, and the SRE Agent — kept **read-only on Azure** — fixes it
the same way it arrived: by **opening a remediation Pull Request** that a human
reviews and merges. No one touches the live Azure resources by hand.

> **Prerequisite:** finish the **common setup** in
> [`sre-agent-setup.md`](sre-agent-setup.md) §1–§5 first. In §4, grant the agent
> **Reader (`accessLevel: "Low"`) + Monitoring Contributor** on the demo resource
> group — read-only, no write access.
>
> Want the fast, direct version instead? See
> [`scenario-a-direct.md`](scenario-a-direct.md).

> **Provision in code:** setting `enable_sre_agents=true` deploys `agent-b` with
> **Reader** access + Monitoring Contributor + Azure Monitor already wired. §B1–§B5
> below (GitHub Connector, tool policy, custom agent, knowledge, response plan)
> stay manual — they have no ARM property.

The committable artifacts for this scenario live in [`../agent/`](../agent/).

---

## B1. Add the GitHub Connector (required for PR remediation)

The read-only **Code Access** from common-setup §3 lets the agent *read*
source/IaC. To let it **open Pull Requests** as its remediation, also add the
**GitHub Connector**:

1. Go to **Builder → Connectors → Add connector → GitHub**.
2. Authenticate with an identity (OAuth/PAT/GitHub App) that has **Pull
   requests: Read/Write** and **Issues: Read/Write** on `rutgerpels/sreagent`.
3. Select **Add**.

**Checkpoint:** the agent can now create branches, issues, and PRs. (Code Access
and the GitHub Connector are different connections — you want both.)

---

## B2. Hard guardrail — global Tool Access Policy (deny Azure writes)

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

> Combined with the **Reader** (`accessLevel: "Low"`) permission from common-setup
> §4, the agent has *neither the RBAC nor the tool permission* to write to Azure
> — two independent guardrails.

---

## B3. GitOps custom agent (behavioural steering)

1. Go to **Builder → Custom agents → New**.
2. Name it e.g. `gitops-remediation`, and paste the **Instructions** from
   [`../agent/gitops-remediation-agent.md`](../agent/gitops-remediation-agent.md).
3. Give it the **GitHub Connector** and **Code Access** tools. Save.

---

## B4. Knowledge file (the exact fix)

Add [`../agent/knowledge/gitops-runbook.md`](../agent/knowledge/gitops-runbook.md)
under **Builder → Knowledge → Add** so the agent knows the leak maps to
`infra/leak.auto.tfvars`.

---

## B5. Route the response plan to the GitOps agent (Review mode)

Edit the response plan from common-setup §5: set **Response custom agent** to
`gitops-remediation` and **Agent autonomy level** to **Review**.

> **Run-mode nuance:** Review mode only gates *Azure infrastructure* writes —
> which the agent no longer performs. GitHub PR creation proceeds based on the
> custom-agent instructions and the connector's permissions. That's exactly what
> we want: propose a PR, let a human merge it.

---

## B6. Configure the `apply-infra` deploy workflow

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

## B7. Run of show

> The leak climbs over ~30–40 minutes, so **arm the incident before the session**
> (or early in it) and return to it after the walkthrough.

### 0. Before the demo

1. Deploy the environment (if not already):

   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ./scripts/deploy.sh -s "<your-subscription>"     # or pwsh ./scripts/deploy.ps1
   ```

2. Complete [`sre-agent-setup.md`](sre-agent-setup.md) §1–§5 with **Reader**
   access, then §B1–§B6 above.
3. Open the frontend and tick **"Generate steady traffic"** so baseline telemetry
   flows into Application Insights.

### 1. Set the scene (2 min)

- Open the **frontend URL** — ContosoPay checkout. Place an order; show the
  confirmed response (frontend → checkout-api → payment-service).
- Show the architecture: only the frontend is public; the internal apps use
  managed identity, ACR pull without admin keys, and Key Vault-sourced secrets.
- Open **Application Insights / Grafana** — healthy request rate, latency, and a
  flat `process_memory_rss_bytes` for payment-service.

### 2. Trigger the incident — via a Pull Request (1 min)

```bash
./scripts/trigger-incident-gitops.sh          # bash / Git Bash / WSL
# or, on Windows PowerShell:
pwsh ./scripts/trigger-incident-gitops.ps1
```

- This opens a **Pull Request** that sets `enable_slow_leak = true` in
  `infra/leak.auto.tfvars`. Show the PR diff, then **merge it**.
- Merging runs the **`apply-infra`** GitHub Actions workflow, which
  `terraform apply`s the change and deploys the leak — no one touches the live
  app by hand.
- Talk track: "A change shipped through our normal PR + CI pipeline, exactly like
  a real regression. Let's see what the SRE Agent does."

### 3. Detection (return after memory climbs)

- In Application Insights, payment-service memory trends up.
- The **Azure Monitor alert** (`alert-payment-memory-*`) fires. The SRE Agent's
  **incident scanner** (~1-minute poll of the Alerts API) picks it up and opens
  an investigation thread.

### 4. Investigation & root cause (the star moment)

- The agent correlates the memory trend with the **GitHub PR + merge commit**
  from step 2 and produces an **explainable root-cause hypothesis**.

### 5. Remediation the GitOps way (human approval = PR merge)

- The agent is **denied direct Azure writes** (global Tool Access Policy +
  Reader-only RBAC). Instead of restarting the container itself, it **opens a
  remediation Pull Request** that sets `enable_slow_leak = false` in
  `infra/leak.auto.tfvars`, with the root cause and evidence in the description.
- Show the agent's PR. **Review and merge it** — that is the human approval gate.
- Merging runs `apply-infra` again; `terraform apply` rolls a fresh
  `payment-service` revision and memory recovers. Talk track: "The fix shipped
  the same way the bug did — reviewed code, no console cowboy-ops."

### 6. Proactive & conversational

- Show a **scheduled health-check** task posting results to Teams/Slack.
- Ask the agent **natural-language questions** and show grounded answers.

### 7. Memory / pattern awareness

- Re-arm with `./scripts/trigger-incident-gitops.sh` (opens a fresh PR) and show
  the agent resolving faster, recognising the now-familiar pattern.

### 8. Reset / clean up

```bash
./scripts/trigger-incident-gitops.sh --reset     # opens a PR turning the leak off
./scripts/teardown.sh -s "<your-subscription>"   # remove everything
```

---

## B8. Mapping to Azure SRE Agent capabilities

| Demo moment | SRE Agent capability |
| --- | --- |
| Step 3 | Detect incident from Azure Monitor / alerts |
| Step 4 | Correlate telemetry with the originating GitHub PR + commit; explainable root cause |
| Step 5 | Remediate via a **GitHub PR**; deployed only after a human merges (no direct Azure writes) |
| Step 6 | Proactive scheduled health checks; natural-language Q&A |
| Step 7 | Pattern-aware, faster repeat resolution |

---

## B9. Troubleshooting (Scenario B)

| Symptom | Cause / fix |
| --- | --- |
| Agent tries to run `az containerapp update` instead of opening a PR | The global **Tool Access Policy** (§B2) isn't applied, or it was set at a non-global scope (only *global* can deny). Re-apply `agent/tool-access-policy.json` at global scope, and confirm the response plan routes to the `gitops-remediation` custom agent (§B5). |
| Agent can't open a PR | The **GitHub Connector** (§B1) is missing or lacks **Pull requests: Read/Write**. Add/repair it. |
| Merging a PR doesn't deploy | The `apply-infra` workflow isn't configured. Set the `TFSTATE_*` and `AZURE_*` Actions variables (§B6) and ensure the OIDC identity has Contributor on the demo RG + Storage Blob Data Contributor on the state account. |
| `apply-infra` run fails on `terraform init` | The `TFSTATE_*` variables don't match the state account the deploy script created. Re-read them from the deploy output (or `scripts/deploy.* ` prints them) and update the Actions variables. |

See [`sre-agent-setup.md`](sre-agent-setup.md) §7 for common troubleshooting.

---

## References

- [Agent permissions][perms] and [run modes][modes]
- [Tool access policies][tap] — the hard GitOps guardrail
- [GitHub connector][ghc] and [connect source code][csc]
- [GitOps remediation config](../agent/README.md) — the committable agent artifacts

[perms]: https://learn.microsoft.com/en-us/azure/sre-agent/permissions
[modes]: https://learn.microsoft.com/en-us/azure/sre-agent/run-modes
[tap]: https://learn.microsoft.com/en-us/azure/sre-agent/tool-access-policies
[ghc]: https://learn.microsoft.com/en-us/azure/sre-agent/github-connector
[csc]: https://learn.microsoft.com/en-us/azure/sre-agent/connect-source-code
