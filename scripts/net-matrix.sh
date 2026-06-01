#!/usr/bin/env bash
# All-to-all pod-to-pod bandwidth matrix over the kubernetes pod network
# (Calico) - the throughput executors actually get when they shuffle. Runs an
# iperf3-server DaemonSet (one per worker), then for every ordered (src,dst)
# worker pair runs a client pod on src and records Gbit/s. SEQUENTIAL so one
# transfer never contends with another (a parallel matrix would hide a slow
# link). Flags links well below the median so "stupid things" stand out.
# Everything lives in a throwaway namespace that is torn down on exit.
#
#   scripts/net-matrix.sh            # ~3-4 min for 7 workers
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
ns=netmatrix
img=nicolaka/netshoot
dur=${1:-3}

cleanup() { kubectl delete ns "$ns" --force --grace-period=0 >/dev/null 2>&1; }
trap cleanup EXIT
kubectl get ns "$ns" >/dev/null 2>&1 && cleanup && sleep 3
kubectl create ns "$ns" >/dev/null

# iperf3 server on every non-control node (pod network).
cat <<YAML | kubectl -n "$ns" apply -f - >/dev/null
apiVersion: apps/v1
kind: DaemonSet
metadata: { name: iperfsrv }
spec:
  selector: { matchLabels: { app: iperfsrv } }
  template:
    metadata: { labels: { app: iperfsrv } }
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - { key: node-role.kubernetes.io/control-plane, operator: DoesNotExist }
      containers:
      - name: s
        image: $img
        command: ["iperf3","-s"]
YAML

echo ">> waiting for iperf3 servers (all DaemonSet pods Ready, incl. image pull)..."
des=0; rdy=0
for i in $(seq 1 60); do
  read -r des rdy < <(kubectl -n "$ns" get ds iperfsrv -o jsonpath='{.status.desiredNumberScheduled} {.status.numberReady}' 2>/dev/null)
  des=${des:-0}; rdy=${rdy:-0}
  [ "$des" -ge 2 ] && [ "$rdy" = "$des" ] && break
  sleep 5
done
echo ">> servers ready: $rdy/$des"
sleep 3

# node -> server pod IP, only for Running servers (skips dead/unreachable nodes).
mapfile -t rows < <(kubectl -n "$ns" get pods -l app=iperfsrv --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.spec.nodeName} {.status.podIP}{"\n"}{end}' | sort)
nodes=(); declare -A ip
for r in "${rows[@]}"; do [ -z "$r" ] && continue; set -- $r; nodes+=("$1"); ip[$1]=$2; done
echo ">> ${#nodes[@]} servers: ${nodes[*]}"
[ "${#nodes[@]}" -ge 2 ] || { echo "need >=2 servers"; exit 1; }

# Drive the matrix: one client pod per source, hitting each dest sequentially.
declare -A bw
allvals=""
for s in "${nodes[@]}"; do
  # sleep lets Calico finish programming pod routes (the first connection in a
  # fresh pod otherwise races and fails); retry once per pair for robustness.
  cmd="sleep 2;"
  for d in "${nodes[@]}"; do
    [ "$s" = "$d" ] && continue
    cmd="${cmd}echo D=$d; { iperf3 -c ${ip[$d]} -t $dur -f m || iperf3 -c ${ip[$d]} -t $dur -f m; } | awk '/receiver/{print \$7}';"
  done
  echo ">> src $s ..."
  out=$(kubectl -n "$ns" run "c-${s#node-}" --image=$img --restart=Never --rm -i \
    --overrides="{\"apiVersion\":\"v1\",\"spec\":{\"nodeName\":\"$s\"}}" \
    --command -- sh -c "$cmd" 2>/dev/null)
  d=""
  while IFS= read -r line; do
    case "$line" in
      D=*)        d=${line#D=} ;;
      [0-9]*)     bw[$s,$d]=$line; allvals="$allvals $line" ;;
    esac
  done <<<"$out"
done

# Median (for outlier flagging).
med=$(echo $allvals | tr ' ' '\n' | grep . | sort -n | awk '{a[NR]=$1} END{print (NR%2)? a[(NR+1)/2] : int((a[NR/2]+a[NR/2+1])/2)}')
echo
echo "== pod-to-pod bandwidth matrix (Gbit/s, rows=src -> cols=dst) =="
printf "      "; for d in "${nodes[@]}"; do printf "%7s" "->${d#node-}"; done; echo
for s in "${nodes[@]}"; do
  printf "%-6s" "${s#node-}"
  for d in "${nodes[@]}"; do
    if [ "$s" = "$d" ]; then printf "%7s" "-"; else
      v=${bw[$s,$d]:-}
      if [ -z "$v" ]; then printf "%7s" "?"; else
        flag=""; [ "$v" -lt $(( med * 6 / 10 )) ] && flag="*"
        printf "%7s" "$(awk -v m="$v" 'BEGIN{printf "%.2f%s", m/1000, "'"$flag"'"}')"
      fi
    fi
  done
  echo
done
echo "median=$(awk -v m="$med" 'BEGIN{printf "%.2f", m/1000}') Gbit/s   (* = link < 60% of median; ? = no result)"
echo ">> cost-model intra-cluster bandwidth (set in carma-all, not .env): median = $(( med * 1000000 )) bps"
