# Eq/Ord decidability — CLOSED (closed built-in constraints, no type classes)

## Status: LANDED 2026-07-03 (gate-green). One follow-up (1b) in `next/`.

The generic Eq/Ord soundness hole (#2) is closed **without introducing type classes**.
The key reframe: closing it does NOT require the user-facing type-class feature that was
deferred (no `class`/`instance`, no `=>` surface syntax, no dictionaries). It needs
*closed, built-in* `Ord`/`Eq` constraint tracking — Jones-style qualified types
restricted to the fixed `{Ord, Eq}` predicate set, invisible to developers except as a
clearer error at a genuinely-wrong call.

The full landed design, verification, files, and the remaining 1b work live in the single
source of truth: **`roadmap/next/eq_ord_generic_soundness.md`**.

## What closed

- **#1 (stdlib-result / `Maybe Int`) — CLOSED (Eq/Ord Stage 1).** The `</==` operand
  check is driven from the HM-resolved type at `checker.ml` `infer_binop`; the drift-prone
  shadow `infer_expr_type` was retired. Ground non-instance operands are rejected
  (`String.toInt a < String.toInt b` → "ordering operator `<` is not defined for type
  `Maybe Int`").
- **#3 (records/ADTs containing a function) — CLOSED (2026-07-02).** `is_equatable`
  recurses through record/ADT fields.
- **#2 (generic `TVar` helper, `genLt f f`) — LANDED (2026-07-03):**
  - **Layer 1 (compile-time, same-module):** obligations harvested from a fn body and
    discharged at each call site — `genLt f g` rejected; `genLt 1 2` and valid generic
    helpers (`member`/`maximum`/`minimum`) accepted; 0 corpus over-rejection.
  - **Layer 2 (runtime backstop, all cases):** `tesl-equal?` (`tesl/private/runtime.rkt`)
    raises a defined error on a function operand instead of `equal?`'s silent `#f`.

## The instance set was NOT changed
`ty_is_ord`/`ty_is_eq` still only *classify* which types may be compared (Ord = Int,
Float, PosixMillis + newtypes; Eq = anything without a function component). No per-type
"implementation" is written — comparison is one primitive. `String` stays Eq-only (not
Ord) — a separate one-line policy knob if ever wanted.

## Remaining — 1b (cross-module compile-time)
Reject an *imported* generic comparator at compile time (`List.member fn xs`), not only at
runtime. Tracked in `roadmap/next/eq_ord_generic_soundness.md`; when it lands, that doc
moves here and the topic is fully closed. Until then, cross-module misuse is caught
fail-closed at runtime by Layer 2.

## Why the deferred "type classes" framing was set aside
The original plan proposed full qualified types / type classes and deferred them as a big
language step. In practice the same soundness guarantee was achieved with a small,
invisible, additive mechanism (harvest + discharge over a closed predicate set), so the
learning-curve concern never applied.
