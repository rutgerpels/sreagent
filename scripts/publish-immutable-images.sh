#!/bin/bash

# Publishes one image per commit SHA, locks the ACR manifest, and emits digests.

set -euo pipefail

readonly SHA_PATTERN='^[0-9a-f]{40}$'
readonly DIGEST_PATTERN='^sha256:[0-9a-f]{64}$'
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Error: required command '$1' was not found." >&2
        exit 1
    }
}

if (( $# < 5 )); then
    echo "Usage: $0 <acr-name> <acr-login-server> <commit-sha> <output-file> <service>..." >&2
    exit 1
fi

readonly ACR_NAME="$1"
readonly ACR_LOGIN_SERVER="$2"
readonly IMAGE_TAG="$3"
readonly OUTPUT_FILE="$4"
shift 4
readonly SERVICES=("$@")
readonly SOURCE_REPOSITORY="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown/unknown}"

require_command az
require_command docker
require_command jq
[[ "${IMAGE_TAG}" =~ ${SHA_PATTERN} ]] || {
    echo "Error: image tag must be a full lowercase commit SHA." >&2
    exit 1
}

repositories_json="$(az acr repository list --name "${ACR_NAME}" --output json)"
digests='{}'

for service in "${SERVICES[@]}"; do
    repository_exists="$(jq --arg service "${service}" 'index($service) != null' <<< "${repositories_json}")"
    tag_exists=false
    if [[ "${repository_exists}" == "true" ]]; then
        tags_json="$(az acr repository show-tags --name "${ACR_NAME}" --repository "${service}" --output json)"
        tag_exists="$(jq --arg tag "${IMAGE_TAG}" 'index($tag) != null' <<< "${tags_json}")"
    fi

    if [[ "${tag_exists}" == "true" ]]; then
        metadata="$(az acr repository show --name "${ACR_NAME}" --image "${service}:${IMAGE_TAG}" --output json)"
        write_enabled="$(jq -r '.changeableAttributes.writeEnabled' <<< "${metadata}")"
        delete_enabled="$(jq -r '.changeableAttributes.deleteEnabled' <<< "${metadata}")"
        if [[ "${write_enabled}" != "false" || "${delete_enabled}" != "false" ]]; then
            echo "Error: ${service}:${IMAGE_TAG} exists but is not write/delete locked; refusing a mutable SHA tag." >&2
            exit 1
        fi
        echo "Reusing locked image ${service}:${IMAGE_TAG}." >&2
    else
        [[ "${SKIP_BUILD:-false}" != "true" ]] || {
            echo "Error: ${service}:${IMAGE_TAG} is absent and SKIP_BUILD=true." >&2
            exit 1
        }
        docker build \
            --label "org.opencontainers.image.revision=${IMAGE_TAG}" \
            --label "org.opencontainers.image.source=${SOURCE_REPOSITORY}" \
            --tag "${ACR_LOGIN_SERVER}/${service}:${IMAGE_TAG}" \
            "${REPOSITORY_ROOT}/src/${service}"
        docker push "${ACR_LOGIN_SERVER}/${service}:${IMAGE_TAG}"
        az acr repository update \
            --name "${ACR_NAME}" \
            --image "${service}:${IMAGE_TAG}" \
            --write-enabled false \
            --delete-enabled false \
            --output none
    fi

    metadata="$(az acr repository show --name "${ACR_NAME}" --image "${service}:${IMAGE_TAG}" --output json)"
    digest="$(jq -r '.digest // empty' <<< "${metadata}")"
    write_enabled="$(jq -r '.changeableAttributes.writeEnabled' <<< "${metadata}")"
    delete_enabled="$(jq -r '.changeableAttributes.deleteEnabled' <<< "${metadata}")"
    [[ "${digest}" =~ ${DIGEST_PATTERN} ]] || {
        echo "Error: ACR returned an invalid digest for ${service}:${IMAGE_TAG}." >&2
        exit 1
    }
    [[ "${write_enabled}" == "false" && "${delete_enabled}" == "false" ]] || {
        echo "Error: ${service}:${IMAGE_TAG} could not be locked." >&2
        exit 1
    }
    digests="$(jq -c --arg service "${service}" --arg digest "${digest}" '. + {($service): $digest}' <<< "${digests}")"
done

printf '%s\n' "${digests}" > "${OUTPUT_FILE}"
