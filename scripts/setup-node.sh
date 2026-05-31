#!/usr/bin/env bash
# Run once on the control node: prepare /storage on every node + install build deps here.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

sudo mkdir -p "$ROOT"; sudo chown -R "$(id -un):" "$ROOT"
for w in $WORKER_NODES; do
  ssh "$w" "sudo mkdir -p $ROOT && sudo chown -R \$(id -un): $ROOT"
done

sudo apt-get update -qq
sudo apt-get install -y -qq build-essential pkg-config libssl-dev cmake unzip curl git gettext-base
command -v cargo >/dev/null || curl -sSf https://sh.rustup.rs | sh -s -- -y
if [ ! -x /usr/local/bin/protoc ]; then
  curl -sSL -o /tmp/protoc.zip https://github.com/protocolbuffers/protobuf/releases/download/v27.2/protoc-27.2-linux-x86_64.zip
  sudo unzip -o /tmp/protoc.zip -d /usr/local 'bin/protoc' 'include/*'
fi
pip3 install -q --user duckdb
echo "setup done"
