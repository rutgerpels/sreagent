# Azure SRE Agent — Reference

This is the reference companion to the three scenario guides
([Scenario A](scenario-a-direct.md), [Scenario B](scenario-b-gitops.md), and
[Scenario C](scenario-c-private-gitops.md)). The
scenario guides walk you through everything in order; come here when you want
more background on a step, on the available options, or when something does not
behave as expected.

The Azure SRE Agent is a **managed Azure service**. The default setup creates it
in the Azure SRE Agent portal at <https://sre.azure.com>. Optionally,
`infra/agents.tf` provisions the agent resource and Azure RBAC with
`enable_sre_agents = true`; connector, policy, and Builder configuration remain
portal steps.

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
| **Reader** (`Low`) | Reader-level workload diagnostics; core monitoring roles still manage the alert lifecycle. | Scenario B and Scenario C |
| **Privileged** (`High`) | The agent can also perform changes, such as restarting a revision or updating a setting. | Scenario A |

**Monitoring Contributor at subscription scope** — assigned by Azure SRE Agent
for both permission levels so it can acknowledge and close Azure Monitor alerts
and update monitoring settings. Scenario B therefore combines the Reader
permission level with the required global tool policy that denies direct Azure
mutation paths. Scenarios B and C therefore use the same GitOps guardrail
pattern. (The agent does not subscribe to the alert's action group; the
action group is only used if you also want to notify a person by email or
webhook.)

Workload roles are scoped to the **single demo resource group**. Monitoring
Contributor is the intentional exception: Azure SRE Agent requires it at
subscription scope for the Azure Monitor alert lifecycle.

---

## 4. Connecting your source code (GitHub Code Access)

Code Access lets the agent index the repository so it can connect an incident to
the change that caused it. In the agent portal, open the **Code** card on the
setup page (or **Builder → Knowledge base → Add repository**), choose **GitHub**,
sign in, and select this demo's repository (`<your-org>/<your-repo>`). When the
card shows the repository with a green check, the agent has begun indexing the
code. Code Access is repository context only in this demo. It is not a terminal Git
credential, and its onboarding OAuth session is not reused by the custom MCP
connector.

Scenario B uses the fast demo path: **Builder → Connectors → Add connector →
MCP → GitHub** with a same-day fine-grained PAT scoped to this repository and
limited to **Contents: Read and write** plus **Pull requests: Read and write**.
Revoke it immediately after the demo.

Scenario C uses SRE Agent's native **Code Access → Bring your own GitHub App**
flow. The GitHub App private key is imported as a Key Vault key, the SRE Agent
managed identity uses it for signing, and GitHub operations are attributed to the
app identity instead of a user.

The optional MCP broker remains an advanced hardening pattern for teams that want
the agent to call only two allowlisted issue/status tools instead of general
branch/file/Pull Request authoring tools.

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

## 6. Network integration

Scenario C uses **Settings → Workspace configuration → Network → Azure VNet** to
route SRE Agent outbound traffic through your virtual network. This is the right
mode when the agent must reach private Azure data-plane endpoints such as Key
Vault through private DNS, private endpoints, NSGs, UDRs, and firewalls.

Azure VNet mode requires a dedicated subnet:

- `/28` or larger;
- delegated to `Microsoft.App/environments`;
- in the same region as the SRE Agent resource;
- not shared with Container Apps, private endpoints, runners, or other services.

Network integration controls outbound egress only. Platform services still use
the SRE Agent managed infrastructure, and public services such as GitHub SaaS
either need allowed FQDN egress from your VNet or the relevant SRE Agent infra
network toggle.

---

## 7. Optional: provisioning the agent with Terraform

Most of the agent setup is done in the portal because the GitHub sign-in, the
response plan, and (for Scenarios B/C) the tool policy and subagent (custom agent) are
interactive, portal-only steps. If you prefer, the agent resource itself, its
access level, and its Azure Monitor wiring can be created in Terraform instead:
set `enable_sre_agents = true` and `sre_agent_sponsor_group_id` in
`terraform.tfvars`. This provisions two agents — one with Privileged access for
Scenario A and one with Reader access for GitOps scenarios. You still complete the
GitHub sign-in and response plan in the portal.

---

## 8. Troubleshooting

| Symptom | What to check |
| --- | --- |
| The agent portal will not load or the sign-in loops | A corporate firewall is blocking `sre.azure.com` or `*.azuresre.ai`. Allowlist both. |
| "Insufficient privileges" when granting resource access | You need **Owner** or **User Access Administrator** on the subscription or resource group. Ask an administrator, or activate the role just-in-time with PIM. |
| The alert fired but the agent never opens an investigation | Confirm Azure Monitor is the active incident platform (§5) and that the agent's identity has the core monitoring roles described in §3. |
| There is no alert to pick up | The memory alert only exists after the application is deployed. Confirm `az monitor metrics alert list -g <resource-group>` lists the `alert-payment-memory-…` rule. |
| The repository is not listed during Code Access | The signed-in GitHub identity does not have access to the demo repository. Re-authenticate with an account that does. |
| BYO GitHub App validation fails | Verify the GitHub App **Client ID** starts with `Iv...`, the private-key URI points to `https://<vault>.vault.azure.net/keys/<name>`, and the agent managed identity has **Key Vault Crypto User** on the vault or key scope. |
| BYO GitHub App validation still fails after key/RBAC checks | Check Key Vault networking. A private-only vault blocks the connector if the SRE Agent validation path is not allowed to reach the Key Vault data plane. Use Scenario C's Azure VNet mode, an approved network exception, or the PAT shortcut. |
| Custom MCP discovery returns 401 | Advanced broker path only: confirm the connector uses **Managed identity**, selects the GitOps SRE Agent identity, and requests the dedicated `api://<client-id>/.default` scope. A raw unauthenticated request is expected to return 401. |
| The GitHub MCP wizard asks for a PAT | This is expected only for the PAT shortcut. For native BYO GitHub App, configure it in **Builder → Code Access**, not the MCP GitHub tile. |
| The remediation issue opens but no workflow starts | Broker path only: confirm `SRE_GITHUB_APP_BOT_LOGIN` exactly matches `<app-slug>[bot]`, the `sre-remediation` label exists, and the workflow is present on the default branch. |
| The PAT shortcut cannot open a PR | Confirm the fine-grained PAT has **Contents: Read and write** and **Pull requests: Read and write** on this repository, and that the custom agent selected the GitHub branch/file/Pull Request tools. |

---

## 9. Removing the agent

If Terraform created the agent (`enable_sre_agents = true`), the normal
repository teardown removes it with the rest of the Terraform-managed
environment. If you created the agent in the portal, delete that agent in the
portal separately. Each scenario guide covers tearing down the ContosoPay
environment itself.

---

## References

- [Create and set up Azure SRE Agent](https://learn.microsoft.com/en-us/azure/sre-agent/create-and-set-up)
- [Complete setup for Azure SRE Agent](https://learn.microsoft.com/en-us/azure/sre-agent/complete-setup)
- [Agent permissions](https://learn.microsoft.com/en-us/azure/sre-agent/permissions)
  · [Run modes](https://learn.microsoft.com/en-us/azure/sre-agent/run-modes)
- [Tool access policies](https://learn.microsoft.com/en-us/azure/sre-agent/tool-access-policies)
- [GitHub connector](https://learn.microsoft.com/en-us/azure/sre-agent/github-connector)
  · [Connect source code](https://learn.microsoft.com/en-us/azure/sre-agent/connect-source-code)
- [MCP connectors](https://learn.microsoft.com/en-us/azure/sre-agent/mcp-connectors)
- [Authenticate as a GitHub App installation](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation)
