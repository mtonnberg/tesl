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

## Status: DEFERRED to `roadmap/later` (decision 2026-06-30, core_polish)
Critically examined against the overarching goal of this cycle — a **smaller, more
stable** core — none of the remaining candidates earn their cost:

- **Int (`min`/`max`)**: operator-only, trivially liftable — but lifting it would
  **add files** (`int.tesl` + `int-derived.rkt` + a `gen-stdlib-rkt.sh` LIFTED
  entry + a CI drift-gate line) to remove **~4 lines** from `int.rkt`. Net result
  is *more* surface and more moving parts, the opposite of "smaller core". The doc
  itself rates the win "negligible". Not worth it.
- **Dict (29) / Set (24)**: the doc rates these "materially more work and **higher
  drift risk**" — they touch hash/set internals **and** proof machinery
  (`filterCheck`, `requireKey`, `ForAll`) on the most heavily-used stdlib modules.
  Adding drift risk to hot, proof-bearing stdlib is squarely against "more
  **stable** core". A lift here trades real risk for a small reduction in the
  hand-written line count.
- **`foreign fn`**: DECLINE. Adding a host-FFI form introduces a new trust boundary
  and surface; the security audit explicitly lists "**no user-facing FFI**" as a
  *strength*. It closes no real gap. A genuine primitive gap (e.g. password
  hashing) should be added as a specific primitive, not a general FFI.

The "why" (shrink the trusted hand-written Racket core) is understood and was a
legitimate driver for the List/Either lifts already shipped — but for the
*remaining* modules the cost/risk is net-negative for this cycle's stability goal.
Revisit if the trusted-core size becomes a pressing concern and the drift gate
(now extended to all of `example/` + `tests/`, see `snapshot_drift_gate`) plus
per-combinator parity tests make Dict/Set lifts provably safe.
