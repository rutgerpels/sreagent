# Run of Show — ContosoPay / Azure SRE Agent demo

This demo ships in **two scenarios**. Both use the same deployed environment and
the same planted memory-leak fault; they differ in **how the incident is
triggered** and **how the SRE Agent remediates it**. Pick the one that fits your
audience.

| | **Scenario A — On-the-spot** | **Scenario B — Full GitOps** |
| --- | --- | --- |
| **Trigger** | A script pokes the live app (`trigger-incident-direct`) | A **Pull Request + CI** deploys the change (`trigger-incident-gitops`) |
| **Agent Azure access** | **Privileged** (read/write) | **Reader** (read-only) |
| **Remediation** | Agent **fixes Azure directly** after you approve | Agent **opens a remediation PR**; a human merges it |
| **Best for** | A fast, self-contained "watch the agent fix it" moment | The realistic DevOps / change-management story |
| **Full talk track + setup** | [`scenario-a-direct.md`](scenario-a-direct.md) | [`scenario-b-gitops.md`](scenario-b-gitops.md) |

Common, scenario-independent agent setup (create the agent, connect GitHub Code
Access, connect Azure Monitor) is in
[`sre-agent-setup.md`](sre-agent-setup.md) §1–§5. Each scenario doc above carries
its own end-to-end run of show (set the scene → trigger → detect → root cause →
remediate → reset).

> **Tip:** the leak climbs over ~30–40 minutes, so arm the incident *before* the
> session and return to it after the walkthrough — in either scenario.
