#!/bin/bash
# Exercise the checkout chain without publishing host ports or sending telemetry.
set -euo pipefail

[[ $# == 2 ]] || { echo "Usage: $0 <acr-login-server> <commit-sha>" >&2; exit 1; }
readonly registry="$1"
readonly sha="$2"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "A full commit SHA is required." >&2; exit 1; }
readonly network="scenario-d-smoke-${sha:0:12}-$$"
readonly payment="${network}-payment"
readonly checkout="${network}-checkout"
readonly frontend="${network}-frontend"

cleanup() {
    local result=$?
    if (( result != 0 )); then
        for container in "$payment" "$checkout" "$frontend"; do
            docker logs --tail 30 "$container" 2>/dev/null || true
        done
    fi
    for container in "$frontend" "$checkout" "$payment"; do
        docker rm --force "$container" >/dev/null 2>&1 || true
    done
    docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker network create "$network" >/dev/null
docker run --detach --name "$payment" --network "$network" --network-alias payment \
    --env ENABLE_SLOW_LEAK=false --env PAYMENT_FAILURE_MODE=off \
    "$registry/payment-service:$sha" >/dev/null
docker run --detach --name "$checkout" --network "$network" --network-alias checkout \
    --env PAYMENT_SERVICE_URL=http://payment:8080 \
    "$registry/checkout-api:$sha" >/dev/null
docker run --detach --name "$frontend" --network "$network" \
    --env CHECKOUT_API_URL=http://checkout:8080 \
    "$registry/frontend:$sha" >/dev/null

for attempt in {1..30}; do
    if docker exec "$frontend" node -e '
        fetch("http://localhost:8080/api/checkout", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ amount: 42, currency: "EUR" }),
            signal: AbortSignal.timeout(5000),
        }).then(async response => {
            const body = await response.json();
            if (!response.ok || body.status !== "confirmed" ||
                body.amount !== 42 || body.currency !== "EUR" ||
                body.payment?.status !== "approved") throw new Error("Checkout failed");
        }).catch(error => { console.error(error.message); process.exitCode = 1; });
    '; then
        echo "Container checkout smoke succeeded."
        exit 0
    fi
    sleep 2
done
echo "Container checkout smoke failed after 30 attempts." >&2
exit 1
