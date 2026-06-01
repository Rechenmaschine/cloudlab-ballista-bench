#!/usr/bin/env bash
# Run a sequence of benchmark configs back-to-back on the live cluster (no
# redeploy between runs; the scheduler + executors stay up, so this just
# replays more workloads). Use it to gather replicates (same config, repeated)
# and concurrency sweeps so the no-cache calibration gets error bars.
#
# Each argument is "QUERIES:CONCURRENCY:NAME". Runs are sequential because they
# share the scheduler's append-only trace file (run.sh slices each run's
# portion by byte offset); overlapping runs would interleave and corrupt the
# slices.
#
# Usage:
#   scripts/sweep.sh 1000:20:rep1 1000:20:rep2 1000:20:rep3
#   scripts/sweep.sh 1000:10:k10 1000:20:k20 1000:40:k40
set -euo pipefail
cd "$(dirname "$0")/.."

for spec in "$@"; do
  IFS=: read -r q c n <<<"$spec"
  echo "===== sweep run: ${q} queries, K=${c}, name=${n} ====="
  bash scripts/run.sh "$q" "$c" "$n"
done
echo ">> sweep complete (${#} runs)"
