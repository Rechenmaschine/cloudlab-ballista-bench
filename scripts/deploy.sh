#!/usr/bin/env bash
# Render the manifest templates from .env and apply them.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

vars='$NAMESPACE $CONTROL_NODE $IMAGE_TAG $DATA_DIR $WORK_DIR'
for t in manifests/*.yaml.tmpl; do
  envsubst "$vars" < "$t"
  echo ---
done | kubectl apply -f -
