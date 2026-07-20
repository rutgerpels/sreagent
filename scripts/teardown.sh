#!/bin/bash
# ============================================================================
# Tear down the entire ContosoPay / Azure SRE Agent demo.
#   terraform destroy removes every resource created by the deploy.
#
# Note: the Key Vault has purge protection enabled, so it is soft-deleted (not
# purged) and ages out after the retention window. Names use a random suffix so
# this never blocks a future deploy.
# Usage: ./scripts/teardown.sh --scenario A|B|C [-s SUBSCRIPTION]
# ============================================================================

set -euo pipefail

SUBSCRIPTION=""
SCENARIO=""
PREFIX="contosopay"
ENVIRONMENT="demo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFRA_DIR="${REPO_ROOT}/infra"
readonly SCRIPT_DIR REPO_ROOT INFRA_DIR

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--subscription) SUBSCRIPTION="$2"; shift 2 ;;
        --scenario) SCENARIO="$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        --env) ENVIRONMENT="$2"; shift 2 ;;
        -h|--help) echo "Usage: $0 --scenario A|B|C [-s SUBSCRIPTION] [--prefix P] [--env E]" >&2; exit 1 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

readonly SCENARIO_PATTERN='^(A|B|C)$'
[[ "${SCENARIO}" =~ ${SCENARIO_PATTERN} ]] || {
    echo "--scenario A, B, or C is required." >&2
    exit 1
}

command -v terraform >/dev/null 2>&1 || { echo "terraform not found on PATH." >&2; exit 1; }
command -v az >/dev/null 2>&1 || { echo "az not found on PATH." >&2; exit 1; }

if [[ -n "${SUBSCRIPTION}" ]]; then
    az account set --subscription "${SUBSCRIPTION}"
fi
ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
export ARM_SUBSCRIPTION_ID
export ARM_USE_AZUREAD="true"

STATE_RG="rg-${PREFIX}-tfstate"
STATE_HASH="$(printf '%s\0%s\0%s' "${ARM_SUBSCRIPTION_ID}" "${PREFIX}" "${SCENARIO}" | sha256sum | cut -c1-16)"
STATE_SA="sttf${STATE_HASH}"
STATE_CONTAINER="tfstate"
STATE_KEY="${PREFIX}-${SCENARIO}-${ENVIRONMENT}.tfstate"

az storage account show --name "${STATE_SA}" --resource-group "${STATE_RG}" --output none >/dev/null 2>&1 || {
    echo "Scenario ${SCENARIO} state storage '${STATE_SA}' was not found." >&2
    exit 1
}

terraform -chdir="${INFRA_DIR}" init -input=false -reconfigure \
    -backend-config="resource_group_name=${STATE_RG}" \
    -backend-config="storage_account_name=${STATE_SA}" \
    -backend-config="container_name=${STATE_CONTAINER}" \
    -backend-config="key=${STATE_KEY}"

ACTUAL_SCENARIO="$(terraform -chdir="${INFRA_DIR}" output -raw scenario 2>/dev/null || true)"
[[ "${ACTUAL_SCENARIO}" == "${SCENARIO}" ]] || {
    echo "State scenario '${ACTUAL_SCENARIO:-unknown}' does not match '${SCENARIO}'. Refusing teardown." >&2
    exit 1
}

echo "==> terraform destroy"
terraform -chdir="${INFRA_DIR}" destroy -input=false -auto-approve \
    -var "deploy_apps=false" \
    -var "scenario=${SCENARIO}" \
    -var "prefix=${PREFIX}" \
    -var "environment=${ENVIRONMENT}"

echo "==> Teardown complete."
