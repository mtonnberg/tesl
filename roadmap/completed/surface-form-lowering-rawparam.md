# Surface-form lowering — the raw-param-blocked remainder

Split out of `roadmap/next/surface-form-lowering.md` (the cache/email lowering
shipped 2026-06-30 on `core_polish`; see `completed/surface-form-lowering.md`).
Everything here is **blocked on the same hard prerequisite** and is high-risk,
byte-identity-sensitive deep-compiler work — deferred until that prerequisite
lands.

## THE shared blocker (the prerequisite for all of the below)
The emitter performs **context-dependent raw-param unwrapping**: a bare `EVar`
that is a raw parameter is emitted as `*name` (the raw value) iff
`ctx.func_kind <> None` **and** the name is in `ctx.param_names` / `ctx.raw_locals`,
otherwise as the GDP subject gensym. Those tables are **emit-time only**. Any
lowering whose faithful reproduction needs per-leaf knowledge of "is this `EVar` a
raw param?" cannot be made byte-identical at desugar time — verified three times
(EUnop pilot, LInterp, ETelemetry/EPublish). See the design note at
`compiler/lib/desugar.ml` (module docstring + the `lower_expr` "NOT lowered" list).

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
   position-aware lowering rule (independent of the raw-param blocker, but equally
   byte-identity-sensitive).

## Verification bar (all of them)
Every lowering must keep `test_integration` 58-lesson byte-exact **0-differ**,
`differential-proofs.sh` green, and the diagnostic-snapshot corpus byte-identical
(error-message quality must hold or rise).
