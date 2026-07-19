# Azure SRE Agent setup reference

This reference explains the shared Azure SRE Agent model used by
[Scenario A](scenario-a-direct.md),
[Scenario B](scenario-b-gitops.md), and
[Scenario C](scenario-c-private-gitops.md).

## Selected deployment profile

Terraform accepts one immutable `scenario`:

| Scenario | Access | Resource-group role | Mode | GitHub write path |
| --- | --- | --- | --- | --- |
| A | High | Contributor | Autonomous | None; direct Azure remediation |
| B | Low | Reader | Review | Built-in GitHub MCP with a short-lived fine-grained PAT |
| C | Low | Reader | Review | None until remote HTTP MCP supports the required nonsecret authentication |

The deployment workflows provision one agent matching the profile. State is
isolated by subscription, prefix, scenario, and environment. Never convert a
scenario in place.

## Control plane and data plane

Azure SRE Agent configuration spans two supported management surfaces:

- Azure Resource Manager creates the agent, identities, network attachment,
  sandbox, model, budget, telemetry, incident platform, and first-party
  connector child resources.
- The SRE Agent API manages global permissions, extended agents, incident
  filters, schedules, knowledge, and GitHub Code Access.

Scenario C automates both surfaces. Terraform/AzAPI owns ARM resources and
`scripts/reconcile-sre-agent.*` idempotently applies and verifies the API-owned
resources from `agent/scenario-c/manifest.json`.

Scenarios A and B retain their scenario-specific portal procedures. Do not run
the Scenario C manifest against another profile.

## Azure permissions

The agent acts through managed identities:

- Scenario A receives Contributor on only the demo resource group.
- Scenarios B and C receive Reader on only the demo resource group.
- Log Analytics Reader and Monitoring Reader support investigation.
- The deployment identity receives SRE Agent Administrator only at the created
  agent scope so the reconciler can manage data-plane configuration.

The managed service may require broader monitoring permissions for the Azure
Monitor incident lifecycle. That documented exception does not grant general
workload Contributor. RBAC remains the hard mutation boundary for B and C.

## Code Access is not a write connector

Code Access supplies source search, file references, commit correlation, and
root-cause context. It is not automatically a GitHub write credential:

- A uses Code Access only.
- B combines Code Access with the built-in GitHub MCP connector.
- C optionally configures a read-only bring-your-own GitHub App through the API.

Scenario C stores the Code Access App PEM as a Key Vault secret. The workflow
passes only its URI. A dedicated identity reads only that secret through
secret-scoped Key Vault RBAC; the agent action identity has no secret-read role.
This is separate from the broker's proposed issues-write App and non-exportable
signing key.

See
[GitHub connector in Azure SRE Agent](https://learn.microsoft.com/azure/sre-agent/github-connector).

## Incident and evidence connections

Every scenario needs:

1. the selected scenario resource group;
2. its Log Analytics workspace and Application Insights resource;
3. Azure Monitor as the incident platform;
4. the repository through the selected Code Access method;
5. a response plan matching the Sev2 payment memory alert.

Scenario C creates the first-party observability connectors as ARM children and
reconciles the response plan through the API. The five-minute alert window lets
the deterministic leak produce an explainable 8–12 minute trend.

## Run modes and policy

- A uses Autonomous mode.
- B and C use Review mode.

Review mode makes proposed GitOps actions visible for human approval. It is not
an authorization boundary by itself. Reader RBAC, connector credentials, and
the global tool policy enforce the boundary.

Scenario C reconciles
[`agent/tool-access-policy.api.json`](../agent/tool-access-policy.api.json)
globally. It denies Azure, Kubernetes, terminal, shell, Terraform, and generic
GitHub mutation paths while allowing investigation.

## Connector behavior

### Scenario A

No GitOps connector or broker. Azure tools operate under the
High/Contributor/Autonomous profile.

### Scenario B

Use the built-in GitHub MCP connector with a short-lived, fine-grained,
single-repository PAT. Enable only the branch, file, and Pull Request operations
needed for the one-file remediation and revoke the PAT after the demo.

### Scenario C

Application Insights, Log Analytics, and Azure Monitor connectors are
Terraform-owned ARM child resources.

The custom remote MCP connector is not enabled. Current Streamable-HTTP
documentation supports bearer-token and custom-header authentication; managed
identity is documented for supported Azure-backed stdio connectors. The broker
requires an Entra token for a dedicated audience and exact agent principal, so
substituting a static bearer token, PAT, anonymous access, or network-only trust
is forbidden.

The reconciler fails if `SRE_REMEDIATION_CONNECTOR_ENABLED=true`. Revisit this
when Microsoft documents a supported remote HTTP managed-identity flow.

## Scenario C network integration

Terraform attaches the Scenario C agent to its dedicated subnet. VNet
integration controls egress and lets supported traffic use private DNS, routes,
firewalls, and logging.

It does not create inbound private connectivity for the agent. Connector traffic
may bypass VNet integration during the preview. Private endpoints protect state,
ACR, and Key Vault, but do not make all SRE Agent platform paths private.

See
[Azure SRE Agent network integration](https://learn.microsoft.com/azure/sre-agent/network-integration).

## Scenario C external bootstrap

Automation still requires operator-supplied, nonsecret metadata and externally
issued credentials:

- GitHub App creation and installation;
- GitHub App private-key issuance;
- Key Vault insertion of the Code Access PEM secret;
- future broker Entra and signing-key bootstrap only after its authentication
  path is supported;
- broker Entra application registration and consent.

GitHub does not provide a noninteractive API for creating an App or issuing its
initial private key. These are explicit bootstrap boundaries, not portal-managed
agent configuration.

## Response-plan outcomes

- A directly mitigates Azure under its Autonomous policy.
- B opens an unmerged one-file Pull Request with the built-in GitHub MCP.
- C investigates and proposes the same one-file GitOps fix. Until the broker
  connector authentication gap closes, a human opens the remediation Pull
  Request with `scripts/trigger-incident-gitops.* --reset`.

For B and C, the durable fix changes only `infra/leak.auto.tfvars` from `true`
to `false`; human merge remains the approval gate.

## Removal

- Destroy the exact scenario state with matching values.
- Remove externally created GitHub Apps, Entra consent, and key material when no
  longer required.
- Revoke Scenario B's PAT.
- Never reuse a destroyed scenario's state for another profile.

## Official references

- [Deploy with infrastructure as code](https://learn.microsoft.com/azure/sre-agent/deploy-iac)
- [Azure SRE Agent API reference](https://learn.microsoft.com/azure/sre-agent/api-reference)
- [Azure SRE Agent permissions](https://learn.microsoft.com/azure/sre-agent/permissions)
- [Azure SRE Agent run modes](https://learn.microsoft.com/azure/sre-agent/run-modes)
- [Azure SRE Agent GitHub connector](https://learn.microsoft.com/azure/sre-agent/github-connector)
- [Azure SRE Agent MCP connectors](https://learn.microsoft.com/azure/sre-agent/mcp-connectors)
- [Azure SRE Agent network integration](https://learn.microsoft.com/azure/sre-agent/network-integration)
- [Key Vault RBAC](https://learn.microsoft.com/azure/key-vault/general/rbac-guide)
