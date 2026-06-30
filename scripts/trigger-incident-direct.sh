#!/bin/bash
# ============================================================================
# Trigger (or reset) the ContosoPay demo incident the direct, on-the-spot way.
#
# This is the SCENARIO A trigger. It flips the planted memory-leak feature flag
# (ENABLE_SLOW_LEAK) directly on the running payment-service Container App with a
# single `az containerapp update`. No Pull Request, no CI -- the change hits the
# live revision immediately.
#
# Use this for the fast, self-contained demo where the SRE Agent has Privileged
# (High) access and mitigates ON THE SPOT (restart revision / set the env var
# back) after you approve in the agent UI.
#
# For the realistic, change-managed GitOps flow (PR + CI, agent remediates via a
# PR) use scripts/trigger-incident-gitops.sh instead.
#
# Usage:
#   ./scripts/trigger-incident-direct.sh                 # arm the incident
#   ./scripts/trigger-incident-direct.sh --reset         # turn the leak back off
#   ./scripts/trigger-incident-direct.sh -g RG -p APP     # override RG / payment app
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFRA_DIR="${REPO_ROOT}/infra"
readonly SCRIPT_DIR REPO_ROOT INFRA_DIR

RESOURCE_GROUP=""
PAYMENT_APP=""
DESIRED="true"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reset)              DESIRED="false"; shift ;;
        -g|--resource-group)  RESOURCE_GROUP="$2"; shift 2 ;;
        -p|--payment-app)     PAYMENT_APP="$2"; shift 2 ;;
        -h|--help)            echo "Usage: $0 [--reset] [-g RG] [-p APP]" >&2; exit 1 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

command -v az >/dev/null 2>&1 || { echo "az not found on PATH. Install the Azure CLI and run 'az login'." >&2; exit 1; }

# Resolve RG / payment app from terraform outputs unless explicitly provided.
if [[ -z "${RESOURCE_GROUP}" ]]; then
    RESOURCE_GROUP="$(terraform -chdir="${INFRA_DIR}" output -raw resource_group_name)"
fi
if [[ -z "${PAYMENT_APP}" ]]; then
    PAYMENT_APP="$(terraform -chdir="${INFRA_DIR}" output -raw payment_app_name)"
fi

echo "==> Applying ENABLE_SLOW_LEAK=${DESIRED} directly to '${PAYMENT_APP}' (rg: ${RESOURCE_GROUP})"
az containerapp update \
    --name "${PAYMENT_APP}" \
    --resource-group "${RESOURCE_GROUP}" \
    --set-env-vars "ENABLE_SLOW_LEAK=${DESIRED}" >/dev/null

if [[ "${DESIRED}" == "true" ]]; then
    echo "==> Incident armed. payment-service memory will climb over ~30-40 min."
    echo "    Watch App Insights / the memory alert, then let the SRE Agent investigate and mitigate."
else
    echo "==> Leak disabled. A new revision rolled out and memory reset."
fi
