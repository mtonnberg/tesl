# Local rolling database and queue migrations

A small **kind + OpenTofu + Helm** example: one disposable PostgreSQL instance,
one schema worker, and two application replicas. It builds three versions of the
same Tesl application and measures availability while rolling between them.

| Release | Change | What remains compatible during overlap |
|---|---|---|
| V1 | `Note.title`; queued `Delivery { id, text }` | Initial schema |
| V2 | Rename `Note.title` → `headline` using checked `Derived` rules | Old/new row access and identical queue payloads |
| V3 | Queue payload becomes `{ id, message, priority }` | Stored entities remain unchanged; checked conversion preserves the message |

The row and queue changes are separate revisions. Their frozen source, codecs,
conversion and reviewed row Contract are produced through guarded compiler
previews—not by rewriting installed history.

## Run

Requires a running local Docker engine. The optional repository shell supplies
kind, kubectl, Helm, OpenTofu and the normal Tesl compiler/Go toolchain:

```sh
CI=1 nix develop .#kubernetes --command \
  python3 example/kubernetes-rolling/run.py
```

`CI=1` suppresses the repository shell's unrelated convenience PostgreSQL server.
The runner builds static applications, creates **its own named local cluster**,
loads the images, runs the rollout and checks, then deletes that cluster. It
refuses to reuse an existing cluster name and never uses your current kubecontext.
The API is mapped only to `127.0.0.1:8080`.

For inspection after the run:

```sh
CI=1 nix develop .#kubernetes
python3 example/kubernetes-rolling/run.py \
  --output .tesl-stuff/rolling-inspect --cluster rolling-inspect --keep

export KUBECONFIG="$PWD/.tesl-stuff/rolling-inspect/kubeconfig"
kubectl -n tesl-rolling get pods
curl -s http://127.0.0.1:8080/health
kind delete cluster --name rolling-inspect --kubeconfig "$KUBECONFIG"
exit
```

Use `--port 18080` if 8080 is occupied. Each run requires a new output directory.
`build.py --output DIR` builds all releases without Docker/Kubernetes; pass that
directory to `run.py --releases DIR` to reuse them.

**Rootless Docker:** kind needs sufficient host inotify resources. If kube-proxy
reports `too many open files`, inspect `fs.inotify.max_user_instances` and follow
kind's rootless prerequisites. The runner waits for kube-proxy and DNS before
installing the application; it does not change host sysctls.

## Why the migration Job is not a pre-upgrade `deploy`

`app --schema deploy` completes retirement. Running it before replacing old pods
can wait for precisely those pods that Helm has not yet rolled.

Instead, OpenTofu orders three releases from the same small chart:

```text
database
   ↓
migrator: Recreate worker --install → schema-worker-ready
   ↓
app: RollingUpdate (0 unavailable, 1 surge) → post-hook deploy/retire
```

1. **Schema worker:** `/worker.sh` runs `app --schema worker --install --json`.
   It checks that `TESL_SCHEMA_INSTALLER_DSN` and the independently configured
   Worker `MigrationConfig.ddlConnection` reach the same database. The Installer
   then creates Tesl's bookkeeping tables/functions and stages checked migrations.
   Its connection closes and its DSN is removed from the current Go environment.
   The long-running Worker then expands the adjacent revision and keeps row
   backfill/queue conversion running without completing the current Contract.
   `/worker.sh` marks it Ready only after `schema-worker-ready`. The old schema
   worker is replaced while old application pods continue serving. There is no
   pre-install Installer Job.
2. **Application rollout:** ordinary `/app`, with Request credentials. Readiness
   performs a database query. Two replicas, `maxUnavailable: 0`, `maxSurge: 1`, a
   brief preStop drain and termination grace preserve overlap.
3. **Retirement Job:** the Helm post-install/post-upgrade hook runs `--schema deploy`
   with separate Installer and Worker connections. It waits for old-instance
   heartbeats/claims to drain and then completes the reviewed Contract. OpenTofu
   waits for that hook before moving to the next release.

Worker installation/setup is bounded by `TESL_SCHEMA_DEPLOY_TIMEOUT_SECONDS`;
after setup, the Worker runs until a signal or cancellation stops it. Plain
`--schema worker` retains its existing behavior and ignores the Installer
environment variable unless `--install` is explicit.

The migrator runtime Secret contains both the Worker DDL credentials and the
Installer DSN. The app Request Secret contains no privileged credentials.
`chart/templates/hooks.yaml` contains only the app post-install/post-upgrade
deployment Job and its Secret. Two database logins do not require two startup
commands or pods.
Database work after setup uses only the Worker login. The pod still receives the
Installer secret at startup: closing its connection and clearing the Go environment
do not guarantee erasure of original process memory or delete the Kubernetes Secret.

The public passwords in `chart/values.yaml` are local-demo values. PostgreSQL uses
`emptyDir`: deleting/replacing its pod loses the demo database. This example
shows application rolling availability, not database HA or production provisioning.
The one-second queue visibility timeout is also a demo setting; real handlers
need a lease budget appropriate to their execution and renewal latency.

## What the checks measure

- `/health` performs an admitted database read and reports the release.
- The probe continuously reads, inserts unique notes and submits unique jobs;
  every timeout, HTTP error or invalid response is retained as a failure.
- Pod snapshots establish Ready-pod overlap for V1/V2 and V2/V3.
- A checked business gate initially keeps jobs retryable, preserving a real
  backlog across the rollout. `POST /deliver` opens it after V3; receipt inserts
  are idempotent by job payload ID. No private queue-table mutation is used to
  manufacture the backlog or migration progress.
- A read-only database inspector checks versions/floors, completed Contracts,
  final row columns, retained payloads and conversion receipts. Compatible retries
  may advance unchanged job stamps before Contract, so an extra restamp audit is
  not required for every job.
- All accepted note values and job results are checked after the rollout.

The combined command recorded **observed zero downtime for these compatible
adjacent changes**, over the sampled window. Arbitrary rejected conversions,
incompatible version gaps,
infrastructure failures or overload do not acquire a zero-downtime guarantee from
`maxUnavailable: 0`. Contract is a retirement boundary: avoid automatically rolling
back to an image whose version has already been retired. Helm `atomic` rollback
is deliberately disabled.

## Files and evidence

- `app.tesl`, `schema/`, `versions/`: small typed application and release inputs.
- `build.py`: guarded freeze/refresh, Contract generation, source checks and builds.
- `chart/`: database, worker and application templates plus their schema Jobs.
- `infra/`: pinned Helm provider and ordered OpenTofu resources.
- `run.py`, `probe.py`: local orchestration and measured availability/data checks.

The output directory retains generated source/binaries, OpenTofu state, kubeconfig,
apply logs, `availability.json`, `pod-readiness.json`, per-version database
snapshots and `result.json`. The default output is under ignored `.tesl-stuff`.
Keep custom output directories untracked too: they contain kubeconfig credentials
and OpenTofu state.

Combined-command local run (`--schema worker --install`): **731 samples, zero
failures** (505 health reads, 113 note writes, 113 job submissions), minimum
**2 Ready pods**, both version overlaps, **81 retained-job conversions**, and
**121 correct final job receipts**. Health p95 was 53.3 ms and maximum 673.5 ms.
Evidence is under `.tesl-stuff/worker-install-kube/`; these are local observations,
not a production SLA. The cluster was cleaned up.
