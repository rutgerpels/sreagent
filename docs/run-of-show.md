# ContosoPay demo run-of-show

ContosoPay demonstrates Azure SRE Agent incident detection, evidence-based root
cause analysis, approval, remediation, proactive checks, and repeated-incident
learning. The three scenarios use the same application and memory alert but
select different immutable security profiles.

## Choose one profile

| | Scenario A | Scenario B | Scenario C |
| --- | --- | --- | --- |
| Story | Autonomous direct recovery | Fast enterprise GitOps | Private-network enterprise GitOps |
| Agent profile | High / Contributor / Autonomous | Low / Reader / Review | Low / Reader / Review |
| Control endpoints | Public | Public, RBAC and TLS protected | Private state, ACR, and Key Vault |
| Deployment runner | GitHub-hosted or local wrapper | GitHub-hosted or local wrapper | Private self-hosted: `self-hosted`, `Linux`, `X64`, `azure-private`, `contosopay` |
| Code context | Code Access | Code Access | Read-only BYO GitHub App for Code Access |
| Write path | Direct Azure action after the configured approval | Built-in GitHub MCP connector with a short-lived fine-grained PAT | Entra-protected broker using a separate issues-write GitHub App |
| Broker | None | None | Required and deployed by the normal workflow |
| Guide | [Scenario A](scenario-a-direct.md) | [Scenario B](scenario-b-gitops.md) | [Scenario C](scenario-c-private-gitops.md) |

**Code Access and GitHub writes are different capabilities.** Code Access
indexes and correlates source. Scenario B adds the built-in GitHub MCP connector
for branch/file/Pull Request writes. Scenario C instead uses a custom broker and
a separate remediation GitHub App. Scenario A has neither write path.

## Profile and state safety

Terraform accepts one `scenario` value (`A`, `B`, or `C`) and derives the network,
agent, runner, and broker profile. Resource names include the scenario. The state
account hash includes subscription, prefix, and scenario; the state blob is
`<prefix>-<scenario>-<environment>.tfstate`.

In-place scenario conversion is unsupported. For the GitHub Actions path,
destroy the active profile first, delete the repository `DEPLOYMENT_SCENARIO`,
`TF_PREFIX`, and `TF_ENVIRONMENT` variables, and only then dispatch **deploy** for
another scenario. The workflow refuses a different scenario, prefix, or
environment while the marker exists. Never point a new profile at old state.

After a successful manual **deploy**, review its summary and explicitly set the
repository Actions variables `TF_PREFIX` and `TF_ENVIRONMENT`, then set
`DEPLOYMENT_SCENARIO` last as the activation marker. Until that marker exists,
push-triggered `apply-infra` and `deploy-apps` emit a notice and succeed as no-ops
without Azure OIDC or deployment-runner work. A nonempty invalid marker still
fails. This explicit activation needs no PAT or additional GitHub App. Workflow
images use the full 40-character commit SHA.

## Shared preparation

1. Start from a healthy `main` branch where
   `infra/leak.auto.tfvars` contains `enable_slow_leak = false`.
2. Configure GitHub Actions Azure OIDC variables. Never add an Azure client
   secret.
3. Dispatch **deploy** with the selected profile.
4. After it succeeds, set `TF_PREFIX` and `TF_ENVIRONMENT` to the deployed values,
   then set `DEPLOYMENT_SCENARIO` last to activate push deployment.
5. Open the frontend, place a test order, and enable steady traffic.
6. Create or connect the matching SRE Agent and add the demo resources, logs,
   code, and Azure Monitor incident platform.
7. Configure the scenario's response plan and tool policy before arming the
   incident.

## Live presentation

### 1. Establish the healthy baseline

Show:

- the public frontend;
- internal-only checkout and payment services;
- stable payment-service memory;
- Application Insights or Grafana telemetry;
- the selected scenario profile and state isolation.

### 2. Arm the incident

- **Scenario A:** run `scripts/trigger-incident-direct.*`.
- **Scenario B or C:** merge the incident Pull Request produced by the deploy
  workflow or `scripts/trigger-incident-gitops.*`.

Memory rises over approximately 8–12 minutes. Use this time to explain the alert's
five-minute average and the scenario's security boundary.

### 3. Investigate

Show the Azure Monitor incident and the agent's evidence:

- working-set memory trend;
- affected payment-service revision;
- leak feature flag;
- deployment commit or Pull Request;
- source and runbook context.

### 4. Remediate with the scenario boundary

- **A:** the agent performs a direct Azure remediation in Autonomous mode within
  the configured approval controls. Typical actions are disabling the fault,
  restarting the revision, or changing the scale setting.
- **B:** the hard tool policy denies direct Azure mutation. The agent uses the
  built-in GitHub MCP connector to open an unmerged Pull Request that sets
  `enable_slow_leak = false`. A human reviews and merges it.
- **C:** the hard tool policy denies direct Azure mutation. The agent calls the
  custom MCP broker. The broker's remediation GitHub App creates a constrained
  issue; the Scenario C-only workflow validates it and opens the unmerged
  one-file Pull Request. A human reviews and merges it.

The remediation issue and `sre-remediation-pr` workflow belong only to Scenario
C. Scenario B opens the Pull Request directly through its built-in connector.

### 5. Verify and repeat

Show the new healthy revision, flattened memory, and resolved alert. Re-arm the
incident to demonstrate faster pattern recognition. Optionally configure a
scheduled health check to report memory, active alerts, and revision health.

## Reset and teardown

Reset the fault through the same operational boundary used by the scenario:

- Scenario A: direct reset script.
- Scenario B: GitHub MCP remediation Pull Request or reset trigger Pull Request.
- Scenario C: broker remediation or reset trigger Pull Request.

Destroy the exact scenario state after the demo. Remove temporary Scenario B PATs.
For Scenario C, remove or rotate the remediation GitHub App key and uninstall the
two GitHub Apps if they are no longer required.

## References

- [Azure SRE Agent run modes](https://learn.microsoft.com/azure/sre-agent/run-modes)
- [Azure SRE Agent permissions](https://learn.microsoft.com/azure/sre-agent/permissions)
- [Azure SRE Agent GitHub connector](https://learn.microsoft.com/azure/sre-agent/github-connector)
- [Azure SRE Agent network integration](https://learn.microsoft.com/azure/sre-agent/network-integration)
- [Container Apps networking](https://learn.microsoft.com/azure/container-apps/networking)
