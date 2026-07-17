#!/bin/bash

# Verifies the out-of-band Scenario C GitHub App signing key contract.

set -euo pipefail

if (( $# != 2 )); then
    echo "Usage: $0 <key-vault-name> <key-name>" >&2
    exit 1
fi

readonly KEY_VAULT_NAME="$1"
readonly KEY_NAME="$2"

if ! key_json="$(az keyvault key show \
    --vault-name "${KEY_VAULT_NAME}" \
    --name "${KEY_NAME}" \
    --output json 2>/dev/null)"; then
    echo "Error: Scenario C requires the one-time GitHub App key import before application deployment." >&2
    echo "Run scripts/configure-github-app-key.sh or scripts/configure-github-app-key.ps1, then rerun the deployment." >&2
    exit 1
fi

key_type="$(jq -r '.key.kty // empty' <<< "${key_json}")"
enabled="$(jq -r '.attributes.enabled // false' <<< "${key_json}")"
key_operations="$(jq -c '.key.keyOps // [] | sort' <<< "${key_json}")"
[[ "${key_type}" == "RSA" || "${key_type}" == "RSA-HSM" ]] || {
    echo "Error: remediation key must be RSA or RSA-HSM." >&2
    exit 1
}
[[ "${enabled}" == "true" ]] || {
    echo "Error: remediation key must be enabled." >&2
    exit 1
}
[[ "${key_operations}" == '["sign"]' ]] || {
    echo "Error: remediation key must permit only the sign operation." >&2
    exit 1
}
