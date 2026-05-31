#!/usr/bin/env python3
# Turn a Redbench workload.csv into SQL for ballista-cli:
#   setup.sql      - CREATE EXTERNAL TABLE per parquet dir in --data-dir
#   workload.sql   - filtered SELECTs (or workload.<i>.sql when --shards > 1)
import argparse, csv, os, sys

csv.field_size_limit(1 << 30)


def truthy(v):
    return str(v).strip().lower() in ("1", "true", "t", "yes")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--workload", required=True)
    p.add_argument("--data-dir", required=True)
    p.add_argument("--out-dir", required=True)
    p.add_argument("--limit", type=int, default=0)
    p.add_argument("--shards", type=int, default=1)
    a = p.parse_args()
    os.makedirs(a.out_dir, exist_ok=True)

    tables = sorted(d for d in os.listdir(a.data_dir)
                    if os.path.isdir(os.path.join(a.data_dir, d)) and not d.startswith("."))
    with open(os.path.join(a.out_dir, "setup.sql"), "w") as f:
        for t in tables:
            f.write(f"CREATE EXTERNAL TABLE {t} STORED AS PARQUET "
                    f"LOCATION '{os.path.join(a.data_dir, t)}';\n")

    rows = []
    with open(a.workload, newline="") as f:
        for r in csv.DictReader(f):
            sql = (r.get("sql") or "").strip()
            if not sql or truthy(r.get("was_aborted")):
                continue
            if (r.get("query_type") or "select").strip().lower() != "select":
                continue
            rows.append((r.get("arrival_timestamp") or "", sql))
    rows.sort(key=lambda x: x[0])
    if a.limit:
        rows = rows[:a.limit]

    k = max(1, a.shards)
    outs = [open(os.path.join(a.out_dir, "workload.sql" if k == 1 else f"workload.{i}.sql"), "w")
            for i in range(k)]
    for i, (_, sql) in enumerate(rows):
        outs[i % k].write(sql.rstrip().rstrip(";") + ";\n")
    for f in outs:
        f.close()
    print(f"{len(tables)} tables, {len(rows)} queries, {k} shard(s) -> {a.out_dir}")


if __name__ == "__main__":
    main()
