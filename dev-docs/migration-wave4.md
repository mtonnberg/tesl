# Migration performance: fourth sweep

> Audience: contributors reviewing compiler reuse, CI setup and migration evidence.

Baseline: `1bcdcbe`, subsequently squash-merged as PR #118 (`a5f79c5`). Those
commits have identical trees. This branch builds on the merged `main` history.

## Candidates and selection

| Candidate | Decision |
|---|---|
| Reuse source-history discovery within compilation | Implemented with live source, directory and import guards on every hit. |
| Reuse parsing of captured inputs | Implemented for immutable ASTs keyed by exact filename and bytes. Filesystem import resolution is not cached. |
| Reuse canonical serialization and hashing | Not pursued: profiling identified repeated discovery/parsing as the larger opportunity. |
| Split stable Go runtime compilation from generated data | Not pursued: prior dependency experiment did not achieve reuse; requires a different initialization boundary. |
| Reduce database catalog round trips per batch | Not pursued in this increment. Compiler improvements do not establish HTTP latency or database execution improvements. |
| Smaller CI environments | Implemented for the shared fixture producer, retaining its actual compilation and converter tests. |

An instrumented V20 emission made 690 history inspections and 68,995 parser
calls. History inspection consumed about 59 CPU seconds; parsing about 19 CPU
seconds, partially overlapping. Instrumentation was removed from shipping code.

## What is reused, and what remains checked

The cache scope now covers frontend validation and emission together. Scoping
only the source-history capture left substantial initial validation work outside
reuse. Nested captures share the scope; return or exception releases it.

Parsing is pure in filename and bytes. The cache stores only successful immutable
ASTs. It never substitutes an AST for changed source or another filename. It has
a 256-entry cap and a 32 MiB serialized key/value weight budget.

History discovery keys include canonical project root, family, inclusion mode,
ABI/compatibility labels, and actual lifted-stdlib paths/bytes. Each hit still:

- checks canonical regular source files and their content hashes;
- scans revision and Contract directories;
- resolves each captured import again;
- rechecks actual stdlib inputs.

A stale entry causes ordinary discovery to run again. Valid edits can therefore
produce a fresh history; malformed or ill-typed inputs still fail through the
original checker. Errors are not cached. The history cache has a 16-entry cap and
32 MiB serialized weight budget. These weights are not exact heap-size limits.

Discovery still does not claim to type-check migration bodies. Existing
declaration, proof-context, source-seal, whole-application and publication checks
remain in their original paths. No database observations or permissions enter
these compiler caches.

## Measurements

From `compiler/`, with `TESL_REPO_ROOT` pointing at the checkout:

```sh
dune exec test/bench_migration_compilation_cache.exe -- /path/to/v20/source Schema.Tracker 100
```

This alternates uncached/cached/cached/uncached, compares exact results, and keeps
wave three's inventory cache enabled on both sides of the history comparison.

| Component | Before seconds | After seconds | Scope |
|---|---|---|---|
| Repeated application parsing | 0.961, 1.014 | 0.0061, 0.0057 | 1,000 identical parses, including initial miss; over 100× component improvement. |
| History discovery | 3.616, 3.285 | 0.856, 0.883 | 100 discoveries including live guards; approximately 4×. |

Independent baseline/candidate compiler binaries emitted identical frozen V20
source in alternating order:

| Pair | Before seconds | After seconds | Ratio |
|---|---:|---:|---:|
| First | 113.88 | 42.79 | 2.66× |
| Second | 107.87 | 61.18 | 1.76× |

These local whole-emission measurements do not demonstrate a 10× whole-job or
database execution improvement. All emitted files matched after substituting the
compiler build ABI and verifying the resulting ABI-bound transform contracts and
their SHA-256 hashes. Arbitrary hash differences were not masked.

Raw evidence is local under `/tmp/nix-shell.E25jrS/opencode/`:
`wave4-emission-results.json` and `wave4-emission-{before,after}-{1,2}/`.

## Fixture CI setup

The producer now uses `nix develop .#migration-fixtures`. It includes the pinned
Go/C toolchain, OCaml/Dune/Alcotest, Python, Git and download prerequisites. It
does not build unrelated editor, database, static-analysis or DAST tools. Those
tools and their checks remain in the jobs which use them.

The recorded Go environment, Go version, OCaml version and Dune version matched
the full development shell. A full producer invocation succeeded with inherited
environment removed; its bundle passed manifest verification and restoration.
The restored executables then ran actual PostgreSQL lifecycle tests. Cold hosted
setup timings are still required; no whole-CI speedup factor is claimed.

## Correctness and performance acceptance

- Parser regressions cover changed filenames/bytes, malformed input, nested
  scopes, eviction and exception cleanup.
- Warm history-cache regressions cover private helper type errors, added/removed
  Contracts, malformed revisions, import shadowing, canonical-file replacement,
  changed project aliases, stdlib changes, eviction and scope cleanup.
- Existing inventory, ABI, frozen closure, application, transform-link, compiled
  history, Contract and queue-conversion suites passed.
- Full V1–V20 PostgreSQL lifecycle passed with 1,000 extra HTTP-created tasks,
  retaining API tests, old/new overlap, retained cohorts, finality and restart.
- All restored native index/preparation/guard/cancellation groups passed under
  race instrumentation on PostgreSQL 18.

The supplied PR #118 logs showed its V1–V20 and rolling correctness checks passed,
then the latency comparison failed. Its aggregate job failed because that shard
failed. The hosted metric-level result was not available locally. Compiler reuse
does not establish a fix for that hosted HTTP result.

Wave four's unchanged pinned-baseline latency gate passed locally:

| Metric | 99% upper paired delta (ms) | Allowed limit (ms) |
|---|---:|---:|
| Read p50 | 0.207867 | 0.500000 |
| Read p95 | 0.326096 | 2.000000 |
| Write p50 | 0.215215 | 0.940669 |
| Write p95 | 0.279715 | 2.000000 |

Candidate requests remained slower than that older pinned baseline; this is a
local acceptance result, not a request-speedup claim or hosted qualification.
The script now prints each metric, baseline/candidate values, paired delta,
confidence bound and limit before its existing decision. Baseline, sample counts,
calibration policy, thresholds and failure conditions are unchanged.

Successful local evidence: `wave4-twenty-final/`,
`wave4-lifecycle-completion.json`, `wave4-fixture-restore.json`, and
`wave4-latency-complete/result.json` under the temporary directory above.
Earlier lifecycle attempts were interrupted by an outer tool timeout and user
cancellation; an earlier latency attempt was interrupted by signal 15. Their
partial evidence remains in `wave4-twenty-evidence*` and `wave4-latency/` and is
not counted as passing. Full hosted CI remains required.
