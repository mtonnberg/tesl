# Runtime performance: bounded Memory selection

> Audience: contributors reviewing query algorithms, compiler dispatch and regression coverage.

Baseline: `8961503`, including the PR #120 runtime-packaging fix. Branch:
`perf/runtime-migration-wave6`.

## Selected bottleneck

The Memory backend previously allocated a full-table-sized result buffer even
for an unordered range of a few rows. Ordered `limit` and ordered `selectOne`
filtered and copied all matching rows, then stable-sorted the entire result.
Profiling a bounded query over a large table identified a substantial scaling
opportunity without changing types, proofs, SQL admission or database protocols.

This increment targets Memory-backed runtime and HTTP queries. It makes no
measured claim about migration execution time or whole-CI build time.

## Semantics preserved

Unordered `TableSelectRange` still evaluates every predicate once, in insertion
order on the original immutable snapshot. It only retains the requested range.
It does not stop evaluation at LIMIT, including LIMIT zero: later effects and
failures remain observable. Negative offsets retain the existing failure path.

Ordered bounded selection has a separate runtime entry point whose comparator
must be pure, total and a strict weak order. The emitter uses it only for
Int/String/Bool column comparisons and non-secret nominal wrappers of those
types. Arbitrary-precision Int comparisons remain exact. Float and Quantity,
including nominal wrappers, keep the original stable-sort implementation because
IEEE NaN comparisons do not satisfy the stronger ordering requirement.

All matching predicates finish before comparisons start. A heap of snapshot
positions selects the requested prefix; original positions break equal-key ties.
The retained prefix is sorted before the requested range is copied out. Large
prefixes and unbounded requests keep full sorting. No comparator or predicate
runs under the table lock. Existing transaction-gate and immutable-snapshot rules
remain, and result slices do not alias the stored row slice.

PostgreSQL dispatchers still send their original SQL plans and arguments to
PostgreSQL. The optimization only selects a different Memory implementation when
the database is unbound; it does not cache or bypass database admission.

## Measurements

### Runtime component

```sh
cd runtime/go
GOMAXPROCS=2 go test ./teslrt -run '^$' \
  -bench '^BenchmarkMemoryBoundedSelection$' -benchmem -count=3
```

The benchmark constructs a valid unique-ID dataset outside timing and compares
the retained legacy algorithm with bounded selection in the same binary. Dataset:
100,000 rows, roughly 104 bytes per row; requested result: ten rows.

| Operation | Legacy | Bounded | Allocation per operation |
|---|---|---|---|
| Ordered range | 206–218 ms | 3.78–4.10 ms | 10.4 MB → 0.804 MB |
| Unordered range | 4.55–5.18 ms | 1.37–1.44 ms | 10.4 MB → 1,152 bytes |

Ordered selection improved approximately **50–58×** in this component sample.
The unordered range saves roughly **9,000× allocated bytes**, not total process
memory; its elapsed-time gain is much smaller. Stored table memory is unchanged.
Raw output: `/tmp/nix-shell.E25jrS/opencode/wave6-memory-bench.log`.

### Compiled HTTP workload

`scripts/measure-memory-selection.py` compiles `bench/BoundedMemory.tesl`, creates
20,000 rows through the actual HTTP insertMany endpoint, then measures real HTTP
queries. Seeding is outside query timing. Every returned value and ordering is
compared against an independent Python result, including untouched fields.

Before/after/after/before runs used five warmups and thirty measured requests per
endpoint. Median request times:

| Endpoint | Before, first/second run (ms) | After, first/second run (ms) |
|---|---|---|
| Ordered first page | 29.218 / 24.608 | 0.771 / 0.815 |
| Ordered page with offset | 27.716 / 24.124 | 0.842 / 0.793 |
| Ordered selectOne | 30.933 / 24.446 | 0.682 / 0.718 |
| Unordered range | 0.895 / 2.279 | 0.395 / 0.406 |

The ordered endpoints improved approximately **30–45× end to end**. This does
not establish production p99 budgets, a gain for all queries, or a PostgreSQL
throughput gain. Float/NaN and large-offset/full-sort fallback cases are not
included in the speedup claim.

Evidence: `/tmp/nix-shell.E25jrS/opencode/w6-memory-{b1,a1,a2,b2}/result.json`.
All runs reported `correctness-passed` and retain raw observations and build hashes.

## Regression coverage

- Differential tests compare bounded selection with the unchanged stable-sort
  reference across ties, shuffled IDs, ascending/descending order, selective
  predicates, empty sets, offsets, limits and integer boundary values.
- Predicate tests preserve late failures even after LIMIT is satisfied, including
  LIMIT zero, and ensure comparisons do not precede predicate completion.
- Reentrant predicates can read/write the table without deadlocking; selection
  still sees its original snapshot. Returned row slices cannot mutate storage.
- Concurrent readers remain blocked during a Memory transaction and do not see
  rolled-back writes.
- A structural comparison-count test prevents ordered selectOne from silently
  returning to full sorting; bounded-range result capacity is checked too.
- Compiled Tesl tests exercise primitive, nominal and large-integer ordering,
  stable ties, offsets, and both Float and nominal-Float NaN compatibility.
- Both ordinary and versioned Memory dispatchers avoid evaluating SQL operands;
  actual PostgreSQL tests verify SQL execution and once-only operand evaluation.
- Differential fuzzing passed locally and is included in the existing Go fuzz
  gate. Existing gates were not removed or relaxed.

The full hosted CI run remains required. Local timing evidence is stored in
temporary directories and is not a durable CI artifact.
