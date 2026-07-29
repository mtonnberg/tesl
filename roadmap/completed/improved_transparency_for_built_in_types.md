# Improved transparency for built-in types

**Status: COMPLETED 2026-07-29.** compiler/lib/stdlib_docs.ml (logic) + stdlib_docs_entries.ml (~430 hand rows) + generated capability/config/family entries; `tesl doc` + `--doc-json` in main.ml and listed in `tesl --help`; LSP hover priority 2 queries --doc-json first (memoized), stdlib-sigs hash kept only as keyword/SQL fallback; seam tests in test_stdlib_docs.ml enforce coverage + scheme-arity by construction; manual/GETTING-STARTED.md documents the command.

## Background

A developer using Tesl outside this repo cannot see what a builtin type or
function really looks like. `SmtpConfig`'s fields exist only in an OCaml
validation schema; `Email.send` is a parser special form whose signature exists
only as spec prose; hovering either in the editor shows nothing. Record/ADT
shapes are the worst case: without them it is guesswork how to "please" the
compiler, which breaks the fundamental Tesl goal of helping the developer
forward.

Today the builtin surface is scattered across four unsynchronized
representations:

- `type_system.ml` `stdlib_env` — types (curried schemes, **no parameter
  names**), ~263 rows.
- `type_system.ml` `tesl_module_exports` — names per module, no types.
- `editor/tesl-lsp/tesl-lsp.rkt` `stdlib-sigs` — ~298 hand-written Tesl-syntax
  hover strings, ~60% module coverage (no `Tesl.Email`, `Tesl.JWT`,
  `Tesl.Money`, ...), silently drifting.
- `validation_structural.ml` `config_block_schema` — config record fields in a
  bespoke validation DSL.

Special forms (`Email.send`, `Cache.get`, `select`, `telemetry`, ...) have no
machine representation at all.

## Goal

Every builtin type and function — whether declared in Tesl or implemented in
Racket — is viewable by a developer in their own project, expressed in Tesl
syntax, via:

1. **CLI**: `tesl doc` (module index), `tesl doc Tesl.Email` (module surface),
   `tesl doc Email.send` / `tesl doc SmtpConfig` (single item). The command is
   listed in `tesl --help` so people and AI agents discover it.
2. **Editor hover**: every builtin name hovers to its Tesl signature; the
   hand-maintained Racket `stdlib-sigs` hash is replaced by a compiler query so
   it can never drift again.

Coverage is enforced by construction: a test fails if any exported builtin
name lacks a signature.

## Design

**Single source of truth: a signature catalog in the compiler**
(`compiler/lib/stdlib_docs.ml`): for each stdlib module, for each export, a
Tesl-syntax signature (with parameter names) plus a one-line doc. Record and
config-block types get full Tesl declarations (`record SmtpConfig { host:
String, port: Int, ... }` with optional-field and constraint notes); builtin
ADTs get full `type` declarations (e.g. `EmailBody = TextBody String | ...`);
special forms get a signature-shaped entry marked as a syntax form.

**Anti-drift, enforced by tests (the load-bearing part):**

- every function entry's signature is parsed and its type checked ≡ the
  `stdlib_env` scheme (a hand-written signature that disagrees with the
  checker fails the build);
- every name in `tesl_module_exports` + `always_available_stdlib_names` has an
  entry (generated constructor families — TimeZone zones, currencies, units —
  are documented per family);
- config-record entries are generated from `config_block_schema`, not
  hand-copied.

**Plumbing:**

- `tesl doc <name>` resolves bare, dotted, and type names; module pages group
  entries by section; output is plain Tesl code blocks.
- `--doc-json <name>` gives the LSP the same payload; hover priority 2 in
  `tesl-lsp.rkt` calls it (the LSP already shells out to the compiler for
  type-at/field-at), deleting the 320-line Racket hash.
- Lifted stdlib modules (`tesl/list.tesl`, `tesl/either.tesl`) already carry
  real Tesl signatures — the catalog reads those, it does not duplicate them.

## Verification

- Consistency tests above (signature ≡ scheme, coverage, config generation).
- CLI tests: `tesl doc SmtpConfig`, `tesl doc Email.send`, `tesl doc
  Tesl.Email`, unknown-name suggestion.
- LSP test: hover on `Email.send` and `SmtpConfig` returns the Tesl signature.
- `./compile-examples.sh` + `dune test` green.
