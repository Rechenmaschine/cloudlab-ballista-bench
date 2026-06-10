#!/usr/bin/env bash
# Run the s3-central concurrency sweep under three MinIO egress conditions, in
# order: no cap, 2.5 Gbit/s, 1 Gbit/s. Each condition tags its runs with a
# NAME_PREFIX so they land in distinct run dirs and resume independently (re-run
# this script to resume after an abort -- completed points are skipped).
#   KS / REPS / QUERIES overridable via env.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export KS="${KS:-1 2 3 5 10 15 20}" REPS="${REPS:-1 2 3}" QUERIES="${QUERIES:-1000}"

run_pass() {  # <prefix> <egress_bw>
  echo "############################################################"
  echo "## PASS '$1'  cap=${2:-none}  KS={$KS} REPS={$REPS} Q=$QUERIES  $(date '+%F %T')"
  echo "############################################################"
  MINIO_EGRESS_BW="$2" NAME_PREFIX="${1}_" "$here/sweep.sh"
}

run_pass nolim ""     || { echo "## DRIVER STOP: pass nolim failed"; exit 1; }
run_pass bw2g5 2500M  || { echo "## DRIVER STOP: pass bw2g5 failed"; exit 1; }
run_pass bw1g  1G     || { echo "## DRIVER STOP: pass bw1g failed";  exit 1; }
echo "## ALL PASSES DONE $(date '+%F %T')"
