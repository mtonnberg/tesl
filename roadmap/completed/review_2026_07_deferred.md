# 2026-07 review — deferred items (ALL RESOLVED)

## Status (2026-07-03): no open items remain

Every item that was carved to this list is now closed. The one remaining
forward-looking piece — cross-module compile-time Eq/Ord (**1b**) — is tracked in
`roadmap/next/eq_ord_generic_soundness.md`, not here.

## Updates

**Decision (historical)** Adding *user-facing type classes* was judged too large a
language expansion (steeper learning curve), so it was deferred. **This did not block
the fix:** the generic Eq/Ord hole was closed WITHOUT type classes, via closed built-in
`Ord`/`Eq` constraint tracking — see below.

## Resolved

### Larger engineering (multi-step)
1. **TS-ORD/EQ — decidability. RESOLVED.**
   - **#3 CLOSED (2026-07-02):** `is_equatable` recurses through record/ADT fields, so a
     record/ADT transitively containing a function is non-equatable.
   - **#1 CLOSED (Eq/Ord Stage 1):** the `</==` check is driven from the HM-resolved
     operand type at `checker.ml` `infer_binop`; the drift-prone shadow `infer_expr_type`
     is retired. Ground non-instance operands (`Maybe Int`, functions, records for `<`)
     are rejected with a precise message. *(Verified: `String.toInt a < String.toInt b`
     → "ordering operator `<` is not defined for type `Maybe Int`".)*
   - **#2 LANDED (2026-07-03), WITHOUT type classes** — closed built-in `Ord`/`Eq`
     constraint tracking (no `class`/`instance`, no `=>`, no dictionaries):
     - **Layer 1 (compile-time, same-module):** generic-comparator misuse rejected at the
       call site (`genLt f g` rejected; `genLt 1 2` / `member`/`maximum`/`minimum`
       accepted; 0 corpus over-rejection).
     - **Layer 2 (runtime backstop, all cases):** `tesl-equal?` makes `==`/`!=` on a
       function a defined error instead of `equal?`'s silent `#f`.
     - Full design, verification, and files: **`roadmap/completed/type_decidability_ord_eq.md`**.
     - Verified green by the full `./compile-examples.sh` gate (all 11 phases).
   - **Remaining — 1b (cross-module compile-time):** reject an *imported* comparator
     (`List.member fn xs`) at compile time (currently caught at runtime by Layer 2).
     Tracked in **`roadmap/next/eq_ord_generic_soundness.md`**. When 1b lands, that `next/`
     doc moves to `completed/` and this topic is fully closed.

### Moderate — additive checks
1. ~~**CAP-UUID**~~ — Completed.
2. ~~**DRIFT-1** (Tesl.Cli removed; env-vars-only)~~ — Completed.
