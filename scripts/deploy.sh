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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFRA_DIR="${REPO_ROOT}/infra"
readonly SCRIPT_DIR REPO_ROOT INFRA_DIR
SERVICES=("frontend" "checkout-api" "payment-service")

usage() {
    echo "Usage: $0 [-s SUBSCRIPTION] [-t IMAGE_TAG] [--skip-build]" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--subscription) SUBSCRIPTION="$2"; shift 2 ;;
        -t|--tag)          IMAGE_TAG="$2"; shift 2 ;;
        --skip-build)      SKIP_BUILD="true"; shift ;;
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
echo "    Subscription: $(az account show --query name -o tsv) (${ARM_SUBSCRIPTION_ID})"

if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not reachable. Start Docker and retry." >&2
    exit 1
fi

echo "==> terraform init"
terraform -chdir="${INFRA_DIR}" init -input=false

echo "==> terraform apply (phase 1: platform, no apps yet)"
terraform -chdir="${INFRA_DIR}" apply -input=false -auto-approve -var 'deploy_apps=false'

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
    -var 'deploy_apps=true' -var "image_tag=${IMAGE_TAG}"

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
echo " Next steps — connect the Azure SRE Agent:"
echo "  1. Go to https://sre.azure.com and create an SRE Agent."
echo "  2. Point it at resource group '${RESOURCE_GROUP}'."
echo "  3. Connect this GitHub repository (for commit correlation)."
echo "  4. Subscribe the agent to action group 'ag-sre-*' in the RG."
echo "  5. Run scripts/trigger-incident.sh to start the demo incident."
echo ""
