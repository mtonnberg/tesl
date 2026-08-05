# Bare stdlib CONSTRUCTORS are import-gated

## Status: DONE 2026-08-05. Found 2026-08-05 while landing `Tesl.CivilTime` (GitHub #78).

A stdlib ADT constructor resolved in a module that never imported its module, and
`tesl check` reported nothing:

```tesl
module Noimport exposing [f]

import Tesl.Prelude exposing [Bool(..), Int, String]   # no Tesl.CivilTime import

fn f(n: Int) -> Bool =
  case Monday of
    Monday -> True
    _ -> False
```
```
$ tesl check noimport.tesl        # (no output — 0 errors)
$ raco expand noimport.rkt        # Monday: unbound identifier
```

Now:

```
error[T001]: constructor `Monday` requires `import Tesl.CivilTime`
             (or `import Tesl.CivilTime exposing [Weekday(..)]`)
```

with the machine-applicable import fix `Import_suggest.build_fix` already
provides for the function case.

## Why it happened

`Checker.check_stdlib_fn_import_scope` was the gate; `collect_stdlib_fn_uses` was
its input, and the input had the hole — documented in the code that had it:
`record` dropped every name for which `Type_system.stdlib_home_module_of` was
`None`, and that registry (built from the DOTTED export rows) had no constructor
rows at all. Constructors got their TYPES from `stdlib_env`, a flat global
namespace with no import in it, so the name type-checked and nothing else ever
asked where it came from.

## The rule as shipped

A bare, capital-initial, dot-free stdlib name used in a module resolves ONLY if
one of its home modules is imported. Satisfying spellings, all three verified
against `raco expand`:

| spelling | brings the constructors? |
|---|---|
| `import Tesl.CivilTime` | yes |
| `import Tesl.CivilTime exposing [Weekday(..)]` | yes |
| `import Tesl.CivilTime exposing [Monday]` | yes (the constructor named directly) |
| `import Tesl.CivilTime exposing [Weekday]` | **no** — the type only |

Decisions taken, each of them load-bearing:

1. **EVERY reference position counts, including patterns.** Value positions are
   where the runtime bites (the emitter builds its `require` list from the
   imports, so an unimported constructor is unbound at load). A pattern emits a
   quoted variant tag and needs no binding — but it is gated anyway, so the rule
   is one rule and a module's import list stays a complete, greppable inventory
   of the stdlib surface it uses. Covered positions are pinned individually in
   `test_import_gated_ctors.ml`: `let` value, `if` branch, list element, record
   field, lambda body, `case` guard, nested sub-pattern, test-block statement,
   top-level binding, and both `case` scrutinees and arm patterns.
2. **No stdlib module is ambient.** `Nothing`/`Something`, `Ok`/`Err`,
   `NoRowDeleted`/`RowsDeleted` and the `String` type-name symbol HAPPEN to be
   bound with no import, because the always-emitted dsl/runtime + Prelude +
   dsl/sql requires provide them. That accident is not a licence: the 13 corpus
   modules that relied on it were given the import they were missing.
   `Type_system.always_available_stdlib_names` now holds only what no module
   provides — operators, the Prelude literals (`True`/`False`/`Unit`), and the
   GDP proof utilities.
3. **Local declarations win, and are not shadowing.** A module declaring its own
   `type Either a b = Left … | Right …` (learn lesson37) or its own
   `type Weekday = Mon | …` is untouched: `collect_bound_names` now collects local
   ADT constructors, newtype/alias names, records and entities. Declaring AND
   importing the same name remains the separate `check_name_shadowing` error.
4. **A constructor may have several home modules.** `Left`/`Right` are exported by
   both `Tesl.Either` and `Tesl.EitherPrim` (the lifted-module split that breaks
   the require cycle), so the registry maps a name to a LIST and any one import
   satisfies it — `tesl/either.tesl` imports only the prim. The diagnostic names
   the others ("also exported by …").
5. **Config-only names are NOT gated.** The 489 IANA `TimeZone` constructors, the
   ISO 4217 currency constructors, the config-block markers, the SI aliases and
   the Sso provider constructors are `Stdlib_config_names.require_suppressed`:
   they emit no `require` under ANY import, so gating them would demand imports
   that cannot help. Config-block RHSs are also still not swept (they desugar at
   compile time), and `listenAddress Loopback` is a closed parser keyword set, not
   a reference to `Tesl.Net`'s `Loopback`.
6. **Module qualifiers are not values.** `Dict` in `Dict.lookup` parses as a
   nullary constructor; qualifier occurrences are collected first and skipped, so
   a qualified call does not demand an import for a value named `Dict`.

## Corpus fallout (step 5 of the original plan, measured not guessed)

13 files, all of them relying on an accidentally-ambient name or an under-narrow
exposing list, so the change landed as an ERROR rather than a warning:

- `Nothing`/`Something` with no `Tesl.Maybe` import — 9 lessons/tests
  (lesson06, lesson18, lesson19, lesson20, lesson21, lesson26, lesson32,
  lesson57, lesson71, `tests/query-parameters-tests.tesl`);
- `TextBody`/`HtmlBody`/`RichBody` under `import Tesl.Email exposing [Email,
  SmtpConfig, emailCap]` — lesson60, `example/user-service-api.tesl`,
  `tests/email-tests.tesl` (these WORKED, because an `email` block emits a
  wholesale require of the module — the import list was simply not telling the
  truth about what the module used);
- test fixtures in `test_email.ml`, `test_email_integration.ml`,
  `test_review47_antagonistic.ml`, `test_proofsuite_crossparam.ml`.

Every `.rkt` snapshot for the changed `.tesl` files was regenerated and re-checked
with `raco expand`.

## Single source (the class fix underneath)

Four consumers hand-listed stdlib ADT constructor groups, and each omission was
invisible from the others. Three are now DERIVED from the new
`Type_system.stdlib_adt_ctor_groups` (`(module, type, constructors)`):

- `Validation_names.stdlib_adt_ctors` — local-ADT collision + `Type(..)` exposing
  expansion;
- `Emit_racket.adt_constructors` — `Type(..)` → require expansion (this gained the
  missing `EmailBody` row);
- `Type_system.stdlib_ctor_home_modules` — the gate itself, derived from
  `tesl_module_exports` minus always-available minus config-only, so a new stdlib
  ADT is gated the moment its constructors are exported.

The fourth, `Validation_common.builtin_ctor_info`, needs per-constructor field
types and stays hand-written; the test asserts it COVERS the groups, with the two
pre-existing gaps (`DeleteResult`, `JobResult` — a `case` over them is not
exhaustiveness-checked) listed explicitly so closing one is a visible edit.

## Tests

- `compiler/test/test_import_gated_ctors.ml` — the repro; the four import
  spellings; every reference position, gated and then clean with `Maybe(..)`; the
  three no-false-positive shapes (local ADT, module qualifier, family form); the
  single-source derivations.
- `tests/stdlib-bare-name-gate.sh` (ci.sh phase 9d) — the RUNTIME ratchet, because
  the compiler tables are only a static approximation of "would this be unbound?".
  Per representative name: rejected without its import, and with the import both
  the check AND `raco expand` succeed; plus the always-available names really are
  bound. A gate that rejected the only working spelling would be worse than the
  hole, and only `raco expand` can catch that.

## Recorded, still open (found while measuring, out of this item's scope)

1. **Config-only constructors outside a config block.** `FixedOffset n` in a
   function body type-checks and is unbound WITHOUT an import; with
   `import Tesl.Time exposing [FixedOffset]` it expands (the import emits a
   wholesale module require). Since the name is `require_suppressed` it is not
   gated, so the no-import spelling stays typechecks-then-unbound. The right
   diagnostic is "config-only constructor cannot be used outside a config block",
   not an import demand.
2. **`Unit` in value position.** `Unit` is in `always_available_stdlib_names` and
   `case Unit of _ -> True` type-checks, but the emitted module has `Unit` as an
   unbound identifier. Same class, one name, no module to import.
3. **TYPE-position scope.** This item gated VALUE and PATTERN references. Whether
   a bare stdlib TYPE name in a type position is import-gated was not touched.
