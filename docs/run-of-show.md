# Run of Show — ContosoPay / Azure SRE Agent demo

A live talk track for showing the Azure SRE Agent detecting, explaining, and (with
approval) mitigating a real incident in a cloud-native app.

> Total runtime: the memory leak climbs over ~30–40 minutes, so **arm the incident
> before the session** (or early in it) and return to it after the walkthrough.

---

## 0. Before the demo (one-time setup)

1. Deploy the environment:

   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ./scripts/deploy.sh -s "<your-subscription>"     # or pwsh ./scripts/deploy.ps1
   ```

   Note the printed **frontend URL**, **resource group**, and **Grafana endpoint**.

2. Onboard the **Azure SRE Agent** (managed service, provisioned separately).
   For the full step-by-step manual see [`docs/sre-agent-setup.md`](sre-agent-setup.md).
   In brief:
   - Go to <https://sre.azure.com> and create an agent in a supported region
     (e.g. Sweden Central).
   - Scope it to the demo **resource group** with **Reader** + **Monitoring
     Contributor** (read-only investigation + alert scanner; the agent will *not*
     write to Azure).
   - Connect this **GitHub repository**: **Code Access** (read) **and** the
     **GitHub Connector** with *Pull requests: Read/Write* (so it can remediate
     via PR).
   - Connect **Azure Monitor** as the **incident platform**
     (**Builder → Incident platform → Azure Monitor → Save**). Alerts in the
     granted resource group then flow to the agent automatically via a ~1-minute
     scanner — no action-group receiver or webhook is required.
   - **Enforce GitOps** (the DevOps twist): apply the global **Tool Access
     Policy** that denies Azure CLI writes, add the `gitops-remediation` custom
     agent + runbook, and configure the `apply-infra` workflow variables. See
     [`docs/sre-agent-setup.md`](sre-agent-setup.md) §6 and [`agent/`](../agent/).

3. Open the frontend, tick **"Generate steady traffic"** so there is baseline load
   and telemetry flowing into Application Insights.

---

## 1. Set the scene (2 min)

- Open the **frontend URL** — ContosoPay checkout. Place an order; show the confirmed
  response (frontend → checkout-api → payment-service).
- Show the architecture: only the frontend is public; `checkout-api` and
  `payment-service` are internal-only Container Apps. Each app uses a user-assigned
  managed identity, pulls from ACR without admin keys, and reads its App Insights
  connection string from Key Vault.
- Open **Grafana** / **Application Insights** — healthy request rate, latency, and a
  flat `process_memory_rss_bytes` for payment-service.

## 2. Trigger the incident (1 min)

```bash
./scripts/trigger-incident.sh          # bash / Git Bash / WSL
# or, on Windows PowerShell:
pwsh ./scripts/trigger-incident.ps1
```

- This opens a **Pull Request** that sets `enable_slow_leak = true` in
  `infra/leak.auto.tfvars`. Show the PR diff, then **merge it**.
- Merging runs the **`apply-infra`** GitHub Actions workflow, which
  `terraform apply`s the change and deploys the leak — no one touches the live
  app by hand.
- Talk track: "A change just shipped through our normal PR + CI pipeline. Let's
  see what the SRE Agent does."

## 3. Detection (return after memory climbs)

- In Application Insights, `process_memory_rss_bytes` / working-set memory for
  payment-service is now trending up.
- The **Azure Monitor alert** (`alert-payment-memory-*`) fires. The SRE Agent's
  **incident scanner** (a ~1-minute poll of the Alerts API — *not* an action-group
  subscription) picks it up and opens an investigation thread.

## 4. Investigation & root cause (the star moment)

- The SRE Agent picks up the alert and:
  - Correlates the memory trend with the **GitHub PR + merge commit** from step 2.
  - Produces an **explainable root-cause hypothesis** (memory growth began shortly
    after the `enable_slow_leak = true` change shipped).

## 5. Remediation the GitOps way (human approval = PR merge)

- The agent is **denied direct Azure writes** (global Tool Access Policy +
  Reader-only RBAC). Instead of restarting the container itself, it **opens a
  remediation Pull Request** that sets `enable_slow_leak = false` in
  `infra/leak.auto.tfvars`, with the root cause and evidence in the description.
- Show the agent's PR. **Review and merge it** — that is the human approval gate.
- Merging runs `apply-infra` again; `terraform apply` rolls a fresh
  `payment-service` revision and memory recovers. Talk track: "The fix shipped
  the same way the bug did — reviewed code, no console cowboy-ops."

## 6. Proactive & conversational

- Show a **scheduled health-check** task posting results to Teams/Slack.
- Ask the agent **natural-language questions** ("What changed before this incident?",
  "Which app owns the most memory right now?") and show grounded answers.

## 7. Memory / pattern awareness

- Re-arm with `./scripts/trigger-incident.sh` (opens a fresh PR) and show the
  agent resolving faster, recognising the now-familiar pattern.

## 8. Reset / clean up

```bash
./scripts/trigger-incident.sh --reset    # opens a PR turning the leak off (or: pwsh ./scripts/trigger-incident.ps1 -Reset)
./scripts/teardown.sh -s "<your-subscription>"   # remove everything
```

---

## Mapping to Azure SRE Agent capabilities

| Demo moment | SRE Agent capability |
|-------------|----------------------|
| Step 3      | Detect incident from Azure Monitor / alerts |
| Step 4      | Correlate telemetry with the originating GitHub PR + commit |
| Step 4      | Explainable root-cause hypothesis |
| Step 5      | Remediate via a GitHub PR; deployed only after a human merges (no direct Azure writes) |
| Step 6      | Proactive scheduled health checks; natural-language Q&A |
| Step 7      | Pattern-aware, faster repeat resolution |
