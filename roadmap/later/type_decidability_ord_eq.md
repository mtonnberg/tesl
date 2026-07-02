# Ordering/equality decidability — fail closed

## Status (2026-07-02)
**#3 CLOSED:** `is_equatable` recurses through record/ADT field types — a nominal
type that transitively contains a function is non-equatable (regression R75_EQFIELD;
see `roadmap/completed/review_2026_07_closed_items.md`). **#1 and #2 remain** (below):
both need the deferred Eq/Ord qualified-type layer / HM-type consumption — a per-fn
stdlib table (#1) or a blunt fail-closed TVar guard (#2) would be drift-prone /
over-reject valid generic code (the deliberate S14b maintainer decision).

## Why
**TS-ORD/EQ (high):** `<`/`==` are fully-polymorphic stdlib signatures guarded by a
second, hand-written shadow inferencer (`is_orderable`/`is_equatable`). Where the
shadow disagrees with the real HM checker the guard fails open:
- `String.toInt a < String.toInt b` (both `Maybe Int`) accepted → runtime crash
  (shadow returns `None` → `None → allow`).
- `genLt f f` / `genEq f f` on functions via a generic helper accepted → crash / silent `#f`
  (`TVar → true` arm ignores instantiation).
- record/ADT with a function field compared `==` accepted → silent wrong
  (`is_equatable` doesn't recurse into nominal definitions).

## Fix (instance = fail closed, now)
- `None` from the shadow inferencer → **reject** (was: allow), with a clear message
  ("cannot determine that <expr> is comparable; annotate or restructure").
- `TVar` in ord/eq position → reject unless bounded by a resolved comparable type.
- `is_equatable`/`is_orderable` recurse through record/ADT field types (a type that
  transitively contains a function is not comparable).

This is the safe direction (may over-reject some valid generic comparisons; those
get an explicit annotation path). Full principled fix = qualified types (Eq/Ord
classes) participating in HM generalization/instantiation → **roadmap/later**
(`type_classes_eq_ord.md`).

## Tests
the three repros → REJECTED; direct `Int`/`Float`/`String` comparisons → accepted;
a representative sample of the example corpus still compiles.

## Status: CARVED → `roadmap/later/review_2026_07_deferred.md` §6 — 2026-07-02
The fail-closed instance fix was NOT landed this pass: making the shadow guard
reject on `None`/`TVar` risks over-rejecting valid generic comparisons without a
principled replacement + annotation escape hatch. Deferred to the qualified-types
(Eq/Ord) design.
