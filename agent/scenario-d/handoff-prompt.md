# Scenario D — operator handoff prompt

The handoff between the two agents is manual. Paste the text below into the
**existing SRE Agent incident thread** (Review mode) after the Observability
Agent has produced its issue. Replace the placeholders.

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
