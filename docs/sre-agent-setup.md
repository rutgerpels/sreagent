# Azure SRE Agent setup reference

This reference explains the shared Azure SRE Agent concepts used by
[Scenario A](scenario-a-direct.md),
[Scenario B](scenario-b-gitops.md), and
[Scenario C](scenario-c-private-gitops.md). Follow the selected scenario guide
for the ordered procedure.

## 1. One selected deployment profile

Terraform accepts one immutable `scenario` and derives the SRE Agent profile:

| Scenario | Access | Resource-group role | Mode | GitHub write path |
| --- | --- | --- | --- | --- |
| A | High | Contributor | Autonomous | None; direct Azure remediation |
| B | Low | Reader | Review | Built-in GitHub MCP with short-lived fine-grained PAT |
| C | Low | Reader | Review | Entra-protected custom broker with remediation GitHub App |

The GitHub deployment workflows set `enable_sre_agents = true`, so Terraform
provisions exactly one agent matching the selected profile. Direct Terraform use
can set the same variable explicitly. It does not create parallel autonomous and
GitOps agents. GitHub connections, tool policy, custom-agent behavior, and
response plans remain manual portal configuration.

The agent can instead be created at <https://sre.azure.com>. In either path,
verify that the effective access and mode match the selected Terraform state.

## 2. State and environment identity

Agent configuration must target the resource group from the same scenario state.
The state storage-account hash includes subscription, prefix, and scenario, and
the blob key is:

```text
<prefix>-<scenario>-<environment>.tfstate
```

In-place scenario conversion is unsupported. If the operating model changes,
create a new isolated environment and agent configuration, validate them, and
then explicitly destroy the old state.

## 3. Azure permissions

The agent acts through a managed identity.

### Workload access

- Scenario A receives Contributor on only the demo resource group.
- Scenarios B and C receive Reader on only the demo resource group.
- Log Analytics Reader and Monitoring Reader support investigation.

The managed Azure SRE Agent can require Monitoring Contributor at subscription
scope for the Azure Monitor alert lifecycle. That documented exception does not
grant general workload Contributor. For B and C, the hard tool policy is still
required to deny direct Azure mutation paths.

Review the current role list in
[Azure SRE Agent permissions](https://learn.microsoft.com/azure/sre-agent/permissions).

### Key Vault access in Scenario C

Scenario C has two distinct cryptographic consumers:

- the selected SRE Agent receives only the Key Vault access needed by its
  configured Code Access method;
- the remediation broker receives a custom role limited to key metadata read
  and sign actions, scoped to its single imported remediation key.

The broker does not receive Key Vault Secrets User and cannot retrieve a PEM.
Key Vault data-plane authorization uses Azure RBAC. See
[Key Vault RBAC](https://learn.microsoft.com/azure/key-vault/general/rbac-guide).

## 4. Code Access is not a write connector

Code Access supplies repository knowledge:

- source and infrastructure search;
- file and line references;
- commit/deployment correlation;
- root cause context.

It is not automatically the credential used for GitHub writes.

- **A:** Code Access only; no GitHub write connector.
- **B:** Code Access plus the built-in GitHub MCP connector. The connector uses a
  short-lived, fine-grained, single-repository PAT for minimum branch/file/Pull
  Request tools.
- **C:** a read-only BYO GitHub App for Code Access plus a different,
  issues-write remediation GitHub App used only by the broker.

Azure SRE Agent documents these as distinct connection types in
[GitHub connector in Azure SRE Agent](https://learn.microsoft.com/azure/sre-agent/github-connector).

## 5. Incident and evidence connections

For every scenario:

1. add the selected scenario resource group;
2. add its Log Analytics workspace and Application Insights resource;
3. connect **Azure Monitor** as the incident platform;
4. add the repository through the scenario's Code Access method;
5. create a response plan matching the Sev2 payment memory alert.

The alert is based on a five-minute average so transient spikes do not trigger
the incident. The feature-flagged leak is calibrated to produce an explainable
rise over approximately 8–12 minutes.

## 6. Run mode and approval behavior

The selected profile sets:

- A: **Autonomous**;
- B and C: **Review**.

Review mode makes GitOps changes visible for human approval before the selected
tool is called, and the resulting Pull Request remains unmerged. Scenario A is
not Review mode. If a live Scenario A presentation requires an explicit pause,
configure and test the portal approval policy for its direct mutation tools
without changing the Terraform-derived mode.

See [Azure SRE Agent run modes](https://learn.microsoft.com/azure/sre-agent/run-modes).

## 7. Hard GitOps policy for B and C

Apply
[`agent/tool-access-policy.portal.json`](../agent/tool-access-policy.portal.json)
at global scope for B and C. Confirm that it denies:

- Azure and Kubernetes write tools;
- terminal and shell fallback;
- Terraform apply and destroy paths.

Allow only the read diagnostics needed for investigation. A prompt is not a
security boundary; RBAC and tool policy are.

Scenario B then enables only the built-in GitHub MCP branch/file/Pull Request
tools required by its custom agent. Scenario C enables only the two constrained
broker tools.

See
[Azure SRE Agent tool access policies](https://learn.microsoft.com/azure/sre-agent/tool-access-policies).

## 8. Connectors by scenario

### Scenario A

No GitOps write connector and no broker. The default agent uses Azure tools
under the High/Contributor/Autonomous profile.

### Scenario B

Add the built-in GitHub MCP connector with a short-lived fine-grained PAT.
Restrict the PAT to one repository and minimum permissions. Select only the
tools needed to create an unmerged one-file remediation Pull Request. Revoke the
PAT after the demo.

See
[fine-grained PAT guidance](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens).

### Scenario C

Add the custom Streamable HTTP MCP endpoint produced as
`sre_remediation_broker_endpoint_url`. Use managed-identity authentication and
the configured Entra scope. Easy Auth permits only the exact agent principal;
the broker checks that principal again.

Select only:

- `create_slow_leak_remediation_issue`;
- `get_slow_leak_remediation_status`.

See
[Azure SRE Agent MCP connectors](https://learn.microsoft.com/azure/sre-agent/mcp-connectors).

## 9. Scenario C network integration

Scenario C uses **Settings > Workspace configuration > Network > Azure VNet**.
Azure SRE Agent network integration controls egress. It lets the agent use the
VNet's private DNS, routes, firewalls, and logging to reach private Azure
data-plane endpoints.

The dedicated subnet:

- is delegated to `Microsoft.App/environments`;
- is in the same region as the SRE Agent;
- is not shared with Container Apps, private endpoints, or runners;
- is `/27` or larger in this demo, which is more conservative than the current
  service minimum of `/28`.

The integration does not create an inbound private endpoint for the agent.
Platform traffic stays on managed infrastructure. Configure the documented
infra-network options or VNet egress needed for code repositories and remote MCP
servers.

See
[Azure SRE Agent network integration](https://learn.microsoft.com/azure/sre-agent/network-integration).

## 10. Scenario C broker authentication

The broker uses external HTTPS because the one Container Apps environment must
keep the frontend public and the managed agent requires a reachable remote MCP
endpoint. Internal per-app ingress does not meet that managed-service
reachability requirement.

Protection is layered:

1. TLS-only external ingress;
2. Container Apps Easy Auth;
3. dedicated Entra audience;
4. exact SRE Agent principal allow-list;
5. Easy Auth token store for the validated Entra access-token header;
6. application-level RS256 signature, issuer, audience, expiry, and object-ID
   validation;
7. platform principal-header consistency check when present;
8. two fixed-purpose MCP tools;
9. issues-only GitHub App permissions;
10. Scenario C-only workflow validation.

See
[Container Apps authentication](https://learn.microsoft.com/azure/container-apps/authentication)
and
[Container Apps networking](https://learn.microsoft.com/azure/container-apps/networking).

## 11. Scenario C remediation signing key

The remediation App PEM is imported once through:

- `scripts/configure-github-app-key.sh`; or
- `scripts/configure-github-app-key.ps1`.

Run the script from the private network. It never enables public Key Vault
access. It temporarily grants the operator **Key Vault Crypto Officer**, imports
a non-exportable RSA key with only `sign`, and removes the temporary assignment.

The supported names are:

- `sre_remediation_github_app_private_key_name`
- `SRE_GITHUB_APP_PRIVATE_KEY_NAME`
- `GITHUB_APP_PRIVATE_KEY_KEY_URI`
- `sre_remediation_broker_key_uri`

The broker's managed identity has a custom role containing only
`Microsoft.KeyVault/vaults/keys/read` and
`Microsoft.KeyVault/vaults/keys/sign/action`. It constructs a
`CryptographyClient` from the unversioned key URI and requests RS256 signing. It
never downloads private key material. Do not create a broker PEM secret.

GitHub App JWTs must use RS256 and are exchanged for short-lived installation
tokens. See
[GitHub App JWT authentication](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app)
and
[installation authentication](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation).

## 12. Response-plan outcomes

The response plan should produce one of these scenario-specific outcomes:

- **A:** direct Azure remediation under the configured Autonomous approval
  policy;
- **B:** built-in GitHub MCP opens an unmerged remediation Pull Request;
- **C:** broker creates the trusted remediation issue, then the Scenario C-only
  workflow opens an unmerged remediation Pull Request.

For B and C, the Pull Request changes only
`infra/leak.auto.tfvars` from `true` to `false`. The human merge is the durable
GitOps approval gate.

## 13. Removal

- Destroy the exact scenario state with the matching scenario value.
- Remove a portal-created SRE Agent separately.
- Revoke Scenario B's PAT.
- For C, rotate or remove the remediation key, remove Entra consent if no longer
  needed, and uninstall both GitHub Apps.

Never reuse the destroyed scenario's state for a different profile.

## Official references

- [Create and set up Azure SRE Agent](https://learn.microsoft.com/azure/sre-agent/create-and-set-up)
- [Azure SRE Agent permissions](https://learn.microsoft.com/azure/sre-agent/permissions)
- [Azure SRE Agent run modes](https://learn.microsoft.com/azure/sre-agent/run-modes)
- [Azure SRE Agent GitHub connector](https://learn.microsoft.com/azure/sre-agent/github-connector)
- [Azure SRE Agent MCP connectors](https://learn.microsoft.com/azure/sre-agent/mcp-connectors)
- [Azure SRE Agent network integration](https://learn.microsoft.com/azure/sre-agent/network-integration)
- [Key Vault RBAC](https://learn.microsoft.com/azure/key-vault/general/rbac-guide)
- [Key Vault key operations](https://learn.microsoft.com/azure/key-vault/keys/about-keys-details)
