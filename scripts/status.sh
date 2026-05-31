#!/usr/bin/env bash
# Quick cluster health: pods + registered executors.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

kubectl -n "$NAMESPACE" get pods -o wide
sched=$(kubectl -n "$NAMESPACE" get pod -l app=ballista-scheduler -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)
[ -n "$sched" ] && echo "executors registered: $(curl -s "http://$sched:$SCHEDULER_PORT/api/executors" | grep -o '"host":' | wc -l)"
