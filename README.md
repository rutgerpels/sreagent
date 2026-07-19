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
| **C** | Low access, Reader, Review mode; Terraform plus API reconciliation | Private ACR, Key Vault, and state endpoints; dedicated SRE Agent egress subnet; private self-hosted runner | Read-only Code Access; agent-initiated writes disabled until remote HTTP MCP supports the required nonsecret authentication |

Resource names and tags include the selected scenario. Remote state is isolated
too:

- the state storage-account hash includes subscription, prefix, and scenario;
- the blob key is `<prefix>-<scenario>-<environment>.tfstate`.

**Never change `scenario` in an existing state.** In-place profile conversion is
unsupported and is rejected by the deployment paths. To adopt another profile:

1. destroy the active scenario with the same scenario, prefix, and environment
   values that created it;
2. delete the repository `DEPLOYMENT_SCENARIO`, `TF_PREFIX`, and
   `TF_ENVIRONMENT` variables;
3. dispatch **deploy** with the new explicit scenario, which creates separate
   environment and state.

The workflow refuses to deploy a different scenario or automatic target while an
activation marker exists. This ordering prevents an automatic in-place profile
conversion; it does not reuse the destroyed profile's state.

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

Scenario C keeps the constrained remediation broker source dormant because the
managed service cannot reach per-app internal Container Apps ingress and current
remote Streamable-HTTP connector documentation does not expose the
managed-identity authentication flow required by the broker. The implementation
does not deploy another public endpoint or downgrade to a static bearer secret,
PAT, anonymous access, or network-only trust. The frontend is the only public
application; `checkout-api` and `payment-service` remain internal.

See the official documentation for
[Container Apps networking](https://learn.microsoft.com/azure/container-apps/networking),
[Container Apps authentication](https://learn.microsoft.com/azure/container-apps/authentication),
and
[Azure SRE Agent network integration](https://learn.microsoft.com/azure/sre-agent/network-integration).

## Deployment

### GitHub Actions

The manual **deploy** workflow supports A, B, and C. The scenario, prefix,
environment, and location are explicit dispatch inputs. A and B use GitHub-hosted
runners; C uses the labeled private self-hosted runner.

Configure these nonsecret repository variables before dispatch:

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

Do not set `DEPLOYMENT_SCENARIO`, `TF_PREFIX`, or `TF_ENVIRONMENT` before the
first deployment. Dispatch **deploy** with explicit A/B/C, prefix, and environment
inputs. After the deployment succeeds and you have reviewed its summary, activate
push deployment by setting these nonsecret repository Actions variables under
**Settings > Secrets and variables > Actions > Variables**, in this order:

- `TF_PREFIX` = the deployed prefix;
- `TF_ENVIRONMENT` = the deployed environment;
- `DEPLOYMENT_SCENARIO` = the deployed `A`, `B`, or `C` profile, set last as the
  activation marker.

This explicit operator step avoids adding a PAT or a third GitHub App with
repository Variables write permission to the deployment trust boundary.

An absent activation marker permits an explicit manual deploy. An existing valid
marker permits only the same scenario, prefix, and environment. A different
scenario or target fails in preflight with instructions to destroy the active
profile first and then clear all three profile variables. Terraform independently
verifies the scenario recorded in the isolated state before updating it.

Push-triggered `apply-infra` and `deploy-apps` behavior is fail closed:

- an unset `DEPLOYMENT_SCENARIO` emits a notice and a skipped-deployment summary,
  then succeeds without requesting Azure OIDC or a deployment runner;
- a nonempty value other than `A`, `B`, or `C` fails;
- an active scenario without valid `TF_PREFIX` and `TF_ENVIRONMENT` fails;
- a valid value runs against the persisted prefix and environment;
- explicit workflow dispatch remains validated and may run while the repository
  marker is absent, but it cannot disagree with an active scenario.

The deployment workflows provision exactly one SRE Agent for the selected
profile. Optional `SRE_AGENT_MODEL_PROVIDER` and `SRE_AGENT_MODEL_NAME`
variables override the default `MicrosoftFoundry` / `Automatic` model
configuration.

For Scenario C, Terraform/AzAPI also owns the agent VNet, sandbox, identities,
telemetry, budget, incident platform, and first-party connector child resources.
The workflow then runs `scripts/reconcile-sre-agent.sh` to apply and verify the
global tool policy, custom agent, response plan, health schedule, knowledge, and
optional Code Access from `agent/scenario-c/manifest.json`.

Each full commit-SHA image is published once, write/delete locked in ACR, resolved
to a `sha256` manifest digest, and deployed by digest. Do not use mutable tags
such as `latest`. Partially created application state from an older tag-based
revision has no trusted digest map for recovery; replace that isolated scenario
environment rather than guessing image ownership.

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

The teardown verifies the scenario recorded in state before destroying. If you
intend to select another scenario, delete `DEPLOYMENT_SCENARIO`, `TF_PREFIX`, and
`TF_ENVIRONMENT` only after the destroy succeeds. Leaving the scenario variable
absent keeps push automation in its safe no-op state.

## Scenario C GitHub identities and key custody

The Scenario C design separates two workload GitHub Apps:

1. a read-only bring-your-own App for SRE Agent **Code Access**;
2. a future issues-write remediation App used only by the dormant broker.

Code Access provides repository context and correlation. It is not the
write-capable broker credential. Store its PEM as a Key Vault secret and set
`SRE_CODE_ACCESS_ENABLED`, `SRE_CODE_ACCESS_GITHUB_APP_CLIENT_ID`, and
`SRE_CODE_ACCESS_GITHUB_APP_PRIVATE_KEY_SECRET_NAME` as nonsecret repository
variables. The workflow passes only the secret URI and derives the agent managed
identity from Terraform output.

The proposed remediation App has only Metadata read and Issues read/write on
this repository. Its broker source is retained but no broker resources are
deployed until the service supports the required remote HTTP managed-identity
authentication. In the current preview, a human initiates the one-file
remediation Pull Request.

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

Do not upload the **remediation** PEM as a Key Vault secret and do not place it
in Terraform, GitHub Actions, repository files, or shell history. Code Access
uses its own separate PEM secret. See
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
- Scenario C performs no PAT-based GitHub writes and rejects unsupported remote
  MCP authentication.

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
| `scripts/` | Local A/B deploy, teardown, incident triggers, Scenario C key import, and SRE Agent reconciliation |
| `agent/` | Declarative Scenario C manifest, tool policy, custom-agent prompts, and runbook |
| `docs/` | Scenario guides and SRE Agent reference |

## Further reading

- [Azure SRE Agent GitHub connector](https://learn.microsoft.com/azure/sre-agent/github-connector)
- [Azure SRE Agent MCP connectors](https://learn.microsoft.com/azure/sre-agent/mcp-connectors)
- [Azure SRE Agent infrastructure as code](https://learn.microsoft.com/azure/sre-agent/deploy-iac)
- [Azure SRE Agent API reference](https://learn.microsoft.com/azure/sre-agent/api-reference)
- [GitHub App permissions](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app)
- [Fine-grained personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
