# ============================================================================
# GitOps source of truth for the planted memory-leak fault (NON-SECRET).
#
# This file is committed on purpose (see the .gitignore exception). Terraform
# auto-loads *.auto.tfvars, so whatever is set here is the desired state of the
# payment-service ENABLE_SLOW_LEAK flag.
#
# DEMO FLOW:
#   * scripts/trigger-incident-gitops.* opens a PULL REQUEST that flips this to `true`.
#   * Merging that PR runs .github/workflows/apply-infra.yml, which performs a
#     `terraform apply` against the remote state -> the leak is deployed.
#   * The Azure SRE Agent remediates by opening another PR that sets this back to
#     `false` (it is denied direct `az containerapp update` writes). Merging that
#     PR redeploys the fix. No one edits the live Azure resources by hand.
#
# Keep this `false` in main so the demo always starts from a healthy state.
# ============================================================================
enable_slow_leak = true
