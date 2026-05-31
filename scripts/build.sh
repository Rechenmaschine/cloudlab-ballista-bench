#!/usr/bin/env bash
# Build scheduler/executor images + ballista-cli from the fork; load images on workers.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
export PATH=/usr/local/bin:$HOME/.cargo/bin:$PATH PROTOC=/usr/local/bin/protoc

# Use the docker daemon kubelet uses (cri-dockerd). sudo so it works whether or
# not the user is in the docker group.
docker() { sudo docker "$@"; }

[ -d "$BALLISTA_SRC/.git" ] || git clone -b "$BALLISTA_REF" "$BALLISTA_REPO" "$BALLISTA_SRC"
cd "$BALLISTA_SRC"
cargo build --release -p ballista-scheduler -p ballista-executor -p ballista-cli
docker build -f dev/docker/ballista-scheduler.Dockerfile -t "ballista-scheduler:$IMAGE_TAG" .
docker build -f dev/docker/ballista-executor.Dockerfile  -t "ballista-executor:$IMAGE_TAG" .

docker save "ballista-executor:$IMAGE_TAG" | gzip > /tmp/executor.tgz
echo "loading executor image on workers in parallel: $WORKER_NODES"
for w in $WORKER_NODES; do
  ( rsync /tmp/executor.tgz "$w:/tmp/executor.tgz" \
      && ssh "$w" 'gzip -dc /tmp/executor.tgz | sudo docker load' \
      && echo "  $w: loaded" ) &
done
wait
