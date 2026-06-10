#!/usr/bin/env bash
# Verify the MINIO_EGRESS_BW knob empirically. The annotation shapes MinIO's
# AGGREGATE egress, and the real workload issues many concurrent S3 GETs, so we
# pull a test object over N parallel streams from a worker pod and sum the
# achieved throughput (a single TCP flow tops out ~2 Gbit on the overlay and
# would under-report). Run after deploy.sh; compare unshaped vs capped.
#   experiments/s3-central/measure-bw.sh [size_mib=512] [worker_node] [streams=16]
set -euo pipefail
export EXPERIMENT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$EXPERIMENT_DIR/../../scripts/lib/common.sh"

size_mib=${1:-512}; node=${2:-}; streams=${3:-16}; bytes=$(( size_mib * 1024 * 1024 ))
kubectl -n "$NAMESPACE" get deploy minio >/dev/null 2>&1 || { echo "FATAL: MinIO not deployed in ns $NAMESPACE -- run deploy.sh first"; exit 1; }
kubectl -n "$NAMESPACE" rollout status deploy/minio --timeout=120s >/dev/null

# 1. Ensure a public test object of the requested size (upload is MinIO ingress,
#    which MINIO_EGRESS_BW does NOT cap, so staging stays fast even when capped).
mc=$ROOT/bin/mc
[ -x "$mc" ] || { mkdir -p "$ROOT/bin"; curl -Ls https://dl.min.io/client/mc/release/linux-amd64/mc -o "$mc"; chmod +x "$mc"; }
kubectl -n "$NAMESPACE" port-forward svc/minio "${MINIO_PORT}:9000" >/dev/null 2>&1 &
pf=$!; trap 'kill $pf 2>/dev/null' EXIT; sleep 3
"$mc" alias set carma "http://127.0.0.1:${MINIO_PORT}" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" >/dev/null
"$mc" mb --ignore-existing carma/bwtest >/dev/null
"$mc" anonymous set download carma/bwtest >/dev/null
have=$("$mc" stat --json "carma/bwtest/obj-${size_mib}" 2>/dev/null | grep -o '"size":[0-9]*' | head -1 | cut -d: -f2) || true   # absent object: grep exits 1, don't let pipefail kill us
[ "${have:-0}" = "$bytes" ] || head -c "$bytes" /dev/zero | "$mc" pipe "carma/bwtest/obj-${size_mib}" >/dev/null
kill $pf 2>/dev/null; trap - EXIT

# 2. Pull it over $streams concurrent streams from a worker pod. Aggregate =
#    total bytes / wall time (~ the slowest stream's time_total); summing per-
#    stream average speeds would overcount when streams finish at different times.
[ -n "$node" ] || node=$(echo $WORKER_NODES | awk '{print $1}')
echo ">> pulling ${size_mib} MiB x ${streams} streams from MinIO via pod on $node (cap=${MINIO_EGRESS_BW:-none})..."
maxt=$(kubectl -n "$NAMESPACE" run "bwtest-$$" --image=nicolaka/netshoot --restart=Never --rm -i \
  --overrides="{\"apiVersion\":\"v1\",\"spec\":{\"nodeName\":\"$node\"}}" \
  --command -- sh -c "for i in \$(seq 1 ${streams}); do curl -s -o /dev/null -w '%{time_total}\n' http://minio:9000/bwtest/obj-${size_mib} & done; wait" </dev/null 2>/dev/null \
  | awk '{if ($1+0 > m) m=$1+0} END{printf "%.3f", m}')
awk -v t="$maxt" -v tot="$(( bytes * streams ))" -v st="$streams" -v cap="${MINIO_EGRESS_BW:-none}" 'BEGIN{
  if (t+0 <= 0) { print "FATAL: download failed (no timing) -- check MinIO reachability/auth"; exit 1 }
  bps = tot / t
  printf ">> measured: %.2f Gbit/s aggregate over %d streams  (%.0f MB/s)   [cap=%s]\n", bps*8/1e9, st, bps/1e6, cap }'
