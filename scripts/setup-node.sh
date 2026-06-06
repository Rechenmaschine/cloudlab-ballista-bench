#!/usr/bin/env bash
# Run once on the control node: prepare /storage on every node + install build deps here.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

# Make every node DETERMINISTIC for benchmarking. Two knobs:
#  1. Disable hyperthreading (SMT) so a task slot maps to a real physical core,
#     not a sibling thread (else cores_per_executor overstates compute). `nosmt`
#     in GRUB persists across reboot.
#  2. Pin the CPU clock: governor=performance + turbo OFF => a FIXED base
#     frequency on every core. The default `schedutil` governor swings the clock
#     ~1.2-3.2 GHz with load, so cold/early tasks run slow and later tasks fast
#     (a ~1.8x within-run warm-up) AND different nodes idle at different clocks -
#     which silently pollutes per-task times and breaks the homogeneity the CPU
#     pin is supposed to give. Turbo is off because it's thermal/neighbour-
#     dependent and not sustainable on all cores at once => nondeterministic.
# Then restart kubelet so k8s re-reports the halved (SMT-off) core count.
# check-cluster.sh asserts SMT off + governor=performance.
tune_node() {
  echo off | sudo tee /sys/devices/system/cpu/smt/control >/dev/null 2>&1
  grep -q nosmt /etc/default/grub || {
    sudo sed -i 's/\(GRUB_CMDLINE_LINUX="[^"]*\)"/\1 nosmt"/' /etc/default/grub
    sudo update-grub >/dev/null 2>&1
  }
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee "$g" >/dev/null 2>&1; done
  [ -e /sys/devices/system/cpu/intel_pstate/no_turbo ] && echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo >/dev/null 2>&1
  [ -e /sys/devices/system/cpu/cpufreq/boost ] && echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost >/dev/null 2>&1
  # governor=performance caps the MAX but leaves the floor low: idle cores still
  # drop to ~1.2GHz and sleep in C-states, so at low concurrency tasks land on
  # cold cores and ramp up mid-execution -> their measured compute is inflated,
  # which made "total work" spuriously DECREASE with concurrency. Pin the floor
  # to the ceiling AND disable deep C-states so every core holds a fixed ~2.4GHz
  # whether busy or idle -> per-task compute is concurrency-independent.
  [ -e /sys/devices/system/cpu/intel_pstate/min_perf_pct ] && echo 100 | sudo tee /sys/devices/system/cpu/intel_pstate/min_perf_pct >/dev/null 2>&1
  for c in /sys/devices/system/cpu/cpu*/cpufreq; do sudo tee "$c/scaling_min_freq" < "$c/scaling_max_freq" >/dev/null 2>&1; done
  for s in /sys/devices/system/cpu/cpu*/cpuidle/state[1-9]; do echo 1 | sudo tee "$s/disable" >/dev/null 2>&1; done
  sudo systemctl restart kubelet 2>/dev/null || true
}

sudo mkdir -p "$ROOT"; sudo chown -R "$(id -un):" "$ROOT"
echo ">> tuning control node (SMT off, fixed clock)"
# Best-effort: every knob suppresses errors, but `set -e` would still abort the
# whole script (incl. the dep installs below) if a sysfs write is rejected --
# e.g. no_turbo/min_perf_pct on a CPU running intel_pstate in passive mode. Keep
# tuning non-fatal; check-cluster.sh is what asserts the knobs that must hold.
tune_node || echo "  (some tuning knobs not settable on this node; continuing -- verify with check-cluster.sh)"
for w in $WORKER_NODES; do
  echo ">> preparing $w (storage, iperf3, SMT off, fixed clock)"
  # storage dirs + iperf3 (for check-cluster.sh --net) + SMT off + clock pin
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$w" \
    "sudo mkdir -p $ROOT && sudo chown -R \$(id -un): $ROOT && sudo apt-get install -y -qq iperf3; $(declare -f tune_node); tune_node" \
    || echo "  $w unreachable, skipped"
done

sudo apt-get update -qq
sudo apt-get install -y -qq build-essential pkg-config libssl-dev cmake unzip curl git gettext-base iperf3 jq
command -v cargo >/dev/null || curl -sSf https://sh.rustup.rs | sh -s -- -y
if [ ! -x /usr/local/bin/protoc ]; then
  curl -sSL -o /tmp/protoc.zip https://github.com/protocolbuffers/protobuf/releases/download/v27.2/protoc-27.2-linux-x86_64.zip
  sudo unzip -o /tmp/protoc.zip -d /usr/local 'bin/protoc' 'include/*'
fi
pip3 install -q --user duckdb
echo "setup done"
