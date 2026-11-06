# Migration build reuse and catalog inspection

> Audience: contributors measuring migration execution and hosted CI build costs.

Branch baseline: `424d6af` (including the embedded-documentation CI repair).

This records the first reuse increment. [Wave two](migration-wave2.md) extends it
with overlapping core/lifecycle lanes and shared native index fixtures.

## Hosted experiment

The migration protocol workflow builds these fixtures once per revision:

- Four ordinary row releases.
- Queue conversion, repair and catch-up releases, including the instrumented V4.
- Twenty project-tracker releases, pure fixtures, application binaries and API-test executables.

Every PostgreSQL matrix lane downloads the same bundle, verifies its exact source
and toolchain identity, hashes and executable modes, and copies it into that
lane's private temporary workspace. It then runs the existing lifecycle,
adversarial, restart, cleanup and PostgreSQL API tests. Missing or changed inputs
refuse rather than falling back to an unchecked bundle. A failed producer makes
the database jobs fail, not silently skip their required checks.

The build receipt includes the full tracked source digest, revision/tree,
compiler hash, Go/OCaml/Dune identities and Go compilation settings. Each consumer
records the manifest hash and verification/copy time. The tar archive preserves
executable modes across GitHub artifact upload/download.

This first build-sharing step is confined to the supported-major workflow.
The authoritative `CI` migration shard still independently builds and executes
the complete gate. Compiler-native fixtures outside the three release drivers
also retain their existing builds. No cross-workflow artifact lookup or old
revision fallback is used.

### What to compare in GitHub Actions

The default PR run enables reuse. A manual run on the **same branch revision**
with `reuse_fixtures=false` rebuilds the fixtures independently in each lane.
Both manual settings run the same PostgreSQL majors and scenario flags; compare
manual against manual, rather than a nightly run with its larger trace workload.

Retained evidence:

- `migration-fixture-build-SHA`: producer manifest, individual build logs and
  three immutable-specification benchmark samples from the hosted runner.
- `migration-pgMAJOR-SHA`: the unchanged phase receipt/log inventory plus
  `prebuilt-fixtures.json` when reuse was enabled.
- Job summaries: per-phase elapsed times and producer/restore costs.

Report workflow elapsed time **including the producer**, matrix runner-minutes,
artifact transfer/verification cost, fixture-build time and lifecycle execution
time separately. Reuse should reduce duplicate build CPU, but the producer is
an upstream dependency, so it does not by itself promise a shorter critical
path. PostgreSQL lanes retain every database-version witness. Test execution is
never replaced with cached success.

## Generated runtime compilation cache

The row and queue release builders now use `-trimpath` consistently, as the
twenty-release builder already did. Pure fixture tests explicitly use `-count=1`.
This permits compilation-cache reuse for identical generated packages moved to
another directory. It does not share tests' execution results, nor make runtime
packages with different generated history bytes identical.

The shared producer owns a disposable Go build cache. It warms normal/race
dependencies once and uses the existing ownership-checked pruning policy between
families so unrelated generated application archives do not accumulate. Developer
caches are neither pruned nor repurposed.

## Catalog improvements

### One function-catalog query per inspection

`pgControlFunctionCatalogs` reads the requested protected function inventory in
one parameterized query in the caller's transaction snapshot. It compares the
same owner, language, argument/result signatures, body, volatility, configuration,
security attributes and exact execution grants. Request-only functions still
check inherited Worker privileges. Missing first/middle/last functions and
changes after a previously successful check are regression-tested. The outer
closed-inventory count still rejects extra control-owned functions.

There is no cross-transaction cache of database metadata or permissions. Table
catalog reads and all live version/retirement/lease/ABI checks remain live.

### Reuse immutable expected SQL, not admission decisions

The format-5 expected-function builder repeatedly reconstructed more than a
megabyte of strings per call. A bounded 16-namespace cache now retains those
deterministic specifications and returns a private slice to each caller. Go
strings are immutable; mutation of a returned struct cannot alter shared data.
Eviction and concurrent caller mutation have race-instrumented tests.

Three local Go benchmark samples measured reconstruction at 1.02–1.14 ms and
1,273,793–1,273,798 bytes/operation, versus 2.29–3.14 microseconds and 8,192 bytes
for a cached copy (529 allocations versus one). This is a component result,
not a migration-throughput or CI wall-time claim.

A local PostgreSQL 17 comparison of five inspections of eleven functions,
alternating individual queries and one batch, measured 134.7/25.3/23.1/132.6 ms.
Both variants used the same new comparison implementation; this isolates the
query grouping, not a whole historical-binary comparison. Hosted phase times and
the complete supported-major results determine the practical benefit.

The expensive PostgreSQL-side physical-header and queue-inventory parsers remain
a further target. This change preserves their definitions and checks rather than
introducing a new stored metadata format or caching their permission results.

The typed-row read wrapper also no longer repeats the initial admission query
immediately after the outer format-5 transaction wrapper has already performed
it. No SQL or application callback intervenes. The compatibility fence, ABI
checks and final live read-admission check remain. PostgreSQL 18 regressions
exercise post-query refusal, explicit-transaction admission at commit, writer
ordering, compiled old/new readers and first-write ABI races.

## Local verification and hosted failures folded into this branch

The shared producer completed the row, queue and twenty-release builds. Local
times were 98.63 s, 208.41 s and 2704.07 s, plus 103.76 s of private cache warm-up
and a warm compiler build. Full verification and relocated copying took 8.81 s.
The copied row/queue binaries passed their complete rollout/catch-up scenarios.
The copied V1–V20 binaries passed all required PostgreSQL API cases, cohort,
overlap, finality and restart assertions. An initial invocation was interrupted
by the tool's shorter outer timeout after V17; the subsequent complete run used
the existing CI-scale observation budget, without changing scenario deadlines.
These are local measurements, not a claim about hosted critical-path reduction.

Protected-catalog/refusal and facility suites pass with race instrumentation on
PostgreSQL 17 and 18. Artifact tests reject changed source/toolchain identities,
changed binaries, missing releases, lost executable modes, symlinks and
mid-verification source edits. Workflow syntax, phase inventories and the Python
packaging regression suite pass.

The reported `424d6af` failures are also addressed here:

- Documentation: add the review audience banner and index links, and remove the
  hand-written corpus counts rejected by the documentation gate.
- Go snapshots: regenerate the changed runtime artifact/ABI identities; review
  those changes rather than skipping byte-exact checks.
- macOS Intel: retry transient source read timeouts and retryable HTTP failures
  within a fixed total download budget. Partial files are discarded before a
  retry; pinned source-hash verification remains mandatory.
- Windows: retry only the observed transient access-denied/sharing-violation
  errors when publishing the completed SDK directory. Existing output is never
  replaced, and persistent failures still stop the build.
- Native assembly now retains logs even on failure and reports captured child
  output. The Windows retry behavior is regression-tested through simulated
  Windows errors locally; real native-host confirmation comes from the PR jobs.

The PostgreSQL 18 matrix failure in run `42040296693` occurred only after all
correctness phases passed. Its final A/A benchmark qualification rejected write-
p95 noise of 1.303 ms against a 1.000 ms budget. The new pre-comparison
qualification policy and retained-trial audit are documented in
[the latency gate](../scripts/MIGRATION-LATENCY.md). Actual A/B failures are never
retried, and no performance threshold or pinned baseline was relaxed.

**Latency remains a merge check, not a claimed local pass.** A local qualified
comparison against the required historical baseline still rejected read-p50.
The explicit diagnostic comparison against current main had nearly equal read
and write medians, but its write-p95 confidence bound also exceeded the limit.
Both failed results are retained in `/tmp/nix-shell.E25jrS/opencode/latency-catalog-admission`
and `latency-versus-main`; they are not presented as successful regressions.
The hosted PR runs must determine whether the fixed runner budget is met. The
historical baseline predates later stage-admission work; changing that baseline
or those acceptance budgets would be a separate reviewed policy decision.
