#!/usr/bin/env bash
# Download IMDb, convert to schema-correct Parquet, copy to the worker nodes.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

csv=$ROOT/imdb-csv
mkdir -p "$csv" "$DATA_DIR"
[ -f "$csv/title.csv" ] || curl -L "$IMDB_URL" | tar -xz -C "$csv"
python3 bin/imdb_to_parquet.py --schema data/imdb_schema.sql --csv-dir "$csv" --out-dir "$DATA_DIR"

for w in $WORKER_NODES; do
  echo "copying dataset to $w"
  rsync -a --delete "$DATA_DIR/" "$w:$DATA_DIR/"
done
