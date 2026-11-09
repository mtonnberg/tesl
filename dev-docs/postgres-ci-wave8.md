# Eighth sweep: indexed PostgreSQL predicates and shared Contract checking

> Audience: contributors reviewing runtime performance and compiler verification.

Baseline: `a6e73da` (`main`, merged wave seven). Branch: `perf/postgres-ci-wave8`.

## Primary result: real PostgreSQL HTTP lookups

Nullable equality previously used `IS NOT DISTINCT FROM`; nullable runtime-list
membership used `array_position(array, column) IS NOT NULL`. These preserve NULL
semantics, but can prevent PostgreSQL from using an existing equality index.
An ordered membership query could scan the primary-key index across the entire
table and discard almost every row.

The compiler now emits these positive WHERE predicates:

```sql
(column = $1 OR (column IS NULL AND $1 IS NULL))
(column = ANY ($1::text[])
 OR (column IS NULL AND array_position($1::text[], NULL) IS NOT NULL))
```

The actual array carrier follows the declared column type. Each operand still
binds once; repeated references use the same parameter. Negative equality and
membership retain their previous NULL-safe expressions. These rewrites preserve
exactly which rows satisfy WHERE, including supported AND/OR combinations. They
are not interchangeable Boolean-valued expressions outside that context: SQL
UNKNOWN can replace FALSE without changing WHERE's selected rows.

### Complete HTTP measurements

`bench/NullablePostgres.tesl` serves ordinary release HTTP handlers against a real
private PostgreSQL 17.10 database. Both versions use identical data and the same
pre-existing B-tree on `owner`. Index creation, seeding, validation and EXPLAIN
are outside timing. Timings include response transfer; client JSON parsing is
outside timing. This synthetic workload uses server-generated operands selected
by a path capture, with no authentication or uploaded-list decoding.

Four runs alternate **before/after/after/before**. Each uses eight warmups and
20 measured samples per case. Below: PostgreSQL's actual default `auto` planning.

| Table rows | Request | Before medians (ms) | After medians (ms) | Approximate gain |
|---:|---|---|---|---:|
| 100,000 | Equality, 10 full rows | 7.114 / 7.594 | 0.414 / 0.424 | 17–18× |
| 100,000 | Membership, 20 full rows | 22.321 / 23.509 | 0.495 / 0.493 | 45–48× |
| 100,000 | Membership with NULL, 30 full rows | 23.994 / 24.740 | 0.540 / 0.602 | 40–46× |
| 1,000,000 | Equality, 100 full rows | 35.382 / 35.035 | 1.148 / 1.369 | 26–31× |
| 1,000,000 | Membership, 200 full rows | 298.262 / 293.874 | 2.001 / 1.812 | 147–165× |
| 1,000,000 | Membership with NULL, 300 full rows | 293.469 / 305.465 | 2.390 / 2.782 | 105–128× |

Count endpoints also improved. At one million rows, non-NULL equality count was
24–26 ms before versus 0.56–0.59 ms after; membership count was 57–58 ms versus
0.37–0.38 ms. Empty-list and missing-value results are checked but do not supply
the headline speedup.

All 22 cases in every run checked counts, complete rows, ordering, NULLs,
duplicate operands, Unicode/quotes, and Int values beyond int64. Separate
`force_generic_plan` controls also passed and retained substantial improvements.
No acceptance threshold or planner setting was changed for the default results.

Outside-timing EXPLAIN evidence identifies the mechanism: a baseline million-row
membership plan filtered 999,800 rows while scanning the primary-key index;
candidate used the owner bitmap index and fetched the 200 matching rows. Plan
diagnostics run in separate sessions with identical SQL, role and operands;
their prepared-plan counters are retained, not attributed to the HTTP connection.

Reproduce, alternating baseline/candidate checkouts with built compilers:

```sh
python3 scripts/measure-nullable-postgres.py \
  --repo-root /path/to/checkout --output /tmp/nullable-run \
  --rows 100000 1000000 --warmup 8 --samples 20 \
  --plan-modes auto force_generic_plan
```

Raw timings, exact emitted SQL, plans, tool versions and source/compiler/binary
hashes: `/tmp/nix-shell.3bBrzt/opencode/w8-null-{b1,a1,a2,b2}/result.json`.
All four runs reported `correctness-passed`.

These gains require selective predicates and a suitable existing index. Broad
matches, dense NULLs, absent indexes, network latency and larger responses change
the benefit. In particular, a generic plan can visit NULL index entries even when
the operand excludes NULL. Local measurements do not establish production p99
or a PostgreSQL 14 performance result.

A separate million-row, approximately 90%-NULL SQL spot check forced generic
planning: both versions scanned the table. A non-NULL membership hit took
97 ms before and 110 ms after; mixed-NULL membership took 268/264 ms. These single
SQL samples are not HTTP measurements, but show why the selective indexed
workload's speedup must not be generalized to dense-NULL generic plans.

## Compiler result: one checked history per Contract batch

Application diagnostics used to discover, check and plan the entire family
history separately for every retained Contract. `diagnostics_batch` now shares
one successfully checked plan inside that single call. It still checks every
Contract independently against its own source overlay and current compiler ABI.

Reuse validates captured source bytes, directory membership, import resolution,
stdlib identities and checked-history guards. Changed inputs rebuild through the
original checker; failed history construction is not cached. The single-module
API remains an independent differential oracle. There is no cross-call cache.

Three-run medians for full family Contract diagnostics, including discovery and
parsing (not whole builds):

| Fixture | Contracts | Single API | Batch API | Gain |
|---|---:|---:|---:|---:|
| Checked-in Todo V13 | 4 | 1.568 s | 0.526 s | 2.98× |
| Reconstructed Tracker V20 scenario | 9 | 7.223 s | 1.403 s | 5.15× |
| Heavy generated V20 | 19 | 18.993 s | 2.340 s | 8.12× |

Heavy fixture's separately recorded pre-edit baseline was 16.751 s (7.16× versus
candidate); the table reports contemporaneous alternating single/batch calls.
Tracker sources follow the real twenty-release scenario but are reconstructed,
not an archived rollout. Their checked history is suitable for source diagnostics;
Go emission refused its legacy ABI seals on both compilers, so no emission gain is
claimed from that fixture.

Complete CLI `agent-context` on that Tracker application, alternating B/A/A/B,
took **7.205 / 7.593 s → 1.807 / 1.841 s**, approximately **4×**. Full JSON output
was identical, including diagnostics and proof obligations. This is a whole
diagnostic-command improvement, not a measured whole-CI speedup.

Reproduce the component measurement:

```sh
cd compiler
TESL_REPO_ROOT=/path/to/repo dune exec test/bench_migration_contract.exe -- \
  /path/to/project Schema.Family 3
```

Evidence: `contract-candidate-results.md` and `w8-compilation/result.json` under
the temporary directory above.

## Verification and remaining candidates

Contract differential tests compare complete ordered diagnostics across valid and
invalid selectors, parse errors, edited frozen history, changed directories,
unsaved buffers, different projects, pinned-source conflicts and application
integration. The focused Contract/application/history/ABI/storage/transform-link
run passed 125 cases.

SQL regressions exercise Memory/PostgreSQL agreement for equality, inequality,
membership, NULL combinations, empty lists, compound predicates and update/delete.
Additional live driver tests cover nullable NUMERIC, secrets and JSONB, including
JSON null versus SQL NULL and once-only argument evaluation. A sealed transforming
history test checks renamed/copied nullable fields, repeated logical field holes
and exact parameter alignment in emitted versioned queries.

Final verification also passed all 28 Contract cases (including four actual
native PostgreSQL cases), all 13 ordinary typed migration-query cases, and the
new driver-carrier test under Go's race detector. An isolated committed checkout
rebuilt with no generated differences, regenerated all 199 snapshots unchanged,
passed documentation integrity, and passed CI suite/shard inventory checks.

Other candidates found during this sweep:

- Backfill's nullable-cursor OR may cause repeated prefix scans with generic
  plans. Actual default worker-plan evidence is needed before selecting it;
  splitting initial/resumed queries could preserve existing CAS/finality rules.
- Legacy non-unique index declarations are not currently installed by bootstrap.
  Implementing them requires a bounded-carrier/deployment design: B-tree indexes
  on unbounded keys can introduce new write failures.
- Wide versioned row reads repeatedly construct decoder layouts. Result-set-local
  sharing merits profiling while retaining per-row generation and proof checks.
