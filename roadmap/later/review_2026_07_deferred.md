# 2026-07 review — OPEN items only

## Updates

**Decision** Since adding type classes to the language is a large decision (on how the language will evolve and it could make the learning curve much steeper, we will wait with this since this is a language expansion)

# Background

Closed work has moved to `roadmap/completed/review_2026_07_closed_items.md` (and the
per-topic files in `roadmap/completed/`). This file lists only what remains. Each is
unblocked but touches soundness-critical or broad-impact code, so it needs its own
verified pass — a rushed change would risk false-positives/regressions and worsen DX.

> **PFC-2 is now CLOSED** (a0 construction enforcement + a field-proof propagation +
> b container producer check) — see `roadmap/completed/review_2026_07_closed_items.md`.

### Larger engineering (multi-step)
1. **TS-ORD/EQ — principled decidability** (`type_decidability_ord_eq.md`).
   **#3 CLOSED (2026-07-02):** `is_equatable` now recurses through record/ADT
   fields, so a record/ADT that transitively contains a function is non-equatable
   (`record Handler { callback: (Int -> Int) }; a == b` rejected; plain records
   still `==`). Two sub-holes REMAIN, both needing the deferred Eq/Ord layer:
   **#1** stdlib-result non-orderable types (`String.toInt a < String.toInt b`,
   `Maybe Int`) leak because the shadow `infer_expr_type` doesn't know stdlib return
   signatures — the clean fix is to consume the HM checker's resolved types (a
   per-fn table would be the drift-prone anti-pattern); **#2** functions via a
   generic `TVar` helper (`genLt f f`) — needs `Eq`/`Ord` as qualified types in HM
   generalization/instantiation (TVar is deliberately permissive per the S14b
   maintainer decision; a blunt fail-closed guard over-rejects valid generic code).

### Moderate — additive checks needing careful false-positive verification
1. ~~**CAP-UUID** — `uuid` uncharged statically; **currently masked** by a separate~~
   ~~`unit -> T` parse/type bug that makes `UUID.v4/v7` uncallable (fix together).~~
   Completed
2. ~~**DRIFT-1 — DONE (2026-07-02):** the whole `Tesl.Cli` module was removed (config~~
   ~~is env-vars-only); `import Tesl.Cli` and bare `cli.args` are now compile-time~~
   ~~errors, closing the typecheck-but-unbound-at-runtime drift. `todo-api` migrated~~
   ~~to env-var port resolution. See `roadmap/completed/review_2026_07_closed_items.md`.~~
   completed

