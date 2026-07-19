# Legacy Scenario C custom-agent prompt

New Scenario C deployments reconcile
[`scenario-c/gitops-remediation.instructions.md`](scenario-c/gitops-remediation.instructions.md)
through the supported SRE Agent API. This file remains only so older portal
bookmarks do not silently retain the obsolete broker instructions.

Do not configure the remote remediation MCP connector until Microsoft documents
a supported managed-identity authentication flow for remote Streamable-HTTP MCP.
Do not substitute a static bearer secret, PAT, anonymous access, or network-only
trust.

Use the reconciled instructions. They require read-only investigation, the exact
one-file GitOps recommendation, and a human-triggered remediation Pull Request
while the connector remains unsupported.
