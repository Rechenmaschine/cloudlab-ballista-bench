#!/usr/bin/env python3
# Generate SQL for ballista-cli from a Redbench workload.csv.
# The CSV is already arrival-sorted, so stream the first --limit executable
# SELECTs and stop. No full read, no sort, no cache: O(limit), not O(7.6M).
#   setup.sql            - CREATE EXTERNAL TABLE per parquet dir in --data-dir
#   queries/qNNNNNN.sql  - one file per query, zero-padded in arrival order
# run.sh drains queries/ through a work-conserving pool of N client slots, so the
# load stays uniform; one file per query is what lets a freed slot pick up the
# next arrival without any fixed per-client assignment (the old --shards split).
import argparse, csv, os

csv.field_size_limit(1 << 30)


def truthy(v):
    return str(v).strip().lower() in ("1", "true", "t", "yes")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--workload", required=True)
    p.add_argument("--data-dir", required=True)
    p.add_argument("--out-dir", required=True)
    p.add_argument("--limit", type=int, default=0, help="0 = all")
    a = p.parse_args()
    qdir = os.path.join(a.out_dir, "queries")
    os.makedirs(qdir, exist_ok=True)

    tables = sorted(d for d in os.listdir(a.data_dir)
                    if os.path.isdir(os.path.join(a.data_dir, d)) and not d.startswith("."))
    with open(os.path.join(a.out_dir, "setup.sql"), "w") as f:
        for t in tables:
            f.write(f"CREATE EXTERNAL TABLE {t} STORED AS PARQUET "
                    f"LOCATION '{os.path.join(a.data_dir, t)}';\n")

    n = 0
    with open(a.workload, newline="") as f:
        for r in csv.DictReader(f):
            if a.limit and n >= a.limit:
                break
            sql = (r.get("sql") or "").strip()
            if not sql or truthy(r.get("was_aborted")):
                continue
            if (r.get("query_type") or "select").strip().lower() != "select":
                continue
            with open(os.path.join(qdir, f"q{n:06d}.sql"), "w") as q:
                q.write(sql.rstrip().rstrip(";") + ";\n")
            n += 1
    print(f"{len(tables)} tables, {n} queries -> {a.out_dir}", flush=True)


if __name__ == "__main__":
    main()
