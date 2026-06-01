#!/usr/bin/env bash
# Wipe any existing deployment and recreate it fresh from the .env-rendered
# manifests. A full delete+recreate (not just `apply`) guarantees pods restart
# on the current image, even when the image tag is unchanged after a rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

vars='$NAMESPACE $CONTROL_NODE $IMAGE_TAG $DATA_DIR $WORK_DIR $TRACE_DIR $TASK_SLOTS'
render() { for t in manifests/*.yaml.tmpl; do envsubst "$vars" < "$t"; echo ---; done; }

echo ">> wiping namespace $NAMESPACE"
kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=false
echo ">> waiting for $NAMESPACE to terminate"
kubectl wait --for=delete namespace/"$NAMESPACE" --timeout=120s || {
  echo "!! namespace stuck terminating, clearing finalizers" >&2
  kubectl get ns "$NAMESPACE" -o json \
    | jq 'del(.spec.finalizers)' \
    | kubectl replace --raw "/api/v1/namespaces/$NAMESPACE/finalize" -f -
}
# Fresh trace file for the new scheduler. The writer opens it append-mode at
# startup (hostPath persists across pods), so truncate now that the old pod is
# gone — each deploy starts a clean trace; run.sh still slices per run on top.
echo ">> preparing trace dir $TRACE_DIR (on $CONTROL_NODE)"
mkdir -p "$TRACE_DIR" && chmod 777 "$TRACE_DIR" && : > "$TRACE_DIR/stages.jsonl"

echo ">> deploying"
render | kubectl apply -f -
