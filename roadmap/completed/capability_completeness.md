# Capability completeness — DONE (2026-07-02)

> All items landed: **CAP-COMPOSE** (whole-program grant coverage, earlier),
> **CAP-01** (qualified calls to imported effectful fns now charged — regression
> `CAP01` in test_review74_misc), **CAP-UUID** (UUID.v4/v7 callable + uuid-gated —
> regression `R75_CAPUUID`), **DRIFT-1** (Tesl.Cli removed). See
> `roadmap/completed/review_2026_07_closed_items.md`. Full gate green.


CAP-COMPOSE is **done** (whole-program grant coverage) — see
`roadmap/completed/review_2026_07_closed_items.md`. What remains:

- **CAP-01 (high):** a qualified-name call to an imported effectful function can
  escape the transitive capability charge (asymmetry with unqualified calls in the
  effect-collection walk). Fix: charge qualified effectful calls the same as
  unqualified in `collect_needed_capabilities`.
- **CAP-UUID (high):** `UUID.v4/v7` need `uuid` at runtime but have no arm in the
  static effect map (`var_caps`) — dual hand-maintained registries with no
  cross-check. **Currently masked:** `UUID.v4/v7` are uncallable due to a separate
  `unit -> T` parse/type bug (`UUID.v7()` → "cannot unify Unit with List a"), so the
  fix is unverifiable until that bug is fixed — fix them together, and ideally
  single-source the compile-time allowlist and the runtime `require-capabilities!`
  primitive set so they cannot drift.
- **DRIFT-1 — DONE (2026-07-02):** the whole `Tesl.Cli` module was removed (config
  is env-vars-only). `cli.args`/`lookupPortArgument` deleted from `stdlib_env` and
  the import-module list (`type_system.ml`), the `cli.args` field-emit path and the
  `Tesl.Cli`→`tesl/cli.rkt` mapping deleted from `emit_racket.ml`, and the runtime
  `tesl/cli.rkt` + `tesl-cli-args`/`tesl-lookup-port-argument` (`runtime.rkt`)
  removed. Both `import Tesl.Cli` ("unknown stdlib module `Tesl.Cli`") and a bare
  `cli.args` ("unknown name: cli") are now compile-time errors — the former
  typecheck-but-unbound-at-runtime drift is gone. `todo-api` migrated to
  env-var port resolution (`TESL_TODO_API_PORT`, then `PORT`, then default 8086);
  `.rkt` regenerated. See `roadmap/completed/review_2026_07_closed_items.md`.


## Tests
Negative for each; positive controls (correctly-declared programs still compile+run).
