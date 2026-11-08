# Migration and HTTP performance: fifth sweep

> Audience: contributors reviewing runtime batching, compiler checks and performance evidence.

Baseline: `64e9abc` (wave four), squash-merged as `53e5602` in PR #119 with an
identical tree. Branch: `perf/migration-http-wave5`, based on merged `main`.

## Selected large wins

Profiling real HTTP requests with PostgreSQL `pg_stat_statements` exposed a
post-migration bottleneck. Before a transforming migration, the ordinary update
path already used one SQL UPDATE. After Retype and Contract, the typed retained
path still performed writer-setting setup/restoration, UPDATE and processing
checks separately for every selected row. Updating 1,000 rows issued about 5,014
top-level Request-role SQL calls.

The selected runtime change batches publication of eligible, already locked and
decoded rows after Contract. The selected compiler change extends existing
compilation-scoped caches to public module checking, which standalone
`agent-context` and CI fixture validation also use.

A migration-preview cache extension produced only a modest preliminary gain and
was dropped. Active-backfill lease changes and protected PostgreSQL function
rewrites were not pursued: they require separate lifecycle/upgrade work. This
increment does not claim a faster active backfill or a 10× whole-CI build.

## Runtime eligibility and guarantees

The fast path requires the verified settled projection selected by the existing
transaction factory. It excludes active windows, future-generation observations,
secondary UNIQUE indexes, staged guards, nominal/JSONB primary keys, debug SQL
capture and unsupported parameter carriers. Those paths retain ordered individual
updates. `updateAndReturnOne` retains its ambiguity check and individual path.

The UPDATE target still comes from one cursor and its original snapshot. FETCH
still locks and decodes rows; checked codecs materialize original and new values.
The first row of each fetch uses the original single-row publication, preserving
its first-write boundary. Subsequent groups contain at most 128 rows, respect the
PostgreSQL parameter limit, and use an 8 MiB encoded-argument weight budget.
Preparation stops at that budget plus at most one oversized row; fallback reuses
prepared values rather than evaluating codecs again. This is not a total request
heap limit, and the existing FETCH size remains unchanged.

Each group uses typed parameters and UPDATE FROM VALUES. PostgreSQL compares
original/new primary keys and rejects ambiguous duplicate inputs before bulk DML.
A duplicate source-key group falls back. Missing/changed keys or SQL errors fail
the operation. The existing outer admission rolls back all groups, including
earlier single-row writes, even inside a caller-owned transaction.

Writer state is restored after each group. Processing checks still run after the
first write and each successful group; transaction-entry/final ABI checks and
compatibility fences remain. No database admission result is cached across
transactions, and no protected SQL definition or persisted protocol changes.

## End-to-end HTTP measurements

`scripts/measure-settled-update.py` compiles the ordinary V2 fixture, installs and
contracts its database, then measures HTTP updates and reads against PostgreSQL.
Controlled SQL fixture loading is outside timing. Every sample validates every
row identity, updated metadata and untouched fields through the typed HTTP read.
It preserves warmups, raw samples, query statistics and build/source hashes.
Inherited libpq connection/service settings are cleared so commands use only the
private cluster.

Example, after preparing V2 sources with the existing demonstration builder:

```sh
python3 example/db-three-upgrades/run.py --build-only --output /tmp/row-fixtures
python3 scripts/measure-settled-update.py \
  --source /tmp/row-fixtures/v2/source --output /tmp/settled-after
# Use --repo-root /path/to/baseline-checkout for the baseline compiler/runtime.
```

Four local runs used before/after/after/before order, two warmups and eight measured
samples per size. Median full HTTP update times:

| Rows | Before, first/second run (ms) | After, first/second run (ms) | Observed gain |
|---|---|---|---|
| 1 | 4.489 / 4.485 | 4.352 / 4.599 | No meaningful improvement claimed. |
| 100 | 36.970 / 38.620 | 6.626 / 6.727 | About 5.6–5.7×. |
| 1,000 | 337.765 / 345.498 | 25.489 / 26.298 | About **13.1–13.3×**. |

Request-role SQL counts for the large update dropped from about **5,014 to 59**.
The counters can include a background Request-role heartbeat, so occasional extra
calls are retained rather than filtered. Reads of the same large row set remained
around 10 ms; no read-latency or universal HTTP-throughput improvement is claimed.
These small local samples do not establish production p99 budgets.

Raw evidence: `/tmp/nix-shell.E25jrS/opencode/w5-http-{b1,a1,a2,b2}/result.json`.
All reported `correctness-passed`. Earlier exploratory runs measured different
absolute times but the same reduction in per-row SQL work; the table above uses
the controlled repeated runs.

## Compiler/CI measurements

`Compile.check_module` now enters the same bounded, exact-input compilation cache
scope already used by emission. Body, proof and source checks still execute;
repeated schema inventories, parsing and guarded history discovery can be reused
within that one call. Scope cleanup still runs on success or exception.

Alternating before/after/after/before V20 `agent-context` runs took **34.65s,
8.33s, 8.16s, 36.28s**: approximately **4.2–4.4×** for that standalone diagnostic
workload. Complete decoded JSON results matched exactly, including diagnostics,
symbols, obligations, fixes and content hash. This targets repeated checking in
fixture builds and editor/agent queries, not Go compilation itself.

Raw evidence: `/tmp/nix-shell.E25jrS/opencode/wave5-diagnostics-results.json` and
the corresponding before/after JSON snapshots.

## Regression coverage

- PostgreSQL publication tests cover active/future/staged/unique/key fallbacks,
  duplicate inputs, changed/lost keys, SQL failures, expired admission, large
  payloads, aggregate payload budget and unsupported carriers.
- A driver tracer asserts that publication query count stays constant when a
  group grows from two rows to a full group. It does not depend on wall-clock
  timing or skip the SQL writes.
- A real cursor test forces budget fallback and verifies codecs execute exactly
  once for each original/new value.
- A compiled HTTP fixture enters an explicit transaction, reaches multiple bulk
  groups, then loses its PostgreSQL backend. No prefix becomes visible; every
  write rolls back. A fresh retry preserves all values. Captured operands retain
  their evaluation counts, and ambiguous returning updates still publish nothing.
- The full typed-row access suite passed, including existing Contract races,
  first-ABI ordering, old-writer CAS, JSONB/nominal keys and repeated windows.
- Application dependency, source-view, workspace-session, diagnostic-protocol,
  inventory and frozen-closure suites passed for the checking-scope change.
- Go static gates and embedded-runtime synchronization checks passed.

The unchanged pinned-baseline latency gate also passed locally. Its 99% upper
paired deltas were 0.269 ms / 0.431 ms for read p50/p95 and 0.257 ms / 0.344 ms
for write p50/p95, below its original limits. This separate gate measures the
ordinary small V1 workload, not bulk-update speed. Its baseline, policy and
thresholds are unchanged. Evidence: `wave5-latency/result.json` under the same
temporary directory. Full hosted CI remains required.
