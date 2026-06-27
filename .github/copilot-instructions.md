# Copilot Instructions — Azure SRE Agent Demo (Cloud-Native)

> Use this file as `.github/copilot-instructions.md` in the demo repository.
> It tells GitHub Copilot how to build, structure, and secure the entire demo environment.

---

## 1. Project goal

Build a **self-contained, reproducible demo environment** that showcases the value of the
**Azure SRE Agent** for a cloud-native audience (AKS / Azure Container Apps + GitHub CI/CD).

The demo stages a realistic microservices checkout app ("ContosoPay"), deliberately plants a
recoverable fault (a slow memory leak gated behind a feature flag), and lets the Azure SRE Agent:

1. Detect the incident from Azure Monitor / alerts.
2. Correlate telemetry (App Insights) with the originating GitHub deployment + commit.
3. Produce an explainable root-cause hypothesis.
4. Propose mitigations (restart revision, adjust scale rule) — **executed only after human approval**.
5. Run proactive scheduled health checks.
6. Answer natural-language questions about the environment.

The whole environment must be **deployable in a single command** and **tear-down-able** just as easily.

---

## 2. Hard requirements (non-negotiable)

These constraints come directly from the project owner. Treat them as acceptance criteria.

| # | Requirement | Implication for generated code |
|---|-------------|--------------------------------|
| R1 | **Infrastructure as Code = Terraform** | No Bicep/ARM for infra. Terraform `azurerm` provider only. |
| R2 | **Single-command deployment** | One `deploy.sh` / `deploy.ps1` wrapper that runs `terraform init/plan/apply` + app build/push + seed data. |
| R3 | **Local redundancy is acceptable** | Use **LRS** storage, **non-zone-redundant** SKUs. Do not pay for ZRS/GRS. |
| R4 | **Minimize public endpoints** | Only the `frontend` app is publicly reachable. Everything else uses internal ingress / private networking. |
| R5 | **Public repository** | No secrets, no tenant IDs, no subscription IDs, no resource names that leak customer info committed to source. |
| R6 | **No hardcoded secrets** | All secrets live in **Azure Key Vault**; apps read them via **Managed Identity**. CI/CD uses **OIDC federation**, never stored credentials. |
| R7 | **Microsoft security best practices** | Managed identities, RBAC (not access policies), TLS, least privilege, no admin keys, defender-friendly defaults. |

---

## 3. Target architecture

Cloud-native, container-first. Default to **Azure Container Apps** (simpler, scale-to-zero, internal
ingress out of the box). Keep an **AKS variant** documented but not the default.

```
                        ┌─────────────────────────────────────────────┐
                        │              Azure Subscription              │
                        │   Resource Group: rg-sre-agent-demo (LRS)    │
                        │                                              │
  Internet ──TLS──►  ┌──┴───────────────┐                              │
   (only public      │  frontend (CA)   │  external ingress (HTTPS)    │
    endpoint)        │  React/Node SPA  │                              │
                     └────────┬─────────┘                              │
                              │ internal ingress only                  │
                     ┌────────▼─────────┐     ┌─────────────────────┐  │
                     │ checkout-api (CA)│────►│ payment-service (CA) │  │
                     │  internal ingress│     │ internal ingress     │  │
                     └────────┬─────────┘     │ ⚠ planted mem-leak   │  │
                              │               └──────────┬──────────┘  │
                              │                          │             │
       ┌──────────────────────┼──────────────────────────┼──────────┐ │
       │ Managed Identity (user-assigned) on every app    │          │ │
       ▼                      ▼                            ▼          │ │
 ┌───────────┐        ┌───────────────┐          ┌──────────────────┐│ │
 │ Key Vault │        │ App Insights  │          │ Azure Container  ││ │
 │ (RBAC)    │        │ + Log Analytics│         │ Registry (Std)   ││ │
 └───────────┘        └───────┬───────┘          └──────────────────┘│ │
                              │                                       │ │
                     ┌────────▼─────────┐   ┌──────────────────────┐ │ │
                     │ Azure Monitor    │──►│ Action Group         │ │ │
                     │ Alert Rules      │   │ → SRE Agent / Teams  │ │ │
                     └──────────────────┘   └──────────────────────┘ │ │
                        └─────────────────────────────────────────────┘
                                            ▲
                                            │ connected post-deploy
                                   ┌────────┴─────────┐
                                   │ Azure SRE Agent  │  (provisioned separately,
                                   │  (managed)       │   wired to RG + GitHub + alerts)
                                   └──────────────────┘

  GitHub repo ──► GitHub Actions (OIDC, no secrets) ──► build + push to ACR ──► revision update
```

### Component decisions

| Concern | Choice | Why |
|---------|--------|-----|
| Compute | **Azure Container Apps** (Consumption) | Scale-to-zero, built-in internal ingress, KEDA scale rules to demo the "adjust HPA/scale rule" mitigation. AKS variant documented for the K8s-native crowd. |
| Registry | **Azure Container Registry**, Standard SKU, **admin user disabled** | Pull via managed identity (`AcrPull`), no admin keys (R6). |
| Secrets | **Azure Key Vault**, **RBAC authorization**, soft-delete + purge protection on | R6/R7. Apps use `secretRef` → Key Vault via managed identity. |
| Identity | **User-assigned managed identity** per app | Least privilege, explicit role assignments, no client secrets. |
| Telemetry | **Application Insights** (workspace-based) + **Log Analytics** | Source of truth for the agent's correlation. Connection string stored in Key Vault. |
| Networking | Container Apps Environment with **internal-only** apps except `frontend` | R4. Optionally deploy into a custom VNet for private ACA environment. |
| Alerting | **Azure Monitor** metric/log alert → **Action Group** | Fires the incident the SRE Agent picks up. |
| Dashboards (optional) | **Azure Managed Grafana** | "Modern observability" visual; keep behind a flag to control cost. |
| Storage | **LRS** only | R3. |
| CI/CD | **GitHub Actions + OIDC federated credential** | R6 — zero stored secrets. |

---

## 4. Repository layout

Generate the repo in this shape:

```
.
├── .github/
│   ├── copilot-instructions.md         # this file
│   └── workflows/
│       └── deploy-apps.yml             # OIDC build+push+revision update
├── infra/                              # all Terraform
│   ├── main.tf                         # provider, resource group
│   ├── variables.tf
│   ├── outputs.tf
│   ├── versions.tf                     # pinned provider versions + backend
│   ├── identity.tf                     # user-assigned MIs + role assignments
│   ├── registry.tf                     # ACR (admin disabled)
│   ├── observability.tf                # Log Analytics, App Insights
│   ├── keyvault.tf                     # Key Vault (RBAC) + secrets
│   ├── containerapps.tf                # ACA env + 3 apps + ingress + scale rules
│   ├── alerts.tf                       # Monitor alert rules + action group
│   └── grafana.tf                      # optional, count = var.enable_grafana ? 1 : 0
├── src/
│   ├── frontend/                       # public SPA + Dockerfile
│   ├── checkout-api/                   # internal API + Dockerfile
│   └── payment-service/                # internal API w/ planted leak + Dockerfile
├── scripts/
│   ├── deploy.sh                       # single-command deploy (bash)
│   ├── deploy.ps1                      # single-command deploy (PowerShell)
│   ├── teardown.sh
│   └── trigger-incident.sh            # flips feature flag to start the leak
├── docs/
│   ├── run-of-show.md                  # the live demo script / talk track
│   └── aks-variant.md                  # optional AKS deployment notes
├── .gitignore                          # ignore *.tfstate, *.tfvars, .env, etc.
├── terraform.tfvars.example            # placeholders only, NO real values
└── README.md
```

---

## 5. The "ContosoPay" sample app

Keep services tiny (Node.js/TypeScript or .NET minimal API — pick one and be consistent).

- **frontend** — serves a checkout page, calls `checkout-api`. Only app with external ingress.
- **checkout-api** — receives orders, calls `payment-service`. Internal ingress only.
- **payment-service** — "processes" payments. Contains the **planted fault**.

### The planted fault (the heart of the demo)

In `payment-service`, implement a memory leak that is:

- **Gated by a feature flag** `ENABLE_SLOW_LEAK` (read from config/Key Vault), default `false`.
- **Gradual** — e.g., an unbounded in-memory array/cache that grows per request, so memory climbs
  over ~30–40 minutes, matching the "trend started before the alert" narrative.
- **Recoverable** — a revision restart clears it; raising the scale rule mitigates it. This gives the
  agent two legitimate mitigations to propose.
- **Correlatable** — ship the flag flip as a real **git commit + GitHub Actions deployment** so the
  SRE Agent can tie the incident back to a specific commit. `scripts/trigger-incident.sh` performs
  the commit/flag flip on demand.

Emit OpenTelemetry → Application Insights from all three services (request rate, latency, memory).

---

## 6. Security rules for ALL generated code (R5/R6/R7)

Copilot must follow these without exception:

1. **Never** write a literal secret, connection string, password, key, SAS token, subscription ID,
   tenant ID, or object ID into any committed file. Use variables, Key Vault references, or OIDC.
2. **Key Vault is the only secret store.** App settings reference secrets via Container Apps
   `secret` + `secretRef` bound to Key Vault using the app's managed identity. No plaintext env secrets.
3. **Managed identity everywhere.** No service principals with client secrets. ACR pull = `AcrPull`
   role on the app's MI. Key Vault read = `Key Vault Secrets User` role on the app's MI.
4. **Key Vault uses RBAC authorization** (`enable_rbac_authorization = true`), soft-delete and
   **purge protection enabled**.
5. **ACR admin user disabled** (`admin_enabled = false`).
6. **TLS only.** External ingress is HTTPS; `allow_insecure_connections = false`. Min TLS 1.2.
7. **Least privilege role assignments** — scope every `azurerm_role_assignment` to the specific
   resource, never the subscription unless unavoidable, and comment why.
8. **CI/CD via OIDC federated credentials** — the GitHub Actions workflow uses
   `azure/login` with `client-id`/`tenant-id`/`subscription-id` supplied as GitHub **Actions
   variables/secrets configured by the operator**, not committed. No `creds` JSON blobs.
9. **State safety** — `.gitignore` must exclude `*.tfstate*`, `*.tfvars` (except `.example`),
   `.terraform/`, `.env`, and any `*.pem`/`*.key`.
10. **No public exposure beyond `frontend`.** `checkout-api` and `payment-service` are
    `ingress.external = false`. Justify any new public endpoint in a code comment.
11. Enable **diagnostic settings** to Log Analytics on Key Vault, ACR, and the ACA environment for
    auditability.
12. Prefer **`terraform.tfvars.example`** with placeholder values; real `terraform.tfvars` is
    git-ignored.

---

## 7. Terraform conventions

- Pin provider versions in `versions.tf` (e.g., `azurerm ~> 4.x`, `azuread ~> 3.x`). Pin Terraform
  `>= 1.9`.
- Use a **local backend by default** (single-command, no pre-existing remote state needed), but leave
  a commented `azurerm` backend block for teams that want remote state.
- All resources carry consistent **tags**: `project = "sre-agent-demo"`, `env = var.environment`,
  `managed_by = "terraform"`.
- Names derive from a `var.prefix` + `random_string` suffix to keep them globally unique and
  non-identifying (R5). Never hardcode customer names.
- Expose key results in `outputs.tf`: `frontend_url`, `app_insights_name`, `resource_group_name`,
  `acr_login_server`, `key_vault_name`. **Never output secret values** (`sensitive = true` where a
  value must be surfaced).
- Use `for_each`/modules where it reduces repetition across the three apps.
- Idempotent: `terraform apply` twice must be a no-op.

---

## 8. Single-command deployment (R2)

`scripts/deploy.sh` (and `.ps1` mirror) must, in order:

1. Check prerequisites (`az`, `terraform`, `docker`, logged-in `az account`).
2. `terraform -chdir=infra init`.
3. `terraform -chdir=infra apply -auto-approve` (creates RG, ACR, KV, ACA env, identities, alerts).
4. Read ACR login server from `terraform output`.
5. `az acr login`, then **build + push** the three images.
6. Update the Container Apps to the new image tags (or let Terraform manage the tag via a variable
   re-apply).
7. Print the `frontend_url` and a "next steps" block explaining how to connect the **Azure SRE Agent**
   to this resource group, GitHub repo, and alert action group.

Provide `scripts/teardown.sh` → `terraform -chdir=infra destroy -auto-approve`.

> The Azure SRE Agent resource itself is provisioned/connected through the Azure portal or its own
> onboarding flow and is **not** part of this Terraform (it's the managed service consuming this
> environment). Document the wiring steps in `docs/run-of-show.md`, do not script credentials for it.

---

## 9. Demo flow the environment must support

The infra/app must make these moments possible (see `docs/run-of-show.md` for the full talk track):

1. **Incident** — `trigger-incident.sh` flips `ENABLE_SLOW_LEAK` via a committed change → deploy →
   memory climbs → Azure Monitor alert fires.
2. **Investigation** — SRE Agent correlates App Insights memory trend with the GitHub commit.
3. **Mitigation w/ approval** — agent proposes *restart revision* + *raise scale rule*; human approves.
4. **Proactive** — a scheduled health-check task posts results to Teams/Slack.
5. **Ask anything** — natural-language queries return grounded answers.
6. **Memory** — re-trigger shows faster, pattern-aware resolution.

---

## 10. What NOT to do

- ❌ Do not generate Bicep or ARM templates for infrastructure.
- ❌ Do not store any secret, key, or credential in source, tfvars, or workflow YAML.
- ❌ Do not expose `checkout-api` or `payment-service` publicly.
- ❌ Do not use ACR admin user, Key Vault access policies, or storage account keys.
- ❌ Do not use GRS/ZRS or zone-redundant SKUs (local redundancy is the requirement).
- ❌ Do not commit real subscription/tenant IDs or customer-identifying names.
- ❌ Do not provision the SRE Agent's own credentials in code.

---

## 11. Definition of done

- `git clone` → set `terraform.tfvars` from `.example` → run `scripts/deploy.sh` → working demo.
- Only `frontend_url` is publicly reachable; all else internal.
- `gitleaks`/secret scan on the repo returns clean.
- `terraform plan` is empty after a successful apply (idempotent).
- `scripts/trigger-incident.sh` reliably produces the memory-leak incident and alert.
- `scripts/teardown.sh` removes everything.
