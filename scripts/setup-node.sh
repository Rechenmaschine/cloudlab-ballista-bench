#!/usr/bin/env bash
# Run once on the control node: prepare /storage on every node + install build deps here.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

# Disable hyperthreading (SMT) so each task slot maps to a real physical core,
# not a sibling thread - otherwise "40 cores" is really 20 cores + 20 siblings
# and cores_per_executor overstates compute. Runtime toggle for immediate
# effect, `nosmt` in GRUB so it survives reboots, then restart kubelet so
# kubernetes re-reports the real (halved) core count. Baked in here so every
# node is identical + reproducible; check-cluster.sh asserts it stayed off.
disable_smt() {
  echo off | sudo tee /sys/devices/system/cpu/smt/control >/dev/null 2>&1
  grep -q nosmt /etc/default/grub || {
    sudo sed -i 's/\(GRUB_CMDLINE_LINUX="[^"]*\)"/\1 nosmt"/' /etc/default/grub
    sudo update-grub >/dev/null 2>&1
  }
  sudo systemctl restart kubelet 2>/dev/null || true
}

sudo mkdir -p "$ROOT"; sudo chown -R "$(id -un):" "$ROOT"
echo ">> disabling SMT on control node"; disable_smt
for w in $WORKER_NODES; do
  echo ">> preparing $w (storage, iperf3, SMT off)"
  # storage dirs + iperf3 (for check-cluster.sh --net) + disable SMT
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$w" \
    "sudo mkdir -p $ROOT && sudo chown -R \$(id -un): $ROOT && sudo apt-get install -y -qq iperf3; $(declare -f disable_smt); disable_smt" \
    || echo "  $w unreachable, skipped"
done

sudo apt-get update -qq
sudo apt-get install -y -qq build-essential pkg-config libssl-dev cmake unzip curl git gettext-base iperf3
command -v cargo >/dev/null || curl -sSf https://sh.rustup.rs | sh -s -- -y
if [ ! -x /usr/local/bin/protoc ]; then
  curl -sSL -o /tmp/protoc.zip https://github.com/protocolbuffers/protobuf/releases/download/v27.2/protoc-27.2-linux-x86_64.zip
  sudo unzip -o /tmp/protoc.zip -d /usr/local 'bin/protoc' 'include/*'
fi
pip3 install -q --user duckdb
echo "setup done"
