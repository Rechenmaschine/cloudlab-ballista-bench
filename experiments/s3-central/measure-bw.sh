#!/usr/bin/env bash
# Verify the MINIO_EGRESS_BW knob empirically: pull a test object from MinIO via a
# pod on a worker node (the real pod-network read path executors use) and report
# achieved throughput. Run after deploy.sh; compare unshaped vs capped.
#   experiments/s3-central/measure-bw.sh [size_mib=4096] [worker_node]
set -euo pipefail
export EXPERIMENT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$EXPERIMENT_DIR/../../scripts/lib/common.sh"

size_mib=${1:-4096}; node=${2:-}; bytes=$(( size_mib * 1024 * 1024 ))
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
have=$("$mc" stat --json "carma/bwtest/obj-${size_mib}" 2>/dev/null | grep -o '"size":[0-9]*' | head -1 | cut -d: -f2)
[ "${have:-0}" = "$bytes" ] || head -c "$bytes" /dev/zero | "$mc" pipe "carma/bwtest/obj-${size_mib}" >/dev/null
kill $pf 2>/dev/null; trap - EXIT

# 2. Pull it from a worker pod (subject to the MinIO pod's egress cap).
[ -n "$node" ] || node=$(echo $WORKER_NODES | awk '{print $1}')
echo ">> pulling ${size_mib} MiB from MinIO via pod on $node (cap=${MINIO_EGRESS_BW:-none})..."
sp=$(kubectl -n "$NAMESPACE" run "bwtest-$$" --image=nicolaka/netshoot --restart=Never --rm -i \
  --overrides="{\"apiVersion\":\"v1\",\"spec\":{\"nodeName\":\"$node\"}}" \
  --command -- sh -c "curl -s -o /dev/null -w '%{speed_download}' http://minio:9000/bwtest/obj-${size_mib}" 2>/dev/null)
awk -v b="$sp" -v cap="${MINIO_EGRESS_BW:-none}" 'BEGIN{
  if (b+0 <= 0) { print "FATAL: download failed (0 B/s) -- check MinIO reachability/auth"; exit 1 }
  printf ">> measured: %.2f Gbit/s  (%.0f MB/s)   [cap=%s]\n", b*8/1e9, b/1e6, cap }'
