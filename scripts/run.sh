#!/usr/bin/env bash
# Run one benchmark: ./run.sh [queries] [concurrency] [name]
# Results go to a fresh $RUNS_DIR/<name>/ (never overwritten).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

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
echo "executors registered: $execs"

python3 bin/gen_sql.py --workload "$WORKLOAD_CSV" --data-dir "$DATA_DIR" \
  --out-dir "$run" --limit "$queries" --shards "$concurrency"

# Mark the log start, run the queries, then pull the scheduler's stage metrics
# emitted since then (one shot - no fragile long-lived `logs -f` stream).
start=$(date -u -d '2 seconds ago' +%Y-%m-%dT%H:%M:%SZ)

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

kubectl -n "$NAMESPACE" logs deploy/ballista-scheduler --since-time="$start" > "$run/stages.jsonl"

submitted=$(cat "$run"/workload*.sql 2>/dev/null | grep -c ';')
jobs=$(grep -c '"kind":"job"' "$run/stages.jsonl" || true)
{
  echo "queries_requested=$queries"
  echo "queries_submitted=$submitted"
  echo "concurrency=$concurrency"
  echo "date=$(date -Is)"
  echo "jobs=$jobs"
  echo "stages=$(grep -c '"kind":"stage"' "$run/stages.jsonl" || true)"
} | tee "$run/meta.txt"
[ "$jobs" -lt "$submitted" ] && echo "WARNING: captured $jobs/$submitted job rollups - cluster may have been unhealthy mid-run" | tee -a "$run/meta.txt"
echo "results: $run"
