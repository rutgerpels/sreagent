# Deployment and state reference

Operational detail shared by all three scenario walkthroughs. Read the
[scenario chooser](run-of-show.md) first; come here when a walkthrough links to
a specific section.

---

## GitHub Actions OIDC

Deployment authenticates to Azure with **OpenID Connect federation only**. No
Azure client secret, credentials JSON, storage key, or ACR admin credential is
created, stored, or committed.

Configure a federated credential on your deployment identity that trusts this
repository, then set these three **nonsecret** repository Actions variables
under **Settings → Secrets and variables → Actions → Variables**:

| Variable | Value |
| --- | --- |
| `AZURE_CLIENT_ID` | Client ID of the federated deployment identity |
| `AZURE_TENANT_ID` | Entra tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Target subscription ID |

Grant the identity only the control-plane and role-assignment access this demo
needs, scoped as narrowly as your bootstrap design permits.

Scenario C additionally requires `RUNNER_NETWORK_RG`, `RUNNER_VNET_NAME`, and
`RUNNER_PE_SUBNET_NAME`.

---

## Profile and state safety

The single Terraform variable `scenario` selects one **immutable derived
profile**. It is not a set of independent toggles.

| Profile | SRE Agent | Network and runner | GitHub remediation |
| --- | --- | --- | --- |
| **A** | High access, Contributor, Autonomous | Public control endpoints; GitHub-hosted jobs or the local wrapper | Direct Azure remediation; no write connector |
| **B** | Low access, Reader, Review | Public endpoints protected by RBAC and TLS; GitHub-hosted jobs or the local wrapper | Code Access, signed in with a user account (OAuth); no connector and no token |
| **C** | Low access, Reader, Review; Terraform plus API reconciliation | Private ACR, Key Vault, and state endpoints; dedicated agent egress subnet; private self-hosted runner | Code Access; the agent opens the remediation pull request and a human merges it |

Resource names and tags include the selected scenario. State is isolated too:

- the state storage-account name hashes subscription, prefix, and scenario;
- the blob key is `<prefix>-<scenario>-<environment>.tfstate`.

### Never change `scenario` in an existing state

In-place profile conversion is unsupported and is rejected by every deployment
path. To adopt another profile:

1. destroy the active scenario using the same scenario, prefix, and environment
   values that created it;
2. delete the `DEPLOYMENT_SCENARIO`, `TF_PREFIX`, and `TF_ENVIRONMENT`
   repository variables;
3. dispatch **deploy** with the new explicit scenario, which creates a separate
   environment and state.

The workflow refuses to deploy a different scenario while an activation marker
exists. That ordering prevents an accidental in-place conversion; it does not
reuse the destroyed profile's state.

The shared state resource group can hold isolated state accounts or blobs for
other profiles. Do not delete it indiscriminately.

---

## The activation marker

After a successful manual **deploy**, review its summary, then set these
nonsecret repository Actions variables **in this order**:

1. `TF_PREFIX` — the deployed prefix
2. `TF_ENVIRONMENT` — the deployed environment
3. `DEPLOYMENT_SCENARIO` — the deployed `A`, `B`, or `C`, **set last** as the
   activation marker

This explicit operator step avoids adding a PAT or a third GitHub App with
repository-variable write permission to the deployment trust boundary.

Push-triggered `apply-infra` and `deploy-apps` behaviour is fail-closed:

| `DEPLOYMENT_SCENARIO` | Behaviour |
| --- | --- |
| Unset | Emits a notice and a skipped-deployment summary, then succeeds without requesting Azure OIDC or a deployment runner |
| Nonempty but not `A`, `B`, or `C` | Fails |
| Valid, but `TF_PREFIX` or `TF_ENVIRONMENT` missing | Fails |
| Valid, with both set | Runs against the persisted prefix and environment |

Explicit workflow dispatch stays validated and may run while no marker exists,
but it can never disagree with an active scenario. Terraform independently
verifies the scenario recorded in state before updating it.

---

## Immutable images

Each full-commit-SHA image is published once, write/delete locked in ACR,
resolved to a `sha256` manifest digest, and deployed **by digest**.

Do not use mutable tags such as `latest`. Application state created from an
older tag-based revision has no trusted digest map for recovery — replace that
isolated scenario environment rather than guessing image ownership.

---

## Local wrapper (Scenario A or B only)

The local wrapper uses your signed-in Azure user and Azure AD data-plane
authentication for state. It defaults the publication tag to the current full
commit SHA, locks it, and deploys the resolved manifest digest.

```bash
az login
./scripts/deploy.sh --scenario A --prefix contosopay --env demo
```

```powershell
az login
pwsh ./scripts/deploy.ps1 -Scenario B -Prefix contosopay -Environment demo
```

It is not a substitute for OIDC in CI. Scenario C must use the **deploy**
workflow from the private runner, because its state, ACR, and Key Vault
endpoints are private.

---

## Destroying one profile

Use the manual **destroy** workflow and select the exact scenario, prefix, and
environment that created the environment:

| Input | Notes |
| --- | --- |
| Scenario | Must match the state |
| Resource name prefix | Must match the deployment |
| Environment label | Must match the deployment |
| Recovery: force delete resource group | Recovery only — deletes the exact resource group recorded in verified state, then resets that state |
| Delete state blob after destroy | Removes this scenario/environment blob; the shared state account is retained |

Scenario C runs destroy on the private runner. For a locally deployed A or B
environment:

```bash
./scripts/teardown.sh --scenario A --prefix contosopay --env demo
```

Teardown verifies the scenario recorded in state before destroying anything.
Never destroy by guessed resource-name patterns.

If you intend to select another scenario, delete `DEPLOYMENT_SCENARIO`,
`TF_PREFIX`, and `TF_ENVIRONMENT` **only after** the destroy succeeds. Leaving
the marker absent keeps push automation in its safe no-op state.

---

## Agent model configuration

The deployment workflows provision exactly one SRE Agent for the selected
profile. Optional `SRE_AGENT_MODEL_PROVIDER` and `SRE_AGENT_MODEL_NAME`
variables override the default `MicrosoftFoundry` / `Automatic` configuration.

For Scenario C, Terraform and AzAPI also own the agent VNet, sandbox,
identities, telemetry, budget, incident platform, and first-party connector
child resources; the workflow then runs `scripts/reconcile-sre-agent.sh` to
apply and verify the global tool policy, custom agent, response plan, health
schedule, knowledge, and optional Code Access from
`agent/scenario-c/manifest.json`.

---

## Security invariants

These hold in every scenario:

- CI/CD authenticates to Azure with OIDC only; no Azure client secret or
  credentials JSON is stored.
- No credential, PAT, PEM, tenant ID, subscription ID, or customer-identifying
  value is committed.
- Key Vault uses Azure RBAC, purge protection, and soft delete.
- ACR admin and anonymous access are disabled; pulls use managed identity.
- Role assignments are least-privilege and resource-scoped, except where the
  managed SRE Agent requires broader monitoring scope.
- Ingress is TLS-only. `checkout-api` and `payment-service` are never public.
- Scenario B creates no GitHub credential at all; its write path is the OAuth
  Code Access connection, which is interactive and nothing to store or revoke.
- Scenario C performs no PAT-based GitHub writes and rejects unsupported remote
  MCP authentication.

---

## Repository map

| Path | Purpose |
| --- | --- |
| `infra/` | Scenario-derived Terraform profiles and Azure resources |
| `src/` | The three ContosoPay services |
| `.github/workflows/deploy.yml` | Full scenario-aware deployment |
| `.github/workflows/apply-infra.yml` | Scenario-aware infrastructure and flag apply |
| `.github/workflows/deploy-apps.yml` | Full-SHA image build and app update |
| `.github/workflows/destroy.yml` | Verified profile-specific teardown |
| `scripts/` | Local A/B deploy, teardown, incident triggers, SRE Agent reconciliation |
| `agent/` | Declarative Scenario C manifest, tool policy, custom-agent prompts, runbook |
| `docs/` | Scenario walkthroughs and references |

---

## References

- [Azure SRE Agent GitHub connector](https://learn.microsoft.com/azure/sre-agent/github-connector)
- [Azure SRE Agent MCP connectors](https://learn.microsoft.com/azure/sre-agent/mcp-connectors)
- [Azure SRE Agent infrastructure as code](https://learn.microsoft.com/azure/sre-agent/deploy-iac)
- [Azure SRE Agent API reference](https://learn.microsoft.com/azure/sre-agent/api-reference)
- [GitHub App permissions](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app)
- [Fine-grained personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
