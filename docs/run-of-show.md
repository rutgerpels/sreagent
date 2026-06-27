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

2. Onboard the **Azure SRE Agent** (managed service, provisioned separately):
   - Go to <https://sre.azure.com> and create an agent in a supported region
     (e.g. Sweden Central).
   - Scope it to the demo **resource group**.
   - Connect this **GitHub repository** so it can correlate incidents to commits.
   - Subscribe the agent to the **action group** `ag-sre-*` in the resource group.

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
./scripts/trigger-incident.sh
```

- This flips `ENABLE_SLOW_LEAK=true` in `config/feature-flags.env`, commits + pushes
  the change (the correlatable commit), and applies the flag to the live
  `payment-service` Container App.
- Talk track: "A change just shipped. Let's see what the SRE Agent does."

## 3. Detection (return after memory climbs)

- In Application Insights, `process_memory_rss_bytes` / working-set memory for
  payment-service is now trending up.
- The **Azure Monitor alert** (`alert-payment-memory-*`) fires and notifies the
  **action group** the SRE Agent is subscribed to.

## 4. Investigation & root cause (the star moment)

- The SRE Agent picks up the alert and:
  - Correlates the memory trend with the **GitHub deployment + commit** from step 2.
  - Produces an **explainable root-cause hypothesis** (memory growth began shortly
    after the flag-flip commit).

## 5. Mitigation with human approval

- The agent proposes mitigations — **it does not act without approval**:
  1. **Restart the revision** (clears the leaked memory immediately), and/or
  2. **Raise the scale rule** (more replicas spread load and slow the climb).
- Approve a mitigation. Show memory recovering after the restart.

## 6. Proactive & conversational

- Show a **scheduled health-check** task posting results to Teams/Slack.
- Ask the agent **natural-language questions** ("What changed before this incident?",
  "Which app owns the most memory right now?") and show grounded answers.

## 7. Memory / pattern awareness

- Re-arm with `./scripts/trigger-incident.sh` and show the agent resolving faster,
  recognising the now-familiar pattern.

## 8. Reset / clean up

```bash
./scripts/trigger-incident.sh --reset    # turn the leak back off
./scripts/teardown.sh -s "<your-subscription>"   # remove everything
```

---

## Mapping to Azure SRE Agent capabilities

| Demo moment | SRE Agent capability |
|-------------|----------------------|
| Step 3      | Detect incident from Azure Monitor / alerts |
| Step 4      | Correlate telemetry with the originating GitHub deployment + commit |
| Step 4      | Explainable root-cause hypothesis |
| Step 5      | Propose mitigations, executed only after human approval |
| Step 6      | Proactive scheduled health checks; natural-language Q&A |
| Step 7      | Pattern-aware, faster repeat resolution |
