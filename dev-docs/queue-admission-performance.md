# Queue admission performance — measured continuation after `3242931`

> Audience: contributors reviewing queue admission optimizations and their evidence.

## Result and scope

The ordinary-release 257-type workload now reaches first conversion for every
type in **24.535s and 24.549s** in two repeated runs with the same binaries. It
retains old work in the busy first type and verifies payloads and admission
`current/minVersion/compatFloor = 2/1/1`. The earlier corresponding observation
was 685.729s: approximately **28× faster**. The unchanged 25-second check passes
these two runs, but the margin is under half a second. This is not a production SLA.

The workload has 1,024 busy-head jobs and one job for each of 256 later types,
not 257 jobs total. The goal is one converted job of every type, not draining all
1,280 jobs. Timing starts after Worker readiness. Each job still commits separately.

Enqueue setup fell from roughly 202s to **44.756s and 44.232s**. It remains a
separate cost: this work does not claim end-to-end deployment inside 25 seconds.
Build, installation and Worker startup are recorded independently.

## What the profile changed in our understanding

The initial PostgreSQL function profile (257 types, 64 head jobs, 90s observation)
showed 57.08s self-time in `tesl_queue_inventory_preserves`, and 19.76s in canonical
contract framing validation. Only 31 types had progressed. Inventory set comparison
was the largest individual cost, not the callback's simple record construction.

After replacing nested array scans with set difference, the preservation helper
took 0.414s over 275 calls, while 89 types progressed within 90s. Canonical framing
then dominated. Function self-times are used here; nested total-times must not be
added together as if they were independent CPU costs.

## Changes retained

### 1. Relational set inclusion and paired transition checks

Inventory preservation compares `(queue, entire payload JSON)` using SQL set
difference. It does not compare only names or hashes. New SQL-NULL queue names are
excluded so NULL cannot acquire equality that the original `=` predicate lacked.
Empty previous inventories preserve the old short-circuit behavior.

Changed-edge validation materializes old/new members, pairs and valid staged roots
once per statement. Exact membership, installed UUID/fence, source inventory,
old/new contracts and extra staged-source checks remain. These are computational
changes inside one snapshot, not cached database authority.

### 2. Full admission once per job transaction

Application conversion phases now have distinct responsibilities:

- **Next:** selects/locks an eligible ID under the actual version domains; it
  creates no attempt, result, failure or discard authority.
- **Begin:** performs the complete fresh inventory/admission verification before
  minting the private attempt. Its source/target fences and schema-state share
  lock stay held until transaction end.
- **Finish/fail/discard:** require the exact private attempt, current transaction
  ID, sequence, original bytes and source binding. They retain live domain/state
  checks without rebuilding the whole inventory again.

A caller cannot turn a prior selection, committed attempt, rolled-back savepoint,
or self-supplied transaction ID into publication authority. No GUC, process-global
boolean or application-supplied "already verified" flag is used. SQL errors and
cancellation continue to roll back. The isolated format-4 candidate retains its
separate transaction machinery.

### 3. Reuse pure validation output within the operation

`tesl_queue_inventory_checked` returns the JSON inventory and its validated
canonical node together; hashing consumes that node rather than parsing it again.
Queue admission uses the same version/baseline checks without redundantly invoking
the public row-admission wrapper's inventory construction first, because it then
checks the complete queue prefix itself.

These intermediate helpers (`tesl_queue_inventory_checked`,
`tesl_queue_inventory_digest`, `tesl_row_admit_version`) are executable only by
the control owner through the protected definer wrappers. Both Request and Worker
are denied direct access. The public strict helpers retain their validation behavior.

### 4. Canonical framing and construction

- Start framing after the exact checked fixed wrapper, retaining its original
  stack depth so nesting limits remain unchanged.
- Fast-path one- and two-digit lengths/arities, retaining the strict general
  parser for larger lengths and the same leading-zero/truncation rules.
- Construct payload byte chunks and aggregate in their original ordinal order,
  instead of repeatedly copying an ever-growing prefix.
- Check exact JSON object keys with native JSONB operators instead of a SQL
  aggregate over object keys for every payload.
- Materialize the stored physical descriptor once before repeated header-byte
  access, avoiding repeated decompression of a potentially TOASTed value.

A scalar-counter parser experiment was discarded: it did not establish a useful
improvement over the simpler existing stack representation.

## Verification

- Inventory-set equivalence: 169 pairs covering membership, changed payloads,
  ordering, duplicates, missing/null queue names, JSON null and extra fields,
  compared with the original independent relational predicate.
- SQL framing versus the independent Go reader: original cases plus lengths
  0–130, leading zeros, every truncation and single-bit mutation of a valid
  contract, binary atom bytes, malformed counts and nesting boundaries.
- Canonical inventory hashes still agree with the Go implementation.
- New review cases 113–117 cover publication without an attempt; selection
  followed by damaged inventory; denied partial-admission helpers; a committed
  attempt in a later transaction; and a rolled-back attempt in the same transaction.
- The complete **117-case review suite**, **127 existing adversarial cases**,
  **58 compiler queue-source/PostgreSQL cases**, focused runtime race/registration
  checks, six embedding seam tests and three runtime-gate tests pass.

The new function catalog is part of the existing fresh-catalog-first development
protocol. This does not add automatic adoption of an older installed catalog.
The subsequent [readiness pass](migration-delivery-status.md) completed the full
authoritative gate, including these regressions. The timings here retain their
original binary provenance and are not a new throughput measurement after that pass.

## Recorded runs

Local logs under `.tesl-stuff/`:

| Run | Evidence |
|---|---|
| Initial function profile | `perf-admission-before.log` |
| Set inclusion optimization | `perf-admission-set.log` |
| Transaction-local admission | `perf-admission-once.log` — 85.446s in the 64-head profiling workload |
| Checked-node reuse | `perf-admission-checked-once.log` — 42.925s in the 64-head profiling workload |
| Framing/chunk work | `perf-admission-framing.log` — 28.151s, full 1,024-head profiling workload |
| Paired transition checks | `perf-admission-pairs.log` — 25.012s; repeats 25.026s/25.041s, still failing the strict target |
| Physical-header materialization | `perf-admission-materialized-header.log` — profiling enabled, 25.045s |
| Final unprofiled repeats | `perf-admission-final-release.log` — 24.535s/24.549s, target met |
| Final correctness gates | `perf-verified-gates.log` — 117 cases 523.352s, 127 cases 340.323s, compiler group 352.504s, runtime group 134.576s |

Each measurement directory has `measurement.json` with binary/compiler hashes,
budgets, progress samples and result invariants. Intermediate profiling and final
unprofiled runs have different instrumentation; do not treat all rows as a precise
controlled speedup series. Polling is approximately half-second granularity.

## Reproduce and next work

Inside `nix develop`, with built review release inputs:

```sh
python3 scripts/measure-migration-queue-scale.py \
  --artifacts .tesl-stuff/review-releases --output .tesl-stuff/queue-perf \
  --types 257 --backlog 1024 --observe-seconds 90 --release-build
```

Add `--function-profile` for PostgreSQL function timings on the private cluster.
Keep setup and runtime measurements separate. Next measure repeatability under
contention, expensive callbacks, more queues/unchanged types and longer histories;
the current margin does not justify a universal 25-second promise. Enqueue volume
and repeated per-job prefix work are still relevant future optimization targets.
