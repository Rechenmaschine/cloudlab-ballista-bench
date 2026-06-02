#!/usr/bin/env bash
# CARMA grid sweep. EVERYTHING streams to stdout -> ONE log. Launch with:
#   tmux new-session -d -s grid 'bash scripts/grid-sweep.sh 2>&1 | tee /tmp/grid.log'
#   tail -f /tmp/grid.log
# Stall guard: a run is killed ONLY if no query completes for QUERY_TIMEOUT
# (a slow-but-progressing run is fine; a genuinely stuck query/stage is not).
set +e
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

tmux kill-session -t carma 2>/dev/null; pkill -f "ballista-cli --host" 2>/dev/null; pkill -f "scripts/run.sh" 2>/dev/null; sleep 3

wait_execs() { for i in $(seq 1 40); do [ "$(kubectl -n carma get pods -l app=ballista-executor --no-headers 2>/dev/null | grep -c Running)" -ge 3 ] && return 0; sleep 5; done; return 1; }

# per-run node prep: performance governor, no turbo, disable idle states, drop caches (reproducible timing)
prep() { for n in $WORKER_NODES; do ssh -o BatchMode=yes -o ConnectTimeout=8 "$n" '
  for c in /sys/devices/system/cpu/cpu*/cpufreq; do echo performance | sudo tee $c/scaling_governor >/dev/null 2>&1; sudo tee $c/scaling_min_freq < $c/scaling_max_freq >/dev/null 2>&1; done
  [ -e /sys/devices/system/cpu/intel_pstate/no_turbo ] && echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo >/dev/null 2>&1
  [ -e /sys/devices/system/cpu/intel_pstate/min_perf_pct ] && echo 100 | sudo tee /sys/devices/system/cpu/intel_pstate/min_perf_pct >/dev/null 2>&1
  for s in /sys/devices/system/cpu/cpu*/cpuidle/state[1-9]; do echo 1 | sudo tee $s/disable >/dev/null 2>&1; done
  sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null' 2>/dev/null; done; }

KS="1 2 3 5 8 10 20"; REPS="1 2 3"; QUERIES=1000
QUERY_TIMEOUT=600                     # kill a run if NO query completes for this many seconds (10 min)
total=$(( $(echo $KS | wc -w) * $(echo $REPS | wc -w) )); i=0; sweep_start=$(date +%s)
fmt() { printf "%02d:%02d:%02d" $(($1/3600)) $(($1%3600/60)) $(($1%60)); }

echo "############################################################"
echo "## CARMA grid sweep: $total points (K={$KS} x rep={$REPS}), $QUERIES queries each"
echo "## per-query stall guard: $((QUERY_TIMEOUT/60))m | started $(date '+%F %T')"
echo "############################################################"

for rep in $REPS; do
  for K in $KS; do
    i=$((i+1)); name=g${K}r${rep}; t0=$(date +%s)
    echo
    echo "############################################################"
    echo "## [$i/$total] $name   K=$K  rep=$rep   start $(date +%T)"
    echo "############################################################"

    echo "-- deploy (wipe + redeploy + pin) --------------------------"
    ./scripts/deploy.sh
    echo "-- wait for 3 executors ------------------------------------"
    wait_execs && echo "   ok: 3 executors Running" || echo "   WARN: <3 executors after 200s, running anyway"
    echo "-- node prep (governor/turbo/idle/caches) ------------------"
    prep; echo "   prep done"

    echo "-- run: $QUERIES queries @ concurrency $K (live below; stall guard ${QUERY_TIMEOUT}s) --"
    ./scripts/run.sh "$QUERIES" "$K" "$name" &
    runpid=$!
    prev=-1; last_progress=$(date +%s); rc=0
    while kill -0 "$runpid" 2>/dev/null; do
      sleep 30
      rd=$(ls -dt /storage/carma/runs/${name}-*/ 2>/dev/null | head -1)
      n=$(grep -c '"kind":"job"' "${rd}rollups.jsonl" 2>/dev/null); n=${n:-0}
      now=$(date +%s)
      if [ "$n" -gt "$prev" ]; then prev=$n; last_progress=$now; fi
      if [ $(( now - last_progress )) -ge "$QUERY_TIMEOUT" ]; then
        echo "## STALL: no query completed in $((QUERY_TIMEOUT/60))m (stuck at ${n}/${QUERIES}) -- killing run"
        kill -TERM "$runpid" 2>/dev/null; sleep 5; kill -KILL "$runpid" 2>/dev/null
        rc=124; break
      fi
    done
    if [ "$rc" -ne 124 ]; then wait "$runpid"; rc=$?; fi
    pkill -f "ballista-cli --host" 2>/dev/null

    dur=$(( $(date +%s)-t0 )); elapsed=$(( $(date +%s)-sweep_start ))
    avg=$(( elapsed / i )); eta=$(( avg * (total-i) ))
    if [ "$rc" -eq 124 ]; then
      echo "## [$i/$total] $name STALLED (no progress ${QUERY_TIMEOUT}s) -- killed, continuing"
    else
      echo "## [$i/$total] $name DONE rc=$rc in $(fmt $dur)   | $(grep -hE 'jobs=' /storage/carma/runs/${name}-*/meta.txt 2>/dev/null | head -1)"
    fi
    echo "## progress: $i/$total done | sweep elapsed $(fmt $elapsed) | est. remaining $(fmt $eta)"
  done
done
echo
echo "## GRID COMPLETE $(date '+%F %T')   total wall-clock $(fmt $(( $(date +%s)-sweep_start )))"
