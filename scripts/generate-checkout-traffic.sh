#!/bin/bash
# ============================================================================
# Bounded synthetic checkout traffic for Scenario D.
#
# Posts generated test orders to the public frontend /api/checkout endpoint at a
# fixed rate for a finite duration. Start it BEFORE arming the incident and keep
# it running through recovery so the alerts and the post-fix check have data.
#
# Usage:
#   ./scripts/generate-checkout-traffic.sh [-u FRONTEND_URL] [-d SECONDS] [-i SECONDS]
#     -u  frontend URL (default: terraform output frontend_url; https only)
#     -d  duration in seconds (default 900, max 3600)
#     -i  interval between orders in seconds (default 5, min 1)
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)/infra"
readonly SCRIPT_DIR INFRA_DIR

FRONTEND_URL=""
DURATION=900
INTERVAL=5

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--url)      FRONTEND_URL="${2:?Missing value for $1}"; shift 2 ;;
        -d|--duration) DURATION="${2:?Missing value for $1}"; shift 2 ;;
        -i|--interval) INTERVAL="${2:?Missing value for $1}"; shift 2 ;;
        -h|--help)     echo "Usage: $0 [-u URL] [-d SECONDS] [-i SECONDS]" >&2; exit 1 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

command -v curl >/dev/null 2>&1 || { echo "curl not found on PATH." >&2; exit 1; }
[[ "${DURATION}" =~ ^[0-9]+$ && "${DURATION}" -ge 1 && "${DURATION}" -le 3600 ]] || {
    echo "Duration must be an integer between 1 and 3600 seconds." >&2; exit 1; }
[[ "${INTERVAL}" =~ ^[0-9]+$ && "${INTERVAL}" -ge 1 ]] || {
    echo "Interval must be an integer of at least 1 second." >&2; exit 1; }

if [[ -z "${FRONTEND_URL}" ]]; then
    command -v terraform >/dev/null 2>&1 || { echo "terraform not found; pass -u." >&2; exit 1; }
    FRONTEND_URL="$(terraform -chdir="${INFRA_DIR}" output -raw frontend_url)"
fi
[[ "${FRONTEND_URL}" == https://* ]] || { echo "Frontend URL must use https." >&2; exit 1; }
FRONTEND_URL="${FRONTEND_URL%/}"

OK=0
FAILED=0
trap 'echo; echo "==> Stopped. ok=${OK} failed=${FAILED}"' EXIT
END=$((SECONDS + DURATION))

echo "==> Sending test orders to ${FRONTEND_URL}/api/checkout every ${INTERVAL}s for ${DURATION}s"
while (( SECONDS < END )); do
    AMOUNT="$(( (RANDOM % 9000 + 1000) / 100 )).99"
    CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 \
        --request POST --header 'Content-Type: application/json' \
        --data "{\"amount\":${AMOUNT},\"currency\":\"EUR\"}" \
        "${FRONTEND_URL}/api/checkout" || true)"
    if [[ "${CODE}" =~ ^2 ]]; then OK=$((OK + 1)); else FAILED=$((FAILED + 1)); fi
    echo "$(date -u +%H:%M:%S) status=${CODE:-000} ok=${OK} failed=${FAILED}"
    sleep "${INTERVAL}"
done
