# Scenario C: private-network GitOps

Scenario C is the enterprise profile. The Azure SRE Agent uses **Low / Reader /
Review**, Azure data-plane endpoints are private, Azure deployment work runs on a
private self-hosted runner, and GitHub remediation uses a constrained custom MCP
broker.

Scenario C uses no PAT for write operations. It uses two workload GitHub Apps:

1. a read-only bring-your-own App for SRE Agent Code Access;
2. an issues-write remediation App used only by the broker.

Do not combine the Apps or reuse their private keys.

## Security and operating model

| Concern | Scenario C behavior |
| --- | --- |
| Terraform profile | `scenario = "C"` |
| SRE Agent access | Low; Reader on the demo resource group |
| Run mode | Review |
| Azure data plane | Private state Blob, ACR, and Key Vault endpoints |
| SRE Agent networking | Dedicated delegated subnet in Azure VNet mode |
| Azure runner | `[self-hosted, Linux, X64, azure-private, contosopay]` |
| Code context | Read-only BYO GitHub App |
| GitHub write path | Entra-protected broker and a separate issues-write GitHub App |
| Incident | Pull Request sets `enable_slow_leak = true` |
| Remediation | Broker creates a constrained issue; Scenario C workflow opens an unmerged Pull Request |

The Terraform scenario is immutable. The state storage-account hash includes
subscription, prefix, and `C`; the state blob is
`<prefix>-C-<environment>.tfstate`. Never convert A or B state in place. Destroy
an active A or B GitHub Actions profile, delete its `DEPLOYMENT_SCENARIO`,
`TF_PREFIX`, and `TF_ENVIRONMENT` variables, and only then dispatch C as a new
isolated environment.

## Why the broker has external HTTPS ingress

Scenario C keeps the frontend public in the same Azure Container Apps
environment. Container Apps environment accessibility and private endpoints
apply at environment scope, while per-app internal ingress is intended for
traffic from the environment and connected network. Making the entire
environment internal would remove the required public frontend. Giving only the
broker internal ingress does not provide the managed Azure SRE Agent with the
required inbound MCP reachability.

The supported narrow design is therefore:

- frontend: external HTTPS;
- checkout-api and payment-service: internal ingress;
- remediation broker: external HTTPS, Scenario C only;
- Easy Auth: authentication required, dedicated Entra audience, and only the
  exact SRE Agent managed-identity principal allowed;
- broker: independently validates the bearer token's RS256 signature, tenant
  issuer, audience, expiry, and exact managed-identity object ID;
- Easy Auth token store: supplies `X-MS-TOKEN-AAD-ACCESS-TOKEN`, the only token
  header the broker accepts;
- broker: requires `x-ms-client-principal-id` to match the cryptographically
  verified `oid` claim;
- `/health`: static liveness response and the only authentication exclusion.

The broker exposes only two purpose-built MCP operations and cannot provide a
general GitHub token, shell, workflow dispatch, merge, or Azure write capability.

This choice follows the supported
[Container Apps networking model](https://learn.microsoft.com/azure/container-apps/networking)
and
[built-in authentication model](https://learn.microsoft.com/azure/container-apps/authentication).
Easy Auth protects external ingress before the request reaches application code;
independent JWT validation is defense in depth and remains effective during
authentication configuration updates.

## What the normal workflow provisions

Selecting Scenario C in the normal **deploy** workflow provisions:

- scenario-isolated private Terraform state and Blob private endpoint;
- regional application VNet and peering to the runner VNet;
- private ACR and Key Vault endpoints and private DNS links;
- dedicated Container Apps and SRE Agent subnets;
- ContosoPay, telemetry, alerting, and identities;
- broker identity with `AcrPull` and a custom key-read/sign-only role scoped to
  the single imported remediation key;
- Entra-protected broker Container App and Easy Auth configuration;
- broker image published once under the full commit SHA, locked, and deployed by
  exact manifest digest.

There is no independent broker switch. Scenario C implies the broker; A and B
cannot deploy it.

The remaining manual prerequisites are limited to:

1. create and install the two workload GitHub Apps;
2. import the remediation App PEM once as a non-exportable Key Vault RSA key;
3. create the dedicated Entra API registration and complete required consent;
4. configure SRE portal Code Access, MCP connector, tool policy, custom agent,
   knowledge, and response plan.

The workflow does not call undocumented Azure SRE Agent APIs.

## 1. Prepare the private runner and OIDC

Register a Linux x64 runner with all of these labels:

```text
[self-hosted, Linux, X64, azure-private, contosopay]
```

It needs Docker, Azure CLI, Terraform as installed by the workflow, outbound
HTTPS to GitHub and Azure control-plane endpoints, and network access to the
runner VNet/private-endpoint subnet.

Configure these nonsecret repository variables:

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`
- `SRE_AGENT_SPONSOR_GROUP_ID`
- `RUNNER_NETWORK_RG`
- `RUNNER_VNET_NAME`
- `RUNNER_PE_SUBNET_NAME`

Optional address-space overrides are:

- `APP_VNET_ADDRESS_SPACE`
- `APP_PE_SUBNET_PREFIX`
- `CONTAINER_APPS_SUBNET_PREFIX`
- `SRE_AGENT_SUBNET_PREFIX`

The address spaces must not overlap the runner VNet.

GitHub Actions authenticates to Azure with OIDC only. Do not create a client
secret, credentials JSON, storage key, or ACR admin credential.

The Scenario C deployment, apply, app-deployment, and destruction jobs select the
private runner labels. The incident-arming job and Scenario C remediation
issue-to-PR workflow operate only on GitHub and can run on GitHub-hosted runners;
they do not access private Azure endpoints.

## 2. Create the two GitHub Apps

GitHub Apps have no permissions by default. Assign the minimum repository
permissions and install each App only on this repository. See
[Choosing permissions for a GitHub App](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app).

### App 1: Code Access

Create a BYO GitHub App dedicated to SRE Agent repository indexing:

- Metadata: read;
- Contents: read;
- no Issues write;
- no Pull Requests write;
- no Actions, Administration, Secrets, or Workflows permissions;
- no webhook unless the current Code Access onboarding explicitly requires one.

Install it only on this repository. Configure its own credential through the
current **Builder > Code Access > Bring your own GitHub App** flow. This App and
its credential are not supplied to the broker.

Code Access provides source search, file reads, and incident-to-change
correlation. It is not a GitHub write connector. Azure SRE Agent documents the
distinct connection types in
[GitHub connector in Azure SRE Agent](https://learn.microsoft.com/azure/sre-agent/github-connector).

### App 2: remediation issue writer

Create a separate App for the broker:

- Metadata: read;
- Issues: read and write;
- Contents: no access;
- Pull Requests: no access;
- Actions and Workflows: no access;
- Administration, Secrets, and all unrelated permissions: no access;
- webhook: disabled.

Install it only on this repository. Record:

- numeric App ID;
- numeric installation ID;
- bot login, including `[bot]`;
- the downloaded PEM path until one-time import is complete.

The remediation App cannot push code or open a Pull Request. It can only create
and read the constrained issue used by the repository workflow.

## 3. Create the broker Entra application

Create a dedicated Microsoft Entra application registration for the broker API.
Expose this Application ID URI:

```text
api://<broker-api-client-id>
```

Use this client-credential scope:

```text
api://<broker-api-client-id>/.default
```

For `SRE_REMEDIATION_ENTRA_TOKEN_AUDIENCE`, record the API client ID GUID
without the `api://` prefix. Microsoft Entra v2 access tokens carry the API
client ID in the `aud` claim. Record that audience and the scope before
deployment. The workflow
provisions the selected Scenario C SRE Agent identity. After deployment, grant
that identity only the application permission needed to request the audience and
complete tenant admin consent if your tenant requires it.

Easy Auth validates issuer, audience, and allowed identity. The broker
independently verifies the token-store access token against the tenant JWKS and
requires the configured client-ID audience and SRE Agent managed-identity object
ID. It does not accept a caller-controlled `Authorization` header directly.

## 4. Configure Scenario C repository metadata

Set these nonsecret repository variables before running **deploy**:

- `SRE_REMEDIATION_ENTRA_API_CLIENT_ID`
- `SRE_REMEDIATION_ENTRA_TOKEN_AUDIENCE`
- `SRE_REMEDIATION_ENTRA_TOKEN_SCOPE`
- `SRE_GITHUB_APP_ID`
- `SRE_GITHUB_APP_INSTALLATION_ID`
- `SRE_GITHUB_APP_BOT_LOGIN`
- `SRE_GITHUB_APP_PRIVATE_KEY_NAME`

Use `github-app-signing-key` for
`SRE_GITHUB_APP_PRIVATE_KEY_NAME` unless governance requires another valid Key
Vault key name.

The workflow derives the broker's exact allowed caller from the Terraform-managed
Scenario C SRE Agent identity. It maps the key-name value to Terraform variable
`sre_remediation_github_app_private_key_name`. Terraform passes the unversioned
key URI to the broker as `GITHUB_APP_PRIVATE_KEY_KEY_URI` and exposes the same
nonsecret metadata as output `sre_remediation_broker_key_uri`.

Do not use a secret-name variable; no broker PEM secret is supported.

## 5. Deploy Scenario C

Run the manual **deploy** workflow with:

- **Scenario:** `C`;
- the same prefix and environment used by repository automation;
- the desired location;
- **Open incident PR:** as desired.

The preflight accepts an absent activation marker or the same active C target.
It rejects active A or B before private-runner or Azure work and instructs the
operator to destroy that profile first. After deployment succeeds, activate push
deployment by setting `TF_PREFIX` and `TF_ENVIRONMENT` to the deployed values,
then setting `DEPLOYMENT_SCENARIO=C` last under repository Actions variables.
Until then, automatic `apply-infra` and `deploy-apps` pushes are successful
no-ops. Images use the full 40-character commit SHA.

The workflow builds the broker image and provisions its supported infrastructure
as part of the normal deployment. Do not run the local deploy wrapper for C; it
supports A and B only and cannot reach the private endpoints.

Record these outputs from the run summary or Terraform:

- `resource_group_name`
- `key_vault_name`
- `sre_agent_subnet_id`
- `sre_remediation_broker_endpoint_url`
- `sre_remediation_broker_key_uri`
- `sre_remediation_broker_identity_principal_id`

## 6. Import the remediation signing key once

Run the repository key-import script from the private runner network, a peered
jumpbox, or another host that already resolves and reaches the private Key Vault
endpoint.

### Bash

```bash
./scripts/configure-github-app-key.sh \
  --vault-name "<scenario-c-vault>" \
  --private-key "./remediation-app.pem" \
  --key-name "github-app-signing-key"
```

### PowerShell

```powershell
pwsh ./scripts/configure-github-app-key.ps1 `
  -VaultName "<scenario-c-vault>" `
  -PrivateKeyPath "./remediation-app.pem" `
  -KeyName "github-app-signing-key"
```

The key name must match `SRE_GITHUB_APP_PRIVATE_KEY_NAME` and
`sre_remediation_github_app_private_key_name`.

The script:

1. requires existing private network access to the vault;
2. never enables public access or adds a firewall exception;
3. temporarily grants the signed-in operator **Key Vault Crypto Officer** if
   needed;
4. imports the PEM as a non-exportable RSA key;
5. limits the key operations to `sign`;
6. removes the temporary role assignment on exit.

Use `--force` or `-Force` only to import a deliberate new key version during
rotation.

After successful import, securely remove the local PEM according to your
organization's key-custody process. Never upload it as a Key Vault secret, place
it in Terraform state, or store it in GitHub.

Terraform grants the broker's managed identity a custom role with only
`Microsoft.KeyVault/vaults/keys/read` and
`Microsoft.KeyVault/vaults/keys/sign/action`, scoped to the individual imported
key resource rather than the vault. It receives no secret, decrypt,
unwrap, create, rotate, export, or delete permissions. At runtime the broker
receives the key URI, uses `KeyClient`/`CryptographyClient`, and requests RS256
signing from Key Vault. A Key Vault `get` operation exposes only public key
metadata; the broker never reads, downloads, or exports private key material.

See:

- [Key Vault key operations and algorithms](https://learn.microsoft.com/azure/key-vault/keys/about-keys-details)
- [Key Vault Azure RBAC](https://learn.microsoft.com/azure/key-vault/general/rbac-guide)
- [GitHub App JWT requirements](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app)
- [GitHub App installation tokens](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation)

GitHub requires an RS256 App JWT. The broker exchanges that short-lived JWT for
an installation token, whose permissions cannot exceed the App installation and
which expires after one hour.

## 7. Connect the SRE Agent to the private network

Terraform creates a dedicated subnet for the agent. The official service minimum
is currently `/28`; this demo deliberately uses and validates `/27` or larger for
additional headroom. The subnet is:

- delegated to `Microsoft.App/environments`;
- in the same region as the SRE Agent;
- not shared with Container Apps, private endpoints, or runners.

In the SRE Agent portal:

1. open **Settings > Workspace configuration > Network**;
2. select **Azure VNet**;
3. select the Terraform-created SRE Agent subnet;
4. save and verify private DNS resolution and outbound HTTPS.

Azure VNet mode controls outbound traffic only; it does not create an inbound
private endpoint for the agent. Platform traffic stays on managed
infrastructure, while private Azure data-plane traffic follows your VNet, DNS,
NSG, UDR, and firewall path. Configure the documented code-repository and remote
MCP reachability settings needed for GitHub and the broker.

See
[Azure SRE Agent network integration](https://learn.microsoft.com/azure/sre-agent/network-integration).

## 8. Configure Code Access and the broker connector

### Code Access

Under **Builder > Code Access**, choose **Bring your own GitHub App** and use App
1. Add this repository and confirm indexing. Do not use App 2 or the broker key
URI for this connection.

### Custom MCP connector

Under **Builder > Connectors**, add a Streamable HTTP MCP connector:

- endpoint: `sre_remediation_broker_endpoint_url`, ending in `/mcp`;
- authentication: managed identity;
- token scope: `SRE_REMEDIATION_ENTRA_TOKEN_SCOPE`;
- caller: the exact identity in Terraform output
  `sre_agent_identity_principal_ids`.

The endpoint is external HTTPS, but unauthenticated or wrong-principal requests
are rejected before broker tools run. See
[Azure SRE Agent MCP connectors](https://learn.microsoft.com/azure/sre-agent/mcp-connectors).

Enable only:

- `create_slow_leak_remediation_issue`;
- `get_slow_leak_remediation_status`.

## 9. Apply policy and response behavior

1. Grant only Reader-level workload access to the Scenario C resource group.
2. Connect Log Analytics/Application Insights.
3. Connect Azure Monitor as the incident platform.
4. Apply
   [`agent/tool-access-policy.portal.json`](../agent/tool-access-policy.portal.json)
   globally to deny Azure, Kubernetes, terminal, and Terraform writes.
5. Create `gitops-remediation` from
   [`agent/gitops-remediation-agent.md`](../agent/gitops-remediation-agent.md).
6. Assign Azure/Code read tools and only the two broker tools.
7. Add
   [`agent/knowledge/gitops-runbook.md`](../agent/knowledge/gitops-runbook.md).
8. Create a Sev2 payment-memory response plan in **Review** mode.

The agent prompt is behavioral guidance; Reader RBAC, Easy Auth, exact-principal
validation, GitHub App permissions, selected MCP tools, and the hard tool policy
are the enforcement layers.

## 10. Run and remediate the incident

Merge the generated incident Pull Request or create one with:

```bash
./scripts/trigger-incident-gitops.sh
```

```powershell
pwsh ./scripts/trigger-incident-gitops.ps1
```

`apply-infra` runs its Azure work on the private self-hosted runner, verifies the
Scenario C state, and applies the leak flag. The alert fires after the expected
memory rise.

The remediation path is:

1. the SRE Agent investigates with read-only Azure and Code Access tools;
2. in Review mode, a human approves the proposed broker call;
3. Easy Auth and the broker verify the exact caller;
4. the broker asks Key Vault to sign the GitHub App JWT;
5. GitHub returns a short-lived installation token;
6. the remediation App creates the fixed-title, fixed-marker issue;
7. `.github/workflows/sre-remediation-pr.yml` accepts only Scenario C and the
   trusted issue shape/author;
8. the workflow uses its scoped `GITHUB_TOKEN` to open an unmerged one-file Pull
   Request;
9. a human reviews and merges it;
10. normal `apply-infra` deploys the healthy flag through the private runner.

The broker does not open the Pull Request itself. The remediation issue and
workflow are Scenario C-only. Scenario B does not use either.

Verify that the Pull Request changes only:

```text
infra/leak.auto.tfvars
```

from `true` to `false`, then confirm memory and the alert return to healthy.

## 11. Rotate, reset, and destroy

Use the key-import script with `--force` or `-Force` to import a new remediation
key version, update/revoke GitHub keys according to policy, and verify broker
signing before removing the old version.

Reset the incident through a Pull Request:

```bash
./scripts/trigger-incident-gitops.sh --reset
```

Destroy with the manual **destroy** workflow using Scenario `C` and confirmation
`<prefix>-C-<environment>`. The Azure destroy work runs on the private runner and
verifies the C state first. The local teardown wrapper is not the Scenario C
path.

Remove portal-created SRE Agent resources, Entra consent, and both GitHub App
installations separately if no longer needed.

## References

- [Azure SRE Agent setup reference](sre-agent-setup.md)
- [Azure SRE Agent network integration](https://learn.microsoft.com/azure/sre-agent/network-integration)
- [Azure SRE Agent GitHub connector](https://learn.microsoft.com/azure/sre-agent/github-connector)
- [Azure SRE Agent MCP connectors](https://learn.microsoft.com/azure/sre-agent/mcp-connectors)
- [Container Apps networking](https://learn.microsoft.com/azure/container-apps/networking)
- [Container Apps authentication](https://learn.microsoft.com/azure/container-apps/authentication)
- [Key Vault RBAC](https://learn.microsoft.com/azure/key-vault/general/rbac-guide)
- [GitHub App permissions](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app)
