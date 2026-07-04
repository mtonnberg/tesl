# E1 — Import ceremony is heavy and self-defeating (carved from tooling follow-ups)

**Status:** tracked feature follow-up (carved 2026-07-04 from
`tooling-and-ergonomics-followups.md`, per the maintainer's "bounded infra only"
decision — T2 and E3 shipped in that pass; E1 is a deliberate language-design change
best made intentionally, so it lives here).

## The friction
Even `Int`/`String` must be hand-imported from `Tesl.Prelude`, and unused imports are
then flagged (W050) — so import lists must be hand-pruned constantly, and several
flagship examples ship with W050 warnings. This is first-run friction for the target
TS/C#/Java developer.

## Options (a design choice, not a bug-fix)
- **(a) Implicit always-in-scope Prelude** for the ubiquitous primitives (`Int`,
  `String`, `Bool`, `Unit`, …). Changes name resolution: the checker/parser must treat
  those names as in scope without an import, and W050 must not flag the (now-absent)
  import. Blast radius: `checker.ml` scope seeding, the import-scope checks, W050, and
  every example's import list. Requires deciding exactly which names are implicit and
  whether an explicit import is still permitted (and then a no-op, not a W050).
- **(b) `--lint --fix` / `--fmt` auto-prune (and auto-add) imports.** No `--fix` action
  exists today. A bounded-but-new tool: compute the W050 unused set + the unbound-name
  set and rewrite the `exposing [...]` list. Lower blast radius than (a) — no
  name-resolution change — but a real new codepath (import rewriting in the
  formatter/linter, careful with multi-line `exposing` lists — `reflow_exposing_lists`
  already handles their layout).
- **(c) Both.**

## Why deferred
Not a soundness item, and not a bounded fix: (a) is a name-resolution semantics change
touching the checker + every example; (b) is a new `--fix` codepath. Both warrant a
deliberate decision on scope/opt-out before implementation. The rest of the review's
tooling follow-ups (T1 occurrences-line-0, T2 fmt→lint fixpoint, T3 JSON-shape docs,
E2 codec over-teaching, E3 docs single-line-if + block-aware lint) shipped 2026-07-04.

## When picked up
Decide (a) vs (b) vs (c) with the maintainer. If (b): add a `--lint --fix` (or a
`--fmt` pass) that prunes W050 imports and adds unbound-primitive imports, reusing
`reflow_exposing_lists` for layout; guard with a test that an over-broad import list
fmt-fixes to the minimal set. If (a): seed the implicit primitives in the checker's
base env, exempt them from the import-scope + W050 checks, and re-baseline the example
corpus's import lists.
