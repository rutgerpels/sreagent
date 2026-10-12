#!/usr/bin/env bash
# Runs ON the Scenario D runner VM (pushed through `az vm run-command invoke`).
# Installs the build tooling and registers a GitHub Actions runner.
# Arguments: REPO RUNNER_NAME LABELS REG_TOKEN
# The registration token is short-lived and single-use; it is never written to disk.
set -euo pipefail

REPO="$1"
RUNNER_NAME="$2"
LABELS="$3"
REG_TOKEN="$4"
RUNNER_USER="runner"
RUNNER_DIR="/opt/actions-runner"

export DEBIAN_FRONTEND=noninteractive

if ! id "$RUNNER_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$RUNNER_USER"
fi

apt-get update -y
apt-get install -y ca-certificates curl gnupg jq unzip git docker.io

# Azure CLI
if ! command -v az >/dev/null 2>&1; then
  curl -sL https://aka.ms/InstallAzureCLIDeb | bash
fi

# Node.js 20 (the workflows build and test the Node services)
if ! command -v node >/dev/null 2>&1 || ! node --version | grep -q '^v20\.'; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi

systemctl enable --now docker
usermod -aG docker "$RUNNER_USER"

# GitHub Actions runner, verified against the published checksum
if [ ! -x "$RUNNER_DIR/config.sh" ]; then
  release_json="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest)"
  version="$(jq -r '.tag_name' <<<"$release_json" | sed 's/^v//')"
  asset="actions-runner-linux-x64-${version}.tar.gz"
  expected_sha="$(jq -r '.body' <<<"$release_json" | grep -oE '<!-- BEGIN SHA linux-x64 -->[0-9a-f]{64}' | grep -oE '[0-9a-f]{64}' | head -n1 || true)"
  mkdir -p "$RUNNER_DIR"
  curl -fsSL -o "/tmp/${asset}" "https://github.com/actions/runner/releases/download/v${version}/${asset}"
  if [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo "${expected_sha}  /tmp/${asset}" | sha256sum -c -
  else
    echo "WARNING: could not parse published checksum; skipping verification" >&2
  fi
  tar xzf "/tmp/${asset}" -C "$RUNNER_DIR"
  rm -f "/tmp/${asset}"
  chown -R "$RUNNER_USER":"$RUNNER_USER" "$RUNNER_DIR"
fi

cd "$RUNNER_DIR"
if [ ! -f .runner ]; then
  ./bin/installdependencies.sh
  sudo -u "$RUNNER_USER" ./config.sh --unattended --replace \
    --url "https://github.com/${REPO}" \
    --token "$REG_TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$LABELS" \
    --work _work
fi

./svc.sh install "$RUNNER_USER" || true
./svc.sh start
./svc.sh status | head -n 5
echo "runner-d bootstrap complete"
