#!/bin/bash
# ============================================================================
# Single-command deployment for the ContosoPay / Azure SRE Agent demo.
#
# Flow:
#   1. Validate prerequisites (az, terraform, docker, an az login).
#   2. terraform init.
#   3. terraform apply (phase 1): platform only, no apps (images don't exist yet).
#   4. Build + push the three container images to ACR.
#   5. terraform apply (phase 2): the three Container Apps + alert, on the new tag.
#   6. Print the public frontend URL and SRE Agent wiring next-steps.
#
# No secrets are handled here. App secrets live in Key Vault, read via managed
# identity. Usage: ./scripts/deploy.sh [-s SUBSCRIPTION] [-t IMAGE_TAG] [--skip-build]
# ============================================================================

set -euo pipefail

SUBSCRIPTION=""
IMAGE_TAG="$(date -u +%Y%m%d%H%M%S)"
SKIP_BUILD="false"
PREFIX="contosopay"
ENVIRONMENT="demo"
LOCATION="swedencentral"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFRA_DIR="${REPO_ROOT}/infra"
readonly SCRIPT_DIR REPO_ROOT INFRA_DIR
SERVICES=("frontend" "checkout-api" "payment-service")

usage() {
    echo "Usage: $0 [-s SUBSCRIPTION] [-t IMAGE_TAG] [--skip-build] [--prefix P] [--env E] [--location L]" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--subscription) SUBSCRIPTION="$2"; shift 2 ;;
        -t|--tag)          IMAGE_TAG="$2"; shift 2 ;;
        --skip-build)      SKIP_BUILD="true"; shift ;;
        --prefix)          PREFIX="$2"; shift 2 ;;
        --env)             ENVIRONMENT="$2"; shift 2 ;;
        --location)        LOCATION="$2"; shift 2 ;;
        -h|--help)         usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

require() {
    command -v "$1" >/dev/null 2>&1 || { echo "Required command '$1' not found on PATH." >&2; exit 1; }
}

echo "==> Checking prerequisites"
require az
require terraform
require docker

if ! az account show >/dev/null 2>&1; then
    echo "Not logged in to Azure. Run 'az login' first." >&2
    exit 1
fi

if [[ -n "${SUBSCRIPTION}" ]]; then
    echo "==> Selecting subscription: ${SUBSCRIPTION}"
    az account set --subscription "${SUBSCRIPTION}"
fi

ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
export ARM_SUBSCRIPTION_ID
export ARM_USE_AZUREAD="true"   # AAD data-plane auth for the state backend (no keys)
echo "    Subscription: $(az account show --query name -o tsv) (${ARM_SUBSCRIPTION_ID})"

if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not reachable. Start Docker and retry." >&2
    exit 1
fi

# Deterministic, non-identifying remote-state names (must match apply-infra.yml).
STATE_RG="rg-${PREFIX}-tfstate"
STATE_HASH="$(printf '%s' "${ARM_SUBSCRIPTION_ID}-${PREFIX}" | sha256sum | cut -c1-16)"
STATE_SA="sttf${STATE_HASH}"
STATE_CONTAINER="tfstate"
STATE_KEY="${PREFIX}-${ENVIRONMENT}.tfstate"

echo "==> Ensuring remote state storage (${STATE_SA})"
# The state resource group's location is immutable and independent of the app
# region -- if it already exists (e.g. an earlier deploy in another region),
# reuse its location so switching LOCATION doesn't fail with
# InvalidResourceGroupLocation.
STATE_LOCATION="$(az group show --name "${STATE_RG}" --query location -o tsv 2>/dev/null | tr -d '\r' || true)"
STATE_LOCATION="${STATE_LOCATION:-${LOCATION}}"
az group create --name "${STATE_RG}" --location "${STATE_LOCATION}" \
    --tags project=sre-agent-demo env="${ENVIRONMENT}" managed_by=terraform --output none
if ! az storage account show --name "${STATE_SA}" --resource-group "${STATE_RG}" >/dev/null 2>&1; then
    az storage account create --name "${STATE_SA}" --resource-group "${STATE_RG}" \
        --location "${STATE_LOCATION}" --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 \
        --allow-blob-public-access false --https-only true \
        --tags project=sre-agent-demo env="${ENVIRONMENT}" managed_by=terraform --output none
fi
SA_ID="$(az storage account show --name "${STATE_SA}" --resource-group "${STATE_RG}" --query id -o tsv)"
SIGNED_IN_ID="$(az ad signed-in-user show --query id -o tsv)"
az role assignment create --assignee-object-id "${SIGNED_IN_ID}" --assignee-principal-type User \
    --role "Storage Blob Data Contributor" --scope "${SA_ID}" --output none 2>/dev/null || true
echo "    Waiting for role propagation..."
created="false"
for _ in $(seq 1 12); do
    if az storage container create --name "${STATE_CONTAINER}" --account-name "${STATE_SA}" \
        --auth-mode login --output none 2>/dev/null; then created="true"; break; fi
    sleep 10
done
[[ "${created}" == "true" ]] || { echo "Could not create state container (role propagation timed out)." >&2; exit 1; }

echo "==> terraform init (remote azurerm backend)"
terraform -chdir="${INFRA_DIR}" init -input=false -migrate-state -force-copy \
    -backend-config="resource_group_name=${STATE_RG}" \
    -backend-config="storage_account_name=${STATE_SA}" \
    -backend-config="container_name=${STATE_CONTAINER}" \
    -backend-config="key=${STATE_KEY}"

echo "==> terraform apply (phase 1: platform, no apps yet)"
terraform -chdir="${INFRA_DIR}" apply -input=false -auto-approve \
    -var 'deploy_apps=false' -var "prefix=${PREFIX}" -var "environment=${ENVIRONMENT}" -var "location=${LOCATION}"

ACR_NAME="$(terraform -chdir="${INFRA_DIR}" output -raw acr_name)"
ACR_LOGIN_SERVER="$(terraform -chdir="${INFRA_DIR}" output -raw acr_login_server)"
echo "    ACR: ${ACR_LOGIN_SERVER}"

if [[ "${SKIP_BUILD}" != "true" ]]; then
    echo "==> Logging in to ACR"
    az acr login --name "${ACR_NAME}"

    for svc in "${SERVICES[@]}"; do
        echo "==> Building ${svc} -> ${svc}:${IMAGE_TAG}"
        docker build \
            -t "${ACR_LOGIN_SERVER}/${svc}:${IMAGE_TAG}" \
            -t "${ACR_LOGIN_SERVER}/${svc}:latest" \
            "${REPO_ROOT}/src/${svc}"
        docker push "${ACR_LOGIN_SERVER}/${svc}:${IMAGE_TAG}"
        docker push "${ACR_LOGIN_SERVER}/${svc}:latest"
    done
fi

echo "==> terraform apply (phase 2: container apps + alert)"
terraform -chdir="${INFRA_DIR}" apply -input=false -auto-approve \
    -var 'deploy_apps=true' -var "image_tag=${IMAGE_TAG}" \
    -var "prefix=${PREFIX}" -var "environment=${ENVIRONMENT}" -var "location=${LOCATION}"

FRONTEND_URL="$(terraform -chdir="${INFRA_DIR}" output -raw frontend_url)"
RESOURCE_GROUP="$(terraform -chdir="${INFRA_DIR}" output -raw resource_group_name)"
GRAFANA="$(terraform -chdir="${INFRA_DIR}" output -raw grafana_endpoint 2>/dev/null || true)"

echo ""
echo "============================================================"
echo " ContosoPay demo deployed"
echo "============================================================"
echo "  Frontend URL : ${FRONTEND_URL}"
echo "  Resource grp : ${RESOURCE_GROUP}"
[[ -n "${GRAFANA}" && "${GRAFANA}" != "null" ]] && echo "  Grafana      : ${GRAFANA}"
echo ""
echo " Remote Terraform state (set as GitHub Actions *variables* for apply-infra.yml):"
echo "  TFSTATE_RG        : ${STATE_RG}"
echo "  TFSTATE_SA        : ${STATE_SA}"
echo "  TFSTATE_CONTAINER : ${STATE_CONTAINER}"
echo "  TFSTATE_KEY       : ${STATE_KEY}"
echo ""
echo " Next steps — connect the Azure SRE Agent (see docs/sre-agent-setup.md §1-5):"
echo "  1. Go to https://sre.azure.com, create an SRE Agent, and point it at '${RESOURCE_GROUP}'."
echo "  2. Connect this GitHub repo (Code Access) and Azure Monitor as the incident platform."
echo "  3. Then pick a demo scenario and finish the wiring:"
echo "       Scenario A (on-the-spot): docs/scenario-a-direct.md  — grant Privileged access,"
echo "                                 then: scripts/trigger-incident-direct.sh"
echo "       Scenario B (full GitOps): docs/scenario-b-gitops.md  — grant Reader + deny policy,"
echo "                                 then: scripts/trigger-incident-gitops.sh (opens a PR)"
echo ""
