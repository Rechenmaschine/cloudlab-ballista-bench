#!/usr/bin/env bash
# Build scheduler/executor images + ballista-cli from the fork; load images on workers.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
export PATH=/usr/local/bin:$HOME/.cargo/bin:$PATH PROTOC=/usr/local/bin/protoc

[ -d "$BALLISTA_SRC/.git" ] || git clone -b "$BALLISTA_REF" "$BALLISTA_REPO" "$BALLISTA_SRC"
cd "$BALLISTA_SRC"
cargo build --release -p ballista-scheduler -p ballista-executor -p ballista-cli
docker build -f dev/docker/ballista-scheduler.Dockerfile -t "ballista-scheduler:$IMAGE_TAG" .
docker build -f dev/docker/ballista-executor.Dockerfile  -t "ballista-executor:$IMAGE_TAG" .

docker save "ballista-executor:$IMAGE_TAG" | gzip > /tmp/executor.tgz
for w in $WORKER_NODES; do
  echo "loading executor image on $w"
  rsync /tmp/executor.tgz "$w:/tmp/executor.tgz"
  ssh "$w" 'gzip -dc /tmp/executor.tgz | docker load'
done
