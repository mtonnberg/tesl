# Remove the ambient `emailCap` grant

**Status: COMPLETED 2026-07-29.** Grant sites removed (proof_checker.ml build_cap_map, validation_capabilities.ml build_local_cap_map, validation_common.ml collect_imported_cache_caps — renamed from collect_imported_cache_email_caps); P001 guidance now names the exact stdlib import; 3 repo programs migrated + .rkt snapshots regenerated; spec §20.2 shows the import; seam test: email block + no import still rejected (test_fail_closed_hardening.ml).

## Background

`emailCap` is the only capability with two grant paths. Every other builtin
capability (`time`, `dbRead`, `random`, ...) is granted exclusively by importing
its provider module with an explicit exposing list, e.g.
`import Tesl.Time exposing [time]`. `emailCap` can be imported the same way
(`Tesl.Email` provider row exists), but it is *also* granted ambiently: any
`email X = Email { ... }` declaration — even one in a transitively imported
module — implicitly declares `emailCap` for the whole program.

That ambient grant is a capability-visibility hole: a reader of a module that
says `requires [emailCap]` cannot see where the capability comes from, and the
grant leaks across module boundaries with no `exposing` gate.

`cacheCap <Name>` stays declaration-derived by design — it is parameterized by
the cache name and has no provider row; it is not part of this change.

## Goal

`emailCap` behaves exactly like `time`: the only way to make it available is
`import Tesl.Email exposing [emailCap]`. An `email` block alone grants nothing.

## Design

Delete the three `DEmail -> ("emailCap", [])` grant sites:

1. `compiler/lib/proof_checker.ml` — `build_cap_map`.
2. `compiler/lib/validation_capabilities.ml` — `build_local_cap_map`.
3. `compiler/lib/validation_common.ml` — `collect_imported_cache_email_caps`
   (drop the email half; keep the cache half), and rewrite the rationale
   comment above it (it currently justifies ambient email).

Keep the provider row `"Tesl.Email", [("emailCap", [])]` in
`tesl_stdlib_cap_map` — it becomes the only grant path.

Ergonomics: when an undeclared capability is a stdlib-provided one, the P001
guidance names the exact fix (`add import Tesl.Email exposing [emailCap]`)
instead of the generic "declare a capability" text.

## Migration

- 3 repo files use the ambient grant (`example/learn/lesson60-email.tesl`,
  `example/user-service-api.tesl`, `tests/email-tests.tesl`): add `emailCap` to
  their existing `import Tesl.Email exposing [...]` lists; regenerate the three
  committed `.rkt` snapshots.
- Tests: `test_email.ml` base imports gain `emailCap`; the test asserting the
  implicit grant ("email declaration implicitly defines the email capability")
  is inverted; `test_checker_multimodule.ml` email fixtures gain the import;
  `test_fail_closed_hardening.ml` gains a case: `email` block present + no
  import => still rejected.
- Docs: LANGUAGE-SPEC §20 email examples gain the import line (the spec
  currently never shows `import Tesl.Email`); lesson/intro fragments updated.

## Verification

- New checker tests: bare `email` block + `requires [emailCap]` => P001/V001;
  with `exposing [emailCap]` => accepted; transitive-import harvest no longer
  grants.
- `./compile-examples.sh` green; `dune test` green; Racket suite green.
