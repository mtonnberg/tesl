> **STATUS: COMPLETE (2026-06-26); SQL deferred.** Phase 0 (codec benchmark, wired
> into the internal-all aggregate), Phase 1 (specialized primitive ENCODERS →
> direct tesl-encode-prim-* calls, single-source-of-truth in dsl/types.rkt) and
> Phase 2 (specialized primitive DECODERS → direct tesl-decode-prim-field calls;
> shared jsexpr-required-field + tesl-decode-prim-field helpers make generic ≡
> specialized byte-identical on EVERY branch, incl. all negative/error paths) all
> shipped. Honest finding: no measurable wall-clock win on Racket CS (the JIT
> already inlines the dispatch) — the value is structural (one dispatch layer
> removed; single source of truth) and proven byte-behavior-identical. User-type
> fields intentionally stay on the generic registry path. Phase 3 (SQL WHERE-clause
> hoisting) DEFERRED → roadmap/later/sql-compile-time-specialization.md (needs a
> live PostgreSQL test env). Gates green (58-lesson 0-differ; codec negative-branch
> error-text assertions).

---

# Smaller Core — Compile-time specialization of runtime generics

> Part of the **Smaller Core** theme — see `smaller_core.md`. This is the **performance**
> pillar. It is distinct from `next/optimizations.md` (toolchain/build/test speed) and from
> `completed/actually-zero-cost-runtime-proofs.md` (proof-struct allocation) — it targets
> the per-request cost of the runtime's *generic interpreters*.

## Context

A compiled Tesl program runs on the Racket substrate (`dsl/`, ~8.3k lines excluding
tests/debug; 9.9k total). For each HTTP
request the substrate decodes the request body, validates it, runs the handler (possibly
issuing SQL), and encodes the response. Much of that work is done by **generic
interpreters** that re-discover, at runtime, structure the compiler already knew at compile
time.

## The key architectural realization

The compiler statically knows every endpoint's request type, response type, and query
shape. The runtime nonetheless re-walks the request/response types per request, and — even
though the query shape is already hoisted to compile-time literals — still re-extracts
predicates and rebuilds the WHERE-clause string per call. Concretely (verified):

- **Request decode walks the structure twice.** `jsexpr->typed-value` (`dsl/types.rkt:1071-1227`)
  recursively validates the whole request value against a generic type spec; then
  `dsl/web.rkt` (~`:1343-1375`) re-validates with `runtime-type-satisfied?` — a *second*
  full walk of the same structure.
- **Per-field codec dispatch.** Decoding consults a hash registry and tries decoders in a
  loop wrapped in `with-handlers` exception handling, per field
  (`dsl/types.rkt:1957-1985`).
- **Response encode is generic.** `runtime-value->jsexpr`
  (`dsl/types.rkt:585-629`) walks the entire response value via generic type dispatch and
  value-unwrapping at every node. Producing a list of N records with M fields is inherently
  O(N·M) output; the avoidable cost is the per-node *constant factor* — generic dispatch,
  runtime-value unwrapping, and intermediate-hash construction — not the O(N·M) itself.
- **SQL is partly re-extracted every call.** The compiler already hoists most of the query
  shape to literals at compile time via a `sql_select_seed` (`emit_racket.ml:566`, emitted by
  `emit_sql_select` at `:1154-1205` — order/limit/offset/group-by/joins are already constants,
  not a runtime `Ast.expr` walk). The residual runtime cost is narrower: `select-many`
  (`dsl/sql.rkt:1451+`) re-extracts predicates from the clause list (`query-predicates`,
  `query-order`, …) and `compile-where-sql` (~`:951`) builds the WHERE-clause SQL string at
  runtime, though only the *values* are dynamic.

**Therefore: the compiler can emit type-specialized decoders, encoders, and query
templates** — straight-line code that does exactly the work this endpoint needs — instead
of invoking the generic interpreters. The generic interpreters remain for dynamic
boundaries (e.g. values arriving from the database without a static witness) and as a
gated correctness oracle.

## Relationship to existing perf work (no overlap)

- `next/optimizations.md` — build/test/toolchain speed (CI parallelism, batch mode,
  startup, incremental cache). **Not** per-request runtime cost. 3/7 shipped.
- `completed/actually-zero-cost-runtime-proofs.md` — eliminates *proof-struct* allocation
  on statically-proven paths (default-on). It explicitly scopes out the codec/query work:
  this item is that complementary piece.

This item is the **only** one targeting the per-request decode/encode/query overhead.

## Feasibility — verified, not assumed

- The generic decode/re-validate/encode and the residual SQL predicate re-extraction /
  WHERE-clause string-building are present at the line references above.
- The compiler already owns the static type/IR (`ir.ml`'s shared `ir_type`, consumed by the
  TS/Elm emitters) and the compile-time query representation — queries are not a runtime
  `Ast.expr` variant but a `sql_select_seed` (`emit_racket.ml:566`) whose shape is already
  resolved to literals — so it has everything needed to generate specialized code; no new
  front-end analysis is required.
- A **differential mode** is feasible and is the safety key: run specialized + generic side
  by side and assert byte-identical JSON / identical SQL before retiring the generic path,
  exactly mirroring the `TESL_ZERO_COST_PROOFS=0/1` parity discipline.

> Speedup magnitudes below are hypotheses to be *measured* by the Phase 0 harness, not
> assumed.

## Plan

### Phase 0 — Per-request benchmark harness
Stand up a repeatable benchmark for decode/encode/SQL on representative endpoints (a record
request, a `List<Record>` response, a multi-clause query). Tie into the measurement
approach already established by `next/optimizations.md`. No optimization lands without a
before/after number.

### Phase 1 — Specialized response encoders (lowest risk: output only)
Emit a per-type `encode-<T>` that directly constructs the JSON for that type via field
access, replacing the generic `runtime-value->jsexpr` for statically-typed responses. Gate:
**differential** — specialized output byte-identical to generic over the corpus — plus a
benchmark delta.

### Phase 2 — Specialized request decoders (merge decode + validate)
Emit a single type-aware decoder per request type that validates shape and decodes in **one
pass**, removing the `jsexpr->typed-value` + `runtime-type-satisfied?` double walk and the
per-field registry/try-catch dispatch. Keep the generic decoder as the gated fallback and
differential oracle. Gate: differential byte-identical decode results (including error
behaviour on malformed input) + benchmark.

### Phase 3 — Hoist the residual SQL string-building to compile time
Order/limit/offset/group-by/joins are already resolved to literals in the `sql_select_seed`
at compile time, so the residual runtime cost is narrow: `select-many`'s per-call predicate
re-extraction and `compile-where-sql`'s WHERE-clause string-building. Emit a per-query-site
SQL template (WHERE clause pre-built, predicate columns fixed) so the runtime only binds
parameter *values*. Gate: differential identical SQL strings + identical results +
benchmark.

## Weighted pros and cons

**Pros**
- **High — cuts the per-request constant factor**: the second validation walk, the generic
  dispatch / value-unwrapping / intermediate-hash overhead on each node of response encode
  (the O(N·M) output size is inherent and stays — what goes away is the per-node constant
  cost), per-field registry hashing, and the residual predicate re-extraction. Direct
  hot-path latency/throughput win.
- **Medium — smaller generic runtime over time.** As specialization covers the common cases,
  the generic interpreters shrink toward the dynamic-boundary fallback.
- **Medium — composes with the clean core.** Easiest to do well *after* desugaring/lifting
  leave a regular core/IR to generate from.

**Cons / risks**
- **High — emitter is the trusted boundary** and this grows it with new code paths.
  Mitigated by the differential mode (specialized ≡ generic) gating every phase, and by
  keeping the generic path as a runtime-selectable fallback while Tesl is alpha.
- **Medium — must preserve validation semantics exactly**, including error messages and
  rejection of malformed input. The differential corpus must include negative/malformed
  cases, not just happy paths.
- **Medium — codegen complexity / size.** Specialized emitters add OCaml; this item *grows*
  the compiler to *shrink the runtime cost* — it is a performance item, not a size item.
- **Low — interaction with proofs.** Decoders feed proof-carrying values; coordinate with
  `actually-zero-cost-runtime-proofs.md` so specialization and proof handling compose.

## Critical files

- `dsl/types.rkt` — `jsexpr->typed-value` (`:1071-1227`), `runtime-value->jsexpr`
  (`:585-629`), codec registry (`:1957-1985`): the generic interpreters to specialize away.
- `dsl/web.rkt` — request decode/validate path (~`:1343-1375`): the redundant second walk.
- `dsl/sql.rkt` — `select-many` (`:1451+`), `query-*` extractors (`:663-686`),
  `compile-where-sql` (~`:951`): the residual runtime predicate re-extraction +
  WHERE-clause string-building (the rest of the query shape is already a compile-time
  `sql_select_seed`).
- `compiler/lib/emit_racket.ml` — where specialized `encode-<T>` / `decode-<T>` / query
  templates are emitted (codec emission today around `:4402-4565`).
- `compiler/lib/ir.ml` — the shared `ir_type` (`:65-81`) that specialization generates from.
- `compiler/lib/dune`, `tests/` — benchmark harness + differential corpus.

## Verification

1. **Differential equivalence.** Over the corpus (including malformed-input negative cases),
   specialized decode/encode produces byte-identical JSON and SQL to the generic path; gate
   each phase on this before retiring any generic path.
2. **Benchmarks.** Before/after numbers from the Phase 0 harness for each phase; no
   regression in correctness, measurable improvement in the targeted path.
3. **Existing suites.** `tests/*.rkt` (runtime/HTTP/DB) and `compile-examples.sh`
   (validate → test → integration) stay green.
4. **Proof parity.** `TESL_ZERO_COST_PROOFS=0/1` behaviour-identical, confirming
   specialization did not disturb proof handling.
