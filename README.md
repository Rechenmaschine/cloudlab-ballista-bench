# carma-ballista-bench

Benchmark running Redbench queries against a Kubernetes cluster with
datafusion-ballista.

A Redbench `workload.csv` (IMDb/JOB SQL) is replayed against a distributed Apache
DataFusion Ballista cluster on CloudLab Kubernetes; per-run metrics land in
`runs/<name>/`.

## Experiments

Two storage topologies share one cluster, one workload, and one runner — they
differ only in *where the Parquet lives*, so results are directly comparable:

- **`local-scan`** — the dataset is replicated on every worker (hostPath); every
  scan is node-local. The original benchmark.
- **`s3-central`** — the dataset lives on one centralized MinIO node; every scan
  reads it remotely over S3. All workers stay executors, so the compute tier is
  identical to `local-scan`; the only variable is the data source. MinIO's
  read bandwidth is optionally capped (`MINIO_EGRESS_BW`).

Each experiment is a thin wrapper in `experiments/<name>/` over shared logic in
`scripts/lib/`; per-experiment config lives in `experiments/<name>/experiment.env`.

## Usage

Run on the control node of a fresh cluster. Steps 1–4 are shared, one-time setup:

```sh
git clone https://github.com/Rechenmaschine/carma-ballista-bench.git
cd carma-ballista-bench

scripts/setup-node.sh    # one-time: /storage dirs + build deps (rust, protoc, duckdb, kubectl helpers)
scripts/gen-workload.sh  # generate the query set (clone Redbench, download Redset trace, write workload.csv)
scripts/build.sh         # build scheduler/executor images + ballista-cli from the fork; load on workers
```

Then pick an experiment.

**local-scan** (replicated data, node-local scans):

```sh
experiments/local-scan/stage.sh        # download IMDb, convert to Parquet, rsync to every worker
experiments/local-scan/deploy.sh       # render manifests + apply scheduler pod + executor DaemonSet
experiments/local-scan/run.sh 2000 16  # replay 2000 queries with 16 concurrent drivers
experiments/local-scan/sweep.sh        # full K x rep grid sweep
```

The legacy top-level shims (`scripts/stage-data.sh`, `scripts/deploy.sh`,
`scripts/run.sh`, `scripts/grid-sweep.sh`) still work and map to `local-scan`.

**s3-central** (centralized MinIO, remote scans):

```sh
experiments/s3-central/stage.sh        # convert Parquet, bring up MinIO, upload tables to the bucket (once)
experiments/s3-central/deploy.sh       # scheduler + executors with AWS_* env + MinIO; no data hostPath
experiments/s3-central/run.sh 2000 16
experiments/s3-central/sweep.sh
```

No image rebuild is needed: the fork's scheduler and executor already ship the S3
object store (`AmazonS3Builder::from_env()`); `experiment.env` supplies the
`AWS_*` env that points it at MinIO.

To cap storage bandwidth, set `MINIO_EGRESS_BW` (e.g. `1G`) in
`experiments/s3-central/experiment.env` — `deploy.sh` applies it as a
`kubernetes.io/egress-bandwidth` annotation on the MinIO pod (requires the CNI
`bandwidth` plugin). Empty = unshaped. Verify the cap actually binds with
`experiments/s3-central/measure-bw.sh` — it pulls a test object from MinIO via a
worker pod (the real read path) and prints achieved Gbit/s.

To tag a sweep per network condition, set `NAME_PREFIX` (e.g. `NAME_PREFIX=bw1g_`)
so the three passes write distinct run dirs and don't collide on the resume check:

```sh
KS="1 2 3 5 10 15 20" REPS="1 2 3" QUERIES=1000 \
  MINIO_EGRESS_BW=1G NAME_PREFIX=bw1g_ experiments/s3-central/sweep.sh
```

`check-cluster.sh` (homogeneity assert, `--net` for iperf3) and `status.sh` (pod
placement / registered executors) are shared and unchanged.

Notes: `gen-workload.sh` is heavy (downloads a ~18 GB Redset trace) and only
needed once — skip if `$WORKLOAD_CSV` exists. `build.sh` clones the Ballista fork
(`BALLISTA_REPO`/`BALLISTA_REF` in `.env`); node roles are auto-derived.

## Layout

```
.env                 global config: paths, image tag, fork repo/ref (nodes auto-derived)
bin/                 CSV->Parquet + CSV->SQL helpers (gen_sql.py: --location-prefix selects local vs s3://)
manifests/           base namespace + scheduler/executor (local-scan)
scripts/             shared setup/build/gen-workload/check-cluster/status + legacy shims
scripts/lib/         deploy-core / run-core / sweep-core + common.sh (experiment-agnostic logic)
experiments/
  local-scan/        experiment.env + stage.sh + thin deploy/run/sweep wrappers
  s3-central/        experiment.env + stage.sh + wrappers + manifests/ (s3 scheduler/executor + minio)
```

## Runs

`run.sh [queries] [concurrency] [name]` writes a fresh `runs/<name>-<timestamp>/`
(`setup.sql`, `workload*.sql`, `stages.jsonl`, `cli*.log`, `meta.txt`,
`config.txt`, `experiment.env.snapshot`). `meta.txt`/`config.txt` record the
`storage` mode (and `minio_egress_bw`), so every run is self-describing. The
timestamp suffix means reusing a name never collides or overwrites.
