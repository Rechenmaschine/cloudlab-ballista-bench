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

echo ">> [2/3] submitting queries (this is the timed part)..."
# Stream the scheduler's metrics to disk LIVE and derive the progress counter
# from the same stream. A post-hoc `logs --since-time` loses lines once kubelet
# rotates the container log (it silently dropped ~75% of a 2000-query run).
( kubectl -n "$NAMESPACE" logs deploy/ballista-scheduler -f --since-time="$start" 2>/dev/null \
    | grep --line-buffered '"kind":"' \
    | tee "$run/stages.jsonl" \
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

sleep 2                                              # let trailing rollups flush into the stream
pkill -P "$prog" 2>/dev/null; kill "$prog" 2>/dev/null || true; echo
echo ">> [3/3] metrics captured live -> $run/stages.jsonl"

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
