#!/usr/bin/env python3
# Convert headerless IMDb/JOB CSVs to schema-correct Parquet using DuckDB.
# Column names + types come from the DDL so the benchmark SQL resolves.
# Writes one Hive-style dir per table: <out-dir>/<table>/<table>.parquet
import argparse, os, re, sys


def parse_schema(path):
    tables = {}
    for m in re.finditer(r"CREATE\s+TABLE\s+(\w+)\s*\((.*?)\)\s*;", open(path).read(), re.S | re.I):
        cols = []
        for line in m.group(2).splitlines():
            line = line.strip().rstrip(",").strip()
            if not line or line.startswith("--"):
                continue
            col = line.split()[0]
            ty = "INTEGER" if re.search(r"\binteger\b", line.lower()) else "VARCHAR"
            cols.append((col, ty))
        if cols:
            tables[m.group(1)] = cols
    return tables


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--schema", required=True)
    p.add_argument("--csv-dir", required=True)
    p.add_argument("--out-dir", required=True)
    a = p.parse_args()

    import duckdb
    con = duckdb.connect()
    os.makedirs(a.out_dir, exist_ok=True)
    for table, cols in sorted(parse_schema(a.schema).items()):
        csv = os.path.join(a.csv_dir, f"{table}.csv")
        if not os.path.isfile(csv):
            print(f"  skip {table}: no {csv}", file=sys.stderr)
            continue
        os.makedirs(os.path.join(a.out_dir, table), exist_ok=True)
        out = os.path.join(a.out_dir, table, f"{table}.parquet")
        colspec = ", ".join(f"'{c}': '{t}'" for c, t in cols)
        con.execute(
            f"COPY (SELECT * FROM read_csv('{csv}', header=false, columns={{{colspec}}}, "
            f"delim=',', quote='\"', escape='\\', nullstr='', auto_detect=false)) "
            f"TO '{out}' (FORMAT PARQUET);")
        n = con.execute(f"SELECT count(*) FROM '{out}'").fetchone()[0]
        print(f"  {table}: {n} rows")


if __name__ == "__main__":
    main()
