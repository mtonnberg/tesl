# Cumulative runtime performance: PostgreSQL first

> Audience: contributors reviewing cumulative performance changes and insertion semantics.

Branch: `perf/runtime-migration-wave7`. This is a cumulative branch containing
waves five and six, their CI fixes, and wave seven. Its PR targets `main`; PRs
#120 and #121 do not need separate merges once this cumulative change is merged.

## Primary result: real PostgreSQL HTTP updates

End-user PostgreSQL performance is the primary objective. The cumulative branch
includes wave five's settled bulk-update optimization; wave six's bounded Memory
queries and wave seven's keyed Memory insertion are supplemental improvements.
Neither Memory optimization accelerates PostgreSQL queries or inserts.

Remeasured against `main` at `53e5602` with PostgreSQL 17.10, identical V2 source,
and ordinary HTTP requests after Retype/Contract. Before/after/after/before runs
each used two warmups and eight measured samples per size. Fixture loading and
validation were outside timing; all identities, changed values and untouched
fields were checked after every request.

| Updated rows | Main medians, two runs (ms) | Candidate medians, two runs (ms) | SQL calls, usual count |
|---|---|---|---|
| 1 | 6.764 / 6.617 | 6.485 / 6.994 | 19 → 19 |
| 100 | 53.120 / 54.543 | 9.981 / 10.980 | 514 → 24 |
| 1,000 | 484.858 / 496.568 | 37.049 / 40.641 | 5,014 → 59 |

The 1,000-row HTTP update improved approximately **12–13×**; the 100-row update
improved approximately **5×**. SQL counts come from `pg_stat_statements` filtered
to the request role; occasional observations included one extra call. Read times
and singleton writes showed no comparable improvement. These local measurements
do not establish a production p99 budget or an active-migration speedup.

The optimization retains one locked cursor snapshot, checked row codecs,
first-row publication and same-transaction ABI processing. Bounded SQL updates
apply only to eligible settled plans; active migrations, secondary UNIQUE
indexes, unsupported key carriers and debug capture retain the original path.
See [wave five](migration-wave5.md) for eligibility and failure tests.

Reproduce with `scripts/measure-settled-update.py`, using the same source from
`example/db-three-upgrades/run.py --build-only` and alternating `--repo-root`
between baseline and candidate. Raw samples, SQL profiles, tool versions and
source/binary hashes: `/tmp/nix-shell.3bBrzt/opencode/pg-{b1,a1,a2,b2}/result.json`.
All four runs reported `correctness-passed`.

PostgreSQL `insertMany` still executes each row separately. A later duplicate
retains the committed prefix outside an explicit transaction and rolls back
inside one. No PostgreSQL insertion gain is claimed.

## Supplemental bottleneck: Memory insertion

Memory `insertMany` checked every existing row and every earlier batch row for
each primary/unique constraint. That is quadratic work for growing batches.
Inside transactions, every publication also rediscovered its goroutine-local
transaction through `runtime.Stack`.

The optimized path builds lookup maps once per batch and resolves transaction
ownership once while holding the Memory gate. This is enabled only for compiler-
generated pure, total key projections consistent with existing equality. It uses
canonical arbitrary-precision Int keys, String/Bool keys and non-secret nominal
wrappers. Composite unique keys are structured tuples, not diagnostic strings.
Nullable unique constraints retain their existing NULL exemption. Secrets and
unsupported key types keep the legacy path.

## Semantics and resource boundaries

- Unique constraints are checked in declaration order, before the primary key.
  Existing error messages are preserved.
- Each successful row is published in order and increments the table version.
  A later duplicate keeps the successful prefix outside a transaction.
- A transaction rollback restores its original rows; a caught failure inside a
  transaction retains the same behavior as the original path.
- Lookup maps are local to the operation. Updates, deletion, truncation and
  rollback cannot leave a persistent index stale.
- Maps reserve capacity for existing rows, not an entire potentially rejected
  incoming batch. The first row uses legacy checks before any maps are built;
  refusal does not index the existing table or allocate for an unused suffix.
  Nullable unique maps allocate only when a constrained key appears.
- Batches through 32 rows keep original comparisons without key projection or
  map allocation. This cutoff follows measured scan/hash crossover; it does not
  promise every small request is faster.
- Published snapshots stay immutable. Gate and mutex ordering are unchanged.
  Transaction lookup is hoisted only while the gate fixes ownership.
- PostgreSQL retains its sequential per-row SQL, argument evaluation and checked
  row-access path. No database admission, permission or proof check is cached.

Legacy APIs and arbitrary callback evaluation remain unchanged. The new keyed
APIs carry both the original conflict callback and compiler-owned key metadata.
No user-facing Tesl registration or proof-authority API was added.

## Memory component measurements

```sh
cd runtime/go
GOMAXPROCS=1 go test ./teslrt -run '^$' -bench '^BenchmarkMemoryInsertMany' \
  -benchmem -benchtime=200ms -count=3
```

Medians of local samples, including map construction and publication, excluding
fixture generation and compilation:

| Rows | Transaction | Legacy (ms) | Keyed (ms) | Ratio |
|---|---|---:|---:|---:|
| 1,000 | No | 6.814 | 0.439 | 15.5× |
| 1,000 | Yes | 14.159 | 0.449 | 31.6× |
| 8,000 | No | 455.972 | 5.368 | 84.9× |
| 8,000 | Yes | 467.285 | 5.087 | 91.9× |

The singleton safeguard retained allocation counts against large existing tables.
Small-batch timings varied; no universal improvement is claimed there. A refused
first row used the same measured allocation for 64 and 100,000 incoming rows.
Prototype-only results were larger and are not used as production claims.

These measurements include the final first-row refusal guard and lazy nullable
maps. A first-row refusal against 16,384 existing rows used 131 bytes and three
allocations; an all-NULL unique index matched the no-index allocation count.

## Supplemental Memory HTTP workload

```sh
python3 scripts/measure-memory-insert.py --output /tmp/insert-after
# Use --repo-root /path/to/baseline-checkout for the baseline compiler/runtime.
```

The script compiles `bench/InsertManyMemory.tesl`, then measures ordinary and
transactional HTTP batch insertion. The fixture constructs rows inside the
request, so dataset creation and map setup are included. It has a nominal Int
primary key and a composite String/Int unique constraint. Reset and independent
validation are outside timing. Every field and insertion order is checked, and
duplicate-prefix retention, rollback and reinsertion are exercised through HTTP.
This is server-generated data, not an uploaded JSON-body decoding benchmark.

Before/after/after/before runs used two warmups and eight measured samples per
operation/size. These runs preceded the final first-row refusal/all-NULL resource
guard; they are evidence for the initial keyed implementation, not a remeasurement
of that final refinement. Median request times:

| Rows | Operation | Before first/second (ms) | After first/second (ms) |
|---|---|---|---|
| 1 | Ordinary | 0.107 / 0.101 | 0.097 / 0.091 |
| 1 | Transaction | 0.169 / 0.158 | 0.152 / 0.152 |
| 1,000 | Ordinary | 7.661 / 8.495 | 0.515 / 0.494 |
| 1,000 | Transaction | 20.458 / 23.010 | 0.613 / 0.589 |
| 8,000 | Ordinary | 513.722 / 530.682 | 4.341 / 3.728 |
| 8,000 | Transaction | 567.287 / 591.317 | 4.112 / 4.224 |

Large requests improved approximately **118–142×** in this local workload.
The smaller batch improved approximately **15–39×**. These samples do not
establish production p99 budgets, a universal request gain, or faster PostgreSQL
insertions. Raw samples and source/compiler/binary hashes are retained under
`/tmp/nix-shell.3bBrzt/opencode/w7-http-{b1,a1,a2,b2}/result.json`; all runs reported
`correctness-passed`.

## Verification and cumulative scope

Added regressions compare exact failures, row prefixes and version increments
against the original algorithm. They cover existing/batch duplicates, multiple
simultaneous violations, nullable composite keys, large nominal Int values,
secret/unsupported fallback, small-batch projection avoidance, rollback and
reinsertion, caught failures, concurrent batches, and transaction isolation
against readers/writers. Live PostgreSQL tests preserve sequential binder calls,
partial publication and transaction rollback. The full typed migration-query
lifecycle suite also passed.

Runtime file-set/embedded-source checks, generated-code race tests, static Go
gates and native/offline CLI tests passed. Cumulative playground parity passed
with the existing named single-buffer exception. One concurrent local CLI run
hit a compiler relink race while playground build replaced the executable;
serial verification after build completion passed, with no assertion changes.

The unchanged pinned-baseline latency gate passed locally. Its read p50/p95 upper
paired deltas were 0.476/0.613 ms; write p50/p95 were 0.332/0.690 ms. No latency
threshold or sampling policy changed. Evidence: `wave7-latency/result.json` under
the temporary directory above.

This does not resolve the previous hosted PostgreSQL 14 write-p95 verdict by
itself: that run reported a 5.332 ms upper bound against a 2 ms limit. Raw hosted
samples were not available for attribution. Hosted revalidation remains required.

The cumulative PR also includes verified Elm codeload downloads, signature-
verified opam asset-API bootstrap, bounded setup retries, and the runtime feature-
gate fix. It preserves the earlier wave-specific evidence documents. No existing
test workload or acceptance condition was removed to obtain these gains.
