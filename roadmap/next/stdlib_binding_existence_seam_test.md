# Durable seam test: every stdlib name resolves to a real runtime binding

Preventive guard carved out of [[stdlib_surface_binding_drift]] (all concrete
instances of that bug are fixed and the doc is in roadmap/completed). This item
is the *durable* fix — the guard that stops the whole class recurring.

## Why

The `env-builtins-import-soundness` / stdlib-surface-drift class keeps recurring
(email cap, `randomFloat`, `generateId`, `Dict.delete`, `newId`, `mapCheck`,
`randomInt` arity — all 2026-07-06) because a stdlib name lives in several
hand-maintained tables that drift: the `Type_system` import allowlist
(`tesl_module_exports`), the `stdlib_env` type table, and the runtime `.rkt`
`provide` lists. A name present in the first two but missing from the third
**type-checks then crashes at Racket load with "unbound identifier"** — invisible
to the gate because no example happens to use it.

`test_capability_registry.ml` already pins the *capability-charge* table against
an oracle, and `test_fail_closed_hardening.ml` pins builtin-caps ≡ stdlib
providers. The missing guard is **binding existence**: name → real runtime
provide.

## Deliverable

A seam test asserting, for every stdlib name the checker will accept an import
of, that it resolves to an actual runtime binding.

Recommended shape (robust, avoids fragile grep of `provide` forms):
1. OCaml side: enumerate the expected `(module → [names])` from
   `Type_system.tesl_module_exports` ∪ the `stdlib_env` keys mapped through
   `stdlib_home_module`. Dump to a file, or expose via a small function.
2. Racket side: for each stdlib module's `.rkt` (from `emit_racket`
   `module_path_table`), use `(module->exports (string->path rkt))` to get the
   REAL provided identifier set (this correctly includes re-exports like
   `all-from-out`, `struct-out`, and the `list.rkt`→`list-prim`/`list-derived`
   shim chain — a plain grep would miss these). Assert expected ⊆ actual.
3. Fail listing any name that is importable/typed but not provided.

Optionally also add the **cap-coverage** direction (every runtime
`require-capabilities!` site has a matching `stdlib_capabilities` charge and
vice versa) to fold in the Class-B consistency from the parent doc — but note
the Tesl.ApiTest queue helpers (`drainQueue` etc.) are intentionally uncharged
and not exploitable (queue names don't resolve outside test scope); either
exclude them or decide the charge-vs-restrict question first.

## Verification

The test must pass on the current tree (all Class-A instances are already
resolved, so the surface is clean). Then prove it BITES: temporarily remove one
runtime `provide` (e.g. `Dict.delete`) and confirm the test goes red naming that
name; restore. `./ci.sh` 13/13.
