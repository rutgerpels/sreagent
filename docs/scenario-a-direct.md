# Scenario A — On-the-spot remediation (script-driven)

The **fastest, most self-contained** way to run the ContosoPay demo. You trigger
the incident with a script that pokes the live app, and the SRE Agent — granted
**Privileged** access — **fixes it directly** (restarts the revision / sets the
flag back) after you approve in the agent UI.

> **Prerequisite:** finish the **common setup** in
> [`sre-agent-setup.md`](sre-agent-setup.md) §1–§5 first. In §4, grant the agent
> **Privileged (`accessLevel: "High"`) + Monitoring Contributor** on the demo
> resource group.
>
> Want the change-managed, PR-gated version instead? See
> [`scenario-b-gitops.md`](scenario-b-gitops.md).

> **Provision in code:** setting `enable_sre_agents=true` deploys `agent-a` with
> **High** access + Contributor + Azure Monitor already wired, so §A1 below is the
> only portal step left (route its response plan to the default agent).

---

## A1. Configure the response plan (direct mitigation)

In the response plan you created in common-setup §5:

| Setting | Value |
| --- | --- |
| **Response custom agent** | **Default agent** (no custom agent needed). |
| **Agent autonomy level** | **Review** — the agent diagnoses and **proposes** a mitigation (restart revision / scale), and acts only **after you approve**. This keeps the human-in-the-loop moment. |

That's the only scenario-specific agent config. Because the agent has Privileged
RBAC and no tool-access restrictions, its proposed fix is a direct Azure action
such as `az containerapp update --set-env-vars ENABLE_SLOW_LEAK=false` or a
revision restart.

> Prefer hands-off? Set autonomy to **Autonomous** and the agent self-mitigates
> without prompting. For a live audience, **Review** is the better story.

---

## A2. Run of show

> The leak climbs over ~30–40 minutes, so **arm the incident before the session**
> (or early in it) and return to it after the walkthrough.

### 0. Before the demo

1. Deploy the environment (if not already):

   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ./scripts/deploy.sh -s "<your-subscription>"     # or pwsh ./scripts/deploy.ps1
   ```

2. Complete [`sre-agent-setup.md`](sre-agent-setup.md) §1–§5 with **Privileged**
   access, then §A1 above.
3. Open the frontend and tick **"Generate steady traffic"** so baseline telemetry
   flows into Application Insights.

### 1. Set the scene (2 min)

- Open the **frontend URL** — ContosoPay checkout. Place an order; show the
  confirmed response (frontend → checkout-api → payment-service).
- Show the architecture: only the frontend is public; `checkout-api` and
  `payment-service` are internal-only Container Apps with managed identity, ACR
  pull without admin keys, and Key Vault-sourced secrets.
- Open **Application Insights / Grafana** — healthy request rate, latency, and a
  flat `process_memory_rss_bytes` for payment-service.

### 2. Trigger the incident (1 min)

```bash
./scripts/trigger-incident-direct.sh          # bash / Git Bash / WSL
# or, on Windows PowerShell:
pwsh ./scripts/trigger-incident-direct.ps1
```

- This runs a single `az containerapp update` that sets `ENABLE_SLOW_LEAK=true`
  on the live `payment-service` app — a new revision rolls out immediately.
- Talk track: "Someone just toggled a risky feature flag straight on the running
  service. Let's see what the SRE Agent does."

### 3. Detection (return after memory climbs)

- In Application Insights, `process_memory_rss_bytes` / working-set memory for
  payment-service trends up.
- The **Azure Monitor alert** (`alert-payment-memory-*`) fires. The SRE Agent's
  **incident scanner** (a ~1-minute poll of the Alerts API) picks it up and opens
  an investigation thread.

### 4. Investigation & root cause (the star moment)

- The agent correlates the memory trend with the recent change and produces an
  **explainable root-cause hypothesis** — memory growth began right after
  `ENABLE_SLOW_LEAK` was turned on for the payment-service revision.

### 5. Remediation on the spot (human approval)

- The agent **proposes a mitigation** — restart the leaking revision and/or set
  `ENABLE_SLOW_LEAK=false` — and waits.
- **Approve it** in the agent UI. The agent executes the Azure action directly
  (it has Privileged access), rolls a fresh revision, and memory recovers.
- Talk track: "Diagnosed, proposed, and — once a human said yes — fixed in
  seconds, all from the agent."

### 6. Proactive & conversational

- Show a **scheduled health-check** task posting results to Teams/Slack.
- Ask the agent **natural-language questions** ("What changed before this
  incident?", "Which app owns the most memory right now?").

### 7. Memory / pattern awareness

- Re-arm with `./scripts/trigger-incident-direct.sh` and show the agent resolving
  faster, recognising the now-familiar pattern.

### 8. Reset / clean up

```bash
./scripts/trigger-incident-direct.sh --reset     # set ENABLE_SLOW_LEAK=false on the live app
./scripts/teardown.sh -s "<your-subscription>"   # remove everything
```

---

## A3. Mapping to Azure SRE Agent capabilities

| Demo moment | SRE Agent capability |
| --- | --- |
| Step 3 | Detect incident from Azure Monitor / alerts |
| Step 4 | Correlate telemetry with the originating change; explainable root cause |
| Step 5 | **Directly** remediate the Azure resource after human approval (Privileged access, Review mode) |
| Step 6 | Proactive scheduled health checks; natural-language Q&A |
| Step 7 | Pattern-aware, faster repeat resolution |

---

## A4. Troubleshooting (Scenario A)

| Symptom | Cause / fix |
| --- | --- |
| Agent sees the RG but can't run the mitigation | It only has Reader/Monitoring Contributor. Re-run common-setup §4 and grant **Privileged (`High`)** on `rg-contosopay-demo-<suffix>`. |
| Agent opens a PR instead of fixing directly | You applied the Scenario B Tool Access Policy / `gitops-remediation` agent. For Scenario A, route the response plan to the **default agent** and remove the global deny policy. |
| `trigger-incident-direct` can't find the app | Pass `-g <rg> -p <payment-app>` (PowerShell: `-ResourceGroup`/`-PaymentApp`), or run it from the repo root so `terraform output` resolves the names. |

See [`sre-agent-setup.md`](sre-agent-setup.md) §7 for common troubleshooting.
