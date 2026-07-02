# CAP-A2 / A2-part2 — per-handler runtime capability narrowing (WON'T DO / discarded)

> Relocated 2026-07-02 from `close_all_open_issues.md` (Wave 1, item A2-part2).
> Backlog ID: **CAP-A2** (`stability_deferred_backlog.md`). Review §4.1, §10 item 2.

## Disposition: DISCARDED (maintainer decision, 2026-07-02)

**The soundness hole is already closed at compile time; the runtime narrowing is a
safety-net Tesl deliberately does not want.** Do not implement it.

- The *actual* fix, **A2-part1 (compile-time, landed `84b55c9`)**, makes capability
  laundering through `auth`/`check`/`establish` bodies a **compile error** — the §4.1
  exploit (a read-only endpoint whose `check`/`auth` body performs an undeclared
  `dbWrite`) can no longer be written; the effect must be declared in the signature.
- **CAP-A2 (this item)** is only the *runtime* half: narrow the ambient capability set
  per handler so `declared == enforced` at run time. That is pure defense-in-depth
  **behind** the compile-time check.

Given a sound compile-time check, CAP-A2 adds nothing to soundness. The compiler proves
every function declares the capabilities it uses (directly + transitively), so
`used ⊆ declared` for every function and the ambient union can never gate a
legitimately-declared effect. Runtime narrowing could only catch an effect the *static
checker missed* — i.e. it is a backstop for a compiler bug. That is exactly the
"runtime re-verification net" Tesl's design rejects: **single-mode erasure, the compiler
is the sole contract, and the runtime safety-net is to be removed, not grown.** Adding
runtime narrowing moves in the wrong direction.

## The one invariant to preserve (this is where the guarantee lives)

Discarding CAP-A2 is safe **iff the static capability check stays sound and complete**:
1. Every effect-producing primitive is capability-gated (SQL read/write, email, http,
   jwt, pubsub, aiProvider, env, time, random, …).
2. Every function-kind's body is statically capability-checked. A2-part1 closed the last
   gap by making `cap_check_kind_info` (`validation_capabilities.ml`) an **exhaustive
   match** over `func_kind`, so a newly-added function kind is a *compile error* until it
   is classified — completeness is enforced-by-construction, not hoped for.
3. Each function declares its own transitive effects (handler bodies, `auth` via-fns,
   `check`/`establish` bodies, and their callees) — verified today.

If a future change adds a new effect primitive or a new declaration kind that can execute
effects, it must be capability-gated / checked (the exhaustive match forces the latter).
Guard *that* invariant; do not resurrect runtime narrowing.

## Historical record — why the runtime narrow was reverted (`e6328b2`)

A naive narrow (`declared ∩ ambient` per handler) is unsound in the *opposite* direction:
a handler's emitted `requires` row is not its complete runtime capability set. The gate's
`tesl test` step caught two regressions:
- **SSE `pubsub`** — pub/sub runs under the handler context but its grant is not in the
  handler's `requires` row; the narrow denied it.
- **kanel `listMyOrgsHandler` `db-read`** — the handler's `auth` via-fn does a DB read; the
  capability belongs to the auth function, not the handler's declared row; the narrow
  denied it.

These confirmed that per-handler narrowing would require *complete per-callsite* inference
(transitive + auth-body + server-scoped grants) — a large prerequisite whose only payoff is
a redundant runtime net. Hence: discard.

## If ever reconsidered

Only relevant if the direction reverses (keep/grow a runtime capability net instead of
erasing it). Then the prerequisite is complete per-callsite capability inference before any
narrowing flip. Not planned.

## Refs

- Review: §4.1 (read-only endpoint performs unauthorized DB writes), §10 item 2.
- Backlog: `stability_deferred_backlog.md` → **CAP-A2**.
- Source: `capability.rkt` (`call-with-declared-capabilities` — stays a subset-assertion),
  `validation_capabilities.ml` (`cap_check_kind_info` — the exhaustive static check).
- Static fix landed: `84b55c9` (A2-part1). Runtime narrow reverted: `e6328b2`.
