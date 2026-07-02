# Capability completeness — remaining (open) items

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
- **DRIFT-1 (high):** ~~`cli.args` typechecks with no import but is unbound at runtime;~~
  ~~the import-scope guard skips lowercase module prefixes (`cli`). Fix must not~~
  ~~disturb other lowercase-prefixed stdlib names. (`todo-api` imports it correctly, so~~
  ~~only the unimported case is affected.)~~
  Remove the cli import, should not be possible and should not be part of the language. All config should be done via environment vars.


## Tests
Negative for each; positive controls (correctly-declared programs still compile+run).
