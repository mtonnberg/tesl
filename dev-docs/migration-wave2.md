# Migration performance: second sweep

> Audience: contributors reviewing CI scheduling and migration runtime changes.

Base: PR #116 at `aa447d2`. This branch is stacked on that PR until it merges.
All nine candidates were examined. Six are implemented; three are deliberately
deferred after experiments or compatibility witnesses, rather than bypassing
the checks which make the existing migration protocol safe.

## Decisions

| Candidate | Result | Concrete boundary |
|---|---|---|
| Overlap fixture construction with early database tests | Implemented | Core checks start immediately; lifecycle checks wait for fixtures. A source/major-bound verifier requires both successful lanes and the exact original phase union. |
| Share more compiler-generated fixtures | Implemented | Ordinary indexes, stage preparation, guarded promotion and cancellation fixtures are built once. Each PostgreSQL lane still runs their native/race lifecycle tests. |
| Stable runtime compilation across releases | Deferred | A Go dependency experiment shows that changing a data-only dependency still recompiles its importing engine package. Moving JSON to a child package is not sufficient. |
| Batch table-catalog inspection | Implemented | Definitions and ordinary ACLs are grouped; unexpected sequences are checked as a set. Builtin metadata is reused only within one inspection. |
| Parse physical headers once | Deferred pending catalog upgrade design | The optimized SQL executes, but the existing exact-body catalog reader rejects it. Changing protected definitions in place is not a compatible runtime-only optimization. |
| Bounded multi-batch Worker turns | Replaced after failed measurements | Register immutable shards once per Worker connection session; keep one batch per lease. Claims and publications still inspect live state every batch. |
| Index history receipts per inspection | Implemented | Receipts are grouped by version without losing duplicates or order; retirement membership is indexed. No persisted receipt is cached across snapshots. |
| Bulk backfill publication | Implemented for a conservative subset | Primitive keys, no secondary UNIQUE indexes and no active staged guards; other cases retain the guarded pipeline. |
| Parallel key-range shards | Deferred pending protocol upgrade | A genuine compiled application refuses a second shard. Current readers require shard zero and full-range coverage, and finality assumes one shard per entity/window. |

## CI coverage and scheduling

`scripts/migration-lanes.py` derives both lane inventories from the existing
authoritative migration inventory. The split is immediately before
`test_migration_row_indexes`: it allows kernel and early compiler/runtime work
to overlap the shared producer. The original per-major required check name is
retained by the final verification job.

Both lanes own private PostgreSQL clusters. The lifecycle lane bootstraps its
compiler and verifies copied artifacts; it does not claim a second compiler-build
phase in the union. Receipts bind source revision/tree, PostgreSQL major, ordered
phase inventory and hashes of the actual phase evidence. Missing, reordered,
duplicated, changed or failed work refuses. Failed upstream jobs cannot borrow
old successful receipts. The default local and authoritative CI runner still
executes the complete serial gate.

Native index fixtures are part of the existing artifact manifest and hash/mode
verification. Their compile-time refusal assertions execute in the producer;
the consumer runs every native test on its own PostgreSQL server. Direct export
flags remain cleared by the mandatory runner. The prebuilt path is selected only
after manifest verification. Each fixture build uses `-trimpath`; ordinary runtime
tests retain their existing source-location behavior.

The expected critical-path saving is overlap, not removal of assertions:
`build + core + lifecycle` becomes `max(build, core) + lifecycle` in the matrix.
Runner startup, compiler bootstrap, artifact transfer and verification still
count. Hosted measurements are required before assigning an overall factor.
The independent authoritative CI migration shard remains a separate workload.

## Runtime guarantees

Table inspection uses the same JSON catalog projection and deparsing as the
single-table reader. Aggregate observations are bounded to 64 MiB. Missing tables,
unexpected objects, write grants, inherited privileges and sequences still refuse.
No stored default/trigger is evaluated by inspection. Tests compare batch and
individual results and mutate catalog/ACL state after a successful observation.

Workers register immutable shards once per connection session. Each ordinary
batch still claims and releases its lease, with fresh live-state inspection and
publication admission. Retirement after preparation is recognized only through
a fresh verified retirement receipt. Renewal is joined before lease release.
Finality retains its existing full-rescan renewal scope.

Bulk publication happens only after the first successful single-row CAS and ABI
latch. The first write's ordering remains observable to crash/race tests. Later
bounded groups use a typed `UPDATE FROM VALUES` statement. The individual and
bulk paths share the same predicate builder for primary-key identity, xmin,
generation, full transaction-ID distance and snapshot age.

PostgreSQL's own key equality checks for duplicate encoded keys before any bulk
DML. Duplicates fall back to the original ordered pipeline. Nominal/JSONB keys,
secondary uniqueness and staged guard windows also keep the original path.
SQL errors still roll back every group, the processing receipt and cursor.
A compiled fixture pauses after a successful bulk group, accepts an old writer's
edit to a later row, forces a serialization failure, then verifies complete
rollback and a fresh retry preserving that edit.

## Why the three deferrals are real

The cache experiment used a Go module with `main -> engine -> data`, a mutable
exported history variable, `-trimpath`, and the same compilation cache. Changing
only the variable initializer caused both data and engine compilation again.
Logs are in `/tmp/nix-shell.E25jrS/opencode/runtime-cache-probe/{before,after}.log`.
A useful runtime split therefore needs a different initialization boundary, not
just another package. This increment does not expose an unchecked history-loading
API or use unsafe linkage to manufacture cache reuse. Expanded fixture reuse is
the lower-risk improvement implemented instead.

`TestPgRowHeaderOptimizationNeedsCatalogUpgrade` installs a single-parse prototype
inside a rolled-back transaction. The new body is valid and verifiable against
its own exact specification, but the existing specification refuses it. No SQL
definition change is shipped. A future design must handle old and new binaries,
installation/restart and rollback, not just benchmark a fresh database.

`TestPgRowParallelShardRequiresProtocolUpgrade` adds a second shard to a real
compiled V2 application's test database and verifies that its normal status path
refuses the layout. Enabling ranges also needs typed bounds in the read query,
coverage/disjointness verification and updated finality/old-reader behavior.
Parallelizing only independent entities is a possible alternative, but does not
solve the single-large-table case and needs separate ownership/connection tests.

## Verification and measurements

- Partition and receipt tests cover the complete phase union, wrong sources or
  majors, missing/duplicate lanes, changed bytes, failed upstreams and stale
  success receipts after a failed retry.
- Artifact verification tests include the new native index executables.
- All four reused native index/stage groups passed on PostgreSQL 18 with race
  instrumentation, without reconstructing their applications in the consumer.
- PostgreSQL 18 catalog/drift/permission and Worker baseline tests passed.
- Compiled bulk-publication rollback, ordinary pipeline rollback, finality,
  lease renewal, serialization retry, cancellation and restart checks passed in
  the selected row lifecycle suite. Unselected compiler cases were not counted
  as executed by that focused invocation.
- One race-instrumented catalog sample read the same 29 tables in 71.8 ms as a
  batch versus 182.5 ms individually. This is component evidence, not startup p99.

Whole-workload measurements use ordinary before/after binaries, the same rollout
source, alternating order, full-row validation, Worker restart, old/new writes,
rejection/repair and Contract. Small local samples are not production acceptance.

The rejected multi-batch prototype passed targeted lifecycle tests but failed a
rollout with `tesl: row lease lost or expired`; another run passed correctness at
123.07 rows/s versus baseline runs near 560 rows/s. These observations do not
isolate the cause, but are insufficient evidence to retain longer lease turns.
Raw results remain in `wave2-pair-{before,after}-{1,2}` under
`/tmp/nix-shell.E25jrS/opencode/`. Earlier favorable samples do not override them.

After restoring single-batch leases and preparing shards once per connection,
four alternating local runs used 10,000 rows, two clients, one-second request
samples and a 300-second rollout limit:

| Execution order | Build | Backfill rows/s | Backfill seconds | Contract seconds |
|---|---|---:|---:|---:|
| First | Candidate | 545.68 | 18.33 | 11.46 |
| Second | `aa447d2` | 370.76 | 26.97 | 16.49 |
| Third | Candidate | 410.41 | 24.37 | 12.82 |
| Fourth | `aa447d2` | 339.98 | 29.41 | 18.03 |

All reported `correctnessPassed` and `allRowValuesVerified`. Raw results are in
`wave2-single-{before,after}-{1,2}/result.json` under the same temporary directory.
The combined candidate improved these local samples; they do not isolate each
optimization or establish a production speedup or request-latency budget.
The final single-batch implementation also passed the compiled lifecycle and
bulk rollback cases, and the bulk guard cases including transaction-ID wrap,
changed keys and wrong generations.

Protected SQL definitions, latency thresholds and the pinned comparison baseline
are unchanged. Hosted CI and native-platform results remain required.
