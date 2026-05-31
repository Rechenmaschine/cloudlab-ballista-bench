# carma-ballista-bench

Benchmark running Redbench queries against a Kubernetes cluster with
datafusion-ballista.

A Redbench `workload.csv` (IMDb/JOB SQL) is replayed against a distributed Apache
DataFusion Ballista cluster on CloudLab Kubernetes; per-run metrics land in
`runs/<name>/`.

## Usage

Run on the control node of a fresh cluster:

```sh
git clone https://github.com/Rechenmaschine/carma-ballista-bench.git
cd carma-ballista-bench

scripts/setup-node.sh    # /storage dirs + build deps
scripts/build.sh         # build Ballista images + ballista-cli, load on workers
scripts/stage-data.sh    # IMDb -> Parquet -> workers
scripts/deploy.sh        # scheduler + executors
scripts/run.sh 2000 16   # replay 2000 queries at concurrency 16  (run.sh N K)
scripts/status.sh
```

`build.sh` clones the Ballista fork (set in `.env`), node roles are auto-derived,
and the Redbench `workload.csv` must be placed at `$WORKLOAD_CSV` before `run.sh`.

## Layout

```
.env        config: paths, image tag, fork repo/ref (nodes auto-derived)
bin/        CSV->Parquet + CSV->SQL helpers
manifests/  scheduler + executor, rendered from .env
scripts/    setup-node, build, stage-data, deploy, run, status
```

## Runs

`run.sh [queries] [concurrency] [name]` writes a fresh `runs/<name>-<timestamp>/`
(`setup.sql`, `workload*.sql`, `stages.jsonl`, `cli*.log`, `meta.txt`). The
timestamp suffix means reusing a name never collides or overwrites.
