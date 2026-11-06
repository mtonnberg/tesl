# Post-merge migration review — 2026-11-05

> Audience: contributors investigating migration CI failures, integration and performance.

Baseline: main `1fc72cbfa50f579e577adfc67b5d8aa31bfce1dc`.
PR #102 head: `d0caabc0735cb3c212ba0d386450a3f726cf06f0`.
Their source trees are identical (`git diff --exit-code` passes).

## Implementation follow-up

The findings below describe the initial review. Follow-up work has now:

- Integrated the four PRs locally, including the shared versioned Go overlay.
- Fixed #111's newtype traversal, including imported wrappers with private
  underlying records and owner-scoped lookup. Invariant refusals no longer
  prescribe an unsupported cross-check remedy.
- Fixed #112's required wire-type closure and repeated import paths. Unused
  transitive imports remain excluded. Distinct owners of one flattened client
  name now refuse with a constructive error instead of silently choosing a type.
  Named TypeScript schema references are
  lazy, so cross-module declaration order does not cause initialization errors;
  nonprimitive newtype schemas preserve their underlying wire representation.
- Reproduced both failing PostgreSQL 18 staged-index tests, then initially made
  them pass with the original 15-second readiness deadline. Completing an index now
  dispatches other pending work immediately; failed attempts still wait for a
  poll. A ten-minute-poll regression initially built all five indexes in 11.86
  seconds. The complete suite later exposed remaining deadline sensitivity;
  correctness-test readiness now uses 60 seconds, capped by scenario context.
  This budget correction is distinct from the scheduling speedup.
- Added bounded backfill pipelining: one writer-setting scope per fenced batch,
  first successful CAS/latch kept in order, then groups of at most 128 guarded
  UPDATE statements. A 260-row PostgreSQL 18 race regression forces a later
  group to fail and verifies complete rollback, fresh retry and preserved edits.

### Paired performance result: useful, short of the 10× target

Four sequential ordinary-binary runs used the same 10,000-row rollout workload,
PostgreSQL 17.10, two clients, a 2,000-row batch and one-second fixed sampling
phases. Order: before, after, after, before. Both variants already contain the
index scheduling fix and the integrated PRs; this comparison evaluates the
backfill pipeline. Application/schema/Contract source hashes match; sealed
migration headers reflect their respective compiler/runtime ABIs. Both measured
pipeline runtime files match the working tree byte-for-byte. Subsequent client
emitter changes are not represented in those benchmark binary hashes.

| Metric | Before 1 | After 1 | After 2 | Before 2 |
|---|---:|---:|---:|---:|
| Steady backfill rows/s | 385.93 | 465.57 | 547.18 | 431.65 |
| Backfill including startup/restart | 28.84 s | 25.95 s | 22.55 s | 28.00 s |
| Contract | 17.49 s | 15.90 s | 19.08 s | 18.01 s |

Median throughput improved **1.24×**; median backfill elapsed time improved
**1.17×**. Contract improvement is not established. All four runs passed full-row
validation, overlapping writers, Worker restart, rejected cleanup, repair,
Contract and post-Contract restart. Short control phases provide insufficient
evidence for the original p99 budgets; this is not release acceptance or a
statistical confidence claim. **10×–100× has not been achieved.**

The first candidate's retained PostgreSQL profile gives a better next target:
`tesl_admit` ran 33,352 times (23.80 s inclusive, 8.97 s self time),
`tesl_row_physical_source_header` ran 66,839 times (7.67 s), and
`tesl_queue_inventory_checked` ran 33,373 times (4.59 s self time). These are
whole-workload cumulative counters, including requests/setup, not isolated
backfill CPU. They indicate repeated admission/header/inventory work deserves
the next profile and optimization; reducing network round trips alone did not
produce an order-of-magnitude local speedup.

Compact hashes and timings: [migration-pipeline-measurements.json](migration-pipeline-measurements.json).
Raw artifacts remain under `/tmp/nix-shell.E25jrS/opencode/rollout-{before,after}-{results,repeat}`.
Reproduce with `scripts/measure-migration-rollout.py --rows 10000 --clients 2
--seconds 1 --max-rollout-seconds 300`, separate immutable artifact/output paths
for each variant, and no concurrent builds or tests during measurement.

### Follow-up verification

- 104 validation, 19 client-generation, 21 module-system, seven Elm-cycle and
  seven membership tests pass, including PostgreSQL 18 membership execution.
- JSONB coverage: 18 cases passed initially; the remaining case expected the
  old emitter diagnostic. It now checks the earlier `V001` rejection and passes.
- Actual generated TypeScript passes strict TypeScript 5.8.3 compilation, module
  initialization, valid nested-record decoding and malformed-value rejection
  with Zod 3.24.4. Generated Elm compiles against refinement-proofs 5.0.1.
- PostgreSQL 18 first-latch rollback, CAS miss, serialization retry and the new
  cross-group rollback tests pass with race instrumentation. Two backend-kill
  cases exceeded their 30-second scenario budgets while unrelated compiler/Go
  builds were running; all three backend-kill cases pass in isolation with the
  same binaries and unchanged deadlines. Keep that hosted-load sensitivity visible.
- The full Dune suite now exits **0** on PostgreSQL 18, with successful results
  cached and failed cases rerun serially. The first broad invocation omitted
  `TESL_MIGRATION_TEST_DSN` (some suites require it in addition to shared-cluster
  variables) and exposed exact-string TypeScript expectations plus lifecycle
  budget failures. Corrected configuration, updated lazy-schema expectations and
  explicit 90-second optional-record/guard-activation scenario budgets resolved
  them. No production deadlines or correctness assertions were relaxed.
  Final logs: `/tmp/nix-shell.E25jrS/opencode/compiler-suite-{final,serial,verified}.log`.
  This is a verified incremental suite, not one uninterrupted all-fresh pass.
- Browser compiler builds with `dune build --profile release
  playground/tesl_playground_js.bc.js`. Nix development-shell evaluation succeeds.
- Hosted complete CI and the supported-major matrix still need a fresh result
  on the integrated revision. Original PRs #111, #112, #113 and #115 can then
  close as superseded; issue #114's runtime-list requirement is covered. Its
  optional left-join alternative is not required for that resolution.

## Initial review decisions

1. Land the CI history/preflight and aggregate-test-budget fixes separately.
2. A combined integration PR for #111, #112, #113 and #115 is feasible, but
   #111 and #112 need the corrections below. Existing green checks predate
   integration with db-migrations. #115's authoritative check is already red.
3. Prioritize backfill SQL batching and catalog-query batching for a **measured
   10× throughput improvement**. Treat 100× as a stretch target for network-bound
   work, not an established whole-system result.

## Why green PR checks became red on main

The [last PR matrix](https://github.com/mtonnberg/tesl/actions/runs/41547051273)
passed PostgreSQL 14 and 18. Main's [ordinary CI](https://github.com/mtonnberg/tesl/actions/runs/41600952033),
native portability and playground also passed. The failures are in the separate
[migration matrix](https://github.com/mtonnberg/tesl/actions/runs/41600951933)
and its [nightly run](https://github.com/mtonnberg/tesl/actions/runs/41807985988).

### 1. Squash merge lost a required benchmark input

The latency comparison pins `9852f263b0ce52f78045c3edb266625aa4460674`, an
internal commit in PR #102. It is not an ancestor of the squash commit. Fetching
all main history does not guarantee that object exists. The old feature branch
is no longer advertised by the remote.

Nightly PostgreSQL 14 completed every preceding phase, including V1–V20 and the
rolling workload, then failed immediately in `latency-regression`:

```text
git rev-parse --verify 9852f263b0ce52f78045c3edb266625aa4460674^{commit}
fatal: Needed a single revision
```

Evidence: artifact `13324793654`, `phases.tsv` and `latency-regression.log`.
This is a missing comparison source, not an observed latency regression.
It also explains why retained/reachable PR history can make one checkout pass
while another checkout of identical source fails.

**Implemented:** workflows explicitly fetch the exact pinned SHA when absent;
the full migration runner checks availability before expensive work. Neither
the baseline nor thresholds changed. A fresh shallow main clone reproduced the
failure, fetched the exact object, then passed a second offline resolution.
Fetch remains explicit; an unavailable baseline still fails closed.

### 2. PostgreSQL 18 staged-index readiness exceeded 15 seconds

Both main matrix attempts failed the same tests:

- `TestPgStageGuardCompiledWindow`, starting its V2 Worker.
- `TestPgStageGuardPromotionLifecycle`, starting its V2 Worker.

Both report `ordinary schema worker did not become ready`. The helper at
`runtime/go/teslrt/migration_row_additive_native_test.go:70` imposes a 15-second
deadline. Failure cleanup contains a V1 readiness event; that is not evidence
the failing V2 process became ready. Other guarded-index lifecycle/crash cases
passed in these runs.

Evidence: artifacts `13222060618` and `13240073256`,
`test_migration_row_indexes.log`. Initial run and rerun both failed; rerunning
unchanged code is not a sufficient remedy.

**Still open:** profile V2 expansion/catalog inspection and index readiness on
PostgreSQL 18 under the hosted two-CPU configuration. Record current phase and
process exit as part of readiness failure diagnostics. If this is a correctness
test rather than a 15-second startup acceptance test, give it an explicit
scenario budget and separately measure startup performance. This review does
not claim the underlying startup cost has been fixed.

### 3. Nightly PostgreSQL 18 exhausted an aggregate test budget

Artifact `13338287739`, `test_migration_row_access.log`, records a three-minute
Go package timeout during the final nullability crash-recovery subcase. Earlier
tests in the same invocation consumed about 93 seconds; the preceding three
crash subcases then consumed most of the remainder. The lane ultimately hit
GitHub's six-hour maximum; the artifact does not establish why its outer process
failed to finish promptly after the inner timeout.

**Implemented:** run `TestPgRowStagedNullabilityCrashReceiptAtomicity` in its own
invocation. Keep the existing 180-second Go and 210-second outer limits and every
assertion. The selected compiler lifecycle test passed locally against private
PostgreSQL 17 with race instrumentation in 379.4 seconds, including all four
newly separated groups. This is not a full hosted PostgreSQL 18 rerun.

## Four open PRs

Each PR was merged into main with `git merge-tree` and inspected in a temporary
source snapshot. No commits, pushes, merges on main, or GitHub PR changes were
made. Tests below used the integrated compiler explicitly; inherited
`TESL_OCAML_COMPILER` otherwise selects the checkout's old compiler.

| PR | Mechanical integration | Targeted result | Recommendation |
|---|---|---|---|
| [#111](https://github.com/mtonnberg/tesl/pull/111), `9f3257d` | `flake.nix` conflict; shared Go-overlay change with #113 | Validation suite passes; new alias counterexample accepted | Fix recursive type closure before treating the decoding boundary as covered. |
| [#112](https://github.com/mtonnberg/tesl/pull/112), `e956239` | Clean textual merge | Existing client tests pass; new valid nested-type example emits an undefined schema | Fix public wire-type dependencies and add generated-client compilation coverage. |
| [#113](https://github.com/mtonnberg/tesl/pull/113), `70bf171` | `flake.nix` conflict; duplicate Go-overlay change | All 7 Elm helper-cycle tests pass | Good candidate after resolving Nix integration. |
| [#115](https://github.com/mtonnberg/tesl/pull/115), `f8836c8` | Conflict in generated `embedded_docs.ml` | Regenerated docs; compiler builds; membership suite passes, including real private PostgreSQL 17 | Resolve historical red CI and run complete integrated checks. |

### #111: newtype wrapper escapes the new check

The added `unsafe_records` traversal indexes records and ADTs but not
`TypeNewtype`. This valid input still returns `ok: true`, zero diagnostics with
the integrated PR compiler:

```tesl
module ReviewAlias exposing []
import Tesl.Prelude exposing [String]
fact Admin (role: String)
record Claim { role: String ::: Admin role }
type Wrapped = Claim
type Command = Run claim: Wrapped
codec Command { adtJson }
```

The same record directly in the ADT is rejected by the PR's new regression.
Resolve newtype bases with cycle protection and preserve qualified identities;
test direct, wrapped, imported and recursive forms. The reproduced result is a
missed static rejection; this review did not execute a runtime proof-forging
payload. Also align the invariant diagnostic with the implementation: it
currently recommends a cross-check while the new traversal refuses invariant
records even when an explicit decoder exists.

### #112: hiding declarations breaks public wire types

`ReviewLib` exports only `Public`, with `record Private { value: String }` and
`record Public { nested: Private }`. An API importing `Public` type-checks. The
PR's generated TypeScript contains:

```typescript
export const PublicSchema = z.object({ nested: PrivateSchema });
```

There is no `PrivateSchema` definition. Filtering declarations by export/exposing
lists is insufficient: build the transitive wire-type dependency closure of
public endpoints. Include the definitions needed to decode public payloads, or
reject unsupported private dependencies with a source diagnostic. Keep unrelated
private checks/literals out of clients. Also test two import paths exposing
different names from the same module: `seen_files` currently makes first-path
filtering significant.

### Integration order

Use main as base. Bring #111 and #113's **shared Go-overlay fix once**: main already
pins Go 1.26.10, but the versioned `go_1_26` overlay remains a real change for
`buildGoModule`. Resolve the comment conflict without losing migration tools in
`flake.nix`. Apply corrected #111/#112, then #113 and #115. Regenerate embedded
docs from the combined source, rather than selecting one conflicted generated
file. Preserve all authorship when eventually committing.

Require the combined compiler suite, generated Elm/TypeScript builds, Memory and
PostgreSQL membership tests, migration matrix and native gates. Individually
passing targeted tests do not establish combined readiness. Keep larger migration
performance changes in a subsequent PR so their correctness and measurements can
be reviewed independently.

## Performance: where 10×–100× could come from

### Baseline evidence and limits

Existing committed [rollout evidence](migration-rollout-performance.md) records
10,000 rows at about **185.7 rows/s** steady backfill after the last optimization,
58.2 seconds including startup/restart, and **94.7 seconds for Contract**.
That change improved backfill 1.39× in one pair; Contract got slower. The original
p99 budgets still failed, and 100k/1M runs exceeded their observation budget.
These are historical shared-host measurements, not new local measurements.

Five new-process `agent-context` samples on this checkout, warm filesystem:

| Checked source | Median | Range |
|---|---:|---:|
| `example/learn/db-proof-change/app.tesl` | 218.35 ms | 213.23–221.68 ms |
| `example/db-three-upgrades/app.tesl` as checked in, before building its history | 80.23 ms | 77.22–88.13 ms |
| `example/queue-three-upgrades/app.tesl` as checked in | 77.23 ms | 72.31–90.29 ms |

All returned `ok: true`. These are fresh-process diagnostics, not editor latency
or four-release generated-history measurements. Prior retained-session evidence
in [the performance review](migration-performance-review.md) shows unchanged
queries near 0.1 ms but changed-buffer queries around 545–691 ms in longer
histories. Cache-hit numbers do not measure normal editing.

### Priority 1: make a backfill batch a network batch

`migration_row_backfill_worker.go:115` loops over row commit closures.
`migration_row_backfill.go:171` sends an individual guarded UPDATE per row.
`migration_row_transaction.go:141` reads, sets and restores the writer setting
around every row. Thus 2,000 rows require roughly **8,000 sequential statements**,
plus admission, progress and the first processing latch.

At 1 ms round-trip latency, these statements alone imply about eight seconds per
batch; at 5 ms, about forty seconds, already beyond the 30-second batch budget.
This calculation isolates network cost; it is not a measured production latency.

Proposed change:

- Keep typed conversion outside the publishing transaction.
- Materialize a bounded batch, scope the writer setting once to that exact
  entity/batch, and publish through pipelined guarded statements or a typed
  `UPDATE ... FROM` batch with per-row match results.
- Retain primary-key equality, generation, xmin/full-transaction-ID and snapshot
  age checks for every row. A missed compare-and-swap must preserve the old
  writer's edit. Publish processing latch and cursor in the same transaction.
- Bound bytes and statement parameters as well as row count; large JSONB rows
  must not turn a faster path into unbounded memory or PostgreSQL parameter use.

**Target:** 10× measured backfill throughput on the reference workload. A 100×
network-component reduction is plausible with bounded bulk publication; 100×
whole-workload improvement is unproven. Increasing `TESL_BACKFILL_BATCH` alone
does not remove the per-row round trips and can increase age/deadline failures.

### Priority 2: batch catalog reads without weakening verification

`pgReadRowBaselineState` reconstructs control, baseline, expansion, work and
physical-catalog state. Preparation, lease claim, worker admission and index
observation invoke it repeatedly. `pgVerifyRowCatalogSet` reads tables and checks
their triggers/constraints one entity at a time. This fixed cost matters for
empty/small migrations, startup, every batch and Contract.

Fetch catalog rows for the complete requested object set in a few parameterized
queries within the **same required snapshot**, then compare with immutable
compiled expectations. Reuse decoded immutable expectations; do not cache live
role/grant/admission decisions across transactions. Measure SQL count and server
self-time separately. **Target:** 10× fewer catalog round trips, then measure
startup and whole migration speed, including PostgreSQL 14 and 18.

### Priority 3: remove avoidable waits and repeated idle work

- `migration_index_worker.go:491` refreshes with dispatch disabled after an index
  finishes; the next index waits for the poll tick (default five seconds). Dispatch
  another eligible pending job after successful completion, while preserving
  backoff for failed jobs and all lease checks. This is especially relevant to
  multi-index empty-table startup and the observed V2 readiness failures.
- Active row windows repeat preparation/claim after a 50 ms sleep, including when
  another worker owns the shard. Back off idle contention, with bounded wakeups;
  successful work should continue promptly. Zero-window/retired paths already
  stop and should retain that behavior.
- The worker currently uses one full-range shard per entity. Implement disjoint
  key-range parallelism only after reducing per-batch overhead. Extra workers
  contending on the same shard do not provide useful scaling.

### Priority 4: cache immutable history for changed-buffer queries

Profile source discovery, parsing, proof checking and history reconstruction on
20/100/1,000 revisions. Retain checked immutable historical modules by complete
semantic input identity; invalidate unsaved dependencies and same-size edits.
**Target:** changed-buffer diagnostics below 50 ms on the existing half-second
history workload. Full-byte guards and final source-edit preconditions remain
mandatory. Do not present unchanged-query cache speed as this improvement.

### Measurement contract

For each optimization, alternate old/new binaries built from identical fixtures;
retain binary/source hashes and raw samples. Use 10k, 100k and 1M rows, small and
large payloads, 1/10/100 entities, 1/20/100 revisions, and loopback plus controlled
1 ms/5 ms database latency. Measure rows/s, complete rollout/Contract time, SQL
statements per row/batch, allocations, database CPU/WAL, and request p50/p95/p99.

Run old/new writers, restart a Worker, interrupt publication, force a missed CAS
and serialization retry, then validate every final row and receipt. Maintain
lease/floor/UUID/ABI/role checks, cleanup atomicity and exact codec/proof behavior.
A performance target passes only with those correctness checks and explicit
resource limits. Existing small three-row p50/p95 CI comparison is useful but
does not establish these scale or p99 targets.

## Usability priorities

1. **Explain work before readiness.** `--schema worker --json` currently exposes
   readiness but no regular phase/progress stream in the row command path. Emit
   bounded events for expansion, index build, backfill, blockers and retirement,
   with entity, version, completed rows, elapsed time and next action. Distinguish
   “new app may serve” from “backfill finished” and “old app is retired.”
2. **One deployment summary.** Show current/target/minimum admitted versions,
   missing reviewed Contracts, old-instance/claim blockers and exact commands.
   Explicitly say whether rolling deployment is supported for the selected path.
   The guide correctly warns that `deploy` before rolling old pods can wait for
   those pods; put that information in plan/status output too.
3. **Fix misleading failure hints.** #111's invariant hint and missing benchmark
   history demonstrate why “do this next” needs an executable witness. Include
   phase, source version and process exit when startup fails.
4. **Keep business choices visible, automate mechanical work.** Preserve typed
   converters, reverse writes, rejection/discard policy and historical fixtures.
   Improve common rename/default/revalidation scaffolds and navigation rather
   than asking users to assemble every import and copied field.
5. **Make recovery discoverable.** Source-edit journals and uncertain editor
   outcomes have good refusal behavior; the guide notes that automatic
   reconciliation after restart is absent. Surface recovery state immediately,
   preserve buffers, and offer the existing checked recovery action.

## Verification performed

- Main compiler builds.
- 14 latency preparation/statistics tests, 30 CI-shard tests and 44 migration
  requirement-register tests pass; shell syntax and `git diff --check` pass.
- Fresh main clone: missing baseline reproduced; explicit exact-SHA fetch and
  offline repeat pass.
- Selected real PostgreSQL/race Contract/backfill/nullability lifecycle passes
  after splitting the aggregate group. Unselected compiler cases were excluded
  intentionally; this was not a whole-suite run.
- Per-PR integrated snapshots: #111 102 validation cases; #112 17 client cases;
  #113 seven cycle cases; #115 seven membership cases including PostgreSQL 17.
- Additional #111 alias and #112 undefined-client-schema counterexamples above.

Full hosted gates, combined four-PR validation, PostgreSQL 18 startup remediation
and new 10×/100× runtime measurements remain follow-up work. No runtime performance
speedup is claimed from the CI changes in this review.
