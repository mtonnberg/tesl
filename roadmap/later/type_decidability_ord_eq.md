# Eq/Ord open polymorphism (#2) — qualified types

## Status (2026-07-02)
**#1 and #3 CLOSED; the shadow inferencer is RETIRED (Eq/Ord Stage 1).** The
`<`/`==` operand-decidability check is now driven from the HM-resolved operand
type at `checker.ml` `infer_binop` (see
`roadmap/completed/review_2026_07_closed_items.md`, "TS-ORD/EQ"). Ground operands
outside the Ord/Eq instance set are rejected with a precise message; generic
operands stay permissive. Only **#2** remains, below.

## The residual (#2): open Eq/Ord polymorphism
A comparison hidden behind a GENERIC boundary is not caught, because a type
variable is deliberately treated as permissive (the S14b decision):

```tesl
fn genLt(a: a, b: a) -> Bool = a < b   -- `a` generic -> permissive -> accepted
fn bad() -> Bool = genLt f g           -- f, g : Int -> Int -> compiles, but is a
                                       --   function comparison (crash / silent #f)
```

`genLt`'s body types `a < b` while `a` is still generic, so the ground-operand
check does not fire; the call site `genLt f g` has no comparison operator, so
nothing re-checks the now-concrete `a = Int -> Int`. Direct/concrete function
comparison IS already rejected (Stage 1) — only this generic-helper indirection
leaks.

## Why it is deferred (not a blunt patch)
The two cheap "fixes" are both wrong:
- A **per-fn stdlib table** (the old shadow's approach) is drift-prone and cannot
  see user-defined generic helpers.
- **Rejecting every `TVar` in ord/eq position** over-rejects all valid generic
  comparison helpers (`member`, `maximum`, `minimum`, and any user helper that
  compares its parameters), which the corpus relies on.

## The principled fix — qualified types (Eq/Ord type classes)
Give `<`/`==` qualified schemes (`Ord a => a -> a -> Bool` / `Eq a => ...`) so the
`Ord`/`Eq` constraint is CAPTURED during `generalize` on a helper like `genLt`
(inferred type `Ord a => (a, a) -> Bool`) and DISCHARGED at each call site when
`a` is instantiated to a concrete type (`Int -> Int` -> no instance -> reject;
`Int` -> discharged). This is a real HM extension:
- constraints threaded through `instantiate`/`generalize` (a `constraints` field
  on `scheme`, or a constraint-set carried alongside the substitution);
- discharge at instantiation against the same instance predicates already in
  `checker.ml` (`ty_is_ord`/`ty_is_eq`);
- a clear "no `Ord`/`Eq` instance for type `T` (required by generic use of `<`)"
  message with the originating call site.

Scope it so generic helpers keep compiling (constraint deferred, not rejected) and
only concrete instantiation at a non-instance type fails.

## Tests (when landed)
`genLt f g` / `genEq f g` -> REJECTED at the call site; `genLt 1 2`,
`member x xs`, `maximum xs`, `minimum xs` on comparable elements -> accepted; add
to the `F-decidable-comparison` group in `test_wave2_soundness.ml`.
