#!/bin/bash
# ============================================================================
# Tear down the entire ContosoPay / Azure SRE Agent demo.
#   terraform destroy removes every resource created by the deploy.
#
# Note: the Key Vault has purge protection enabled, so it is soft-deleted (not
# purged) and ages out after the retention window. Names use a random suffix so
# this never blocks a future deploy.
# Usage: ./scripts/teardown.sh [-s SUBSCRIPTION]
# ============================================================================

set -euo pipefail

SUBSCRIPTION=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFRA_DIR="${REPO_ROOT}/infra"
readonly SCRIPT_DIR REPO_ROOT INFRA_DIR

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--subscription) SUBSCRIPTION="$2"; shift 2 ;;
        -h|--help) echo "Usage: $0 [-s SUBSCRIPTION]" >&2; exit 1 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

command -v terraform >/dev/null 2>&1 || { echo "terraform not found on PATH." >&2; exit 1; }
command -v az >/dev/null 2>&1 || { echo "az not found on PATH." >&2; exit 1; }

if [[ -n "${SUBSCRIPTION}" ]]; then
    az account set --subscription "${SUBSCRIPTION}"
fi
ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
export ARM_SUBSCRIPTION_ID

echo "==> terraform destroy"
terraform -chdir="${INFRA_DIR}" destroy -input=false -auto-approve

echo "==> Teardown complete."
