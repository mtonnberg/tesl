# Operating a checked migration

Tesl migrations are a deployment lifecycle, not just DDL. Source checking establishes
the allowed transition; installed history and runtime fences establish when it is
safe to publish new data and retire old users.

## Which connection runs which command?

| Operation | Principal | Purpose |
|---|---|---|
| `tesl migrate generate`, `tesl migrate contract`, `agent-context`, source tests | Compiler/tooling | Prepare and check source; do not modify the application database |
| `app --schema install --worker ROLE --request ROLE` | Short-lived installer | Register the exact compiled baseline or queue/repair staging |
| `app --schema deploy --json` | Separate Installer, then Worker connections | Install, stage, catch up and complete the reviewed target Contract in one finite deployment job |
| `app --schema worker --install` | Separate Installer, then Worker connections | Install/stage, then run expansion and backfill/queue conversion while preserving old-version overlap |
| `app --schema worker` | Configured Worker | Publish checked expansion and perform conversion/backfill |
| Ordinary HTTP/queue application | Configured Request | Serve admitted requests and process compatible jobs |
| `app --schema status --json` | Configured read-capable application principal | Observe installed progress without mutation |
| `app --schema contract Vn` | Worker | Retire the expanded current target and perform authorized cleanup |

Role flags must match the compiled configuration. Installer credentials are not
Worker credentials; having broad PostgreSQL privileges does not replace exact
application-role admission. Worker commands use the configured DDL connection.
Original V1 installation is required for the current fresh-install-first protocol;
missing old catalog objects cause refusal, not automatic adoption.

## The deployment sequence

### Automatic production deployment

For versioned Worker-topology applications, run the latest binary as a deployment
job before starting the new application services:

```sh
app --schema deploy --json
```

Configure `MigrationConfig.ddlConnection` with Worker credentials and supply
`TESL_SCHEMA_INSTALLER_DSN` only to the deployment job. The command verifies that
both dedicated sessions reach the same database, installs/stages with the
Installer, closes that connection, then executes with the Worker. The installed
database UUID, fence and origin remain pinned across phases. Roles come from the
compiled configuration; the operation takes no role override or force flag.

Use a deployment-scoped administrative Installer identity and the configured
non-administrative Worker login. Existing role-isolation checks apply throughout:
a non-administrative login retaining control-owner membership blocks Worker
execution. Provision these roles outside the application.

For a transforming target, include its reviewed final row Contract as well as
the intermediate Contracts. Deployment completes final backfill and cleanup
before reporting `schema-deployed`; a missing final Contract is rejected before
database mutation. Queue targets also finish their retirement. Compatible
additive targets retain the admission window they need.

The job waits for recent retiring instances and live claims, up to
`TESL_SCHEMA_DEPLOY_TIMEOUT_SECONDS` (default 600; range 1–86400). The deployment
controller must stop retiring services. Data rejection, missing repair code,
catalog drift and source/ABI mismatches fail the job. Retry resumes immutable
receipts; failure never starts the new Request process.

The [Compose rollout](deploy.md#automatic-migration-job-worker-topology) supplies
the stop → deployment job → start wiring with separate credential files. It uses
one latest image for every retained migration step.

### Install and start a long-running Worker for a rolling deployment

```sh
app --schema worker --install [--json] [--database App.Main]
```

This command uses two independently configured inputs:

| Input | Login and work |
|---|---|
| `TESL_SCHEMA_INSTALLER_DSN` | Installer: create Tesl's bookkeeping tables and PostgreSQL functions, and stage checked migrations |
| `MigrationConfig.ddlConnection` | Worker: expand application tables and convert stored rows or queued jobs |

The shared `pgPrepareRowWorker` helper installs/stages with the Installer,
verifies that the Worker connection reaches the same database, closes the
Installer connection and unsets `TESL_SCHEMA_INSTALLER_DSN` from the current Go
environment. It returns only the Worker connection/configuration and the pinned
installed database UUID, fence and origin. The same role checks described above
apply; two logins do not require separate commands or containers.

Installation/setup is bounded by `TESL_SCHEMA_DEPLOY_TIMEOUT_SECONDS` (default
600; range 1–86400). The ongoing Worker instead runs until a signal or cancellation
stops it. It performs the ordinary Worker's supported adjacent/additive expansion,
row backfill and queue conversion, reports `schema-worker-ready`, and preserves
old-version overlap. It does not finish the current target's Contract and does
not serve HTTP. Existing `--schema worker` behavior is unchanged: without explicit
`--install`, it ignores the Installer environment variable.

Closing a connection, dropping Installer configuration and unsetting an
environment variable do not make this process a security isolation boundary.
These actions do not guarantee erasure of original environment bytes or process
memory, delete a Kubernetes Secret, or prevent a compromised host or operator
from retrieving startup credentials. PostgreSQL still checks the Worker login's
permissions on its connection.

For the [Kubernetes rolling example](../example/kubernetes-rolling/README.md),
the order is database → migrator Worker ready → application rolling update →
retirement Job. `/worker.sh` runs `--schema worker --install`; there is no separate
pre-install Job. The migrator runtime Secret contains Worker DDL credentials and
the Installer DSN, while the app Request Secret contains no privileged credentials.
The remaining app post-install/post-upgrade hook runs finite `--schema deploy`:
it catches up and completes the reviewed target Contract after old applications
and their claims drain. Running that retirement command before rolling old pods
can wait for pods that the deployment controller has not yet replaced.

The example's recorded measurements cover the previous separate install/worker
commands; verification evidence for the combined startup is still pending.

### Preview in CI

```sh
tesl migrate generate app.tesl --manifest-json
```

This emits the compiler-owned guarded edit preview without writing source files
or connecting to the application database. CI can retain it as a review artifact,
alongside compilation and migration fixture results. Editor-side apply is not
needed to use this workflow.

### What runs automatically today

Once deployed and configured, the schema Worker performs supported next-step
expansion and backfill/queue conversion. It also catches up across **wholly additive
missing row revisions**: a V4 Worker can apply retained V2, V3 and V4 steps to a V1
database without deploying the V2/V3 applications. A latest additive artifact can
install its genuine retained V1 baseline and use the same path on a new database.

Each step retains its exact source identity, normal fences and durable receipts;
restart resumes incomplete work. Required indexes still gate readiness, and old
compatible applications remain admitted. For explicit Worker-only catch-up across
gaps containing row transformations, use:

```sh
app --schema catch-up --json
```

It executes retained row expansions, finishes retained index jobs, closes required
additive epochs, and runs reviewed intermediate Contracts. No intermediate
application deployment is needed. The binary must contain the complete frozen
history, typed conversions and required Contract declarations. Installation remains
a separate Installer operation; on a new database, the latest artifact installs
its genuine retained V1 before catch-up.

Stop incompatible application/worker instances and wait 30 seconds after their
last heartbeat before catch-up. The command refuses recent retiring instances,
uses the normal transaction fences, and never implies `--force`. Data rejection
blocks retirement and preserves the admitted repair path; repair the source and
rerun the same command. Process interruption resumes from durable receipts.

For row-only histories, success reports `schema-caught-up` at the latest expanded
version. That final row window remains open for ordinary Worker backfill and
Request use; its own Contract is still explicit.

For supported **queue-only payload histories**, use the newest binary for both
deployment operations, with separate credentials:

```sh
# Installer credentials: install the retained V1 origin if needed and stage edges.
app --schema install --worker WORKER_ROLE --request REQUEST_ROLE --json
# Worker credentials: execute the staged history and retire every queue edge.
app --schema catch-up --json
```

Installation stages immutable future source/target proposals in bounded groups.
Staging grants no version admission, conversion attempt or expansion receipt.
Activation still requires the actual adjacent predecessor and its finality.
Queue catch-up converts retained jobs and completes every queue-conversion edge
it executes. When the target itself changes queue payloads, its Contract also
completes before success, establishing the latest admission floor. It refuses
live old claims, recent retiring instances, rejected/invalid payloads, and missing
staged or executable repair authority. Include every needed historical
`QueueRepair` declaration in the newest artifact, install it, and rerun catch-up.

Request processes wait for verified readiness. Installation/staging, explicit
Contract commands remain available, alongside the row catch-up coordinator. The
`deploy` command above wires installation/staging and Worker execution into one
finite production operation.

### Ordered row and queue changes

Use separate revisions when changing both stored rows and queue payloads:

1. Author the row change while keeping queue membership and payload contracts
   unchanged. Generate and review that revision's row Contract.
2. Freeze it and author the queue-payload change, keeping the settled entities
   unchanged. Preserve any required `Same` declarations for retained nominal types.
3. Build the latest artifact with both revisions and the row Contract. Run its
   `--schema install` as Installer, then `--schema catch-up` as Worker. No
   intermediate application image is required.

Row retirement preserves unchanged job bytes and records their version restamp
in the same transaction as the row finality and admission floor. Live old claims
block that transaction. Rejection or interruption cannot publish a partial
restamp/retirement. The following queue edge binds the exact completed row
Contract's settled layout before converting jobs.

`MIG028` names conflicting row entities and queue payloads when they share an
edge, and gives the split/order and next commands. The executable
[ordered row/queue witness](../scripts/test-ordered-row-queue.py) covers Retype /
WriteBack followed by a payload change, old-writer overlap, repair, active claims,
crash recovery, audit corruption refusal and a subsequent additive epoch.

Contract is the retirement/finalization step: establish final data and queue
state, fence out retiring versions, then perform the reviewed cleanup. Automatic
Contract execution means scheduling that same checked operation when safe.
It does not by itself provide installation, conversion or multi-version catch-up.
Those complete automatic deployment/catch-up paths are required release work;
see [delivery requirements](../dev-docs/migration-delivery-status.md#clarified-release-requirements-maintainer-2026-10-12).

### Current explicit-command sequence

1. Preserve the old release and frozen source. Prepare the next transition through
   the guarded compiler workflow; run `agent-context` and business/fixture tests.
2. For row cleanup, generate and review the exact Contract source before building
   the release. Queue-only Contract needs no row-cleanup declaration.
3. Run any required installation/staging as installer. Staging alone does not admit
   the target. Run its schema Worker with Worker credentials.
4. Start the new Request application after expansion. Keep the predecessor only
   while admitted. Old writes invalidate unfinished row transformations; queue
   conversion and repair keep exact old payload identities.
5. Inspect status. Repair rejection through the supported typed policy, stop old
   processes, and wait for their last heartbeat to age out (30 seconds).
6. Run the current target's Contract as Worker. A future/unpublished target cannot
   report success by replaying an earlier retirement. Retry and restart consume
   the same immutable receipts.

See [cleanup contracts](migration-contracts.md) for row rules and additive epoch
closure; [lesson 96](../example/learn/lesson96-typed-queue-conversion.md) for queue
conversion, separately deployed repair and retirement.
For a longer multi-table history, run the
[twenty-release project tracker](../example/db-twenty-releases/README.md): its 95
Tesl API tests run on the retained PostgreSQL database at the corresponding release.

Queue conversion installation stages at most 32 source lineages per transaction.
A failure rolls back its current group; earlier committed groups remain immutable
and an exact retry reuses them. Staging alone leaves admission floors and payloads
unchanged. Catalog verification and admission fences are renewed for each group;
sharing validation inside one transaction never authorizes a later transaction.

## Diagnose queue blockers without reading raw historical tables

```sh
./app --schema status --json
./app --schema status
```

Status includes schema expansion, recent instances, verified index-job projection
and a protected queue summary. Human output prints blocker codes, counts and
actions. JSON includes per-job-type old/rejected/invalid counts, installed repair
revision and whether the source payload contract is unchanged. No historical
payload bytes or arbitrary callback reason text is returned. The first 100 job
types are reported; `complete: false` explicitly marks a larger inventory.
The `rejected`/`invalid` counts include current-version operational quarantines.
Their migration blocker entries count only historical payloads that prevent
retirement; a current-version quarantine does not hide unrelated old work.

| Code | Meaning | Supported next action |
|---|---|---|
| `QUEUE_MIGRATION_REJECTED` | A decoded historical record failed business conversion | Add a new checked QueueRepair revision, rebuild/import it into the target app, install it, run that repaired Worker |
| `QUEUE_PAYLOAD_INVALID` | Frozen decoder cannot interpret the bytes | Investigate the representation or explicitly authorize an `on: "unconverted"` discard revision; typed repair cannot fabricate the old value |
| `QUEUE_MIGRATION_EXECUTION_FAILED` | A bound callback/codec trapped, exhausted its budget or produced an unusable result | Deploy an `on: "execution-failed"` corrected converter or an explicit `on: "unconverted"` discard revision. An admitted predecessor may also process a still-processable original job |
| `QUEUE_RETIRING_CLAIMS` | Old claimant still owns a live lease | Stop retiring claimants and wait for lease expiry; do not edit claim tokens |
| `QUEUE_CONVERSION_ATTEMPTS` | Conversion work is still recorded | Wait for or restart the correct schema Worker; preserve installed history |
| `RECENT_RETIRING_INSTANCES` | Old processes reported within the heartbeat window | Stop them and wait; queue Contract has no force bypass |
| `QUEUE_OLD_PAYLOADS` | Old-stamped work remains | Run the current Worker; Contract restamps identical unchanged jobs under its fences |

An empty Worker scan is not finality. Contract preflights all blockers before
restamping unchanged pending/delayed/dead jobs. It keeps their bytes, retry count
and schedule, preserves surviving claims, releases expired retiring claims, and
records restamps in the same transaction as retirement. Rollback restores jobs,
audit and admission floors together.

## Queue conversion progress across job types

Each Worker conversion turn selects at most 1–256 jobs. It shares the remaining
budget among remaining conversion descriptors and visits sources in durable
least-recently-served receipt order. A continuously busy first job type therefore
does not monopolize the tested two-type workload; restarting retains service
ordering. A source with no eligible work yields capacity to subsequent sources.

This ordering is a scheduling policy, not a finality cursor or a wall-clock latency
guarantee. Inspect blockers and use Contract to establish retirement. The protected
selector requires the verified receipt lookup index; a development catalog missing
it refuses explicitly. Current evidence covers two-type load/restart, 17-type
backlog progress, 1,024 conversion receipts and a 257-type reference workload.
The latter reaches every type in 24.535s and 24.549s after Worker readiness, with
busy-head work still pending; enqueue setup is approximately 45s separately.
See the [performance report](../dev-docs/queue-admission-performance.md) for exact
workload, binary provenance and limits. This is not a production throughput SLA.

## When callback execution stops

Generated migration graphs share an operational budget: 100,000 entry/loop steps,
128 nested calls and a two-second cooperative deadline. Nested helpers do not
renew fuel. Where supplied, operation cancellation is checked too. Pure adapters
return an error rather than a usable late result. The application queue Worker
records recognized execution faults separately and continues healthy work, including
other jobs of the same type. Payload/version, retry count, due time and conversion
receipts remain unchanged. The attempt's monotone claim sequence and immutable
failure audit commit together; cancellation, lost connections and SQL errors roll
back instead.

Status reports `executionFailed` globally and per job type, with the distinct
blocker above. The private audit binds job, checked source digest, attempt sequence,
original payload hash and a fixed code (`execution-budget`, `execution-trap`, or
`invalid-result`). It contains no arbitrary callback exception text. Restart does
not retry that same source on those same bytes for that job. This evidence is not
a business `Reject` or permission to bypass Contract.

Where the original job is still processable and its predecessor remains admitted,
the application's existing predecessor handler may claim and complete it normally.
Completion retains the audit; its job ID cannot be reused. Once old work and all
other blockers are gone, Contract can retire. For work that must survive, append a
checked `QueueRepair` with `on: "execution-failed"`; for obsolete old work, append
an explicit `on: "unconverted"` discard decision. See [queue remediation](queue-remediation.md)
for fixture, inspection, claim and audit obligations. Do not edit installed history
or delete the audit to manufacture a retry. Purity/type checking is not a static termination
proof; the budget is not hard intrinsic preemption or a memory sandbox.

## Current scope

Row and queue examples demonstrate repeated non-additive upgrades, including
ordered row-first / queue-payload-second changes. A row-transforming edge retains
identical queue contracts; a payload-changing edge retains settled entities.
Simultaneous row/payload changes, queue-bearing table Drop, old-catalog adoption,
and the general `IgnoreOld` schema-change
constructor remain outside the supported surface. Explicit discard revisions can
remove malformed old jobs; they do not reconstruct a typed value. Consult the current language spec
and executable examples rather than contributor milestone history when choosing
an operation.

Changing a queue job's record is different from changing an entity table. A checked
`jobs:` migration can change an `InvoiceJob` payload while stored entities remain
unchanged. To change both an `Order` entity and `InvoiceJob`, use the ordered
workflow above: first the row revision and its Contract, then the payload revision.
Both can be deployed together in the latest binary; the runtime executes their
checked steps in order.
