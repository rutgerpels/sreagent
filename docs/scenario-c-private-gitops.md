# Scenario C — Private-network GitOps

This guide is the enterprise version of the GitOps demo. It keeps the same
Pull Request based incident and remediation flow as
[Scenario B](scenario-b-gitops.md), but moves the SRE Agent into **Azure VNet**
network control mode so it can reach private Azure data-plane endpoints such as
Key Vault through your enterprise network path.

**The story this scenario tells:** the SRE Agent has Reader-level workload
access, direct Azure mutation tools are denied, and remediation still happens by
Pull Request. Unlike Scenario B, Code Access uses **Bring your own GitHub App**
with the private key imported as a Key Vault key. No-PAT PR creation goes through
the broker/API, which uses a GitHub App installation token behind the
scenes and triggers the repository workflow that opens the remediation PR.

Use this mode for security, platform, or enterprise architecture audiences. Use
[Scenario B](scenario-b-gitops.md) for the faster public-endpoint PAT demo.

You will work through eight parts:

1. [Bootstrap and deploy the GitOps baseline](#part-1--bootstrap-and-deploy-the-gitops-baseline)
2. [Prepare the SRE Agent network subnet](#part-2--prepare-the-sre-agent-network-subnet)
3. [Enable SRE Agent Azure VNet mode](#part-3--enable-sre-agent-azure-vnet-mode)
4. [Create the BYO GitHub App](#part-4--create-the-byo-github-app)
5. [Store the GitHub App credential in private Key Vault](#part-5--store-the-github-app-credential-in-private-key-vault)
6. [Connect Code Access with BYO GitHub App](#part-6--connect-code-access-with-byo-github-app)
7. [Configure the no-PAT PR path and response plan](#part-7--configure-the-no-pat-pr-path-and-response-plan)
8. [Run the incident and reset](#part-8--run-the-incident-and-reset)

---

## Part 1 — Bootstrap and deploy the GitOps baseline

Follow [Scenario B, Part 1](scenario-b-gitops.md#part-1--bootstrap-the-pipeline-one-time)
and [Part 2](scenario-b-gitops.md#part-2--deploy-the-environment-with-cicd).
That gives you:

- the GitHub Actions OIDC deployment identity;
- the private self-hosted runner and private endpoint path used by the pipeline;
- ContosoPay, telemetry, Azure Monitor alerting, and private Key Vault;
- the GitOps `apply-infra` workflow and planted-leak Pull Request flow.

Create the Scenario B SRE Agent as described in
[Scenario B, Part 3](scenario-b-gitops.md#part-3--create-the-sre-agent), but do
not configure GitHub Code Access yet. You will do that after VNet integration and
Key Vault key import are ready.

---

## Part 2 — Prepare the SRE Agent network subnet

Azure SRE Agent network integration requires a subnet dedicated to the agent.
Do not reuse the Container Apps environment subnet, private endpoint subnet, or
self-hosted runner subnet.

Subnet requirements from
[Azure SRE Agent network integration](https://learn.microsoft.com/azure/sre-agent/network-integration):

| Requirement | Value |
| --- | --- |
| **Size** | `/28` or larger. Use `/26` if you expect larger fleets or bursty concurrent sessions. |
| **Delegation** | `Microsoft.App/environments` |
| **Region** | Same region as the SRE Agent resource |
| **Use** | Dedicated to SRE Agent network integration |

If your network team owns VNet changes, ask them for a subnet that meets those
requirements and can resolve/reach the demo Key Vault private endpoint. If you
can create it yourself, use a pattern like this:

```bash
NETWORK_RG="<network-resource-group>"
VNET_NAME="<vnet-name>"
SUBNET_NAME="snet-sre-agent"
ADDRESS_PREFIX="10.42.8.0/28"

az network vnet subnet create \
  --resource-group "$NETWORK_RG" \
  --vnet-name "$VNET_NAME" \
  --name "$SUBNET_NAME" \
  --address-prefixes "$ADDRESS_PREFIX" \
  --delegations Microsoft.App/environments
```

Confirm private Key Vault resolution from that VNet path:

- the VNet is linked to `privatelink.vaultcore.azure.net`;
- `<vault-name>.vault.azure.net` resolves to the Key Vault private endpoint IP;
- NSG, UDR, and firewall rules allow outbound HTTPS to that private endpoint.

---

## Part 3 — Enable SRE Agent Azure VNet mode

1. Open the SRE Agent in the Azure portal.
2. Go to **Settings → Workspace configuration → Network**.
3. Select **Azure VNet** as the network control mode.
4. Select **Browse subnets**.
5. Choose the subscription, resource group, VNet, and dedicated delegated subnet
   from Part 2.
6. Save.

In Azure VNet mode, non-platform outbound traffic to Azure resources routes
through your VNet. Platform services still use the Azure SRE Agent managed
infrastructure. If the agent must reach public GitHub SaaS from a locked-down
network, either allow the required GitHub hostnames through your firewall or use
the **Code repositories** infra-network toggle as a transitional exception.

> Preview limitation: SRE Agent network integration controls outbound egress
> only. It does not create an inbound private endpoint for the agent.

---

## Part 4 — Create the BYO GitHub App

1. In GitHub, open **Settings → Developer settings → GitHub Apps → New GitHub
   App**. For an organisation-owned repository, create it under the
   organisation's settings instead.
2. Set:
   - **GitHub App name:** a unique name, for example
     `contosopay-sre-agent`;
   - **Homepage URL:** `https://sre.azure.com`;
   - **Webhook → Active:** unchecked.
3. Under **Repository permissions**, set:
   - **Contents:** **Read-only**;
   - **Issues:** **Read and write**;
   - **Metadata:** **Read-only**.
4. Leave **Pull requests**, **Actions**, **Administration**, **Secrets**, and
   unrelated permissions at **No access**. The remediation PR is created by the
   repository workflow with its short-lived `GITHUB_TOKEN`; the GitHub App only
   creates the constrained trigger issue through the broker.
5. Under **Where can this GitHub App be installed?**, keep it limited to the
   owning account unless broader installation is required. Select
   **Create GitHub App**.
6. On the app's **General** page, record the **Client ID** that starts with
   `Iv...`. This is different from the numeric App ID.
7. Select **Generate a private key** and keep the downloaded PEM file local.
8. Open **Install App**, install it on the repository owner, choose **Only select
   repositories**, and select this repository only.

---

## Part 5 — Store the GitHub App credential in private Key Vault

Store the downloaded GitHub App PEM in the form each component expects:

- **SRE Agent Code Access** expects a Key Vault **key** URI in the form
  `.../keys/<name>`.
- **The broker/API** reads the same PEM from a Key Vault **secret** so it
  can mint a short-lived GitHub App installation token.

Run this from a VNet-connected jumpbox, private self-hosted runner, or other
machine that can reach the private Key Vault endpoint:

```bash
KEY_VAULT_NAME="<demo-key-vault-name>"
KEY_NAME="sre-agent-github-app-key"
PEM_FILE="./<downloaded-github-app-key>.pem"

az keyvault key import \
  --vault-name "$KEY_VAULT_NAME" \
  --name "$KEY_NAME" \
  --pem-file "$PEM_FILE" \
  --ops sign

KEY_URI="https://${KEY_VAULT_NAME}.vault.azure.net/keys/${KEY_NAME}"
echo "$KEY_URI"
```

Grant the SRE Agent managed identity **Key Vault Crypto User** on that Key Vault
or on the imported key scope. Wait a few minutes for RBAC propagation.

Verify the imported key:

```bash
az keyvault key show \
  --vault-name "$KEY_VAULT_NAME" \
  --name "$KEY_NAME" \
  --query "{kid:key.kid,kty:key.kty,ops:key.key_ops,enabled:attributes.enabled}" \
  --output table
```

Expected:

- `enabled` is `true`;
- `kty` is `RSA` or `RSA-HSM`;
- `ops` includes `sign`.

If you use the broker/API for no-PAT PR creation, also store the PEM as a Key
Vault secret using the secret name configured by
`sre_remediation_github_app_private_key_secret_name`:

```bash
az keyvault secret set \
  --vault-name "$KEY_VAULT_NAME" \
  --name "github-app-private-key" \
  --file "$PEM_FILE"
```

Delete the local PEM copy after the key import is verified. Do not put the PEM in
Terraform state, GitHub secrets, workflow inputs, shell history, or repository
files.

---

## Part 6 — Connect Code Access with BYO GitHub App

1. In SRE Agent, open **Builder → Code Access → Add repositories**.
2. Choose **GitHub**, enter `github.com`, continue to **Authenticate**, and
   select **Bring your own GitHub App**.
3. Enter:
   - **Client ID:** the `Iv...` Client ID from the GitHub App;
   - **Private key URI:** the unversioned Key Vault key URI, for example
     `https://<vault-name>.vault.azure.net/keys/sre-agent-github-app-key`;
   - **Key Vault identity:** the SRE Agent managed identity that has
     **Key Vault Crypto User**.
4. Select **Connect**, then add this repository and save.

---

## Part 7 — Configure the no-PAT PR path and response plan

Follow [Scenario B, Part 4c](scenario-b-gitops.md#4c-grant-reader-level-workload-access)
and [Part 5a](scenario-b-gitops.md#5a-apply-the-hard-tool-access-policy) to grant
Reader-level workload access and apply the hard tool access policy. Then use the
broker/API path for PR creation:

1. Enable the optional remediation broker in the deploy/apply workflow variables:
   - `ENABLE_SRE_REMEDIATION_BROKER=true`;
   - `SRE_REMEDIATION_CALLER_PRINCIPAL_ID=<SRE Agent managed identity object ID>`;
   - `SRE_REMEDIATION_ENTRA_API_CLIENT_ID=<broker API app client ID>`;
   - `SRE_REMEDIATION_ENTRA_TOKEN_AUDIENCE=api://<broker API app client ID>`;
   - `SRE_REMEDIATION_ENTRA_TOKEN_SCOPE=api://<broker API app client ID>/.default`;
   - `SRE_GITHUB_APP_ID=<numeric GitHub App ID>`;
   - `SRE_GITHUB_APP_INSTALLATION_ID=<numeric installation ID>`;
   - `SRE_GITHUB_APP_BOT_LOGIN=<app-slug>[bot]`;
   - `SRE_GITHUB_APP_PRIVATE_KEY_SECRET_NAME=github-app-private-key`.
2. Re-run the deploy workflow so Terraform creates the broker Container App and
   prints `sre_remediation_broker_endpoint_url`.
3. In SRE Agent, add a custom MCP connector that points to that `/mcp` endpoint
   and authenticates with managed identity using
   `api://<broker API app client ID>/.default`.
4. Create the `gitops-remediation` custom agent using
   [`agent/gitops-remediation-agent.md`](../agent/gitops-remediation-agent.md).
   Select only Code Access read tools, Azure read tools,
   `create_slow_leak_remediation_issue`, and
   `get_slow_leak_remediation_status`.
5. Add [`agent/knowledge/gitops-runbook.md`](../agent/knowledge/gitops-runbook.md)
   as knowledge and create the same response plan as
   [Scenario B, Part 5d](scenario-b-gitops.md#5d-create-the-response-plan), routed
   to `gitops-remediation`.

The broker exposes only two SRE-specific operations. It does not give the agent a
general GitHub token, terminal access, workflow-dispatch access, or direct Azure
write access.

This keeps the enterprise network posture separate from the GitOps enforcement
boundary: RBAC and tool policy control what the agent may do, while Azure VNet
mode controls where the agent may send traffic.

---

## Part 8 — Run the incident and reset

Run the same GitOps incident and reset flow as
[Scenario B, Part 6](scenario-b-gitops.md#part-6--run-the-incident) and
[Part 7](scenario-b-gitops.md#part-7--reset-and-clean-up).

The expected investigation and remediation are the same: the agent correlates the
memory leak to the incident Pull Request, calls the broker/API, and the
repository workflow opens a remediation Pull Request that sets
`enable_slow_leak=false` for a human to merge.

After the demo, remove or rotate the GitHub App private key, uninstall the GitHub
App if it is no longer needed, and keep or remove the SRE Agent VNet subnet based
on your environment's governance process.
