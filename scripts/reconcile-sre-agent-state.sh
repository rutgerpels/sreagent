#!/bin/bash
# ============================================================================
# Remove unreliable SRE Agent preview resources from Terraform state before
# destroy. Azure resource-group deletion still cleans up any remaining objects.
# ============================================================================

set -euo pipefail

INFRA_DIR="${1:-}"

[[ -n "${INFRA_DIR}" && -d "${INFRA_DIR}" ]] || {
    echo "A valid Terraform infrastructure directory is required." >&2
    exit 1
}

warn() {
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        echo "::warning::$*"
    else
        echo "Warning: $*" >&2
    fi
}

command -v az >/dev/null 2>&1 || { echo "az not found on PATH." >&2; exit 1; }
command -v base64 >/dev/null 2>&1 || { echo "base64 not found on PATH." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found on PATH." >&2; exit 1; }
command -v terraform >/dev/null 2>&1 || { echo "terraform not found on PATH." >&2; exit 1; }

STATE_JSON="$(terraform -chdir="${INFRA_DIR}" show -json)"

mapfile -t CONNECTOR_ROWS < <(jq -r '
    .values.root_module.resources[]?
    | select(.type == "azapi_resource" and .name == "agent_connector")
    | { address, id: (.values.id // "") }
    | @base64
' <<< "${STATE_JSON}")

if [[ "${#CONNECTOR_ROWS[@]}" -gt 0 ]]; then
    command -v timeout >/dev/null 2>&1 || { echo "timeout not found on PATH." >&2; exit 1; }
fi

CONNECTOR_ADDRESSES=()
for row in "${CONNECTOR_ROWS[@]}"; do
    CONNECTOR="$(base64 -d <<< "${row}")"
    CONNECTOR_ADDRESS="$(jq -r '.address' <<< "${CONNECTOR}")"
    CONNECTOR_ID="$(jq -r '.id' <<< "${CONNECTOR}")"
    CONNECTOR_ADDRESSES+=("${CONNECTOR_ADDRESS}")

    if [[ -n "${CONNECTOR_ID}" ]] &&
        ! timeout --kill-after=5s 30s \
            az resource delete \
                --ids "${CONNECTOR_ID}" \
                --api-version 2025-05-01-preview \
                --only-show-errors 2>/dev/null; then
        warn "${CONNECTOR_ADDRESS} could not be deleted directly; resource-group deletion will clean it up."
    fi
done

if [[ "${#CONNECTOR_ADDRESSES[@]}" -gt 0 ]]; then
    terraform -chdir="${INFRA_DIR}" state rm "${CONNECTOR_ADDRESSES[@]}"
fi

mapfile -t AGENT_ROWS < <(jq -r '
    .values.root_module.resources[]?
    | select(.type == "azapi_resource" and .name == "agent")
    | { address, id: (.values.id // "") }
    | @base64
' <<< "${STATE_JSON}")

if [[ "${#AGENT_ROWS[@]}" -eq 0 ]]; then
    exit 0
fi

PRUNE_AGENT_STATE=false
for row in "${AGENT_ROWS[@]}"; do
    AGENT="$(base64 -d <<< "${row}")"
    AGENT_ADDRESS="$(jq -r '.address' <<< "${AGENT}")"
    AGENT_ID="$(jq -r '.id' <<< "${AGENT}")"
    if [[ -z "${AGENT_ID}" ]]; then
        warn "${AGENT_ADDRESS} has no ARM ID; pruning its preview-resource state."
        PRUNE_AGENT_STATE=true
        continue
    fi
    if ! AGENT_JSON="$(az resource show --ids "${AGENT_ID}" --api-version 2025-05-01-preview --output json 2>/dev/null)"; then
        warn "${AGENT_ADDRESS} is already absent in Azure; pruning its preview-resource state."
        PRUNE_AGENT_STATE=true
        continue
    fi
    if ! jq -e '(.identity.principalId // "") | length > 0' <<< "${AGENT_JSON}" >/dev/null; then
        warn "${AGENT_ADDRESS} has no readable managed identity; pruning its preview-resource state."
        PRUNE_AGENT_STATE=true
    fi
done

if [[ "${PRUNE_AGENT_STATE}" != "true" ]]; then
    exit 0
fi

mapfile -t TRACKED_ROLE_ASSIGNMENT_IDS < <(jq -r '
    .values.root_module.resources[]?
    | select(.type == "azurerm_role_assignment"
        and (.name | test("^(agent|agent_system|agent_monitoring_contributor|agent_system_monitoring_contributor|agent_deployer_administrator)$")))
    | .values.id // empty
' <<< "${STATE_JSON}")
for role_assignment_id in "${TRACKED_ROLE_ASSIGNMENT_IDS[@]}"; do
    az role assignment delete --ids "${role_assignment_id}" --only-show-errors 2>/dev/null || true
done

for row in "${AGENT_ROWS[@]}"; do
    AGENT_ID="$(jq -r '.id' <<< "$(base64 -d <<< "${row}")")"
    if [[ -n "${AGENT_ID}" ]]; then
        az rest --method post --url "https://management.azure.com${AGENT_ID}/stop?api-version=2025-05-01-preview" --only-show-errors >/dev/null 2>&1 || true
        az resource delete --ids "${AGENT_ID}" --api-version 2025-05-01-preview --only-show-errors 2>/dev/null || true
    fi
done

mapfile -t STATE_ADDRESSES_TO_REMOVE < <(jq -r '
    .values.root_module.resources[]?
    | select(
        (.type == "azapi_resource" and .name == "agent")
        or
        (.type == "azurerm_role_assignment"
            and (.name | test("^(agent|agent_system|agent_monitoring_contributor|agent_system_monitoring_contributor|agent_deployer_administrator)$")))
    )
    | .address
' <<< "${STATE_JSON}")
if [[ "${#STATE_ADDRESSES_TO_REMOVE[@]}" -gt 0 ]]; then
    terraform -chdir="${INFRA_DIR}" state rm "${STATE_ADDRESSES_TO_REMOVE[@]}"
fi
