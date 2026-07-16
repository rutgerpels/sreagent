# Scenario C — Private-network GitOps

This guide is the enterprise version of the GitOps demo. It keeps the same
Pull Request based incident and remediation flow as
[Scenario B](scenario-b-gitops.md), but moves the SRE Agent into **Azure VNet**
network control mode so it can reach private Azure data-plane endpoints such as
Key Vault through your enterprise network path.

**The story this scenario tells:** the SRE Agent has Reader-level workload
access, direct Azure mutation tools are denied, and remediation still happens by
Pull Request. Unlike Scenario B, GitHub access uses **Bring your own GitHub App**
with the private key imported as a Key Vault key, and the agent uses a dedicated
delegated subnet for outbound traffic to private Azure resources.

Use this mode for security, platform, or enterprise architecture audiences. Use
[Scenario B](scenario-b-gitops.md) for the faster public-endpoint PAT demo.

You will work through eight parts:

1. [Bootstrap and deploy the GitOps baseline](#part-1--bootstrap-and-deploy-the-gitops-baseline)
2. [Prepare the SRE Agent network subnet](#part-2--prepare-the-sre-agent-network-subnet)
3. [Enable SRE Agent Azure VNet mode](#part-3--enable-sre-agent-azure-vnet-mode)
4. [Create the BYO GitHub App](#part-4--create-the-byo-github-app)
5. [Import the GitHub App key into private Key Vault](#part-5--import-the-github-app-key-into-private-key-vault)
6. [Connect Code Access with BYO GitHub App](#part-6--connect-code-access-with-byo-github-app)
7. [Apply GitOps guardrails and response plan](#part-7--apply-gitops-guardrails-and-response-plan)
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
   - **Contents:** **Read and write**;
   - **Pull requests:** **Read and write**;
   - **Metadata:** **Read-only**.
4. Leave **Actions**, **Administration**, **Secrets**, and unrelated permissions
   at **No access**.
5. Under **Where can this GitHub App be installed?**, keep it limited to the
   owning account unless broader installation is required. Select
   **Create GitHub App**.
6. On the app's **General** page, record the **Client ID** that starts with
   `Iv...`. This is different from the numeric App ID.
7. Select **Generate a private key** and keep the downloaded PEM file local.
8. Open **Install App**, install it on the repository owner, choose **Only select
   repositories**, and select this repository only.

---

## Part 5 — Import the GitHub App key into private Key Vault

Import the private key into Key Vault as a **key**, not a secret. The current SRE
Agent BYO App wizard expects a Key Vault key URI in the form `.../keys/<name>`.

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

If validation fails after the key and RBAC checks pass, re-check the network
path: Azure VNet mode must be saved on the agent, the selected subnet must be
able to resolve the Key Vault private endpoint, and firewall/NSG rules must allow
HTTPS to the private endpoint.

---

## Part 7 — Apply GitOps guardrails and response plan

Follow [Scenario B, Part 4c through Part 5](scenario-b-gitops.md#4c-grant-reader-level-workload-access),
with these differences:

- skip the PAT-based GitHub MCP connector;
- in the `gitops-remediation` custom agent, use
  [`agent/gitops-remediation-agent-github.md`](../agent/gitops-remediation-agent-github.md);
- select the GitHub tools exposed by the BYO GitHub App connection that are
  needed to create a branch, update `infra/leak.auto.tfvars`, commit, and open a
  Pull Request;
- keep the global tool access policy that denies terminal fallback and direct
  Azure/Kubernetes/Terraform mutations.

This keeps the enterprise network posture separate from the GitOps enforcement
boundary: RBAC and tool policy control what the agent may do, while Azure VNet
mode controls where the agent may send traffic.

---

## Part 8 — Run the incident and reset

Run the same GitOps incident and reset flow as
[Scenario B, Part 6](scenario-b-gitops.md#part-6--run-the-incident) and
[Part 7](scenario-b-gitops.md#part-7--reset-and-clean-up).

The expected investigation and remediation are the same: the agent correlates the
memory leak to the incident Pull Request, opens a remediation Pull Request that
sets `enable_slow_leak=false`, and waits for a human to merge it.

After the demo, remove or rotate the GitHub App private key, uninstall the GitHub
App if it is no longer needed, and keep or remove the SRE Agent VNet subnet based
on your environment's governance process.
