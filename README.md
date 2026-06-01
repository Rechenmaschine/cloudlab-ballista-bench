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

scripts/setup-node.sh    # one-time: create the /storage dirs and install build deps (rust, protoc, duckdb, kubectl helpers)
scripts/gen-workload.sh  # generate the query set: clone Redbench, download the Redset trace, write workload.csv to $WORKLOAD_CSV
scripts/build.sh         # build the Ballista scheduler/executor Docker images + ballista-cli from the fork, load them on the workers
scripts/stage-data.sh    # download the IMDb/JOB CSVs, convert to Parquet, copy the tables to every worker node
scripts/deploy.sh        # render the manifests from .env and apply the scheduler pod + executor DaemonSet
scripts/check-cluster.sh # assert the cluster is homogeneous (every executor pinned to TASK_SLOTS cores); add --net to iperf3 the worker links
scripts/run.sh 2000 16   # replay 2000 workload queries with 16 concurrent ballista-cli drivers; capture per-run metrics
scripts/status.sh        # show pod placement and how many executors have registered
```

Notes: `gen-workload.sh` is heavy (downloads a ~18 GB Redset trace) and only
needed once - skip it if `$WORKLOAD_CSV` already exists. `build.sh` clones the
Ballista fork (`BALLISTA_REPO`/`BALLISTA_REF` in `.env`); node roles are
auto-derived from the cluster.

## Layout

```
.env        config: paths, image tag, fork repo/ref (nodes auto-derived)
bin/        CSV->Parquet + CSV->SQL helpers
manifests/  scheduler + executor, rendered from .env
scripts/    setup-node, build, stage-data, deploy, check-cluster, run, status
```

## Runs

`run.sh [queries] [concurrency] [name]` writes a fresh `runs/<name>-<timestamp>/`
(`setup.sql`, `workload*.sql`, `stages.jsonl`, `cli*.log`, `meta.txt`). The
timestamp suffix means reusing a name never collides or overwrites.
