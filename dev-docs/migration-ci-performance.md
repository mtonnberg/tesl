# Migration CI timing and fixture reuse

> Audience: contributors measuring migration CI cost without reducing verification coverage.

## Measured bottleneck

The `cc80282` full run took 14,078 seconds. Phase 5 took 12,345 seconds;
the shared migration runner accounted for 11,340 seconds and passed all 60
phases. Its largest entries were twenty releases (2,396s), the kernel (1,597s),
and compiled index/stage scenarios (749s). The final failure was six lint findings,
after those scenarios had already passed.

Static checks now precede the unit, race, migration and fuzz runs. All previous
checks and budgets remain mandatory. This shortens failure feedback; it does not
make a successful run's database scenarios disappear. Running the newly reachable
NilAway check also exposed missing local nil/shape checks, which were fixed rather
than suppressed.

## Scoped Go compilation-cache reuse

The twenty-release builder now uses `-trimpath` consistently for its generated
Go fixture tests, application binaries and API-test binaries. Fixture execution
uses `-count=1`; test-result caching is not a substitute for running assertions.
`build.json` records emission, fixture-test, application-build and API-build times
separately. Trimming is deliberately not global: repository tests can use
`runtime.Caller` to locate fixtures.

Measurements used identical current compiler inputs, separate initially empty
Go compilation caches for each variant, and fresh output paths. Each variant
retained its cache for its relocated repeat:

| V1–V3 construction | Original | Trimmed |
|---|---:|---:|
| First build | 82.933s | 82.154s |
| Relocated repeat | 37.966s | 14.710s |

The repeated build was 2.58 times faster (61.3% less time); compiler invocations
fell from 30 to zero. Source and emitted Go bytes matched across variants.
No original fixture output reported a cached test result.

The complete trimmed V1–V20 run passed all 95 PostgreSQL API cases with no API
skips, preserving cohort, overlap, rejection/repair, retirement and restart
checks. Construction took 1,807.968s and rollout/cleanup 650.759s, totaling
2,458.727s. This does **not** establish a full-run improvement over the historical
2,396s result: those runs were not a controlled A/B comparison. In particular,
each revision changes `migration_history_generated.go` inside the generated
runtime package, so different revisions still require recompilation.
That file now lives in its own generated package (`internal/teslhistory`), so
a new revision recompiles that package and the packages importing it, not the
runtime.

Evidence: `.tesl-stuff/ci-speed-20261019-162324/`, including `analysis.json`,
`final-audit.json`, per-command traces and `full20/rollout.json`.

## Process-local compiler-variant reuse

The row and queue compiler-upgrade scenarios previously built the same A/B/C
compiler fixtures independently. They now share those executables within one
kernel process. Both scenarios still compile their own applications and execute
their independent PostgreSQL lifecycles with race detection.

Reuse requires matching captured input paths/bytes, tool identities and
configuration, environment, build options and edit recipe. Executable hashes are
checked before reuse; inputs and binaries are checked again after scenarios and
at process exit. Changes or failed builds fail closed. Process-lifetime cleanup
replaces the first test's temporary-directory lifetime.

The measured first construction took 14.840s; the verified second lookup took
0.830s and avoided three duplicate Dune builds. Both existing scenarios passed
with no skips, taking 200.00s and 493.21s respectively. These timings demonstrate
eliminated duplicate build work, **not** a measured full-CI speedup. The existing
protocol traceability report remained byte-for-byte identical; Go's
`TestMain(*testing.M)` bootstrap is distinguished from an ordinary test.

Evidence: `/tmp/opencode/ci-speed-compiler-scenarios-final.log` and
`/tmp/opencode/ci-speed-compiler-checks-rooted.log`.

## What remains expensive

The subsequent full run on `df0479b` passed all 24 CI phases and all 60 migration
phases. Total time was 16,380s; phase 5 took 12,885s. Thus the completed run does
not demonstrate an overall wall-time reduction. Its evidence is retained in
`.tesl-stuff/pr-speed-ci-retry.log` and `.tesl-stuff/pr-speed-migrations/`.

After integrating main and fixing a claim-expiry retry race, `60b0b3a` also passed
all 24 CI phases and 60 migration phases. It took 18,303s overall and 14,125s in
phase 5. Evidence: `.tesl-stuff/pr-main-merge-retry-ci.log` and
`.tesl-stuff/pr-main-merge-retry-migrations/`. This later run likewise provides
verification evidence, not an overall performance improvement.

The full passing gate still needs the distinct release histories, source checking,
emission, database transitions, race checks and adversarial scenarios. The changes
above do not justify claiming a large reduction in that passing wall time.
Larger improvements need separately verified work—for example, independent CI
shards with isolated PostgreSQL clusters, or compiler profiling that removes
repeated analysis without bypassing source-integrity checks. Latency comparisons
must continue to run without competing test workloads.

## Isolated authoritative shards

The hosted gate partitions its existing checks across isolated runners. The default `./ci.sh` remains the complete serial local gate. `compiler-integration` owns the 23 parent phases outside the Go gate, including the Dune suite. The compiler suites that the shared migration runner runs as its own phases are plain executables, not `dune test` entries, so each runs once per gate; `test_suite_registration` refuses a suite that is in both places or in neither. `go-runtime` owns the Go gate's static/build/unit/race/fuzz/CLI checks and bootstraps only the compiler executable. `migration` owns the complete shared migration runner, now 61 mandatory phases with private PostgreSQL. It runs as five parallel lane jobs (see [Migration lanes](#migration-lanes)); each has its own cluster. The gate accepts either one complete migration receipt or one receipt for every lane whose phase lists join, in order, into the complete inventory, and refuses a missing lane, a duplicate lane, or a full run mixed with lanes.

Race-instrumented programs default to sleeping one second before exit (`GORACE=atexit_sleep_ms=1000`). The gates start many short-lived schema commands and generated tests, so `ci.sh` and the migration runner set `atexit_sleep_ms=0` unless `GORACE` is already set; a detected race still fails with exit code 66. On the queue release runner this removed about one second per spawned process (about 90 of 400 seconds).

The added rolling-workload smoke builds ordinary old/new programs and checks concurrent requests, backfill restart, rejection/repair, managed-index work and Contract. Its processes stop before the existing isolated latency comparison. The smoke establishes correctness on that runner, not production p99 or large-table acceptance. The supported PostgreSQL-major workflow retains the complete shared runner.

Each shard records the exact commit, tree, clean tracked source and phase inventory, with hashes of its evidence. The required job retains the name `Authoritative gate (./ci.sh)`, runs after every upstream outcome and accepts only the exact successful union: all 25 parent phases, both Go parts and all 61 migration phases. Missing, duplicated, reordered, skipped or failed work refuses. The serial gate also verifies its exact completed phase sequence. The final job preserves the existing verified-content export.

Use `./ci.sh --list-phases` or `./ci.sh --shard migration --list-phases` to inspect the plan. Explicit shard execution requires clean committed source and emits a source-bound receipt; one shard alone is not a green gate. Fresh complete workflow wall times, including startup and final export, are required before assigning any speedup factor. No assertion, timing budget or supported-major check was removed.

The failed predecessor run spent 4,155 seconds in Dune before reporting an early diagnostic-anchor registry failure. The Dune phase now runs that existing small registry check first, while retaining the full suite, so broken help links fail promptly.

## Migration lanes

`scripts/ci-shards.py` declares the lanes once (`MIGRATION_LANE_STARTS`): each
is a contiguous slice of the declared phase order, named by its first phase. The
CI workflow's migration shard (dev-shell PostgreSQL 17) and every major of the
supported-major workflow (PostgreSQL 14 and 18 per push, 14–18 nightly) run the
same five lanes. `full` remains the one-job local run of all 61 phases.

Durations are the measured phase seconds of the last complete hosted run on
PostgreSQL 17, without prebuilt fixtures. "Setup" is runner start, Nix, cache
restore, Go cache warm-up and (outside `kernel`) the compiler bootstrap; it was
about 17 minutes per job before the caches below and is expected to be 5–10
minutes with warm caches.

| Lane | Phases | Measured phase time | Expected job time |
|---|---|---:|---:|
| `kernel` | `compiler-build`, `kernel` | 1,940s (32 min) | ~40 min |
| `runtime` | `control` … `test_migration_row_access` (26 phases) | 2,865s (48 min) | ~57 min |
| `schema` | `test_migration_delete` … `row-retirement` (23 phases) | 2,963s (49 min) | ~58 min |
| `releases` | `row-releases` … `review11` (6 phases) | 2,473s (41 min) | ~50 min |
| `rollout` | `twenty-releases`, `rolling-workload-smoke`, `latency-statistics`, `latency-regression` | 2,095s (35 min) | ~44 min; matrix: after the fixture job, with prebuilt releases |

Four lanes cannot reach an hour: `kernel` alone is 32 minutes, and `review05` /
`review11` read the row and queue release builds of their own runner, so
`row-releases` … `review11` (41 minutes) cannot be split. The verifier refuses a
declaration that splits such a cohort (`MIGRATION_LANE_COHORTS`).

Lane prerequisites follow from the declaration (`scripts/migration-lanes.py plan`):

- Every lane except `kernel` bootstraps the compiler first. That build is logged
  separately (`compiler-bootstrap.log`) and is not credited as a second
  `compiler-build` phase.
- Only `rollout` runs `latency-regression`, so only it fetches the pinned latency
  baseline. Latency still runs last in its runner, after that runner's
  correctness workloads have stopped.
- In the supported-major workflow only `rollout` waits for the shared fixture
  job and restores its verified bundle (`MIGRATION_PREBUILT_LANES`). The other
  lanes start at once and build their own fixtures, exactly as the CI workflow
  always does. Waiting about 20 minutes for the bundle would make `releases` the
  longest job; reuse saves the most in `twenty-releases`.
- The per-major verification job ("PostgreSQL N protocol and race tests") always
  runs after both lane jobs and requires both job results and exactly one
  receipt per lane whose phases join into the complete inventory.

## Content-addressed caches

The workflows restore four caches. Each is saved only by a push to `main`, by
one job per key (other jobs and pull requests only restore), and none stores a
test outcome:

- **Nix store** (`nix-community/cache-nix-action`, key: `flake.nix`,
  `flake.lock`, `nix/**`; saved by `go-runtime`). Store paths are named by the
  hash of their complete build inputs, so Nix uses a restored path only when it is
  exactly the derivation the flake asks for; anything else is built or fetched as
  before. The saver keeps the dev shell's closure through a profile root and
  collects other paths down to 5 GB. This removes the per-job source builds of the
  Go analysis tools, which the Go overlay keeps out of the public binary cache.
- **Go modules** (`~/go/pkg/mod`, key: `runtime/go/go.sum`) and **Go build cache**
  (`~/.cache/go-build`, key: toolchain + `go.sum`; saved by `go-runtime`). Modules
  are checked against `go.sum`. Build actions are keyed by the hash of every input
  (source, flags, compiler, dependencies). Each job runs `go clean -testcache`
  before its gate, so no restored test result can be replayed; `-count=1` remains
  on every mandatory test command.
- **Migration runner Go seed** (key: toolchain + `go.sum`; saved by
  `migration-kernel`). The runner still uses a private `GOCACHE`; it copies the
  seed in, expires test results and then warms as before. The seed is captured
  right after warming, before any phase runs.
- **Dune cache** (`~/.cache/dune`, key: toolchain + compiler sources; saved and
  trimmed to 1 GB by `compiler-integration`) with
  `DUNE_CACHE=enabled-except-user-rules`. Dune reuses only outputs of its own
  compilation rules, keyed by the digest of all their inputs; user rules, which
  include generators and any rule that runs a program, always execute.

The supported-major workflow cancels a superseded run of the same branch or pull
request. Runs on `main` and scheduled runs are never cancelled.
