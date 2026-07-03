# Verification methodology — close the blind spots that let the class survive

## Why
- **VER-PROP (high):** a `where`-guarded `property` with a rarely-true guard passes
  green with zero effective runs (proven: false property, guard `n==999999999`,
  passes). No min-success/discard floor (`emit_racket.ml` property emit).
- **VER-MUT (high):** mutation testing in CI runs one curated file (`lesson42`), and
  `if scored = 0 then 100.0` lets an all-invalid file report a perfect score
  (`main.ml`). No boundary predicates in real examples are mutation-tested.
- **VER-METAMORPHIC (high):** no generative/metamorphic/differential program testing.
  The soundness defense is 9 hand seeds × 7 transforms; 54/139 test modules are frozen
  past-bug fixtures. The class regenerates with each new surface form.

## Fix (carve: high-leverage nets now, big harnesses later)
- Now: add a **min-success floor** to `property` — a guarded property that ran fewer
  than N effective iterations FAILS (or at least warns loudly) instead of passing
  vacuously; track discards.
- Now: fix the `scored = 0 → 100%` mutation-score bug (0 scored = no coverage = fail,
  not 100%).
- Now: add a **metamorphic soundness test** — take the accepted-`ok`/return corpus and
  re-wrap each in `transaction{}` / `with database` / a constructor / `Maybe`, asserting
  the accept/reject verdict is unchanged. This mechanically guards the fail-open class.
- Later (`roadmap/later/`): a grammar-based program fuzzer over `--check`; a runtime
  **proof-witness differential oracle** (retain witnesses under a gated build, assert
  runtime matches compile-time claims — the missing backstop for erased proofs);
  broaden mutation coverage across the example corpus.

## Status: PARTIAL — 2026-07-02
DONE: VER-MUT scored=0 bug (reports "n/a", not a false 100%); durable regression
fixtures for the fixed forgery class (`compiler/test/test_review75_reviewfixes.ml`).
CARVED → `roadmap/completed/review_2026_07_deferred.md` §8-9: property min-success floor
(VER-PROP), grammar fuzzer + metamorphic property + runtime proof-witness
differential oracle, broadened mutation coverage.
