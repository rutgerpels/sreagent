# Scenario D — operator handoff prompt

The handoff between the two agents is manual. Paste the text below into the
**existing SRE Agent incident thread** (Review mode) after the Observability
Agent investigation has been saved as an issue. For the next demo, start the
investigation manually from the fired alert; do not wait for autonomous issue
creation. Replace the placeholders with the actual saved report.

```text
The Azure Copilot Observability Agent investigated this incident and produced
the findings below. Treat them as a hypothesis: verify them before proposing
a change.

Issue: <observability issue URL>
Time window: <start UTC> to <end UTC>
Resources: <payment-service, checkout-api, frontend, resource group>
Findings: <paste the Observability Agent summary>
Impact: <failed /checkout requests and the fired checkout alert>

Please confirm the root cause with your own queries, propose the smallest safe
fix, and wait for my approval before changing anything.
```

Do not paste secrets, tokens or subscription identifiers beyond what the issue
already contains.
