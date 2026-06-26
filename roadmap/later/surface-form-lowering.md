# Surface-form lowering — deferred remainder

Carved out of `reduce_language_size.md` (moved to `completed/` 2026-06-26). That
effort aimed to shrink the emitter by lowering surface forms into a small core in
`desugar.ml` and **deleting** their `emit_racket.ml` arms, byte-identically.

## What shipped (in `completed/reduce_language_size.md`)
- **P3 effect forms:** `EEnqueue` / `EStartWorkers` / `EServe` → one data-driven
  `Ast.ERuntimeCall` core node (3 bespoke emit arms collapsed to 1 walker).
- **P4 Racket dedup:** extracted the one provably-identical helper
  (`proof-infix-operands`) into `dsl/private/proof-utils.rkt`.

## THE shared blocker (the prerequisite for most of the rest)
The emitter performs **context-dependent raw-param unwrapping**: a bare `EVar`
that is a raw parameter is emitted as `*name` (the raw value) iff
`ctx.func_kind <> None` **and** the name is in `ctx.param_names` / `ctx.raw_locals`,
otherwise as the GDP subject gensym. Those tables are **emit-time only**. Any
lowering whose faithful reproduction needs per-leaf knowledge of "is this `EVar` a
raw param?" cannot be made byte-identical at desugar time — verified three times
(EUnop pilot, LInterp, ETelemetry/EPublish). See the design note at
`compiler/lib/desugar.ml` ~lines 32-59.

### Prerequisite work item (unblocks EUnop, LInterp, telemetry, publish)
Lift the `*name` raw-param unwrapping out of the emitter into a faithful core
construct: e.g. a desugar pass that annotates each `EVar` with its raw-param
status (computing the same `func_kind` + `param_names`/`raw_locals` context the
emitter builds), or a dedicated core `raw-ref` node the desugarer emits. Then the
EUnop / LInterp / telemetry / publish lowerings become byte-identically feasible.
High-risk, byte-identity-sensitive; gate on 58-lesson exact-match 0-differ +
differential-proofs + diagnostic snapshots.

## Deferred items
1. **EUnop (P1)** — blocked on the prerequisite above.
2. **LInterp (P2)** — blocked on the prerequisite (`emit_interp` chooses
   `*name` / `name` / `(raw-value name.field)` per segment via emit-time context;
   lower to the FORMAT primitive, **not** `BConcat`, once unblocked).
3. **ETelemetry / EPublish** — blocked on the prerequisite (`*name` for bare EVar).
4. **EWithDatabase / EWithCapabilities / EWithTransaction** — **position-dependent
   emit**: different runtime calls in tail-raw position (`with-database` /
   `call-with-declared-capabilities`) vs statement position (`call-with-database`
   / `with-capabilities`). A single core form cannot capture both; needs a
   position-aware lowering rule.
5. **Cache (`ECacheGet/Set/Delete/Invalidate`) + email (`ESendEmail` /
   `EStartEmailWorker`)** — emit is shape-only (lowering is *feasible* like
   `ERuntimeCall`), but **no committed lesson `.rkt` exercises `cache-*!` /
   `send-email!`**, so byte-identity cannot be gated. Add a byte-gated lesson/test
   first, then lower.

## Verification bar (all of them)
Every lowering must keep `test_integration` 58-lesson byte-exact **0-differ**,
`differential-proofs.sh` green, and the diagnostic-snapshot corpus byte-identical
(error-message quality must hold or rise).
