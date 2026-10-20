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

The full passing gate still needs the distinct release histories, source checking,
emission, database transitions, race checks and adversarial scenarios. The changes
above do not justify claiming a large reduction in that passing wall time.
Larger improvements need separately verified work—for example, independent CI
shards with isolated PostgreSQL clusters, or compiler profiling that removes
repeated analysis without bypassing source-integrity checks. Latency comparisons
must continue to run without competing test workloads.
