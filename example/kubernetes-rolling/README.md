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
migrator: pre-hook install/stage → Recreate schema-worker → worker-ready
   ↓
app: RollingUpdate (0 unavailable, 1 surge) → post-hook deploy/retire
```

1. **Installer Job:** `--schema install` stages the new checked history. It uses
   the Installer credential and grants no premature version admission.
2. **Schema worker:** `--schema worker` expands the adjacent revision and keeps
   backfill/conversion running. `/worker.sh` marks it Ready only after the actual
   `schema-worker-ready` event. The old schema executor is replaced, while old
   application pods continue serving.
3. **Application rollout:** ordinary `/app`, with Request credentials. Readiness
   performs a database query. Two replicas, `maxUnavailable: 0`, `maxSurge: 1`, a
   brief preStop drain and termination grace preserve overlap.
4. **Retirement Job:** the Helm post-install/post-upgrade hook runs `--schema deploy`
   with separate Installer and Worker connections. It waits for old-instance
   heartbeats/claims to drain and then completes the reviewed Contract. OpenTofu
   waits for that hook before moving to the next release.

Request pods receive only Request credentials. Hook credentials are separate.
The public passwords in `chart/values.yaml` are local-demo values. PostgreSQL uses
`emptyDir`: deleting/replacing its pod loses the demo database. This example
shows application rolling availability, not database HA or production provisioning.
The one-second queue visibility timeout is also a demo setting; real handlers
need a lease budget appropriate to their execution and renewal latency.

## What the checks prove

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

This is **observed zero downtime for these compatible adjacent changes**, over
the sampled window. Arbitrary rejected conversions, incompatible version gaps,
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

Verified local run: **763 samples, zero failures** (533 health reads, 115 note
writes, 115 job submissions), minimum **2 Ready pods**, both version overlaps,
**83 retained-job conversions**, and **123 correct final job receipts**. Health
p95 was 32.4 ms and maximum 403.1 ms. Evidence for that run is
`.tesl-stuff/kubernetes-rolling-verified-source/`; measurements are local observations, not
a production SLA. Its cluster was cleaned up.
