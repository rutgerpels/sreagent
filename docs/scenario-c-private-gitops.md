# Scenario C: enterprise private-network GitOps

Scenario C is the enterprise profile: **Low / Reader / Review**, private Azure
data-plane endpoints wherever the services support them, a private self-hosted
deployment runner, and a code-first Azure SRE Agent configuration.

The implementation deliberately separates the two SRE Agent management planes:

1. Terraform and AzAPI own Azure Resource Manager resources.
2. An idempotent reconciler owns documented SRE Agent data-plane resources.

This is not a portal-first deployment. Portal work is limited to external
identity bootstrap that cannot be created noninteractively and to service
features that do not yet expose a supported automation path.

## Automation boundary

| Surface | Owner | Automated state |
| --- | --- | --- |
| Agent, identities, model, budget, incident platform, telemetry, VNet, sandbox | Terraform/AzAPI | Fully declarative |
| App Insights, Log Analytics, Azure Monitor connectors | Terraform/AzAPI ARM children | Fully declarative |
| Agent and connector RBAC | Terraform | Fully declarative |
| Global tool policy | SRE Agent REST reconciler | Idempotent apply and verify |
| `gitops-remediation` custom agent | SRE Agent REST reconciler | Idempotent apply and verify; ARM extensions are tenant restricted |
| Sev2 memory response plan | SRE Agent REST reconciler | Idempotent apply and verify; ARM extensions are tenant restricted |
| Scheduled health check | SRE Agent REST reconciler | Idempotent apply and verify; ARM extensions are tenant restricted |
| GitOps runbook knowledge | SRE Agent REST reconciler | Delete known file, upload, verify successful indexing |
| GitHub Code Access | SRE Agent REST reconciler | Optional; requires externally issued GitHub App material |
| GitHub App creation and private-key issuance | GitHub/operator | External bootstrap; GitHub has no noninteractive App-creation API |
| Remote remediation MCP connector | Disabled | Supported remote HTTP managed-identity authentication is not currently documented |

The optional `agentIdentity.initialSponsorGroupId` surface from the newer stable
ARM schema is intentionally not enabled. Microsoft's current production
Terraform and Bicep templates omit it, and the underlying Agent Identity
platform is tenant restricted. Scenario C instead uses the documented
system-assigned and user-assigned managed identities, which remain fully
declarative and portable across supported SRE Agent tenants.

The reconciler is:

```text
scripts/reconcile-sre-agent.sh
scripts/reconcile-sre-agent.ps1
```

Its desired state is:

```text
agent/scenario-c/manifest.json
```

GitHub Actions runs `apply` and `verify` after Scenario C infrastructure
deployment. It runs `verify` again after application deployment.

## Why Terraform remains the IaC language

The current SRE Agent templates support Bicep and Terraform. Bicep is slightly
ahead as the native ARM authoring experience and may expose new preview
properties first. The ARM reference lists child types for subagents, incident
filters, and scheduled tasks, but live deployment in this tenant returns
`Agent Extensions are not available for this tenant` because that path is
restricted to internal tenants. Microsoft's current Terraform backend therefore
also deploys subagents through the data plane. Global permissions, extended
agents, response plans, schedules, knowledge, and Code Access remain in the
documented REST reconciliation phase for this portable enterprise profile.

This repository retains Terraform because:

- all application, networking, identity, observability, and lifecycle code is
  already Terraform;
- AzAPI can submit the same preview ARM resource shape as Bicep;
- the documented ARM connectors are Terraform-owned child resources;
- switching languages would add state and pipeline complexity without removing
  the REST reconciliation phase.

The reconciler verifies the effective response contract rather than unsupported
request-only fields. In the current preview, `agentType` is not part of the
custom-agent REST envelope, `deepInvestigationEnabled` is not persisted for
incident filters, and scheduled tasks ignore duplicate `name` and `isEnabled`
properties. Those fields are intentionally absent from the desired state so
successful API acceptance cannot mask configuration drift.

Knowledge upload is verified through the documented upload response and
`AgentMemory` indexer execution status. The preview status API does not expose a
document-list operation or filenames, so verify-only runs can prove indexing
health but cannot compare remote file contents byte for byte.

The agent currently uses `Microsoft.App/agents@2025-05-01-preview` because that
schema exposes the required VNet and sandbox properties. Re-evaluate the pinned
version when a stable API exposes the same surface.

## Security and networking model

| Concern | Scenario C behavior |
| --- | --- |
| Terraform profile | `scenario = "C"` |
| SRE Agent workload access | Reader on the demo resource group |
| Run mode | Review |
| Azure data plane | Private state Blob, ACR, and Key Vault endpoints |
| SRE Agent networking | Dedicated delegated subnet and VNet egress |
| Azure runner | `[self-hosted, Linux, X64, azure-private, contosopay]` |
| Code context | Optional read-only bring-your-own GitHub App |
| GitHub mutation | No supported agent-initiated write path in the current preview |
| Incident | Pull Request sets `enable_slow_leak = true` |
| Durable remediation | Human-reviewed Pull Request sets the flag to `false` |

Azure SRE Agent VNet integration controls egress. It does not create an inbound
private endpoint for the agent. During the preview, connector traffic is not
guaranteed to traverse the attached VNet. Do not describe the workspace as
fully private or use network placement as an authentication boundary.

The Terraform-created agent subnet is:

- delegated to `Microsoft.App/environments`;
- in the same region as the SRE Agent;
- separate from Container Apps, private endpoints, and runners;
- `/27` or larger in this demo.

The frontend remains the only public application. `checkout-api` and
`payment-service` use internal ingress. The remediation broker source is
retained, but its infrastructure and connector are intentionally not deployed.

## Remote MCP preview limitation

The current remote Streamable-HTTP connector documentation exposes bearer-token
and custom-header authentication. Managed identity is documented for supported
Azure-backed stdio connectors, not for arbitrary remote HTTP MCP endpoints.

The broker expects an Entra token for a dedicated audience and validates the
exact agent principal. Connecting it with a static bearer secret, PAT,
anonymous access, or network-only trust would weaken the design. Therefore:

- `SRE_REMEDIATION_CONNECTOR_ENABLED` must remain `false`;
- the reconciler rejects `true` with an actionable error;
- the agent remains Reader-only and cannot mutate Azure;
- the response plan can investigate and explain the one-file GitOps fix, but a
  human must create or trigger the remediation Pull Request.

Re-enable this path only after Microsoft documents a supported managed-identity
authentication flow for remote Streamable-HTTP MCP, or after the broker is
redesigned around another supported nonsecret authentication mechanism.

## 1. Prepare the runner and OIDC

Register a Linux x64 runner with:

```text
[self-hosted, Linux, X64, azure-private, contosopay]
```

The runner needs Docker, Azure CLI, outbound HTTPS to GitHub and Azure
control-plane endpoints, and network reachability to the runner VNet and private
endpoints. Terraform and Node.js are installed by the workflow.

Configure these nonsecret repository variables:

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`
- `RUNNER_NETWORK_RG`
- `RUNNER_VNET_NAME`
- `RUNNER_PE_SUBNET_NAME`

Optional address-space overrides are:

- `APP_VNET_ADDRESS_SPACE`
- `APP_PE_SUBNET_PREFIX`
- `CONTAINER_APPS_SUBNET_PREFIX`
- `SRE_AGENT_SUBNET_PREFIX`

The application and runner address spaces must not overlap. GitHub Actions uses
OIDC only; do not create a client secret, credentials JSON, storage key, or ACR
admin credential.

## 2. Prepare optional Code Access

Code Access is a read-only repository context path, not a write connector.
Create a dedicated GitHub App with only:

- Metadata: read;
- Contents: read;
- no Issues, Pull Requests, Actions, Administration, Secrets, or Workflows
  permissions.

Install it only on this repository. Keep it separate from the remediation
broker App.

From a host that can reach the private Key Vault endpoint, upload the Code
Access PEM as a Key Vault **secret**:

```bash
az keyvault secret set \
  --vault-name "<scenario-c-vault>" \
  --name "sre-code-access-github-app-pem" \
  --file "./code-access-app.pem" \
  --output none
```

Then securely remove the local PEM according to your key-custody process.
Terraform attaches a dedicated Code Access identity and grants it `Key Vault
Secrets User` only at that secret's resource scope. The action identity has no
secret-read role. The workflow passes only the secret URI to the API; it never
retrieves or logs the secret value.

Set these nonsecret repository variables:

- `SRE_CODE_ACCESS_ENABLED=true`
- `SRE_CODE_ACCESS_GITHUB_APP_CLIENT_ID=<GitHub App client ID>`
- `SRE_CODE_ACCESS_GITHUB_APP_PRIVATE_KEY_SECRET_NAME=sre-code-access-github-app-pem`

Leave `SRE_CODE_ACCESS_ENABLED=false` until all prerequisites exist. Partial
configuration fails closed.

The Code Access PEM secret is intentionally different from the broker's
non-exportable Key Vault RSA **key**:

- Code Access uses a secret URI consumed by the SRE Agent identity.
- The broker uses a key URI and asks Key Vault to perform RS256 signing.

Never reuse one App or credential for both responsibilities.

## 3. Understand the dormant remediation broker

Scenario C retains the constrained broker implementation so the architecture
can be enabled when the connector authentication gap closes. It does not deploy
the broker identity, Container App, public ingress, RBAC, or auth configuration.

Future enablement requires a separate GitHub App with:

- Metadata: read;
- Issues: read and write;
- no Contents, Pull Requests, Actions, Workflows, Administration, or Secrets
  permissions;
- webhook disabled.

Record its App ID, installation ID, bot login, and downloaded PEM. A future
supported deployment also needs dedicated Entra application metadata:

- `SRE_REMEDIATION_ENTRA_API_CLIENT_ID`
- `SRE_REMEDIATION_ENTRA_TOKEN_AUDIENCE`
- `SRE_REMEDIATION_ENTRA_TOKEN_SCOPE`
- `SRE_GITHUB_APP_ID`
- `SRE_GITHUB_APP_INSTALLATION_ID`
- `SRE_GITHUB_APP_BOT_LOGIN`
- `SRE_GITHUB_APP_PRIVATE_KEY_NAME`

Only after the connector authentication gap closes, import the broker PEM once
as a non-exportable Key Vault RSA key:

```bash
./scripts/configure-github-app-key.sh \
  --vault-name "<scenario-c-vault>" \
  --private-key "./remediation-app.pem" \
  --key-name "github-app-signing-key"
```

```powershell
pwsh ./scripts/configure-github-app-key.ps1 `
  -VaultName "<scenario-c-vault>" `
  -PrivateKeyPath "./remediation-app.pem" `
  -KeyName "github-app-signing-key"
```

The script never opens public Key Vault access. It temporarily grants the
operator Key Vault Crypto Officer, imports a sign-only key, and removes the
temporary assignment. The broker identity receives only key metadata read and
sign operations on that key.

Do not perform this dormant-path bootstrap for the current preview deployment.

## 4. Deploy and reconcile

Run the manual **deploy** workflow with:

- **Scenario:** `C`;
- the selected prefix, environment, and location;
- **Open incident PR:** as desired.

The workflow:

1. creates scenario-isolated remote state;
2. provisions the private network, identities, observability, agent, and ARM
   connectors;
3. builds and digest-pins all images;
4. applies the applications;
5. reconciles global policy, custom agent, response plan, schedule, knowledge,
   and optional Code Access;
6. verifies the resulting SRE Agent state.

After the first deployment succeeds, set:

- `TF_PREFIX`
- `TF_ENVIRONMENT`
- `DEPLOYMENT_SCENARIO=C` last

Until the activation marker is set, push workflows are safe no-ops. The state
blob is `<prefix>-C-<environment>.tfstate`; never convert A or B state in place.

For an explicit local verification from an authenticated host:

```bash
./scripts/reconcile-sre-agent.sh \
  --mode verify \
  --subscription "<subscription-id>" \
  --resource-group "<resource-group>" \
  --agent "<agent-name>"
```

Use `--mode render` without Azure access to inspect secret-safe desired state.

## 5. Run and remediate the incident

Create or merge the incident Pull Request with:

```bash
./scripts/trigger-incident-gitops.sh
```

```powershell
pwsh ./scripts/trigger-incident-gitops.ps1
```

The SRE Agent correlates the Azure Monitor incident, telemetry, and repository
change. Its response plan identifies `infra/leak.auto.tfvars` as the source of
truth and proposes changing only:

```hcl
enable_slow_leak = false
```

Because the remote MCP connector is disabled, perform the supported human
GitOps step:

```bash
./scripts/trigger-incident-gitops.sh --reset
```

Review and merge the generated Pull Request. `apply-infra` applies the healthy
flag through the private runner, and its Scenario C reconciliation step verifies
that agent configuration has not drifted.

Do not use `az containerapp update` for the fix. That would create drift from
Terraform and could be reversed by the next apply.

## 6. Destroy

Use the manual **destroy** workflow with Scenario `C` and confirmation:

```text
<prefix>-C-<environment>
```

The private runner verifies the state profile before destruction. Remove the
GitHub App installations, Entra consent, and externally bootstrapped Key Vault
material separately when no longer required. Do not remove pre-existing shared
runner-network resources.

## References

- [Deploy Azure SRE Agent with infrastructure as code](https://learn.microsoft.com/azure/sre-agent/deploy-iac)
- [Azure SRE Agent API reference](https://learn.microsoft.com/azure/sre-agent/api-reference)
- [Azure SRE Agent ARM template reference](https://learn.microsoft.com/azure/templates/microsoft.app/agents)
- [Azure SRE Agent network integration](https://learn.microsoft.com/azure/sre-agent/network-integration)
- [Azure SRE Agent GitHub connector](https://learn.microsoft.com/azure/sre-agent/github-connector)
- [Azure SRE Agent MCP connectors](https://learn.microsoft.com/azure/sre-agent/mcp-connectors)
- [Microsoft SRE Agent reference repository](https://github.com/microsoft/sre-agent)
- [Key Vault RBAC](https://learn.microsoft.com/azure/key-vault/general/rbac-guide)
