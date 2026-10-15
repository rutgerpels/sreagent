#!/bin/bash
# ============================================================================
# Trigger (or reset) the Scenario D incident: "Payments fail; checkout fails
# with them".
#
# Sets PAYMENT_FAILURE_MODE on the live payment-service Container App. Any
# environment-variable change rolls a new revision, so both arming and reset end
# with a fresh revision. Terraform's desired state stays healthy ("off"); this is
# a temporary, audited live deviation and a later `terraform apply` will not
# re-arm it.
#
# Guards: Terraform state and the live resource group must both identify
# Scenario D, and the live app must be the state-owned resource. Only the single
# PAYMENT_FAILURE_MODE variable is changed.
#
# Usage:
#   ./scripts/trigger-incident-payments.sh              # arm the incident
#   ./scripts/trigger-incident-payments.sh --reset      # payment mode back to off
#   ./scripts/trigger-incident-payments.sh -g RG -p APP # must match state
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFRA_DIR="${REPO_ROOT}/infra"
readonly SCRIPT_DIR REPO_ROOT INFRA_DIR

RESOURCE_GROUP=""
PAYMENT_APP=""
DESIRED="unavailable"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reset)              DESIRED="off"; shift ;;
        -g|--resource-group)  RESOURCE_GROUP="${2:?Missing value for $1}"; shift 2 ;;
        -p|--payment-app)     PAYMENT_APP="${2:?Missing value for $1}"; shift 2 ;;
        -h|--help)            echo "Usage: $0 [--reset] [-g RG] [-p APP]" >&2; exit 1 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

command -v az >/dev/null 2>&1 || { echo "az not found on PATH. Install the Azure CLI and run 'az login'." >&2; exit 1; }
command -v terraform >/dev/null 2>&1 || { echo "terraform not found on PATH." >&2; exit 1; }

SCENARIO="$(terraform -chdir="${INFRA_DIR}" output -raw scenario)"
[[ "${SCENARIO}" == "D" ]] || {
    echo "This trigger is restricted to Scenario D; current Terraform state is Scenario ${SCENARIO}." >&2
    exit 1
}

EXPECTED_RESOURCE_GROUP="$(terraform -chdir="${INFRA_DIR}" output -raw resource_group_name)"
EXPECTED_PAYMENT_APP="$(terraform -chdir="${INFRA_DIR}" output -raw payment_app_name)"
[[ -z "${RESOURCE_GROUP}" || "${RESOURCE_GROUP}" == "${EXPECTED_RESOURCE_GROUP}" ]] || {
    echo "The resource-group argument must match Terraform state; cross-environment mutation is forbidden." >&2
    exit 1
}
[[ -z "${PAYMENT_APP}" || "${PAYMENT_APP}" == "${EXPECTED_PAYMENT_APP}" ]] || {
    echo "The payment-app argument must match Terraform state; cross-environment mutation is forbidden." >&2
    exit 1
}
RESOURCE_GROUP="${EXPECTED_RESOURCE_GROUP}"
PAYMENT_APP="${EXPECTED_PAYMENT_APP}"

LIVE_SCENARIO="$(az group show --name "${RESOURCE_GROUP}" --query tags.scenario --output tsv)"
[[ "${LIVE_SCENARIO}" == "D" ]] || {
    echo "The live resource group is not tagged as Scenario D; refusing mutation." >&2
    exit 1
}
APP_ID="$(az containerapp show --name "${PAYMENT_APP}" --resource-group "${RESOURCE_GROUP}" --query id --output tsv)"
EXPECTED_APP_SUFFIX="/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.App/containerApps/${PAYMENT_APP}"
[[ "${APP_ID,,}" == *"${EXPECTED_APP_SUFFIX,,}" ]] || {
    echo "The live payment app does not match the state-owned resource." >&2
    exit 1
}

echo "==> Applying PAYMENT_FAILURE_MODE=${DESIRED} to '${PAYMENT_APP}' (rg: ${RESOURCE_GROUP})"
az containerapp update \
    --name "${PAYMENT_APP}" \
    --resource-group "${RESOURCE_GROUP}" \
    --set-env-vars "PAYMENT_FAILURE_MODE=${DESIRED}" >/dev/null

if [[ "${DESIRED}" == "off" ]]; then
    echo "==> Payment failure disabled. A fresh healthy revision is rolling out."
    echo "    Confirm with fresh checkout orders (scripts/generate-checkout-traffic.sh)."
else
    echo "==> Incident armed. Payment calls now return 503 and checkout returns 502."
    echo "    Keep synthetic traffic running; the payment-failure alert should fire within minutes."
fi
