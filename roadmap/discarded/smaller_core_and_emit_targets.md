# Smaller core — E1  (design decisions)

> Relocated 2026-07-02 from `close_all_open_issues.md` (Wave 4, item E1/E2).
> Review §8.1. These are **deliberate design decisions to record**, not defects to rush.

---

## E1 — smaller-core grammar collapse

Review §8.1.

### The problem

"Opinionated/explicit" holds; "small" does not. The surface is large: 77 hard keywords
(2–8× Rust/Go/Elm), 21 top-level declaration kinds, 19 bespoke block grammars — and the
reservation set is *inconsistent* (`email`/`test`/`main` usable as fn names;
`cache`/`schema` not). Five competing proof-return forms coexist in the teaching corpus,
contradicting the "one obvious way" claim (the canonical-lowering half of this is tracked
as D7, already closed for the *decision*; grammar collapse is the structural remainder).

### Direction

Demote domain keywords to **contextual**, and collapse the 19 block grammars onto **one
annotated-record grammar** — the "smaller core" the spec itself defers.

### Decision status

**The spec itself defers this.** It is a *breaking* redesign of the public grammar. The
roadmap position is to record it as a deliberate design decision and stage it carefully,
not to attempt it under time pressure. Effort: **L** (breaking).

---

## Refs

- Review: §8.1 (design coherence & size; the spec defers the smaller core).
- Related: `client_generation_soundness.md` (A10 — TS/Elm generator soundness/TCB),
  `independent_emitter_oracle.md` (S8 — per-target oracle cost).
