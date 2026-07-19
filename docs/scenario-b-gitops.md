# Scenario B: public-endpoint GitOps

Scenario B is the fast enterprise GitOps demo. The Azure SRE Agent uses the
Terraform-derived **Low / Reader / Review** profile. It investigates Azure but
does not mutate the workload. Instead, the built-in GitHub MCP connector opens a
remediation Pull Request under a hard tool policy.

This scenario has no custom broker and does not use the
`sre-remediation-pr` issue workflow. Those belong only to Scenario C.

## Security and operating model

| Concern | Scenario B behavior |
| --- | --- |
| Terraform profile | `scenario = "B"` |
| SRE Agent access | Low; Reader on the demo resource group |
| Run mode | Review |
| Endpoints | Public state, ACR, and Key Vault endpoints secured with RBAC and TLS |
| Runner | GitHub-hosted workflow jobs or local deploy wrapper |
| Code context | Code Access |
| GitHub write path | Built-in GitHub MCP connector with a short-lived fine-grained PAT |
| Broker | None |
| Incident | Pull Request sets `enable_slow_leak = true` |
| Remediation | GitHub MCP opens a Pull Request setting the flag to `false` |

Code Access and the write connector are separate. Code Access indexes the
repository and correlates incidents to commits. The GitHub MCP connector provides
only the selected branch, file, and Pull Request tools.

## Before you begin

You need:

- an Azure subscription and enough access to deploy resources and role
  assignments;
- repository permission to configure Actions variables and workflows;
- an OIDC deployment identity for GitHub Actions;
- permission to create and revoke a fine-grained GitHub PAT;
- permission to create or configure an Azure SRE Agent.

The healthy baseline on `main` must contain:

```hcl
enable_slow_leak = false
```

in `infra/leak.auto.tfvars`.

## 1. Configure GitHub Actions

Set these nonsecret repository variables:

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

Do not configure an Azure client secret. The temporary SRE Agent GitHub MCP PAT
is used only in the SRE portal and is never provided to this deployment workflow.

The Azure identity trusts the repository through GitHub Actions OIDC. Do not
create a client secret and do not add a credentials JSON secret. Grant only the
control-plane and role-assignment access needed for this demo, and scope it as
narrowly as your bootstrap design permits.

## 2. Deploy an isolated Scenario B environment

Run the manual **deploy** workflow with Scenario `B`. The deploy and subsequent
`apply-infra` and `deploy-apps` work runs on `ubuntu-latest`.

The workflow:

1. validates the selected scenario and OIDC variables;
2. creates the scenario-isolated remote backend;
3. applies platform resources;
4. builds images tagged with the full 40-character `github.sha`;
5. pushes through authenticated ACR access;
6. applies the Container Apps and alert;
7. optionally opens the incident Pull Request.

After deployment succeeds, set `TF_PREFIX` and `TF_ENVIRONMENT` to the deployed
values, then set `DEPLOYMENT_SCENARIO=B` last under repository Actions variables
to activate push deployment.

The state account hash includes subscription, prefix, and `B`; the state key is:

```text
<prefix>-B-<environment>.tfstate
```

Do not point Scenario B at state created by A or C. To change the active GitHub
Actions profile, destroy the old profile, delete `DEPLOYMENT_SCENARIO`,
`TF_PREFIX`, and `TF_ENVIRONMENT`, and then dispatch the new isolated profile.

### Local alternative

The local wrapper also supports B and defaults to the current full commit SHA:

```bash
az login
./scripts/deploy.sh --scenario B
```

```powershell
az login
pwsh ./scripts/deploy.ps1 -Scenario B
```

The public endpoints make this possible without a private runner. Azure RBAC,
TLS, managed identities, disabled ACR admin access, and Key Vault purge
protection still apply.

### Automation profile requirement

Before explicit operator activation, push-triggered `apply-infra` and
`deploy-apps` emit a notice and succeed as no-ops without Azure OIDC or
deployment-runner work. A nonempty invalid marker fails. Explicit dispatch is
validated and can operate while no marker exists, but it cannot disagree with an
active scenario.

### Verify the baseline

1. Open the workflow summary and record the frontend and resource group.
2. Open the frontend, place an order, and enable steady traffic.
3. Confirm payment-service memory is stable.
4. Confirm the effective scenario is `B`.

## 3. Verify and configure the matching SRE Agent

The GitHub deployment workflow provisions the selected Terraform agent resource.
Open it at <https://sre.azure.com> and complete the manual portal connections.
For direct Terraform or local-wrapper usage, enable that resource explicitly or
create the matching agent in the portal.

The effective profile must be:

| Setting | Value |
| --- | --- |
| Access level | **Low** |
| Workload role | **Reader** |
| Mode | **Review** |
| Managed resource | Only the Scenario B demo resource group |
| Incident platform | Azure Monitor |

The managed service can require broader monitoring roles for alert lifecycle
operations. The hard tool policy below remains mandatory because Reader workload
access and behavioral instructions alone are not the complete enforcement
boundary.

## 4. Configure Code Access

Under **Builder > Code Access**, connect this repository and wait for indexing to
start. This connection provides source and deployment context only. Do not assume
that its sign-in is a Git write credential.

Official Azure SRE Agent documentation distinguishes
[Code Access, GitHub Connector, and GitHub MCP](https://learn.microsoft.com/azure/sre-agent/github-connector).

## 5. Add the built-in GitHub MCP connector

Create a fine-grained PAT specifically for this demonstration:

- owner: the account that owns this repository;
- repository access: only this repository;
- expiration: same day or the shortest practical lifetime;
- permissions: only the minimum Contents and Pull Requests read/write access
  required by the selected tools, plus Metadata read.

Do not put the PAT in Terraform, Key Vault, GitHub Actions, repository variables,
workflow secrets, notes, or command history.

In the SRE Agent portal:

1. open **Builder > Connectors > Add connector**;
2. select the built-in GitHub MCP connector;
3. use PAT authentication and enter the token interactively;
4. enable only tools needed to read the target file, create a branch, commit that
   one-file change, and open an unmerged Pull Request;
5. disable merge, approval, workflow administration, repository administration,
   secret management, and unrelated issue tools.

GitHub recommends fine-grained PATs over classic PATs and allows restriction to a
single owner, repository set, and permission set. See
[Managing personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens).

## 6. Apply the hard tool policy

Apply the repository policy in
[`agent/tool-access-policy.portal.json`](../agent/tool-access-policy.portal.json)
at global scope. Verify that it:

- allows Azure and Kubernetes read diagnostics needed by the demo;
- denies Azure and Kubernetes write tools;
- denies terminal and shell fallback;
- denies Terraform apply and destroy paths.

Do not rely only on the custom-agent prompt. Tool policy is the enforced GitOps
boundary. Test it before the demo by asking the agent to restart
payment-service directly. It must refuse the Azure mutation and offer a Pull
Request path instead.

## 7. Configure GitOps behavior

1. Create the `gitops-remediation` custom agent from
   [`agent/gitops-remediation-agent-github.md`](../agent/gitops-remediation-agent-github.md).
2. Assign only Code Access/Azure read tools and the minimum built-in GitHub MCP
   branch, file, commit, and Pull Request tools.
3. Add
   [`agent/knowledge/gitops-runbook.md`](../agent/knowledge/gitops-runbook.md)
   as knowledge.
4. Connect the Scenario B Log Analytics workspace and Application Insights
   resource.
5. Connect Azure Monitor as the incident platform.
6. Create a response plan for the Sev2 payment-memory alert, route it to
   `gitops-remediation`, and keep **Review** mode.

The response plan should explicitly require:

- evidence before remediation;
- no direct Azure, Kubernetes, terminal, or Terraform mutation;
- exactly one change:
  `infra/leak.auto.tfvars` from `enable_slow_leak = true` to `false`;
- an unmerged Pull Request for human review.

## 8. Run the incident

If **Open incident PR** was enabled on the deploy workflow, review the generated
incident Pull Request. Otherwise create it with:

```bash
./scripts/trigger-incident-gitops.sh
```

```powershell
pwsh ./scripts/trigger-incident-gitops.ps1
```

Merge the incident Pull Request. `apply-infra` selects Scenario B from
`DEPLOYMENT_SCENARIO`, verifies the B state, builds full-SHA images where needed,
and applies `enable_slow_leak = true`.

Memory rises for approximately 8–12 minutes. When the five-minute average crosses
the threshold, the Azure Monitor alert fires and the SRE Agent investigates.

Expected evidence:

- alert and working-set trend;
- affected payment-service revision;
- incident Pull Request and merge commit;
- exact feature-flag change;
- source and runbook context.

## 9. Review the remediation Pull Request

In Scenario B, the SRE Agent uses the built-in GitHub MCP tools directly. It does
**not** create a remediation issue, call the custom broker, or trigger
`sre-remediation-pr`.

The agent creates a branch, changes only `infra/leak.auto.tfvars`, and opens an
unmerged Pull Request. Review and merge it. The normal `apply-infra` workflow
applies the healthy flag to the same Scenario B state.

Verify:

1. the Pull Request changes exactly one expected line;
2. no workflow, source, or secret file is changed;
3. a new healthy payment-service revision starts;
4. memory flattens;
5. the alert resolves.

## 10. Reset, revoke, and destroy

If a manual reset Pull Request is needed:

```bash
./scripts/trigger-incident-gitops.sh --reset
```

```powershell
pwsh ./scripts/trigger-incident-gitops.ps1 -Reset
```

Revoke the fine-grained PAT immediately after the demonstration.

Destroy with the **destroy** workflow using Scenario `B` and confirmation
`<prefix>-B-<environment>`, or use:

```bash
./scripts/teardown.sh --scenario B
```

The teardown verifies the scenario recorded in state. Never destroy by guessed
resource-name patterns and never reuse this state for another profile.

## References

- [Azure SRE Agent setup reference](sre-agent-setup.md)
- [Azure SRE Agent GitHub connector](https://learn.microsoft.com/azure/sre-agent/github-connector)
- [Azure SRE Agent MCP connectors](https://learn.microsoft.com/azure/sre-agent/mcp-connectors)
- [Azure SRE Agent tool access policies](https://learn.microsoft.com/azure/sre-agent/tool-access-policies)
- [Fine-grained PAT guidance](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
