#!/bin/bash
# Import the Scenario C remediation GitHub App PEM as a non-exportable Key Vault
# key. Run from the private runner network; this script never opens the vault.

set -euo pipefail

VAULT_NAME=""
PRIVATE_KEY_PATH=""
KEY_NAME="github-app-signing-key"
FORCE="false"
OPERATOR_OBJECT_ID=""
VAULT_RESOURCE_ID=""
ROLE_ASSIGNMENT_ID=""

usage() {
    cat >&2 <<EOF
Usage: $0 --vault-name NAME --private-key PATH [--key-name NAME] [--force]

Run from a host that already has private network access to the Scenario C vault.
--force imports a new version when the named key already exists.
EOF
    exit 1
}

cleanup() {
    if [[ -n "${ROLE_ASSIGNMENT_ID}" ]]; then
        local removed="false"
        for _ in $(seq 1 6); do
            az role assignment delete \
                --ids "${ROLE_ASSIGNMENT_ID}" \
                --output none >/dev/null 2>&1 || true
            remaining="$(az role assignment list \
                --assignee "${OPERATOR_OBJECT_ID}" \
                --scope "${VAULT_RESOURCE_ID}" \
                --role "Key Vault Crypto Officer" \
                --query "[?id=='${ROLE_ASSIGNMENT_ID}'] | length(@)" \
                --output tsv 2>/dev/null || echo 1)"
            if [[ "${remaining}" == "0" ]]; then
                removed="true"
                break
            fi
            sleep 5
        done
        if [[ "${removed}" != "true" ]]; then
            echo "Could not remove temporary Key Vault Crypto Officer role assignment '${ROLE_ASSIGNMENT_ID}'." >&2
            exit 1
        fi
    fi
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vault-name)  VAULT_NAME="$2"; shift 2 ;;
        --private-key) PRIVATE_KEY_PATH="$2"; shift 2 ;;
        --key-name)    KEY_NAME="$2"; shift 2 ;;
        --force)       FORCE="true"; shift ;;
        -h|--help)     usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

[[ -n "${VAULT_NAME}" && -n "${PRIVATE_KEY_PATH}" ]] || usage
[[ -f "${PRIVATE_KEY_PATH}" ]] || {
    echo "Private-key file not found: ${PRIVATE_KEY_PATH}" >&2
    exit 1
}
readonly KEY_NAME_PATTERN='^[0-9A-Za-z-]{1,127}$'
[[ "${KEY_NAME}" =~ ${KEY_NAME_PATTERN} ]] || {
    echo "Invalid Key Vault key name." >&2
    exit 1
}
grep -q -- "BEGIN RSA PRIVATE KEY\|BEGIN PRIVATE KEY" "${PRIVATE_KEY_PATH}" || {
    echo "The supplied file does not look like a PEM private key." >&2
    exit 1
}

command -v az >/dev/null 2>&1 || {
    echo "Required command 'az' was not found on PATH." >&2
    exit 1
}
az account show --output none >/dev/null 2>&1 || {
    echo "Not logged in to Azure. Run 'az login' first." >&2
    exit 1
}

OPERATOR_OBJECT_ID="$(az ad signed-in-user show --query id --output tsv)"
VAULT_RESOURCE_ID="$(az keyvault show --name "${VAULT_NAME}" --query id --output tsv)"
EXISTING_ROLE="$(az role assignment list \
    --assignee "${OPERATOR_OBJECT_ID}" \
    --scope "${VAULT_RESOURCE_ID}" \
    --role "Key Vault Crypto Officer" \
    --query "[0].id" \
    --output tsv)"
if [[ -z "${EXISTING_ROLE}" ]]; then
    ROLE_ASSIGNMENT_ID="$(az role assignment create \
        --assignee-object-id "${OPERATOR_OBJECT_ID}" \
        --assignee-principal-type User \
        --role "Key Vault Crypto Officer" \
        --scope "${VAULT_RESOURCE_ID}" \
        --query id \
        --output tsv)"
fi

key_state=""
for _ in $(seq 1 12); do
    set +e
    key_error="$(az keyvault key show \
        --vault-name "${VAULT_NAME}" \
        --name "${KEY_NAME}" \
        --output none 2>&1 >/dev/null)"
    key_status=$?
    set -e

    if [[ ${key_status} -eq 0 ]]; then
        key_state="exists"
        break
    fi
    if grep -Eqi '(KeyNotFound|not found|status code: 404|\(404\))' <<< "${key_error}"; then
        key_state="absent"
        break
    fi
    if grep -Eqi '(Forbidden|AuthorizationFailed|status code: 403|\(403\))' <<< "${key_error}"; then
        sleep 5
        continue
    fi

    echo "Could not verify whether key '${KEY_NAME}' exists: ${key_error}" >&2
    exit 1
done

[[ -n "${key_state}" ]] || {
    echo "Key Vault Crypto Officer access did not become effective; refusing to import without verifying key existence." >&2
    exit 1
}
if [[ "${key_state}" == "exists" && "${FORCE}" != "true" ]]; then
    echo "Key '${KEY_NAME}' already exists. Use --force only when rotating the GitHub App key." >&2
    exit 1
fi

echo "==> Importing non-exportable GitHub App signing key"
imported="false"
for _ in $(seq 1 12); do
    if az keyvault key import \
        --vault-name "${VAULT_NAME}" \
        --name "${KEY_NAME}" \
        --pem-file "${PRIVATE_KEY_PATH}" \
        --ops sign \
        --exportable false \
        --output none 2>/dev/null; then
        imported="true"
        break
    fi
    sleep 5
done

[[ "${imported}" == "true" ]] || {
    echo "Key import failed. Run this script from the private runner network and verify Key Vault RBAC propagation." >&2
    exit 1
}

echo "Imported key '${KEY_NAME}' with sign-only operations. The private key cannot be downloaded."
