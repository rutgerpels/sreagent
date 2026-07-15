#!/bin/bash
# Upload a GitHub App private key to the existing demo Key Vault without placing
# the key in Terraform state or shell arguments. Run from the private runner
# network, or supply --operator-cidr for a temporary single-IP firewall rule.
# The script grants the signed-in user temporary secret-write access when needed
# and removes that assignment on exit.

set -euo pipefail

VAULT_NAME=""
PRIVATE_KEY_PATH=""
SECRET_NAME="github-app-private-key"
OPERATOR_CIDR=""
RULE_ADDED="false"
PUBLIC_ACCESS_CHANGED="false"
ORIGINAL_PUBLIC_ACCESS=""
ROLE_ADDED="false"
OPERATOR_OBJECT_ID=""
VAULT_RESOURCE_ID=""

usage() {
    echo "Usage: $0 --vault-name NAME --private-key PATH [--secret-name NAME] [--operator-cidr IPv4/32]" >&2
    exit 1
}

cleanup() {
    if [[ "${PUBLIC_ACCESS_CHANGED}" == "true" ]]; then
        az keyvault update \
            --name "${VAULT_NAME}" \
            --public-network-access "${ORIGINAL_PUBLIC_ACCESS}" \
            --output none >/dev/null 2>&1 || true
    fi
    if [[ "${RULE_ADDED}" == "true" ]]; then
        az keyvault network-rule remove \
            --name "${VAULT_NAME}" \
            --ip-address "${OPERATOR_CIDR}" \
            --output none >/dev/null 2>&1 || true
    fi
    if [[ "${ROLE_ADDED}" == "true" ]]; then
        az role assignment delete \
            --assignee-object-id "${OPERATOR_OBJECT_ID}" \
            --role "Key Vault Secrets Officer" \
            --scope "${VAULT_RESOURCE_ID}" \
            --output none >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vault-name)    VAULT_NAME="$2"; shift 2 ;;
        --private-key)   PRIVATE_KEY_PATH="$2"; shift 2 ;;
        --secret-name)   SECRET_NAME="$2"; shift 2 ;;
        --operator-cidr) OPERATOR_CIDR="$2"; shift 2 ;;
        -h|--help)       usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

[[ -n "${VAULT_NAME}" && -n "${PRIVATE_KEY_PATH}" ]] || usage
[[ -f "${PRIVATE_KEY_PATH}" ]] || { echo "Private-key file not found: ${PRIVATE_KEY_PATH}" >&2; exit 1; }
[[ "${SECRET_NAME}" =~ ^[0-9A-Za-z-]{1,127}$ ]] || { echo "Invalid Key Vault secret name." >&2; exit 1; }

if ! grep -q -- "BEGIN RSA PRIVATE KEY\|BEGIN PRIVATE KEY" "${PRIVATE_KEY_PATH}"; then
    echo "The supplied file does not look like a PEM private key." >&2
    exit 1
fi

command -v az >/dev/null 2>&1 || { echo "Required command 'az' was not found on PATH." >&2; exit 1; }
az account show --output none >/dev/null 2>&1 || { echo "Not logged in to Azure. Run 'az login' first." >&2; exit 1; }

OPERATOR_OBJECT_ID="$(az ad signed-in-user show --query id --output tsv)"
VAULT_RESOURCE_ID="$(az keyvault show --name "${VAULT_NAME}" --query id --output tsv)"
EXISTING_ROLE="$(az role assignment list \
    --assignee "${OPERATOR_OBJECT_ID}" \
    --scope "${VAULT_RESOURCE_ID}" \
    --role "Key Vault Secrets Officer" \
    --query "[0].id" --output tsv)"
if [[ -z "${EXISTING_ROLE}" ]]; then
    az role assignment create \
        --assignee-object-id "${OPERATOR_OBJECT_ID}" \
        --assignee-principal-type User \
        --role "Key Vault Secrets Officer" \
        --scope "${VAULT_RESOURCE_ID}" \
        --output none
    ROLE_ADDED="true"
fi

if [[ -n "${OPERATOR_CIDR}" ]]; then
    if [[ ! "${OPERATOR_CIDR}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; then
        echo "--operator-cidr must be a valid IPv4 CIDR, normally your public IP followed by /32." >&2
        exit 1
    fi

    ORIGINAL_PUBLIC_ACCESS="$(az keyvault show \
        --name "${VAULT_NAME}" \
        --query properties.publicNetworkAccess \
        --output tsv)"
    ORIGINAL_PUBLIC_ACCESS="${ORIGINAL_PUBLIC_ACCESS:-Disabled}"

    EXISTING_RULE="$(az keyvault show \
        --name "${VAULT_NAME}" \
        --query "properties.networkAcls.ipRules[?value=='${OPERATOR_CIDR}'].value | [0]" \
        --output tsv)"
    if [[ -z "${EXISTING_RULE}" ]]; then
        az keyvault network-rule add \
            --name "${VAULT_NAME}" \
            --ip-address "${OPERATOR_CIDR}" \
            --output none
        RULE_ADDED="true"
    fi

    if [[ "${ORIGINAL_PUBLIC_ACCESS}" != "Enabled" ]]; then
        az keyvault update \
            --name "${VAULT_NAME}" \
            --public-network-access Enabled \
            --output none
        PUBLIC_ACCESS_CHANGED="true"
    fi
fi

echo "==> Uploading GitHub App private key to Key Vault"
uploaded="false"
for _ in $(seq 1 12); do
    if az keyvault secret set \
        --vault-name "${VAULT_NAME}" \
        --name "${SECRET_NAME}" \
        --file "${PRIVATE_KEY_PATH}" \
        --output none 2>/dev/null; then
        uploaded="true"
        break
    fi
    sleep 5
done

[[ "${uploaded}" == "true" ]] || {
    echo "Key upload failed. Run from the private runner network or supply a permitted --operator-cidr." >&2
    exit 1
}

echo "GitHub App private key stored as secret '${SECRET_NAME}'."
