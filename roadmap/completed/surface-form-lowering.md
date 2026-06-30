# Surface-form lowering — cache/email families lowered (DONE)

Completed 2026-06-30 on `core_polish`. Carved out of `reduce_language_size.md`
(completed 2026-06-26). That effort shrinks the **trusted emitter**
(`emit_racket.ml` — TCB) by lowering surface forms into a small core in
`desugar.ml` and deleting their bespoke emit arms, byte-identically.

## What shipped here
Lowered the **cache** family (`ECacheGet`/`ECacheSet`/`ECacheDelete`/
`ECacheInvalidate`) and the **email** family (`ESendEmail`/`EStartEmailWorker`)
to the data-driven `Ast.ERuntimeCall` core node — the same mechanism the P3
effect forms (`EEnqueue`/`EStartWorkers`/`EServe`) already use. Six bespoke emit
arms deleted from the trusted emitter; the existing `ERuntimeCall` walker now
renders them. Their `emit_expr` guard arm was extended so an un-desugared form
fails loudly rather than miscompiling.

These six were lowerable because their emit was **shape-only** (a constant prefix
+ keyword tokens, sub-expressions through `emit_expr_simple`) — no
context-dependent raw-param (`*name`) unwrapping.

### Pipeline fix uncovered + fixed
`Desugar.desugar_decl` only lowered `DFunc`/`DConst` bodies — `DTest`/`DApiTest`/
`DLoadTest` were passed through verbatim. That was sound only while the lowered
forms never appeared in a test body, but cache/email **do** (`tests/cache-tests`,
`tests/email-tests`), so they reached the emitter un-desugared and tripped the
guard. Added `desugar_test_stmt` so the pass now traverses test-block bodies and
api/load-test seed statements. `lower_expr` is the identity on every non-effect
node, so traversing a test body that uses no effect form is a structural no-op.

## Byte-identity verification
- All 5 committed `.rkt` exercising cache/email runtime calls regenerate
  **byte-identical**: `lesson59-cache`, `lesson60-email`, `user-service-api`,
  `tests/cache-tests`, `tests/email-tests`.
- Whole-corpus regen sweep: 121 committed `.rkt` byte-identical; the only diffs
  were pre-existing snapshot drift (see `next/snapshot_drift_gate.md`), proven
  unrelated by rebuilding at HEAD without this change.
- `dune test` green incl. `test_desugar` (updated: 9 lowered forms) and
  `test_integration` 58-lesson exact-match.

## The blocked remainder → `roadmap/later/surface-form-lowering-rawparam.md`
`EUnop` / `LInterp` / `ETelemetry` / `EPublish` / `EWithDatabase` /
`EWithCapabilities` / `EWithTransaction` remain blocked on the emit-time
raw-param-unwrapping prerequisite (verified-blocked 3×) — moved to `later` with
the design note intact.
