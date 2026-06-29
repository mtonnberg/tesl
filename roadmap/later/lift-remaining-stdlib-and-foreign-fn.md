# Lift remaining stdlib modules + `foreign fn` — deferred remainder

Carved out of `lifting_implementation.md` (moved to `completed/` 2026-06-26).
The goal was to shrink the **trusted hand-written Racket core** by moving pure
stdlib combinator BODIES into Tesl source compiled to Racket.

## What shipped (in `completed/lifting_implementation.md`)
- Reusable mechanism: leaf-primitive split (`<mod>-prim.rkt`) + real `<mod>.tesl`
  bodies + `scripts/gen-stdlib-rkt.sh` bootstrap (path-normalized) + a `ci.sh`
  `Lifted-stdlib-snapshots` drift gate.
- **List**: 16 combinator bodies lifted. **Either**: 10 combinators (types **and**
  bodies; 10 `stdlib_env` rows removed) — the doc's "biggest win".
- Net: trusted hand-written `.rkt` core 303→265 code lines; `stdlib_env` 162→152.

## Deferred items
1. **Dict (29 `stdlib_env` rows) / Set (24)** — combinators operate on Racket
   hash/set internals **and** carry proof machinery (`filterCheck`,
   `get`/`requireKey`, `ForAll`). Plan: split `<mod>-prim.rkt` (hash/set leaves +
   proof ops), write `<mod>.tesl` rebuilding via `toList`/`fromList`, one module at
   a time, same gate. Materially more work and **higher drift risk** than
   List/Either — sequence carefully and parity-test every combinator.
2. **Int** — liftable subset (`min`/`max`/`clamp`/`sign`/`isPositive`/`isNegative`/
   `isZero`/`isEven`/`isOdd`) needs no prim split (operator-only bodies), but only
   `min`/`max` currently have `stdlib_env` rows; the rest lack type rows (a
   pre-existing inconsistency). Net win is negligible. Plan: lift `min`/`max`
   trivially; separately add the missing type rows if desired.
3. **Maybe / Result** — **nothing to lift**: `tesl/maybe.rkt` / `tesl/result.rkt`
   are ~7-line ADT-constant re-exports with zero combinators and zero `stdlib_env`
   rows (constructors live in `dsl/types.rkt`). No action.

## Verification bar
Per module: `test_integration` 58-lesson byte-exact 0-differ, `gen-stdlib-rkt.sh
--check` up-to-date (no drift, no absolute paths), a behavioral parity test
(lifted body == prior hand-written Racket), diagnostics held, differential green.
