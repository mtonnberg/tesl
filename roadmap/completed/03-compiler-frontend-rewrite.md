# Compiler Frontend Rewrite
## Goal
Replace the Python frontend with the OCaml frontend without changing TESL semantics, diagnostics, or generated Racket behavior on the supported lesson/example surface.
## Status as of 2026-03-29 (COMPLETE)
All exit criteria are met. The OCaml frontend is green across all compiler tests (403 tests in 10 executables), all 33 checked-in lesson `.rkt` files match the OCaml output exactly, the OCaml `--ir` output is the default for `tesl generate ir/ts/elm`, and the TS/Elm downstream generators have been verified to work correctly with the OCaml IR (including `proof_tree` for multi-fact record fields).
## Verified checkpoints
The following were verified in the final completion pass:
- all 10 OCaml compiler test executables pass (403 tests total):
  - `test_lexer.exe` 28, `test_parser.exe` 42, `test_emit.exe` 35, `test_integration.exe` 82,
    `test_advanced.exe` 28, `test_types.exe` 67, `test_proofs.exe` 31, `test_validation.exe` 40,
    `test_diagnostics.exe` 5, `test_ir.exe` 45
- 33/33 checked-in lesson `.rkt` files match the OCaml output (enforced in `test_integration.ml`)
- `test_ir.exe` now covers: endpoints, facts, records (with `proof_tree`), ADTs, newtypes, entities, codecs, module metadata, constraint patterns (gte/lte/gt/lt/starts_with/regex/contains), and real `todo-api.tesl` structure in detail
- `proof_tree` JSON field added to record fields in `ir.ml` — enables correct `&&`/`||` chaining in TS (`SafeSchema.and(ShortSchema)`) and Elm (`And P1 P2`) emitters
- `tesl generate ir/ts/elm` now prefers the OCaml compiler via `_tesl_emit_ir` helper in `shell.nix`; falls back to Python only when the OCaml binary is not built
- `tesl generate ts example/todo-api.tesl` and `tesl generate elm example/todo-api.tesl` verified to produce correct output driven by the OCaml IR
## Architecture
```
compiler/lib/ — location.ml, ast.ml, token.ml, lexer.mll, parser.ml, emit_racket.ml, compile.ml, ir.ml
compiler/bin/ — main.ml (CLI: compile/--check/--check-json/--ir)
compiler/test/ — 10 test files (403 tests total)
```
## Exit criteria — all satisfied
- [x] the OCaml frontend remains green on the full compiler test executable set
- [x] the checked-in lesson `.rkt` files all match the OCaml output
- [x] the important Python frontend test surfaces have direct OCaml equivalents
- [x] the OCaml frontend is the trusted default compiler path for the example/validation workflow
- [x] the Python frontend can be removed without losing behavior, diagnostics, or tooling compatibility
## What remains Python-only (not blocking removal)
- `lint` and `fmt`/`fmt-check` commands — OCaml has no linter or formatter yet; these fall through to Python
- `validate` uses OCaml for check but Python for lint/fmt-check
- `emit_ts.py` and `emit_elm.py` downstream generators — these are standalone IR consumers, not part of the frontend; they are driven by the OCaml `--ir` output
