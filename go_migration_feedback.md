# Go migration feedback

## Recommendation
Continue with Go as the Tesl runtime target. The migration so far supports the original choice: Go is a good fit for Tesl's GC-shaped values and gives the project a conventional HTTP, SQL, crypto, observability, deployment, profiling, debugging, and security-tooling ecosystem.

The strongest gains are operational rather than language-level memory safety: Racket CS is already memory-safe. Go adds a typed verifier for emitted code, standard infrastructure libraries, static deployment, lower startup/RSS expectations, familiar SRE tooling, and an understandable eject/audit story.

The completed work demonstrates that Tesl's pure value semantics can be emitted successfully. It does not yet validate the hardest parts of the migration: HTTP/JSON, SQL, capabilities and proof boundaries, concurrency and cancellation, deployment, and debugger/source-level parity. A thin end-to-end service should be the next major validation milestone.

## Immutability and the trust boundary
Tesl's guarantees only need to hold while developers interact through Tesl code and supported Tesl runtime boundaries. If someone edits or directly manipulates the generated Go code, Tesl's guarantees no longer apply.

Under that contract, deeply immutable Go representations are unnecessary. The current approach is practical:

- Generated Tesl code emits no mutation operations over existing values.
- Runtime collection writers allocate fresh storage.
- List readers may safely return bounded slice views because no supported Tesl operation mutates them.
- Record updates produce new struct values.
- `teslrt.Int` protects its mutable `big.Int` implementation by cloning on ownership boundaries.

Do not add defensive copies to every read merely to protect handwritten Go. That would impose real allocation and traversal costs without strengthening the supported Tesl interface.

The runtime and future HTTP, JSON, SQL, queue, and FFI boundaries remain inside the trusted implementation. They must not expose pooled or subsequently reused buffers as Tesl values, and they must take ownership or copy when external mutable storage enters the Tesl value graph. Nil and empty collections must also be normalized where their distinction would otherwise leak through Go codecs.

Exported Go fields and raw slices are acceptable under this trust model. Hiding `Dict`/`Set` backing fields can still be considered as cheap accidental-misuse protection, but it is not required to uphold the language guarantee.

## Dict and Set semantics
`Dict` and `Set` should remain abstract unordered datatypes. The language should not promise a storage or iteration order.

Recommended public contract:

- `Set.toList` returns every member exactly once, in unspecified order.
- `Dict.keys` returns every key exactly once, in unspecified order.
- `Dict.values` returns one value per binding, preserving multiplicity, in unspecified order.
- `Dict.toList` returns every key/value binding exactly once, in unspecified order.
- Equality, membership, lookup, insertion, removal, and set algebra are independent of storage order.
- Separate `Dict.keys` and `Dict.values` calls have no promised positional relationship; callers that need key/value pairing use `Dict.toList`.
- Programs must explicitly sort when ordering matters for presentation, pagination, snapshots, signatures, hashing, or canonical serialization.

“Unspecified” does not mean the implementation should randomize iteration. The current sorted representation may continue returning deterministic internal order because doing so is free and improves logs, debugging, and reproducibility. That order should remain an implementation detail so a future HAMT, hash table, tree, or other representation can be adopted without a language change or an O(n log n) output-sorting obligation.

If ordered traversal becomes a recurring user requirement, add an explicit operation such as `Set.toSortedList`/`Dict.toSortedList` or a distinct ordered collection type rather than changing the base datatype contract.

## Required Float key fix
Unspecified external iteration order does not remove the current need for a valid internal ordering. The sorted Dict/Set algorithms use an ordering comparator for binary search, deduplication, and ordered merges.

Native IEEE `<` is not compatible with Tesl's `FloatEqual`:

- Every comparison involving NaN is false. Using “neither side is less” as key equivalence therefore makes NaN appear equivalent to arbitrary non-NaN keys.
- Native ordering treats `-0.0` and `+0.0` as equivalent, while `FloatEqual` deliberately distinguishes them.

This affects membership, lookup, replacement, deduplication, equality, and set algebra; it is not merely an output-order issue.

Retain user-visible IEEE comparisons, but introduce a separate collection-key comparator, conceptually `FloatKeyLess`. Its equivalence classes must exactly match `FloatEqual`:

- Finite values and infinities use their normal numeric order.
- `-0.0` and `+0.0` receive distinct positions; `-0.0 < +0.0` is a reasonable choice.
- All NaN representations form one key-equivalence class because `FloatEqual` considers all NaNs equal.
- The NaN class is placed consistently first or last; this choice is internal and is not Tesl language semantics.

The defining law is:

`FloatEqual(a, b)` if and only if both `FloatKeyLess(a, b)` and `FloatKeyLess(b, a)` are false.

Do not globally replace the emitter's ordinary element-ordering helper. User expressions and operations such as `List.sort` have user-visible ordering semantics. Add a distinct key-ordering path used only by Dict/Set search, construction, deduplication, merge, and related internal operations. Float-backed newtypes must inherit the same key comparator.

Tests should cover:

- Comparator irreflexivity, asymmetry, and transitivity.
- Compatibility with `FloatEqual`.
- Multiple NaN signs and payloads.
- `-0.0` versus `+0.0`.
- Infinities, subnormals, and ordinary equal/unequal values.
- Dict lookup/replacement and Set insertion/deduplication for all of the above.
- Union, intersection, difference, subset, and equality involving NaN and signed zeros.

An equality-scanned unsorted slice would avoid the comparator but would reduce Dict lookup to O(n) and could make Set algebra O(n*m). Rejecting Float keys would also work but unnecessarily narrows the language. The collection-specific total comparator is the smallest fix and preserves the current performance characteristics.

## Collection and fold performance
The sorted-slice representation is a reasonable initial choice for the small collections common in API code:

- Lookup is O(log n).
- Bulk construction can sort and deduplicate in O(n log n).
- Set union, intersection, and difference are O(n+m).
- Immutable insertion and removal copy O(n) storage.

The fold operation itself must only add O(n) traversal overhead. Assigning a scalar, slice header, or Dict/Set wrapper accumulator is O(1); the fold must not defensively copy an accumulator merely because it is a collection. The callback's work is additional, so the general complexity is O(n × callback cost), not unconditionally O(n).

The existing specialized `List.map` and `List.filter` shape is correct: allocate a private output once and fill it in one pass. Mapping over strings remains O(n) list work plus the total cost of the individual string operations; copying a Go string value copies its header rather than its backing bytes.

A callback that performs an immutable write on a growing collection is different. At iteration k, the current `List.append`, `Set.insert`, or `Dict.insert` may allocate and copy Θ(k) elements. Folding n unique inserts or singleton appends therefore performs 0 + 1 + ... + (n-1) copies: Θ(n²) time and Θ(n²) cumulative allocation volume.

This must be considered when `List.foldr` and the remaining fold forms are implemented:

- A scalar `foldl`/`foldr` with an O(1) callback must be O(n). `foldr` can traverse the input from the end rather than recurse on the Go stack.
- The canonical list reconstruction pattern, conceptually `List.foldr (fn(x, acc) -> List.append [x] acc) [] xs`, must not emit repeated `ListAppend` calls over a growing accumulator. It should allocate once and fill backwards, use a private transient builder, or use an O(1)-prepend representation followed by a single freeze/reversal.
- Obvious `foldl` accumulation through `Set.insert` from `Set.empty` and Dict insertion from `Dict.empty` should lower to private builders or equivalent bulk constructors, sorting/deduplicating once at freeze time. Dict construction must retain its “later duplicate wins” rule.
- An optimization may mutate only fresh builder state that cannot be observed through an earlier accumulator value. Arbitrary callbacks can retain earlier accumulators inside their result, so general fold lowering must not assume uniqueness without an escape/linearity proof.
- If arbitrary repeated immutable `insert` must have good asymptotic behavior outside recognized builder folds, sorted copy-on-write slices are insufficient; use a persistent tree/HAMT, potentially behind a small-slice representation.
- If an intentionally arbitrary callback repeatedly appends its entire accumulator and cannot be safely recognized, quadratic callback behavior may remain, but it should be documented and preferably diagnosed by a performance lint. The fold implementation itself must not introduce the copying.

Repeated Dict/Set insertion can therefore be quadratic, unlike a persistent hash/tree with structural sharing. Immutability does not universally require O(n) updates; it does when cloning native Go maps or slices. A HAMT or persistent tree could improve asymptotics but would add substantial implementation, audit, allocation, and eject-readability cost.

Treat accidental quadratic collection-building folds as a migration gate rather than a post-parity micro-optimization. Add emitted-shape tests that reject repeated `ListAppend`/Set/Dict copy-on-write calls for recognized canonical builders, plus scaling/allocation benchmarks for n, 2n, and 4n inputs. Before freezing the runtime ABI, benchmark large query results, repeated insertion, bulk construction, lookups, set algebra, fold-based construction, allocation volume, and retained memory.

## Remaining migration risks
The main outstanding risks do not justify changing runtime language, but they should gate Racket retirement:

1. **Mutual tail recursion:** self-tail calls are looped, but deep mutual tail recursion remains Go recursion and can end in an unrecoverable process-level stack overflow. Add an SCC trampoline/state-machine strategy or establish an explicit restriction before accepting attacker-controlled recursion depth.
2. **First-class curried functions:** direct calls and specialized higher-order lowering work, but general function values and partial application still need a consistent calling convention. A direct uncurried entry point plus generated curried adapters is a plausible approach.
3. **Operational vertical slice:** validate HTTP, JSON, pgx, contexts, cancellation, panic containment, concurrency, proof/capability boundaries, and deployment in one real service before adding much more pure-runtime breadth.
4. **Debugger parity:** verify breakpoints, stepping, locals, source mapping, attach-to-running-process, and generated-loop behavior against actual Tesl source.
5. **Differential parity:** continue fail-closed emission and run the backend-neutral corpus against both backends. Tests involving unordered collections must compare membership/bindings rather than incidental list order.
6. **Boundary ownership:** codecs and integrations must define whether returned memory is owned, copied, retained, or pooled. Tesl values must never observe later mutation by trusted runtime code.
7. **Flat ADT size:** the tag-plus-all-payload-fields representation is simple and allocation-friendly, but large multi-variant ADTs may increase value size and copying. Measure before redesigning.
8. **Migration tracker:** keep implemented and pending entries synchronized; stale status makes scope and retirement readiness difficult to assess.

## Suggested near-term sequence
1. Add the equality-compatible Float key comparator and adversarial Dict/Set tests.
2. Record the unordered collection contract in the language/stdlib documentation.
3. Record the generated-Go trust boundary and runtime ownership rules.
4. Define fold complexity requirements and implement private builders/lowering for canonical List, Set, and Dict construction without quadratic copying.
5. Add scaling and allocation gates for map/filter/fold and repeated collection construction.
6. Build and measure one end-to-end HTTP/JSON/SQL service with cancellation and concurrent requests.
7. Validate source-level debugging on that service.
8. Resolve mutual tail recursion and general function values.
9. Expand full differential corpus and mutation parity before considering Racket retirement.
