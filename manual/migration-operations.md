# Operating a checked migration

Tesl migrations are a deployment lifecycle, not just DDL. Source checking establishes
the allowed transition; installed history and runtime fences establish when it is
safe to publish new data and retire old users.

## Which connection runs which command?

| Operation | Principal | Purpose |
|---|---|---|
| `tesl migrate generate`, `tesl migrate contract`, `agent-context`, source tests | Compiler/tooling | Prepare and check source; do not modify the application database |
| `app --schema install --worker ROLE --request ROLE` | Short-lived installer | Register the exact compiled baseline or queue/repair staging |
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

| Code | Meaning | Supported next action |
|---|---|---|
| `QUEUE_MIGRATION_REJECTED` | A decoded historical record failed business conversion | Add a new checked QueueRepair revision, rebuild/import it into the target app, install it, run that repaired Worker |
| `QUEUE_PAYLOAD_INVALID` | Frozen decoder cannot interpret the bytes | Investigate the original representation; typed repair cannot invent a valid old record; general audited discard/adoption is not yet implemented |
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
backlog progress and 1,024 conversion receipts, rather than production-scale
inventories or throughput.

## When callback execution stops

Generated migration graphs share an operational budget: 100,000 entry/loop steps,
128 nested calls and a two-second cooperative deadline. Nested helpers do not
renew fuel. Where supplied, operation cancellation is checked too. A public Worker
reports `migration execution stopped` rather than publishing a usable late result.
The failed job transaction leaves payload/version and receipts unchanged.

Inspect the callback and its input sizes; fix a nonterminating or excessively
expensive policy before retrying. Do not edit a deployed conversion to disguise
history. Purity/type checking is not a static termination proof; this is not hard
intrinsic preemption or a memory sandbox.

## Current scope

Row and queue examples each demonstrate repeated non-additive upgrades. Queue
histories retain membership and unchanged stored entities; unrestricted mixed
row/queue evolution, old-catalog adoption, and general `IgnoreOld`/malformed-data
recovery remain outside the supported surface. Consult the current language spec
and executable examples rather than contributor milestone history when choosing
an operation.
