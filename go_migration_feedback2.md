# Go migration feedback (round 2)

## Method
This is a fresh review, done by reading `roadmap/next/migrate_to_golang.md` (the
maintainer-updated tracker, current to 2026-08-13), the actual runtime code under
`runtime/go/teslrt/`, and `compiler/lib/emit_go.ml`, plus the uncommitted working-tree
diff (JSON codec work in progress). `go_migration_feedback.md` was read for background
only; where its claims could be checked against code, they are noted as confirmed or
superseded rather than repeated on trust. No build/test/benchmark commands were run in
this pass (another agent has the tree), so all conclusions below are from static
reading, not measurement — flagged explicitly wherever that matters.

## Bottom line
Go is still the right call, and this round of evidence strengthens that rather than
weakening it. The pure-value core (Int, Float, String, List, Dict, Set, Maybe, Either,
Tuple, records, ADTs, generics, modules, import cycles, recursion) is now largely
implemented, and it is implemented carefully — the design write-ups for each piece show
real tradeoff analysis, not just "make it compile." The previous review's one load-bearing
finding (the Float key comparator) is fixed correctly and tested exhaustively. Nothing
found in this pass is a reason to reconsider Go as the target.

What has not changed is the shape of the remaining risk: the hardest, most
performance-relevant part of the migration — HTTP, JSON at scale, SQL, concurrency,
cancellation, and debugger parity — is still almost entirely ahead. Corpus reach (17/155
gated files) understates completed foundational work but also honestly reflects that the
big remaining subsystems (`Tesl.Json` ~30 files, `Tesl.Http` ~13, `Tesl.DB` ~13 — over a
third of the corpus) haven't been load-bearing-tested yet. There is exactly one runtime
file touching JSON and zero touching HTTP/SQL/concurrency today.

## Is the migration on the right track?
Yes, on engineering quality; the pace looks slow only if corpus-file-count is read as the
progress metric, which it isn't. Evidence for "on track":

- **The differential-oracle methodology is earning its keep on both sides.** Building a
  second backend has found five real bugs in the *shipping* Racket backend (a cyclic-SCC
  inliner rebinding bug that silently mis-executed a real corpus file,
  `example/sandbox.tesl`; the Float-key bug; a stdlib type-signature/implementation
  mismatch in `List.maximum`/`minimum`; a `filterMap` truthiness bug; a negative-zero
  literal bug). That is a genuine, unplanned return on the migration investment,
  independent of whether Go ships faster services — it means the port is a real
  correctness audit of the 8-year-old Racket implementation, not busywork.
- **Design decisions are argued, not asserted.** The Int hybrid representation
  (`runtime/go/teslrt/int.go`), the List bounded-view rule (`list.go`), and the Dict/Set
  sorted-slice representation (`dict.go`/`set.go`) all read as "here are the forces, here
  is the invariant, here is what breaks if it's violated" rather than ad hoc choices. That
  is the kind of write-up that holds up under later pressure to cut corners.
- **The toolchain gate discipline is real, not aspirational.** `gofmt`, `go vet`,
  `staticcheck`, `golangci-lint` (with `exhaustive`), `gosec`, `govulncheck`, `nilaway`,
  and `go test -race` run on every emitted slice from the start, and a lint finding on
  emitted code is treated as an emitter bug rather than suppressed. This is the practice
  that actually protects the "typed target verifies the emitter" argument from rotting
  into a slogan.
- **Fail-closed is followed consistently.** Function values/currying, mutual tail
  recursion beyond direct loops, generic functions, several stdlib leaves — all correctly
  refuse to emit rather than emitting something subtly wrong. For a project whose whole
  pitch includes "no silent wrong answers," this discipline matters more than raw
  velocity.

Where the tracker itself is candid about scope risk, and that candor should be taken at
face value:

- Its own estimate is "person-year class." That is a large amount of work still ahead,
  and the JSON/HTTP/DB/concurrency slice — the one the previous review flagged as
  "not yet validating the hardest parts" — is unstarted on the concurrency side and only
  just begun on JSON.
- The "unknown unknowns" reconnaissance done before implementing `Tesl.Json` (integer
  precision, key ordering, embedded-Racket-syntax-in-the-shared-AST, `ERuntimeCall`
  desugaring being Racket-only) is exactly the right process, and it already surfaced that
  none of the `reduce_language_size` desugaring for queues/servers/workers/telemetry is
  reusable for Go. That is useful information now; it would have been an expensive
  surprise discovered mid-implementation. Keep doing this reconnaissance-before-coding
  step for HTTP and SQL, which are likely to have similarly sharp edges (connection
  pooling semantics, transaction/cancellation propagation, streaming request/response
  bodies).

## Performance: what's solid vs. what's unverified
**Solid, by inspection:**
- `teslrt.Int`'s int64 fast path (`Add`/`Sub`/`Mul`/`Quo`/`Rem` in `int.go`) is a plain
  branch plus struct return, no allocation, matching the "one predictable branch, ~1-2ns"
  claim. This is the right shape for a hot-path arithmetic type.
- `List` as a Go slice with the "only writers allocate, readers may alias" rule
  (`list.go`), plus the `boundedView` cap (`viewSlack`-based, retain-at-most-2x rule) is a
  genuinely well-thought-out compromise: O(1) `take`/`drop`/`tail` without the classic
  "a one-element view pins a 10,000-row backing array forever" leak. This is better than
  what a first pass usually produces.
- `Dict`/`Set` as sorted slices give O(log n) lookup and O(n+m) set algebra, which is
  reasonable for the small, in-memory collections typical of request/response-shaped API
  code, and determinism (no randomized Go map order) is obtained essentially for free.

**Unverified — no benchmarks exist yet for any of this, which is fine at this stage but
should not be forgotten before the ABI is declared stable:**
- Nothing in the tree measures large-collection or high-throughput behavior. All
  complexity claims above are analytical, not measured. The tracker already commits to
  "benchmark large query results... before freezing the runtime ABI" — that commitment
  should be tracked as a real gate, not a nice-to-have.
- The int64/bignum split has never been profiled under realistic mixed workloads (e.g.,
  many small ints with an occasional large one triggering the `big.Int` spill path).

**A live, previously-identified risk that is still open:** the quadratic
copy-on-write fold problem (any `foldl`/`foldr` that immutably appends/inserts into a
growing accumulator via `List.append`, `Set.insert`, or `Dict.insert` costs Θ(n²) — see
`roadmap/next/migrate_to_golang.md`'s "Accepted as gates before Racket retirement," which
explicitly says this is "not yet done"). `List.foldr` was implemented this round (as a
backward-indexed loop, correctly), but the builder-lowering that would make the canonical
`foldr`+`append` list-reconstruction idiom linear instead of quadratic has not landed.
This is exactly the kind of pattern a Tesl API author will write reflexively (building a
response list, accumulating validation errors, merging query results into a Dict), so it
should be prioritized before, not after, the first HTTP service lands — otherwise the
first real endpoint that folds over a moderately large list will look like a Go
performance problem when it is actually a missing emitter optimization.

## New performance concern found this round: the JSON codec's runtime shape
The first JSON codec slice (in progress, uncommitted) is correctness-first, and
reasonably so — it correctly handles arbitrary-precision integers via
`json.Decoder.UseNumber()` + `big.Int` and matches Racket's alphabetical key ordering.
But the mechanism it uses to get there has a real cost that should be tracked, not
assumed away by "Go is fast":

- Decoding goes through `any`/`map[string]any` with a type switch per field
  (`runtime/go/teslrt/json.go`), not typed struct + `json` tags. Every decoded object is a
  `map[string]any`, every scalar is boxed into an `any`, and encoding builds output by
  walking that map and sorting its keys (`sort.Strings`) on every call, per nesting level.
- This is the idiomatic-Go-vs-parity tension the tracker itself names ("a direct,
  concrete tension with the 'emit idiomatic Go' goal"), and it was resolved in favor of
  parity for the first slice, which is the right order of operations for correctness. But
  it means the current design has meaningfully more allocation and CPU per request than a
  generated-struct-with-tags approach would — on what will likely be the single hottest
  code path in most Tesl HTTP services (`Tesl.Json` is ~30 of 155 corpus files, and every
  JSON API request/response goes through it). This is worth an explicit measurement pass
  once the codec slice is feature-complete, and worth deciding deliberately whether
  Racket's exact byte-level key-order parity is a permanent contract or a migration-era
  crutch that can be relaxed once Racket retires (nothing outside snapshot/golden tests
  should actually depend on JSON key order).

## Risks on the horizon, ranked by how much they could still hurt
1. **The concurrency/IO layer is completely unstarted.** No goroutine, channel, context,
   or connection-pool code exists anywhere in `runtime/go/teslrt` yet. This is still the
   single biggest unknown for the "is Go actually fast/safe here" question, exactly as the
   previous review said, and it hasn't moved. The queue/SSE/worker desugaring being
   Racket-only (confirmed this round) means this is a from-scratch design, not a port —
   budget for it accordingly.
2. **Fold/collection-builder quadratic blowup remains unfixed** (see above). Concrete,
   already-scoped, and should land before or alongside the first real service, since it
   will otherwise masquerade as "Go is slow."
3. **Function values and currying are still unsupported.** `let addFive = fn(x,y)->...;
   addFive 5` and any higher-order function passed or returned as a value still fails
   closed. This blocks more idiomatic Tesl code than it might appear — the tracker
   estimates general function-value support "touches every call site, not just list
   operations." Worth making the calling-convention decision soon; it gates an increasing
   fraction of otherwise-working slices as more of the stdlib gets ported.
4. **Mutual tail recursion can still overflow the Go stack fatally** (no `recover` from a
   stack overflow). Direct self-tail-calls are correctly loop-converted; deep mutual
   recursion is not. Low likelihood in typical CRUD-shaped API code, but it is a
   process-killing crash rather than a graceful error, so it matters more than its
   probability suggests if any Tesl program's input can influence recursion depth.
5. **JSON codec performance shape**, as above — not urgent, but should not be forgotten
   once "does it work" is answered.
6. **Debugger/api-test attach parity is untouched.** This is a hard release gate
   (requirement 3) and typically underestimated; instrumentation-based designs are
   feasible in principle (confirmed by the architecture notes) but the actual DAP/attach
   loop has not been exercised against emitted Go yet.
7. **Scale/timeline.** The tracker's own "person-year class" estimate, combined with the
   fact that JSON/HTTP/DB/concurrency/debugger are all still ahead, means this is a
   multi-quarter effort at the current rigor level. That's not a reason to stop — the
   rigor is what's producing the Racket bug-finds and the well-reasoned runtime design —
   but it's worth the maintainer periodically re-confirming that the org's patience
   matches the person-year-class estimate, rather than discovering a mismatch late.

## What would most de-risk the next stretch
- Land the fold/builder-lowering gate before the first end-to-end service, so early
  performance impressions aren't contaminated by a known, already-diagnosed emitter gap.
- Do the same "reconnaissance before implementation" pass for HTTP and SQL that was done
  for JSON — it paid off (four correctness findings caught before code existed to be
  wrong). Cancellation/timeout propagation and connection-pool lifecycle under load are
  the likely sharp edges.
- Get one real benchmark on the books (even a crude one) comparing emitted Go against the
  Racket backend for a JSON-heavy endpoint, once the codec lands — both to validate the
  performance thesis with data instead of architecture argument, and to catch the
  map-based JSON codec's real cost while it's still cheap to change.
- Keep the differential oracle mandatory on every future slice, including HTTP/SQL — it
  has been the single highest-value practice in the migration so far and there's no
  reason to expect that to stop being true for the harder subsystems.
