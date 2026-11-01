# Migration performance review

> Audience: contributors reviewing PR #102 and migration performance changes.

The migration engine's functional evidence is substantially stronger than its
performance acceptance evidence. The complete PR gate on `846a7fb` passed, but
took almost six hours. The current HTTP regression test does not establish the
absolute overhead or large-table acceptance targets. This pass measures a
specific request-path contention problem and retains the checks that authorize
each database operation.

## Measured request contention

`pgRowObserveGeneration` previously acquired one exclusive observation-cache
mutex before reading live admission and the database's current version. Every
reader of the same admitted database object therefore competed for that mutex,
even when no future generation existed. Contenders slept in five-millisecond
steps. A refresh needed for an old binary could consequently delay unrelated
current-version requests.

The change first attempts the same lock. When that lock is occupied, it checks
live admission, reads the revision in the application's own transaction, and
checks the database UUID. It returns no observation only when the installed
revision is at or below that binary's revision. A future revision still requires
the lock and repeats the original live checks after acquiring it. Cached
observations are never read without their lock. Final request admission,
representation locks, compiler ABI checks and Contract checks remain unchanged.

### Experiment and limits

Both ordinary Go binaries came from the same generated V4 application in
`example/db-three-upgrades`, including the same four-release source history.
The sole code difference was `migration_row_transaction.go`. The before variant
uses that file from `846a7fbb9454ede1e993861624e9c3b5cb1e87f1`; it is **not** the
pre-migration PR base. Both were built with `go build -trimpath`, without race
instrumentation. A private PostgreSQL 17.11 cluster and Go 1.26.10 used identical
configuration, including `track_functions=all`, for both variants. The schema was deployed to
V4 before sampling. Deployment cost was measured separately, not hidden inside
the request results.

Three pairs alternate process order: before/after, after/before, before/after.
Each process is started and checked for readiness independently. Each read phase
has 1, 8 or 32 concurrent persistent HTTP clients; each write phase has one client.
Every client performs 20 warm-up requests followed by 80 measured requests.
There are 240, 1,920 and 7,680 measured reads per binary at the respective client
counts, and 240 writes per binary. This is 20,160 measured requests in total.
The reported values are medians of the three run nearest-rank quantiles
(`ceiling(sample count * fraction)`), not pooled quantiles or confidence bounds.
At one client, p99 is especially noisy because each run has only 80 observations.

A first controlled pilot checked successful HTTP responses, the exact three
row IDs and write acknowledgements. The table below is a second controlled
replay through the committed reusable harness. It additionally checked every
row's full metadata, owner and title before/through the reads and after writes,
and verified that measured executable bytes did not change. All checks passed.
Deployment took 14.416 seconds separately from request sampling.
Other heavy builds and tests were paused during the measurement window.
This is a local-host experiment, with Python's HTTP client, three rows, ordinary
loopback TCP, PostgreSQL function profiling and no expensive custom converter.
It is not a production SLA, a pinned-host acceptance result, a rolling-update
load test, or evidence about ten-million-row tables.

| Operation | Clients | Before p50 | After p50 | Before p95 | After p95 | Before p99 | After p99 |
|---|---:|---:|---:|---:|---:|---:|---:|
| Read three rows | 1 | 2.354 ms | 2.325 ms | 3.013 ms | 2.994 ms | 3.470 ms | 3.615 ms |
| Read three rows | 8 | 4.922 ms | 5.247 ms | 28.995 ms | 7.890 ms | 49.408 ms | 10.119 ms |
| Read three rows | 32 | 37.976 ms | 21.031 ms | 75.737 ms | 31.055 ms | 112.081 ms | 34.971 ms |
| Update one row | 1 | 3.477 ms | 2.943 ms | 4.801 ms | 3.628 ms | 6.472 ms | 11.291 ms |

At eight and 32 clients, median run p99 decreased by 80% and 69% respectively.
The 32-client measured phase, including its warm-up, went from 4.428 seconds to
2.387 seconds. Single-client improvements are not established: read p99 increased
slightly and write p99 increased from 6.472 to 11.291 ms in this small replay.
The first pilot also measured a roughly 9% increase in single-client read median,
whereas this replay's median was slightly lower. Keep that variability visible;
this pass makes no blanket claim of lower latency or absence of a single-client
regression. Larger paired samples and the mandatory latency gate remain required
after integration.

### Reproduction

Build the V1–V4 fixtures once with the current compiler, then build two ordinary
V4 binaries from the same generated tree. For the before binary, use a Go overlay
which replaces only `internal/teslrt/migration_row_transaction.go` with its bytes
from `846a7fb`. The after binary uses the changed file. Keep every other generated
source and build option identical. `--build-only` executes the fixture's normal
checks; it does not skip their assertions.

```sh
work="$(mktemp -d)"
dune build --root compiler bin/main.exe
python3 example/db-three-upgrades/run.py --build-only --output "$work/fixtures"
git show 846a7fbb9454ede1e993861624e9c3b5cb1e87f1:runtime/go/teslrt/migration_row_transaction.go > "$work/runtime-before.go"
python3 - "$work" <<'PYTHON'
import json
from pathlib import Path
import sys
work = Path(sys.argv[1])
runtime = work / 'fixtures/v4/go/internal/teslrt/migration_row_transaction.go'
(work / 'before.json').write_text(json.dumps({
    'Replace': {str(runtime): str(work / 'runtime-before.go')}
}))
PYTHON
(
  cd "$work/fixtures/v4/go"
  go build -trimpath -overlay "$work/before.json" -o "$work/before" ./cmd/app
  go build -trimpath -o "$work/after" ./cmd/app
)
python3 scripts/measure-row-observation-contention.py \
  --before "$work/before" --after "$work/after" --output "$work/request-evidence"
```

The harness accepts explicit executable/output paths and retains raw observations,
binary hashes, PostgreSQL logs, function statistics and a failure result if an
operation or correctness check fails. It owns and stops its private database;
it never points at an application database. It deliberately does not run as a
timing assertion inside a concurrently executing unit-test package.

Final replay artifacts are retained at
`/workspace/.tesl-review-102/runtime-http-portable/results.json` (original raw
observations and summaries) and `results-nearest-rank.json` (the same raw data
re-summarized with the committed nearest-rank convention). No requests or outliers
were dropped during that re-summarization. The first pilot remains at
`/workspace/.tesl-review-102/runtime-http/results.json`; complete source inventories
are in `/workspace/.tesl-review-102/measurement-inputs.json`. The captured fixture
source tree SHA-256 is
`a03afd0037aab31d8bc968b8c9a69edbce743cae22660c88a2de77dfad62f89a`.
The before and after runtime file hashes are
`5eb2fc0027eeb5505d447dda28cc6afa08c501cb0e264f2b00179dfdffdec400`
and `e92587eb8f0404b4b4bcc1f05ae2879a338baf09e04ca7966a7fcbfeb2233695`.
The original binary hashes are
`f6f7ceeb1a53d75e61d716680a956e04383a23c4b4597345feac871d0b9f7d58`
and `7f421e09cbd3b8c4b563f5981ab41b46b9ee84f7a37d0e0d8f36e3bc5de898f1`.
The after runtime bytes match the tracked implementation exactly.

### Correctness verification

The real PostgreSQL regression holds the observation mutex until the call
returns. The original implementation deterministically times out for a
current-version request. The corrected implementation proceeds, while refusing
a changed database UUID or an unadmitted binary and continuing to wait for an
unverified future revision. Existing canceled-waiter, owner-binding and overall
budget tests remain unchanged.

These tests pass with race instrumentation on private PostgreSQL 17 and, in an
independent run, PostgreSQL 18.4. A second reviewer checked the exact fast path's
transaction and lock ordering. These focused checks do not replace the complete
authoritative and supported-major CI rerun on the integrated change.

## What the existing latency gate proves

`scripts/compare-migration-latency.py` pins `9852f26`, a migration-enabled WIP
commit within this PR's history. It compares steady-state format5 V1 HTTP reads
and updates using three rows and one client. It has useful A/A calibration,
alternating paired runs, retained raw observations, correctness checks and a
deterministic upper confidence rule. It rejects missing/invalid evidence and a
deliberate slowdown in its policy tests.

Its limits are material: it reports p50/p95, allows a regression of 50% or the
absolute floor (0.5 ms p50 / 2 ms p95), and does not compare with the PR base's
ordinary non-migration database path. It establishes neither additional
migration overhead nor p99 under contention, rolling writes or table-scale
acceptance. The large 10M/100M workload remains explicitly deferred by the PR
contract. Passing this small regression gate must not be described as meeting
those original targets.

## Developer feedback and CI cost

Preliminary warm-filesystem, new-process samples on the original compiler
measured roughly 234–269 ms for proof-change application diagnostics and
846–915 ms for four-release row/queue applications. Migration source preview
took about 343 ms for the proof example, 1.13 s for four row releases, and 1.61 s
for four queue releases. Those 11-sample medians were collected while other
review work was active, so they locate the order of cost, not a controlled
before/after improvement. Source/history checking should be profiled separately
from process startup and editor UI work.

The existing two-file retained-query benchmark measured approximately
0.20–0.22 ms per repeated query versus 84–87 ms for fresh processes. This confirms
that the retained infrastructure can avoid work on identical inputs; it does not
show the same benefit after editing a proof or in a long migration history.
Complete source-byte and dependency invalidation must stay intact when improving
those paths.

A final quiet probe used the integrated compiler, SHA-256
`1bebd4542806d9f3666f68c0224f6c831b585f81b46a8ce3c8a9acd7bdc9cc78`,
through its framed retained-session protocol. It copied each complete project,
hashed every input again after each edit, and checked that every response had
zero diagnostic-error exit status. The first query has one observation,
unchanged queries have eight, and valid comment-only application edits have
four. All other heavy builds/tests were paused. These numbers exclude Go's
project-snapshot staging, LSP scheduling and UI work; they are not an end-to-end
editor latency measurement or an original-versus-current compiler comparison.

| Project | First retained query | Unchanged median | Comment-edit median |
|---|---:|---:|---:|
| Proof-change example | 117.922 ms | 0.100 ms | 94.179 ms |
| Four-release row application | 859.079 ms | 0.110 ms | 690.820 ms |
| Four-release queue application | 595.021 ms | 0.132 ms | 545.501 ms |

The exact-input query cache works, but even a harmless application comment
invalidates the whole answer and still costs roughly half to three-quarters of
a second in these small histories. That is a concrete developer-feedback
bottleneck. Repeated immutable history analysis needs a component profile and
complete-input reuse; an unchanged-query microbenchmark alone hides it.
The reproducer and raw results are
`/workspace/.tesl-review-102/measure-retained-migrations.py` and
`retained-migration-measurements.json`. An initial attempt used an invalid
comment delimiter, correctly failed parsing, and is retained separately under
`invalid-comment-*`; none of those invalid edit timings appear in this table.

The prior full CI run took nearly six hours; PostgreSQL 14 and 18 matrix lanes
took approximately four hours and four hours 22 minutes. Increasing a timeout
is not a performance optimization. The existing
[CI timing report](migration-ci-performance.md) records repeated generated Go
builds, release histories and independent database scenarios as major costs,
and explicitly reports no demonstrated end-to-end CI speedup from earlier cache
changes. This request-path optimization makes no CI wall-time claim.

## Next performance work, in order

1. Repeat request measurements on pinned hardware with enough samples for p99,
   real deployment concurrency, longer histories, realistic row sizes, cold
   observation refreshes, remote database latency and expensive converters.
   Include old/new writer overlap, Contract, cancellation and correctness oracles.
2. Add an absolute PR-base control using the same application/SQL/transport and
   report additional read/write overhead, not just the current internal V1
   comparison. Keep calibration and failure thresholds explicit.
3. Profile repeated admission work inside a request. In the first local combined
   experiment, PostgreSQL recorded about five `tesl_admit` calls per measured
   request plus warm-up/setup. Physical-header parsing and queue-inventory
   validation were significant function self-time. That suggests a target for
   transaction-bound reuse of pure checked data, not a global admission cache.
   Do not remove fresh version, retirement, UUID or final-read checks to save time.
4. Profile changed-buffer compiler queries on increasing history sizes. Separate
   source discovery/read/hash, parse, proof/type checks, declaration/history
   reconstruction and JSON/UI costs. Cache only with complete semantic inputs;
   same-size/coarse-timestamp edits and unsaved dependencies must invalidate.
5. Split independent CI scenarios into balanced jobs with isolated PostgreSQL
   clusters and preserved phase inventories. Reuse verified compiler/build
   artifacts; keep every assertion, supported-major witness and race test. Run
   latency comparisons on a separate quiet job so sharding does not invalidate
   their measurements. Measure the whole passing run before claiming a speedup.
