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

---

## Known debt: `jwt` gates a pure function (recorded 2026-07-29, NOT to be "fixed")

**The ruling, established when `Tesl.Crypto` landed:** *a capability marks an **effect**.
Sensitivity is carried by types and proofs, which track the **value** rather than the function.*

`Tesl.Crypto` follows it exactly — only `hashPassword` (draws a salt) and `randomToken` are gated,
both on the existing `random`, and `signWith` / `checkSignature` / `checkPassword` / `needsRehash` /
`fingerprint` / `keyFingerprint` are ungated because they are pure. They consume key material, and
that sensitivity lives in `Secret` and in the facts.

**`Tesl.JWT` contradicts the rule.** `JWT.sign` is a pure HMAC over a claims dict and `JWT.verify`
is a pure HMAC comparison, yet both require the `jwt` capability. By the rule they should require
nothing.

**This is deliberately left alone.** Removing a capability is a **breaking change to every
`requires [jwt]` in the wild** — a declaration that becomes unnecessary is a compile error under the
unused-capability checks, so every existing JWT program would need editing for zero safety gain.
The cost is real and the benefit is aesthetic.

So the position is: **`jwt` is grandfathered, and the rule is not to be inferred from it.** Anyone
adding a stdlib surface should follow `Tesl.Crypto`'s pattern, not `Tesl.JWT`'s. `Type_system`'s
`stdlib_capabilities` and `compiler/test/test_capability_registry.ml`'s oracle both carry a comment
saying so, and the oracle fails if a pure Crypto function is ever gated — which is the actual
enforcement.

If `jwt` is ever removed, do it at a major version with a release note, and expect it to touch every
JWT example and lesson.
