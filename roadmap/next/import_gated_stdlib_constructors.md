# Bare stdlib CONSTRUCTORS are not import-gated

## Status: OPEN. Found 2026-08-05 while landing `Tesl.CivilTime` (GitHub #78).

A stdlib ADT constructor resolves in a module that never imported its module.
`tesl check` reports nothing:

```tesl
module Noimport exposing [f]

import Tesl.Prelude exposing [Bool(..), Int, String]   # no Tesl.CivilTime import

fn f(n: Int) -> Bool =
  case Monday of
    Monday -> True
    _ -> False
```
```
$ tesl check noimport.tesl
(no output — 0 errors)
```

Every other spelling of the same mistake is already caught. The FUNCTION case is
a model diagnostic:

```tesl
fn f() -> String =
  Money.currencyCode (Money.usd 100)      # no import Tesl.Money
```
```
error[T001]: function `Money.usd` requires `import Tesl.Money`
             (or `import Tesl.Money exposing [Money.usd]`)
```

So this is not a missing gate — it is one existing gate with a hole in its input,
and the hole is documented in the code that has it.

## Why it happens

`Checker.check_stdlib_fn_import_scope` (`checker.ml:6366`) is the gate. It is fed
by `collect_stdlib_fn_uses` (`checker.ml:6309`), whose recorder says so directly:

```ocaml
(* Per-NODE recorder: a module-qualifier field access (Dict.lookup) or a bare
   gated value (initTelemetry / mockProvider).  Bare constructors are never
   recorded because they are absent from the home-module registry. *)
```

`record` drops any name for which `Type_system.stdlib_home_module_of` is `None`
(`checker.ml:6315`), and that registry (`type_system.ml:1814`, built at
`:1802-1810` from `stdlib_bare_home_module` plus the DOTTED export rows) has no
constructor rows. Constructors get their TYPES from `stdlib_env`, which is a flat
global namespace with no import in it, so the name type-checks and nothing else
ever asks where it came from.

## What it costs

**1. Type-checks, then unbound at runtime.** Emission drives its Racket
`require` list off the imports, so a module that never imported `Tesl.CivilTime`
emits no require for it and the generated module cannot resolve `Monday`. This is
the same "import-gated names outside the allowlist still typecheck-but-unbound"
class as the `env*` builtins fixed at `checker.ml:3476` — constructors are the
part of that class still open.

**2. It leaked into an unrelated module's exhaustiveness.** `Tesl.CivilTime`
exports `Weekday` (`Monday`…`Sunday`) and `Month` (`January`…`December`). Because
the constructor rows in `Validation_common.builtin_ctor_info` are global,
`example/learn/lesson02-adts-and-pattern-matching.tesl` — which declares its own
`type Weekday = Mon | … | Sun` and imports no calendar module — was told:

```
error[V001]: non-exhaustive case: missing constructor(s)
             [Monday, Tuesday, Wednesday, Thursday, Friday, Saturday, Sunday]
```

That symptom is already fixed, but by resolution rather than by import scope:
`build_ctor_info` (`validation_common.ml:877`) now drops builtin rows whose
result type the module DECLARES ITSELF. That is correct and worth keeping — a
redeclared name is a different type — and it is deliberately not import-gating,
because a case can scrutinise a stdlib ADT that arrives from an imported
function without naming the type locally, and dropping the rows there would
silently disable exhaustiveness (fail-open). The hazard was latent for every
stdlib ADT name (`HostClass`, `EmailBody`, `DeleteResult`); common calendar words
are just the first ones a user was likely to pick.

**3. Shadowing is already handled and must stay handled.** A module that BOTH
declares `Weekday` and imports the stdlib's gets
`error[V001]: top-level type `Weekday` shadows imported type from module
`Tesl.CivilTime`` from `check_name_shadowing`. The fix below must not weaken it:
declare+import is a collision, declare-without-import is not.

## What "done" looks like

A bare constructor reference resolves ONLY if its module is imported, with the
exposing list respected (`Weekday(..)` brings the constructors; `Weekday` alone
does not), and an unimported reference produces the guided error the function
case already produces. `Import_suggest.stdlib_modules_exporting`
(`import_suggest.ml:90`) already reads `Type_system.tesl_module_exports` and
covers "types, constructors, proof predicates", so the message and its
machine-applicable import fix need no new tables — only the name has to stop
resolving first.

Sketch, in dependency order:

1. Give the home-module registry constructor rows — derived from
   `tesl_module_exports` (which already lists every constructor) rather than
   hand-listed, so a new stdlib ADT cannot be forgotten.
2. Record bare constructor references in `collect_stdlib_fn_uses`. The
   `bound`-name suppression is already there, so a user's own constructor of the
   same name still wins.
3. Decide the always-available set explicitly. `Bool(..)`, `Maybe`, `Result`,
   `Either` and the Prelude names must not become import errors —
   `Type_system.always_available_stdlib_names` is the existing seam for that
   judgement.
4. Handle the CONFIG-ONLY constructors, which are the reason this needs care
   rather than a one-line change: the 489 IANA `TimeZone` constructors, the
   currency codes and the SI unit names are exported values that appear in config
   blocks, and `Import_suggest` already has a special case for them
   (`import_suggest.ml:262-276`: "a config-only stdlib name … can never become a
   legal type by importing its stdlib home module"). Gating those the same way
   would demand imports nobody writes today.
5. Measure the corpus fallout BEFORE choosing the error's severity: prototype the
   gate, run `./ci.sh`, and count the files that rely on an ungated constructor.
   The number decides whether this lands as an error or as a warning first.

## Why it was not bundled with #77/#78

It is a change to how EVERY stdlib name resolves, and its blast radius is the
whole corpus — measured in step 5, not guessed. #77 (single-line SQL clause
placement) and #78 (`Tesl.CivilTime`) are done and gated; this is the one finding
from that work left open, and it deserves its own gate run.

## Repro kept for the fix

`case Monday of Monday -> True; _ -> False` with no `Tesl.CivilTime` import must
become an error naming the import. The function counterpart
(`Money.usd` with no `Tesl.Money` import) is the message to match.
