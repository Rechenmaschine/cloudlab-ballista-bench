#!/usr/bin/env bash
# Assert the cluster is homogeneous and (optionally) measure it.
#
#   scripts/check-cluster.sh         # fast: node inventory + homogeneity asserts + latency
#   scripts/check-cluster.sh --net   # also run iperf3 throughput between workers (slow; needs iperf3)
#
# What "homogeneous" means here: the NODES are not identical (some 32-core, some
# 40-core), but every EXECUTOR is pinned to TASK_SLOTS cores via the pod's
# CPU request==limit. So we assert executor-level homogeneity (hard PASS/FAIL)
# and just report the raw node differences as info. Exits non-zero on any FAIL,
# so this can gate a run (e.g. `scripts/check-cluster.sh && scripts/run.sh ...`).
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

net=0; [ "${1:-}" = "--net" ] && net=1

fail=0
ok()   { echo "  OK:   $*"; }
warn() { echo "  WARN: $*"; }
bad()  { echo "  FAIL: $*"; fail=1; }
cpu_milli() { case "$1" in *m) echo "${1%m}";; ""|"<none>") echo 0;; *) echo $(( $1 * 1000 ));; esac; }

workers=($WORKER_NODES)
echo ">> control node: ${CONTROL_NODE:-<unknown>}"
echo ">> worker nodes (${#workers[@]}): ${workers[*]}"
[ "${#workers[@]}" -ge 1 ] || { echo "FAIL: no worker nodes derived (is kubectl pointed at the cluster?)"; exit 1; }

# ---------------------------------------------------------------------------
echo; echo "== node inventory (what kubernetes sees) =="
cores_seen=""; mem_seen=""; min_alloc=""
for n in "${workers[@]}"; do
  cpu=$(kubectl get node "$n" -o jsonpath='{.status.capacity.cpu}' 2>/dev/null)
  alloc=$(kubectl get node "$n" -o jsonpath='{.status.allocatable.cpu}' 2>/dev/null)
  mem=$(kubectl get node "$n" -o jsonpath='{.status.capacity.memory}' 2>/dev/null)
  printf "  %-14s cores=%-4s allocatable=%-6s mem=%s\n" "$n" "${cpu:-?}" "${alloc:-?}" "${mem:-?}"
  cores_seen="$cores_seen $cpu"; mem_seen="$mem_seen $mem"
  am=$(cpu_milli "${alloc:-0}")
  [ -z "$min_alloc" ] || [ "$am" -lt "$min_alloc" ] && min_alloc=$am
done

# ---------------------------------------------------------------------------
echo; echo "== homogeneity asserts =="
# Raw node cores: informational. They legitimately differ; the CPU pin is what
# makes the executors identical, so this is INFO, not a failure.
ucores=$(echo $cores_seen | tr ' ' '\n' | sort -u | grep -c .)
if [ "$ucores" -le 1 ]; then ok "all worker nodes have the same physical core count ($(echo $cores_seen | awk '{print $1}'))"
else echo "  INFO: worker nodes have DIFFERENT physical cores ($(echo $cores_seen|tr ' ' '\n'|sort -u|paste -sd/ -)) - masked by the TASK_SLOTS=$TASK_SLOTS CPU pin"; fi
# Memory should be uniform (the cost model treats nodes as RAM-identical).
# Round to GiB first: identical nodes report capacity that differs by a few MiB.
mem_gib=$(for m in $mem_seen; do [ -n "$m" ] && echo $(( ${m%Ki} / 1048576 )); done | sort -u)
if [ "$(echo "$mem_gib" | grep -c .)" -le 1 ]; then ok "all worker nodes have the same memory (~${mem_gib} GiB)"
else bad "worker nodes have DIFFERENT memory ($(echo "$mem_gib" | paste -sd/ -) GiB) - cluster.json assumes uniform RAM"; fi
# TASK_SLOTS must fit the smallest node's allocatable CPU or pods stay Pending.
want=$(( TASK_SLOTS * 1000 ))
if [ -n "$min_alloc" ] && [ "$min_alloc" -ge "$want" ]; then ok "TASK_SLOTS=$TASK_SLOTS fits every node's allocatable CPU (min ${min_alloc}m)"
else bad "TASK_SLOTS=$TASK_SLOTS (${want}m) EXCEEDS smallest allocatable CPU (${min_alloc:-?}m) - those executor pods will stay Pending. Lower TASK_SLOTS."; fi
# Hyperthreading must be OFF on every worker (set by setup-node.sh) so a task
# slot is a real core. If it silently came back (e.g. a node rebooted without
# nosmt taking effect), the node reports double the cores and is no longer
# comparable to the others.
for n in "${workers[@]}"; do
  a=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$n" 'cat /sys/devices/system/cpu/smt/active 2>/dev/null' 2>/dev/null)
  if   [ "$a" = "0" ]; then ok "$n hyperthreading off"
  elif [ -z "$a" ];    then warn "$n unreachable - SMT state unknown"
  else                      bad "$n hyperthreading is ON (smt/active=$a) - run setup-node.sh / disable_smt"; fi
done

# ---------------------------------------------------------------------------
echo; echo "== executor pods =="
mapfile -t lines < <(kubectl -n "$NAMESPACE" get pods -l app=ballista-executor \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{" "}{.status.phase}{" "}{.status.qosClass}{" "}{.spec.containers[0].resources.requests.cpu}{" "}{.spec.containers[0].resources.limits.cpu}{"\n"}{end}' 2>/dev/null)
running=0; good=0
if [ "${#lines[@]}" -eq 0 ] || [ -z "${lines[0]}" ]; then
  warn "no executor pods found in namespace '$NAMESPACE' - is the deployment up? (scripts/deploy.sh)"
else
  for l in "${lines[@]}"; do
    [ -z "$l" ] && continue
    read -r pod node phase qos req lim <<<"$l"
    rm=$(cpu_milli "$req"); lm=$(cpu_milli "$lim")
    status="phase=$phase qos=$qos cpu=$req/$lim"
    [ "$phase" = "Running" ] && running=$((running+1))
    # CPU pinned to exactly TASK_SLOTS (request==limit, CFS-capped) is the
    # homogeneity that matters. QoS is Burstable (memory intentionally unbounded
    # so each executor can use its node's full, equal RAM); with the default
    # CPU-manager policy Guaranteed wouldn't change CPU behaviour, so we don't
    # require it.
    if [ "$phase" = "Running" ] && [ "$rm" = "$want" ] && [ "$lm" = "$want" ]; then
      printf "  OK:   %-22s %-12s %s\n" "$pod" "$node" "$status"; good=$((good+1))
    else
      printf "  FAIL: %-22s %-12s %s (want Running, cpu=$TASK_SLOTS/$TASK_SLOTS)\n" "$pod" "$node" "$status"; fail=1
    fi
  done
  if [ "$good" -eq "$running" ] && [ "$running" -gt 0 ]; then
    ok "$good/$running running executors are identical (cpu pinned to $TASK_SLOTS cores)"
  else
    bad "$good/$running running executors are correctly pinned - the rest need a redeploy (scripts/deploy.sh)"
  fi
  # Cross-check against what the scheduler actually registered.
  sched=$(kubectl -n "$NAMESPACE" get pod -l app=ballista-scheduler -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
  if [ -n "$sched" ]; then
    reg=$(curl -s "http://$sched:$SCHEDULER_PORT/api/executors" | grep -o '"host":' | wc -l | tr -d ' ')
    [ "$reg" = "$running" ] && ok "scheduler has $reg executors registered (matches running pods)" \
                            || warn "scheduler registered $reg executors but $running pods are Running"
  fi
fi

# ---------------------------------------------------------------------------
echo; echo "== reachability + latency (control -> workers) =="
for n in "${workers[@]}"; do
  rtt=$(ping -c 3 -W 1 "$n" 2>/dev/null | awk -F'/' '/rtt|round-trip/{print $5" ms"}')
  [ -n "$rtt" ] && printf "  %-14s avg %s\n" "$n" "$rtt" || warn "$n unreachable by ping"
done

# ---------------------------------------------------------------------------
if [ "$net" = 1 ]; then
  echo; echo "== intra-cluster throughput (iperf3, worker -> worker) =="
  srv=${workers[0]}
  if ! ssh -o BatchMode=yes "$srv" 'command -v iperf3 >/dev/null'; then
    warn "iperf3 not installed on $srv - skipping. Install it (it's in setup-node.sh now): sudo apt-get install -y iperf3"
  else
    ssh "$srv" 'pkill -x iperf3 2>/dev/null; iperf3 -s -D' >/dev/null 2>&1
    sleep 1
    bws=""
    for w in "${workers[@]:1}"; do
      bps=$(ssh -o BatchMode=yes "$w" "command -v iperf3 >/dev/null && iperf3 -c $srv -t 5 -J 2>/dev/null" \
        | python3 -c 'import sys,json;
try:
 print(int(json.load(sys.stdin)["end"]["sum_received"]["bits_per_second"]))
except Exception: print("")' 2>/dev/null)
      if [ -n "$bps" ]; then
        printf "  %-14s -> %-14s %s Gbit/s\n" "$w" "$srv" "$(awk -v b="$bps" 'BEGIN{printf "%.2f", b/1e9}')"
        bws="$bws $bps"
      else warn "$w -> $srv: iperf3 failed (iperf3 installed on $w?)"; fi
    done
    ssh "$srv" 'pkill -x iperf3 2>/dev/null' >/dev/null 2>&1
    if [ -n "$bws" ]; then
      read -r mn mean <<<"$(echo $bws | tr ' ' '\n' | awk 'NR==1{m=$1} {s+=$1;n++; if($1<m)m=$1} END{printf "%d %d", m, s/n}')"
      echo "  min=$(awk -v b="$mn" 'BEGIN{printf "%.2f",b/1e9}') Gbit/s  mean=$(awk -v b="$mean" 'BEGIN{printf "%.2f",b/1e9}') Gbit/s"
      echo "  -> measured intra-cluster bandwidth. This is a cost-model knob (set in carma-all, not .env)."
      echo "     median above; conservative = min link = $mn bps."
    fi
  fi
fi

# ---------------------------------------------------------------------------
echo
if [ "$fail" = 0 ]; then echo ">> PASS: cluster is homogeneous"; exit 0
else echo ">> FAIL: see the FAIL lines above"; exit 1; fi
