#!/bin/bash
# ============================================================================
# Trigger (or reset) the ContosoPay demo incident the GitOps way.
#
# Instead of poking the live Azure resources, this opens a PULL REQUEST that
# flips the planted memory-leak flag (enable_slow_leak) in the committed IaC
# file infra/leak.auto.tfvars.
#
# Merging that PR runs .github/workflows/apply-infra.yml, which `terraform
# apply`s the change against the remote state and deploys it. The incident thus
# enters the system as a reviewable code change + deployment -- exactly the kind
# of change the Azure SRE Agent can later correlate the incident back to.
#
# Requires the GitHub CLI (`gh`) authenticated against this repository.
#
# Usage:
#   ./scripts/trigger-incident-gitops.sh                 # open a PR arming the leak
#   ./scripts/trigger-incident-gitops.sh --reset         # open a PR turning it off
#   ./scripts/trigger-incident-gitops.sh --base main     # override base branch
#   ./scripts/trigger-incident-gitops.sh --branch NAME   # override branch name
#   ./scripts/trigger-incident-gitops.sh --no-pr         # push branch, skip gh pr create
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TFVARS_FILE="${REPO_ROOT}/infra/leak.auto.tfvars"
readonly SCRIPT_DIR REPO_ROOT TFVARS_FILE

RESET="false"
BRANCH=""
BASE="main"
NO_PR="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reset)        RESET="true"; shift ;;
        --branch)       BRANCH="$2"; shift 2 ;;
        --base)         BASE="$2"; shift 2 ;;
        --no-pr)        NO_PR="true"; shift ;;
        -h|--help)      echo "Usage: $0 [--reset] [--branch NAME] [--base BR] [--no-pr]" >&2; exit 1 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

command -v git >/dev/null 2>&1 || { echo "Required command 'git' not found on PATH." >&2; exit 1; }
if [[ "${NO_PR}" != "true" ]]; then
    command -v gh >/dev/null 2>&1 || {
        echo "Required command 'gh' (GitHub CLI) not found. Install it, run 'gh auth login', or pass --no-pr." >&2
        exit 1
    }
fi
git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "${REPO_ROOT} is not a git repository." >&2; exit 1; }
[[ -f "${TFVARS_FILE}" ]] || { echo "Source-of-truth file not found: ${TFVARS_FILE}" >&2; exit 1; }

DESIRED="true"; [[ "${RESET}" == "true" ]] && DESIRED="false"
STAMP="$(date -u +%Y%m%d%H%M%S)"

if [[ -z "${BRANCH}" ]]; then
    if [[ "${RESET}" == "true" ]]; then BRANCH="Bug/disable-memory-leak-${STAMP}"; else BRANCH="Feature/trigger-memory-leak-${STAMP}"; fi
fi

if [[ "${RESET}" == "true" ]]; then
    TITLE="fix(payment-service): disable slow memory leak (enable_slow_leak=false)"
    WHY="Remediates the ContosoPay memory-leak incident by turning the planted fault off. Merging this PR runs the \`apply-infra\` workflow, which \`terraform apply\`s the change and rolls a fresh payment-service revision (clearing leaked memory)."
    ACTION="disable"
else
    TITLE="demo(payment-service): enable slow memory leak (enable_slow_leak=true)"
    WHY="Arms the ContosoPay demo incident. Merging this PR runs the \`apply-infra\` workflow, which \`terraform apply\`s the change and deploys the leak. payment-service memory then climbs over ~30-40 min until the Azure Monitor alert fires and the SRE Agent investigates."
    ACTION="enable"
fi

read -r -d '' BODY <<EOF || true
## What

Sets \`enable_slow_leak = ${DESIRED}\` in \`infra/leak.auto.tfvars\`.

## Why

${WHY}

## How it deploys

GitOps only -- no one edits the live Azure resources by hand. Merge to \`${BASE}\` -> \`.github/workflows/apply-infra.yml\` -> \`terraform apply\`.
EOF

echo "==> Will ${ACTION} the leak via a PR (${BRANCH} -> ${BASE})"

# Work from an up-to-date base without disturbing the user's current checkout.
git -C "${REPO_ROOT}" fetch origin "${BASE}"
git -C "${REPO_ROOT}" checkout -b "${BRANCH}" "origin/${BASE}"

cleanup() { git -C "${REPO_ROOT}" checkout "${BASE}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Portable in-place edit (GNU and BSD sed).
tmp="$(mktemp)"
sed -E "s/^[[:space:]]*enable_slow_leak[[:space:]]*=.*/enable_slow_leak = ${DESIRED}/" "${TFVARS_FILE}" > "${tmp}"
mv "${tmp}" "${TFVARS_FILE}"

if git -C "${REPO_ROOT}" diff --quiet -- "${TFVARS_FILE}"; then
    echo "    enable_slow_leak is already ${DESIRED}; nothing to change."
    git -C "${REPO_ROOT}" checkout "${BASE}" >/dev/null 2>&1
    git -C "${REPO_ROOT}" branch -D "${BRANCH}" >/dev/null 2>&1 || true
    trap - EXIT
    exit 0
fi

git -C "${REPO_ROOT}" add "${TFVARS_FILE}"
git -C "${REPO_ROOT}" commit -m "${TITLE}"
git -C "${REPO_ROOT}" push -u origin "${BRANCH}"

if [[ "${NO_PR}" == "true" ]]; then
    echo "==> Branch pushed. Open a PR from '${BRANCH}' into '${BASE}' to deploy the change."
else
    REPO_SLUG="$(gh repo view --json nameWithOwner -q '.nameWithOwner')"
    PR_URL="$(gh pr create --repo "${REPO_SLUG}" --base "${BASE}" --head "${BRANCH}" --title "${TITLE}" --body "${BODY}")"
    echo "==> Pull request opened:"
    echo "    ${PR_URL}"
    echo "    Review + merge it to deploy the change (apply-infra workflow runs on merge)."
fi
