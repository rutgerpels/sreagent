#!/usr/bin/env bash
# Scenario D only; Azure mutation is delegated to the private-runner workflow.
set -euo pipefail
for tool in az docker node python3 jq git; do
  command -v "$tool" >/dev/null || { echo "Missing runner tool: $tool" >&2; exit 1; }
done
[[ "${SCENARIO_D_PRIVATE_RUNNER:-}" == true ]] || { echo "Use the Scenario D private runner workflow." >&2; exit 1; }
cd "$(dirname "${BASH_SOURCE[0]}")/.."
node scripts/scenario-d-bicep.mjs
