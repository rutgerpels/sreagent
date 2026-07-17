# ContosoPay and Azure SRE Agent

ContosoPay is a reproducible Azure SRE Agent demo built from three small
Node.js/TypeScript services on Azure Container Apps:

- `frontend` is the public checkout application.
- `checkout-api` is available only through internal Container Apps ingress.
- `payment-service` is internal and contains a feature-flagged, recoverable
  memory leak.

The environment includes Azure Container Registry, Key Vault, Application
Insights, Log Analytics, Azure Monitor alerting, and optional Azure Managed
Grafana. Terraform owns the Azure resources; GitHub Actions uses OpenID Connect
(OIDC), not stored Azure credentials.

Start with the [scenario chooser](docs/run-of-show.md), then follow one scenario
guide:

- [Scenario A: autonomous direct remediation](docs/scenario-a-direct.md)
- [Scenario B: public-endpoint GitOps](docs/scenario-b-gitops.md)
- [Scenario C: private-network GitOps](docs/scenario-c-private-gitops.md)

## Immutable deployment profiles

The single Terraform variable `scenario` selects one immutable derived profile.
It is not a collection of independent security toggles.

| Profile | SRE Agent | Network and runner | GitHub remediation |
| --- | --- | --- | --- |
| **A** | High access, Contributor, Autonomous mode | Public control endpoints; GitHub-hosted workflow jobs or the local wrapper | Direct Azure remediation; no GitOps write connector and no broker |
| **B** | Low access, Reader, Review mode | Public endpoints protected by RBAC and TLS; GitHub-hosted workflow jobs or the local wrapper | Built-in GitHub MCP connector with a short-lived fine-grained PAT; no broker |
| **C** | Low access, Reader, Review mode | Private ACR, Key Vault, and state endpoints; dedicated SRE Agent subnet; private self-hosted runner | Entra-protected custom MCP broker using a separate remediation GitHub App; no PAT for writes |

Resource names and tags include the selected scenario. Remote state is isolated
too:

- the state storage-account hash includes subscription, prefix, and scenario;
- the blob key is `<prefix>-<scenario>-<environment>.tfstate`.

**Never change `scenario` in an existing state.** In-place profile conversion is
unsupported and is rejected by the deployment paths. To adopt another profile:

1. deploy the new scenario, which creates a separate environment and state;
2. validate the new environment;
3. explicitly destroy the old scenario with the same scenario, prefix, and
   environment values that created it.

The state resource group can contain isolated state accounts or blobs for other
profiles. Do not delete it indiscriminately.

## Architecture

```text
Internet --TLS--> frontend (external ingress)
                     |
                     | internal HTTPS
                     v
                checkout-api ---> payment-service
                                      |
                                      | feature flag
                                      v
                               deterministic slow leak

Managed identities --> Key Vault (RBAC)
Managed identities --> ACR pull (admin disabled)
OpenTelemetry ------> Application Insights and Log Analytics
Azure Monitor ------> memory alert ------> Azure SRE Agent
```

Scenarios A and B keep the deployment control endpoints public so a GitHub-hosted
runner or the local deployment wrapper can reach them. Authentication remains
RBAC-based and transport remains TLS-only.

Scenario C adds a regional VNet, private endpoints for ACR and Key Vault, private
Terraform-state access from a peered runner VNet, and a dedicated delegated SRE
Agent subnet. The required runner labels are:

```text
[self-hosted, Linux, X64, azure-private, contosopay]
```

The Scenario C remediation broker is the only application endpoint besides the
frontend with external ingress. This is deliberate: a single Container Apps
environment must keep the frontend public, while per-app internal ingress and
environment-level private endpoints do not provide the managed SRE Agent with
the required inbound reachability. The broker therefore uses external HTTPS,
Container Apps built-in authentication (Easy Auth), a dedicated Entra audience,
an allow-list containing the exact SRE Agent principal, and application-level
RS256 token verification against the tenant issuer, audience, and exact managed
identity object ID. The broker accepts only Easy Auth's token-store
`X-MS-TOKEN-AAD-ACCESS-TOKEN` header and requires the platform principal header
to match the cryptographically verified `oid` claim. The business services
remain internal.

See the official documentation for
[Container Apps networking](https://learn.microsoft.com/azure/container-apps/networking),
[Container Apps authentication](https://learn.microsoft.com/azure/container-apps/authentication),
and
[Azure SRE Agent network integration](https://learn.microsoft.com/azure/sre-agent/network-integration).

## Deployment

### GitHub Actions

The manual **deploy** workflow supports A, B, and C. Select the scenario
explicitly. A and B use GitHub-hosted runners; C uses the labeled private
self-hosted runner.

Configure these nonsecret repository variables for OIDC:

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`
- `DEPLOYMENT_SCENARIO`
- `SRE_AGENT_SPONSOR_GROUP_ID`

`DEPLOYMENT_SCENARIO` must be exactly `A`, `B`, or `C`. It is the target for
automatic `apply-infra` and `deploy-apps` runs. A manual workflow-dispatch
selection must match the repository variable. This prevents a manual run and
subsequent push automation from targeting different profiles.

The deployment workflows provision exactly one SRE Agent for the selected
profile. `SRE_AGENT_SPONSOR_GROUP_ID` is the Entra sponsor group object ID.
Optional `SRE_AGENT_MODEL_PROVIDER` and `SRE_AGENT_MODEL_NAME` variables override
the default `MicrosoftFoundry` / `gpt-5` model configuration.

The workflows reject a missing or invalid automatic-deployment scenario and
verify the scenario stored in state. Each full commit-SHA image is published
once, write/delete locked in ACR, resolved to a `sha256` manifest digest, and
deployed by digest. Do not use mutable tags such as `latest`.

Partially created application state from an older tag-based revision has no
trusted digest map for recovery. Replace that isolated scenario environment
rather than guessing image ownership.

For Scenario A, set **Open incident PR** to `false`; use the direct incident
script instead. Scenarios B and C use the incident Pull Request flow.

### Local wrapper for A or B

The local wrapper supports Scenario A and B only. It uses the signed-in Azure
user and Azure AD data-plane authentication for state. It defaults the
publication tag to the current full commit SHA, locks it, and deploys its
resolved manifest digest:

```bash
./scripts/deploy.sh --scenario A
./scripts/deploy.sh --scenario B
```

```powershell
pwsh ./scripts/deploy.ps1 -Scenario A
pwsh ./scripts/deploy.ps1 -Scenario B
```

Scenario C must use the normal **deploy** workflow from the private runner
because its state, ACR, and Key Vault endpoints are private.

### Destroy one profile

Use the manual **destroy** workflow and select the exact scenario, prefix, and
environment. Its confirmation value is
`<prefix>-<scenario>-<environment>`. Alternatively, for a locally deployed A or
B profile:

```bash
./scripts/teardown.sh --scenario A
```

The teardown verifies the scenario recorded in state before destroying.

## Scenario C GitHub identities and key custody

Scenario C uses two separate GitHub Apps:

1. a read-only bring-your-own App for SRE Agent **Code Access**;
2. an issues-write remediation App used only by the broker.

Code Access provides repository context and correlation. It is not the
write-capable broker credential. The remediation App has only Metadata read and
Issues read/write on this repository. It creates a constrained remediation
issue; the Scenario C-only `sre-remediation-pr` workflow validates that issue and
uses its short-lived `GITHUB_TOKEN` to open an unmerged one-file Pull Request.

The remediation App PEM is imported once, from the private network, as a
non-exportable RSA Key Vault **key** with only the `sign` operation:

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

The script never opens public network access. It temporarily grants the signed-in
operator **Key Vault Crypto Officer**, imports the key, and removes that temporary
assignment. Terraform grants the broker a custom role containing only key
metadata read and sign data actions. The broker receives only the key URI,
creates a `CryptographyClient`, and asks Key Vault to perform RS256 signing. It
never reads or downloads the private key.

Use only these names:

- Terraform: `sre_remediation_github_app_private_key_name`
- repository variable: `SRE_GITHUB_APP_PRIVATE_KEY_NAME`
- broker setting: `GITHUB_APP_PRIVATE_KEY_KEY_URI`
- Terraform output: `sre_remediation_broker_key_uri`

Do not upload the PEM as a Key Vault secret and do not place it in Terraform,
GitHub Actions, repository files, or shell history. See
[Key Vault key operations](https://learn.microsoft.com/azure/key-vault/keys/about-keys-details),
[Key Vault RBAC](https://learn.microsoft.com/azure/key-vault/general/rbac-guide),
[GitHub App JWT authentication](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app),
and
[GitHub App installation authentication](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation).

## Security invariants

- CI/CD authenticates to Azure with OIDC only; no Azure client secret or
  credentials JSON is stored.
- No credential, PAT, PEM, tenant ID, subscription ID, or customer-identifying
  value is committed.
- Key Vault uses Azure RBAC, purge protection, and soft delete.
- ACR admin and anonymous access are disabled; pulls use managed identity.
- Role assignments are least-privilege and resource-scoped except where the
  managed SRE Agent requires broader monitoring scope.
- Ingress is TLS-only. `checkout-api` and `payment-service` are never public.
- Scenario B's PAT is fine-grained, single-repository, minimum-permission, and
  short-lived; revoke it after the demo.
- Scenario C performs no PAT-based GitHub writes.

## Repository map

| Path | Purpose |
| --- | --- |
| `infra/` | Scenario-derived Terraform profiles and Azure resources |
| `src/` | Three services plus the Scenario C-only broker |
| `.github/workflows/deploy.yml` | Full scenario-aware deployment |
| `.github/workflows/apply-infra.yml` | Scenario-aware infrastructure and flag apply |
| `.github/workflows/deploy-apps.yml` | Full-SHA image build and app update |
| `.github/workflows/destroy.yml` | Verified profile-specific teardown |
| `.github/workflows/sre-remediation-pr.yml` | Scenario C-only issue-to-PR remediation |
| `scripts/` | Local A/B deploy, teardown, incident triggers, and Scenario C key import |
| `agent/` | Tool policy, custom-agent prompts, and runbook |
| `docs/` | Scenario guides and SRE Agent reference |

## Further reading

- [Azure SRE Agent GitHub connector](https://learn.microsoft.com/azure/sre-agent/github-connector)
- [Azure SRE Agent MCP connectors](https://learn.microsoft.com/azure/sre-agent/mcp-connectors)
- [GitHub App permissions](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app)
- [Fine-grained personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
