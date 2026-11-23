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
migrator: pre-install/pre-upgrade install Job (Installer) → completes
   ↓
migrator: Recreate worker (Worker only) → schema-worker-ready
   ↓
app: RollingUpdate (0 unavailable, 1 surge) → post-hook deploy/retire
```

1. **Install Job:** a Helm pre-install/pre-upgrade hook in the migrator release
   runs `app --schema install --worker demo_worker --request demo_request --json`
   with the admin Installer login. It creates or verifies Tesl's bookkeeping
   tables and PostgreSQL functions, stages the checked migrations, and exits.
   Helm waits for this Job to succeed before it creates or updates the Worker
   Deployment; a failed Job stops the release.
2. **Schema worker:** `/worker.sh` runs `app --schema worker --json` with only
   the Worker login (`MigrationConfig.ddlConnection`). It expands the adjacent
   revision and keeps row backfill/queue conversion running without completing
   the current Contract. `/worker.sh` marks it Ready only after
   `schema-worker-ready`. The old schema worker is replaced while old
   application pods continue serving.
3. **Application rollout:** ordinary `/app`, with Request credentials. Readiness
   performs a database query. Two replicas, `maxUnavailable: 0`, `maxSurge: 1`, a
   brief preStop drain and termination grace preserve overlap.
4. **Retirement Job:** the Helm post-install/post-upgrade hook runs `--schema deploy`
   with separate Installer and Worker connections. It waits for old-instance
   heartbeats/claims to drain and then completes the reviewed Contract. OpenTofu
   waits for that hook before moving to the next release.

### Why the Installer runs in its own Job

Earlier versions of this example started the Worker with `--schema worker
--install`, so the always-on Worker pod received the Installer DSN at startup.
The process closed that connection and cleared it from its Go environment, but
the Kubernetes Secret stayed mounted for the life of the pod and the startup
bytes could remain in process memory. The Installer is a PostgreSQL superuser
here, so a compromised Worker pod could have recovered it.

Now only two short-lived Jobs ever receive the Installer DSN: the install hook
before the Worker changes, and the retirement hook after the application rolls.
Helm deletes both Jobs and their Secrets after they succeed
(`hook-delete-policy: hook-succeeded`); a failed Job and its Secret remain for
inspection until the next attempt replaces them. Who holds which credential:

| Pod | Database login | Installer DSN |
|---|---|---|
| install Job (finite) | `postgres` (Installer) | in its own hook Secret |
| schema worker (long-running) | `demo_worker` | none |
| application (long-running) | `demo_request` | none |
| retirement Job (finite) | `demo_worker`, then `postgres` | in its own hook Secret |

`test_chart.py` renders the chart and checks these scopes and the hook order;
`run.py` runs it before creating a cluster. A failed install Job leaves the old
Worker running and the release incomplete; fix the cause and re-apply.

Worker startup uses `TESL_PG_POOL_LEASE_TIMEOUT_MS` for connecting; after setup,
the Worker runs until a signal or cancellation stops it. `--schema worker
--install` remains available for topologies that prefer one startup command,
at the cost of the Installer credential reaching the long-running process.

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
- `chart/`: database, worker and application templates plus their install and retirement Jobs.
- `test_chart.py`: rendered-chart credential-scope and ordering checks (helm only).
- `infra/`: pinned Helm provider and ordered OpenTofu resources.
- `run.py`, `probe.py`: local orchestration and measured availability/data checks.

The output directory retains generated source/binaries, OpenTofu state, kubeconfig,
apply logs, `availability.json`, `pod-readiness.json`, per-version database
snapshots and `result.json`. The default output is under ignored `.tesl-stuff`.
Keep custom output directories untracked too: they contain kubeconfig credentials
and OpenTofu state.

Separate install Job local run: **805 samples, zero failures** (555 health
reads, 125 note writes, 125 job submissions), minimum **2 Ready pods**, both
version overlaps, **93 retained-job conversions**, and **133 correct final job
receipts**. Health p95 was 69.3 ms and maximum 989.4 ms. Each release's install
Job completed before its Worker rolled; no pod restarted. Evidence is under
`.tesl-stuff/rolling-install-job/`; these are local observations, not a
production SLA. The cluster was cleaned up.

The earlier combined-command run (`--schema worker --install`, Installer DSN in
the Worker pod) recorded 731 samples with zero failures and 121 correct final job
receipts.
