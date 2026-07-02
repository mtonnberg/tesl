# Enforce `exposing` for facts under bare `import Mod`

## Why
**LB-01 (med):** under bare `import Mod` (import-all), a library's `exposing` list is
not enforced for **fact/predicate** names — non-exposed proof predicates leak into the
consumer, undermining single-owner predicate identity at the module boundary.

## Fix
Apply the same `exposing`-membership check to imported fact/predicate names that
already governs value/type imports, for both `import Mod` and `import Mod exposing [..]`.

## Tests
consumer references a non-exposed fact of an imported module → REJECTED; exposed fact
→ accepted; re-export facade still works.

## Status: CARVED → `roadmap/later/review_2026_07_deferred.md` §5 — 2026-07-02
