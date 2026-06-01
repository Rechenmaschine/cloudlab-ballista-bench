#!/usr/bin/env bash
# Run one benchmark: ./run.sh [queries] [concurrency] [name]
# Results go to a fresh $RUNS_DIR/<name>/ (never overwritten).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

# Ctrl-C cleanly stops the drivers and the progress tail. pkill -P only reaches
# direct children, so kill the progress subshell's own children (the kubectl
# log-follow) first, otherwise it orphans and keeps printing after exit.
cleanup() {
  trap - INT TERM
  echo; echo "stopping..."
  [ -n "${prog:-}" ] && pkill -P "$prog" 2>/dev/null   # kubectl/grep/awk in the tail
  pkill -P $$ 2>/dev/null                               # drivers + the tail subshell
  exit 130
}
trap cleanup INT TERM

queries=${1:-2000}
concurrency=${2:-1}
ts=$(date +%Y%m%d-%H%M%S)
name=${3:+$3-}$ts        # "<name>-<timestamp>" if named, else just "<timestamp>"
run=$RUNS_DIR/$name
mkdir -p "$run"

sched=$(kubectl -n "$NAMESPACE" get pod -l app=ballista-scheduler -o jsonpath='{.items[0].status.podIP}')
cli=$BALLISTA_SRC/target/release/ballista-cli

# Don't benchmark an unhealthy cluster (a flapping cluster silently drops jobs).
execs=$(curl -s "http://$sched:$SCHEDULER_PORT/api/executors" | grep -o '"host":' | wc -l)
[ "$execs" -ge 1 ] || { echo "no executors registered (scheduler $sched) - check scripts/status.sh"; rmdir "$run"; exit 1; }
echo ">> run '$name': $queries queries, concurrency $concurrency, scheduler $sched ($execs executors)"

echo ">> [1/3] generating SQL..."
python3 bin/gen_sql.py --workload "$WORKLOAD_CSV" --data-dir "$DATA_DIR" \
  --out-dir "$run" --limit "$queries" --shards "$concurrency"

start=$(date -u -d '2 seconds ago' +%Y-%m-%dT%H:%M:%SZ)

# The full per-stage CARMA trace (kind:"stage_trace") is appended by the
# scheduler to a fixed host file. Record its size now so we can slice out
# exactly this run's portion afterwards (the writer is append-only and shared
# across runs of the same deployment).
trace_file="$TRACE_DIR/stages.jsonl"
trace_off=$([ -f "$trace_file" ] && wc -c < "$trace_file" || echo 0)

echo ">> [2/3] submitting queries (this is the timed part)..."
# Stream the scheduler's ROLLUP metrics to disk LIVE and derive the progress
# counter from the same stream. A post-hoc `logs --since-time` loses lines once
# kubelet rotates the container log (it silently dropped ~75% of a 2000-query
# run). This stream is the lightweight rollup (kind:stage/job); the full
# carma trace is the host file sliced below.
( kubectl -n "$NAMESPACE" logs deploy/ballista-scheduler -f --since-time="$start" 2>/dev/null \
    | grep --line-buffered '"kind":"' \
    | tee "$run/rollups.jsonl" \
    | grep --line-buffered '"kind":"job"' \
    | awk "{ printf \"\r  completed: %d/$queries\", NR; fflush() }" ) &
prog=$!

if [ "$concurrency" -le 1 ]; then
  "$cli" --host "$sched" --port "$SCHEDULER_PORT" --quiet -f "$run/setup.sql" -f "$run/workload.sql" > "$run/cli.log" 2>&1
else
  pids=""
  for i in $(seq 0 $((concurrency - 1))); do
    "$cli" --host "$sched" --port "$SCHEDULER_PORT" --quiet -f "$run/setup.sql" -f "$run/workload.$i.sql" > "$run/cli.$i.log" 2>&1 &
    pids="$pids $!"
  done
  wait $pids
fi

sleep 2                                              # let trailing rollups + trace lines flush
pkill -P "$prog" 2>/dev/null; kill "$prog" 2>/dev/null || true; echo

# Slice this run's portion of the shared trace file into the run dir. This is
# the artifact carma-all ingests (carma::trace::load_stage_trace).
tail -c "+$((trace_off + 1))" "$trace_file" > "$run/stages.jsonl" 2>/dev/null || : > "$run/stages.jsonl"
echo ">> [3/3] full trace -> $run/stages.jsonl  (rollups -> $run/rollups.jsonl)"

# Run-level cluster shape: ONLY what we MEASURE off the live cluster. The cost
# model's knobs (cache budget, bandwidth, pricing) are NOT recorded here -- they
# belong to carma-all and are applied at replay time. num_executors is measured;
# cores_per_executor is the PINNED TASK_SLOTS (executors are homogenized via
# --concurrent-tasks, so the slot count, not a node's physical core count, is the
# cluster's true parallelism unit). Memory is measured from a worker (uniform RAM).
memraw=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{.items[0].status.capacity.memory}' 2>/dev/null || echo "0Ki")
case "$memraw" in
  *Ki) mem_bytes=$(( ${memraw%Ki} * 1024 )) ;;
  *Mi) mem_bytes=$(( ${memraw%Mi} * 1048576 )) ;;
  *Gi) mem_bytes=$(( ${memraw%Gi} * 1073741824 )) ;;
  *[0-9]) mem_bytes=$memraw ;;
  *) mem_bytes=0 ;;
esac
cat > "$run/cluster.json" <<JSON
{
  "cluster_hardware": {
    "num_executors": $execs,
    "cores_per_executor": $TASK_SLOTS,
    "memory_per_executor_bytes": $mem_bytes
  }
}
JSON

# Config snapshot: capture EXACTLY what produced this run so it's reproducible.
# cluster.json/meta.txt record the cluster shape and the request; this records
# the .env knobs + the code versions + what the executors were ACTUALLY pinned
# to (cgroup truth from the live pod, not just the .env intent).
cp ./.env "$run/env.snapshot"
{
  echo "bench_repo_rev=$(git rev-parse --short HEAD 2>/dev/null)$([ -n "$(git status --porcelain 2>/dev/null)" ] && echo -dirty)"
  echo "ballista_ref=$BALLISTA_REF"
  echo "ballista_rev=$(git -C "$BALLISTA_SRC" rev-parse --short HEAD 2>/dev/null)"
  echo "image_tag=$IMAGE_TAG"
  echo "task_slots=$TASK_SLOTS"
  echo "control_node=$CONTROL_NODE"
  echo "worker_nodes=$WORKER_NODES"
  echo "executor_cpu_request=$(kubectl -n "$NAMESPACE" get pod -l app=ballista-executor -o jsonpath='{.items[0].spec.containers[0].resources.requests.cpu}' 2>/dev/null)"
  echo "executor_cpu_limit=$(kubectl -n "$NAMESPACE" get pod -l app=ballista-executor -o jsonpath='{.items[0].spec.containers[0].resources.limits.cpu}' 2>/dev/null)"
  echo "executor_qos=$(kubectl -n "$NAMESPACE" get pod -l app=ballista-executor -o jsonpath='{.items[0].status.qosClass}' 2>/dev/null)"
  # SMT/core state: executor node's real core count (16/20 => hyperthreading off)
  # + the control node's smt toggle, so a run records whether HT silently returned.
  exnode=$(kubectl -n "$NAMESPACE" get pod -l app=ballista-executor -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
  echo "executor_node=$exnode"
  echo "executor_node_cpus=$(kubectl get node "$exnode" -o jsonpath='{.status.capacity.cpu}' 2>/dev/null)"
  echo "smt_control=$(cat /sys/devices/system/cpu/smt/control 2>/dev/null)"
} > "$run/config.txt"

submitted=$(cat "$run"/workload*.sql 2>/dev/null | grep -c ';')
jobs=$(grep -c '"kind":"job"' "$run/rollups.jsonl" || true)
stage_records=$(grep -c '"kind":"stage_trace"' "$run/stages.jsonl" || true)
{
  echo "queries_requested=$queries"
  echo "queries_submitted=$submitted"
  echo "concurrency=$concurrency"
  echo "date=$(date -Is)"
  echo "jobs=$jobs"
  echo "stage_records=$stage_records"
} | tee "$run/meta.txt"
if [ "$stage_records" -eq 0 ]; then
  echo "WARNING: no stage_trace records captured - is BALLISTA_STAGE_TRACE_FILE set on the scheduler? (re-run deploy.sh after pulling)" | tee -a "$run/meta.txt"
fi
if [ "$jobs" -lt "$submitted" ]; then
  echo "WARNING: captured $jobs/$submitted job rollups - cluster may have been unhealthy mid-run" | tee -a "$run/meta.txt"
fi
echo "results: $run"
