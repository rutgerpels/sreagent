#!/bin/bash
# ============================================================================
# Trigger (or reset) the ContosoPay demo incident.
#
# Flips the ENABLE_SLOW_LEAK feature flag for payment-service:
#   * Updates the committed config/feature-flags.env and commits + pushes it,
#     creating the correlatable git commit the SRE Agent ties the incident to.
#   * Applies the flag to the running Container App so memory starts climbing.
#
# Memory then climbs over ~30-40 min, the Azure Monitor alert fires, and the
# SRE Agent can correlate the trend with the commit.
#
# Usage:
#   ./scripts/trigger-incident.sh                 # start the incident
#   ./scripts/trigger-incident.sh --reset         # turn the leak back off
#   ./scripts/trigger-incident.sh -g RG -p APP     # override RG / payment app
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFRA_DIR="${REPO_ROOT}/infra"
FLAG_FILE="${REPO_ROOT}/config/feature-flags.env"
readonly SCRIPT_DIR REPO_ROOT INFRA_DIR FLAG_FILE

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

command -v az >/dev/null 2>&1 || { echo "az not found on PATH." >&2; exit 1; }

# Resolve RG / payment app from terraform outputs unless explicitly provided.
if [[ -z "${RESOURCE_GROUP}" ]]; then
    RESOURCE_GROUP="$(terraform -chdir="${INFRA_DIR}" output -raw resource_group_name)"
fi
if [[ -z "${PAYMENT_APP}" ]]; then
    PAYMENT_APP="$(terraform -chdir="${INFRA_DIR}" output -raw payment_app_name)"
fi

echo "==> Setting ENABLE_SLOW_LEAK=${DESIRED} in ${FLAG_FILE}"
if [[ -f "${FLAG_FILE}" ]]; then
    # Portable in-place edit (works on GNU and BSD sed).
    tmp="$(mktemp)"
    sed "s/^ENABLE_SLOW_LEAK=.*/ENABLE_SLOW_LEAK=${DESIRED}/" "${FLAG_FILE}" > "${tmp}"
    mv "${tmp}" "${FLAG_FILE}"
fi

# Best-effort: commit + push the flip so the agent can correlate to a commit.
if git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "==> Committing the flag flip"
    git -C "${REPO_ROOT}" add "${FLAG_FILE}"
    if git -C "${REPO_ROOT}" diff --cached --quiet; then
        echo "    (no change to commit)"
    else
        msg="demo: set ENABLE_SLOW_LEAK=${DESIRED} (trigger incident)"
        [[ "${DESIRED}" == "false" ]] && msg="demo: reset ENABLE_SLOW_LEAK=false"
        git -C "${REPO_ROOT}" commit -m "${msg}"
        git -C "${REPO_ROOT}" push 2>/dev/null || echo "    (push skipped — no upstream configured)"
    fi
else
    echo "    (not a git repo — skipping commit; flag still applied to the live app)"
fi

echo "==> Applying flag to running Container App '${PAYMENT_APP}'"
az containerapp update \
    --name "${PAYMENT_APP}" \
    --resource-group "${RESOURCE_GROUP}" \
    --set-env-vars "ENABLE_SLOW_LEAK=${DESIRED}" >/dev/null

if [[ "${DESIRED}" == "true" ]]; then
    echo "==> Incident armed. payment-service memory will climb over ~30-40 min."
    echo "    Watch App Insights / the memory alert, then let the SRE Agent investigate."
else
    echo "==> Leak disabled. A new revision was rolled out (memory reset)."
fi
