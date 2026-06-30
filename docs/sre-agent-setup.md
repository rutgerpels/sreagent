# Azure SRE Agent — Reference

This is the reference companion to the two scenario guides
([Scenario A](scenario-a-direct.md), [Scenario B](scenario-b-gitops.md)). The
scenario guides walk you through everything in order; come here when you want
more background on a step, on the available options, or when something does not
behave as expected.

The Azure SRE Agent is a **managed Azure service**. You create it in the Azure
SRE Agent portal at <https://sre.azure.com>; it is intentionally separate from
the Terraform that deploys ContosoPay, because the agent is the *consumer* of
the environment rather than part of it.

> Microsoft documentation:
> [Create and set up Azure SRE Agent](https://learn.microsoft.com/en-us/azure/sre-agent/create-and-set-up)
> · [Complete setup](https://learn.microsoft.com/en-us/azure/sre-agent/complete-setup)

---

## 1. Prerequisites

| Requirement | Why it is needed |
| --- | --- |
| The ContosoPay environment is already deployed | The agent needs live resources, alerts, and telemetry to investigate. Each scenario guide deploys this in its first part. |
| **Contributor** on the target subscription | Lets you create the agent and its supporting resources. |
| **Owner** or **User Access Administrator** on the subscription or resource group | Lets the agent's managed identity receive the role assignments it needs. |
| Browser access to `sre.azure.com` and `*.azuresre.ai` | The agent portal and its APIs are hosted there. Allowlist them if you are behind a corporate firewall. |
| A supported region | For example **Sweden Central** (used by this demo and inside the EU Data Boundary) or **East US 2**. |

---

## 2. Regions and models

When you create the agent you choose a region, and the region determines which
AI model provider is used:

- **Sweden Central** (and other EU regions) use **Azure OpenAI**, which keeps the
  agent inside the EU Data Boundary. This demo is deployed in Sweden Central, so
  this is the recommended choice.
- Regions outside the EU may default to **Anthropic (Claude)**, which is not
  covered by EU Data Boundary commitments.

Keep the agent in the same region as the ContosoPay deployment where possible.

---

## 3. Permissions explained

The agent acts through its **managed identity**. Two kinds of access matter:

**Access level on the demo resource group** — this controls what the agent may
*do* to your Azure resources:

| Access level | Meaning | Used by |
| --- | --- | --- |
| **Reader** (`Low`) | The agent can read configuration, metrics, and logs, but cannot change anything. | Scenario B |
| **Privileged** (`High`) | The agent can also perform changes, such as restarting a revision or updating a setting. | Scenario A |

**Monitoring Contributor on the demo resource group** — required by **both**
scenarios. The agent discovers incidents by polling the Azure Monitor Alerts API
roughly once a minute for fired alerts in the scopes its identity can read.
Monitoring Contributor is what allows it to read those alerts. (The agent does
not subscribe to the alert's action group; the action group is only used if you
also want to notify a person by email or webhook.)

Always scope these grants to the **single demo resource group**, never the whole
subscription.

---

## 4. Connecting your source code (GitHub Code Access)

Code Access lets the agent **read** the repository so it can connect an incident
to the change that caused it. In the agent portal, open the **Code** card on the
setup page, choose **GitHub**, sign in, and select the `rutgerpels/sreagent`
repository. When the card shows the repository with a green check, the agent has
begun indexing the code.

Scenario B additionally uses a GitHub **Connector** (with write permission) so
the agent can *open* Pull Requests. That is a separate connection and is covered
in the Scenario B guide.

---

## 5. Connecting Azure Monitor as the incident platform

This is what makes the agent proactive. In the agent portal, open
**Builder → Incident platform**, choose **Azure Monitor**, and save. No
credentials are needed — it uses the agent's managed identity. Only one incident
platform can be active at a time.

After the platform shows **Connected**, create a **response plan**
(**Create a response plan**). A response plan tells the agent which alerts to act
on and how:

- **Severity filter:** include **Sev2 / Warning**, because the demo's memory
  alert is severity 2.
- **Response agent and autonomy:** these are set per scenario (see each guide).
  Both scenarios use **Review** autonomy so the agent proposes a fix and waits
  for a human.

Within about a minute of saving, a fired memory alert appears as an incident in
the agent and an investigation thread opens.

---

## 6. Optional: provisioning the agent with Terraform

Most of the agent setup is done in the portal because the GitHub sign-in, the
response plan, and (for Scenario B) the tool policy and custom agent are
interactive, portal-only steps. If you prefer, the agent resource itself, its
access level, and its Azure Monitor wiring can be created in Terraform instead:
set `enable_sre_agents = true` and `sre_agent_sponsor_group_id` in
`terraform.tfvars`. This provisions two agents — one with Privileged access for
Scenario A and one with Reader access for Scenario B. You still complete the
GitHub sign-in and response plan in the portal.

---

## 7. Troubleshooting

| Symptom | What to check |
| --- | --- |
| The agent portal will not load or the sign-in loops | A corporate firewall is blocking `sre.azure.com` or `*.azuresre.ai`. Allowlist both. |
| "Insufficient privileges" when granting resource access | You need **Owner** or **User Access Administrator** on the subscription or resource group. Ask an administrator, or activate the role just-in-time with PIM. |
| The alert fired but the agent never opens an investigation | Confirm Azure Monitor is the active incident platform (§5) **and** that the agent's identity has **Monitoring Contributor** on the demo resource group (§3). Reader alone is not enough for the alert scanner. |
| There is no alert to pick up | The memory alert only exists after the application is deployed. Confirm `az monitor metrics alert list -g <resource-group>` lists the `alert-payment-memory-…` rule. |
| The repository is not listed during Code Access | The signed-in GitHub identity does not have access to `rutgerpels/sreagent`. Re-authenticate with an account that does. |

---

## 8. Removing the agent

The agent and its resource group are not managed by this repository's Terraform,
so remove them separately when you are finished:

```bash
az group delete --name rg-sre-agent --yes
```

Each scenario guide covers tearing down the ContosoPay environment itself.

---

## References

- [Create and set up Azure SRE Agent](https://learn.microsoft.com/en-us/azure/sre-agent/create-and-set-up)
- [Complete setup for Azure SRE Agent](https://learn.microsoft.com/en-us/azure/sre-agent/complete-setup)
- [Agent permissions](https://learn.microsoft.com/en-us/azure/sre-agent/permissions)
  · [Run modes](https://learn.microsoft.com/en-us/azure/sre-agent/run-modes)
- [Tool access policies](https://learn.microsoft.com/en-us/azure/sre-agent/tool-access-policies)
- [GitHub connector](https://learn.microsoft.com/en-us/azure/sre-agent/github-connector)
  · [Connect source code](https://learn.microsoft.com/en-us/azure/sre-agent/connect-source-code)
