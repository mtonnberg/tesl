# S7 / C5 — generative negative corpus with attributed kills

> Relocated 2026-07-02 from `close_all_open_issues.md` (Wave 3, item C5/S7).
> Backlog ID: **S7** (`stability_deferred_backlog.md`). Review §7.

## The problem

Soundness is exercised by hand-written negative tests plus a small generative
down-payment. There is no *systematic* generative negative corpus that, for every
accepted proof-bearing program, applies each soundness-breaking transform and asserts the
checker rejects the mutant for the **specific** soundness diagnostic (not merely "some
error").

## Why it matters

Attributed kills are what prove each soundness layer is actually load-bearing: a mutant
that should trip the proof-content gate must be rejected *by that gate*, not accidentally
by an unrelated parse error. This generalizes `s7_generative` from a handful of seeds to
the whole proof-bearing corpus, closing generator class G5.

## Fix approach

For each accepted proof-bearing program, apply a table of soundness-breaking transforms
and assert rejection with the expected diagnostic:

- drop a `:::` (proof carrier),
- retarget a fact subject,
- widen a capability row,
- forge a provenance predicate,
- weaken an `auth` `via`.

The transforms must be designed as **AST rewrites**, one grammar per soundness layer —
not string edits, which are brittle and can produce spurious parse failures that masquerade
as kills.

Down-payment already landed: `test_wave2_soundness.ml` + `test_s7_generative.ml`
(~6 seeds).

## Effort

**L** — the generative generalization over the full proof-bearing corpus (~855–1200
files) is multi-day; the per-layer transform grammar is the design bulk. Pairs with S10
(corpus-wide mutation), which is blocked on this transform grammar.

## Refs

- Review: §7 (`s7_generative` mutates known-good seeds; generalize it).
- Backlog: `stability_deferred_backlog.md` → **S7**.
- Source: `test_wave2_soundness.ml`, `test_s7_generative.ml`.
