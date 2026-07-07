# E1 — Import ceremony is heavy and self-defeating (carved from tooling follow-ups)

**Status:** IMPLEMENTED 2026-07-07 (option d, per the design below; full gate
green — dune test, compile-examples.sh 13/13, scripted LSP code-action smoke).
New engine: `compiler/lib/import_suggest.ml`; regression tests:
`compiler/test/test_import_suggestions.ml` (11 cases).
Originally carved 2026-07-04 from
`tooling-and-ergonomics-followups.md`, per the maintainer's "bounded infra only"
decision — T2 and E3 shipped in that pass; E1 is a deliberate language-design change
best made intentionally, so it lives here.

## The friction
Even `Int`/`String` must be hand-imported from `Tesl.Prelude`, and unused imports are
then flagged (W050) — so import lists must be hand-pruned constantly, and several
flagship examples ship with W050 warnings. This is first-run friction for the target
TS/C#/Java developer.

## Options (a design choice, not a bug-fix)
- **(a) Implicit always-in-scope Prelude** — rejected: changes name resolution
  semantics; keeps Tesl's explicitness story intact matters.
- **(b) `--lint --fix` / `--fmt` auto-prune** — rejected as a standalone CLI tool;
  the machine-applicable edits land instead as structured diagnostic fixes that the
  LSP applies (same data could later back a CLI `--fix` if ever wanted).
- **(c) Both.**
- **(d) Guiding error messages + LSP autoactions** — **CHOSEN.** Keep explicit
  imports; make every import mistake self-repairing: the diagnostic says exactly
  which import to add/extend/prune, and carries a structured fix the editor applies
  in one keypress. Suggestions are not stdlib-only: sibling `.tesl` modules in the
  folder tree are scanned too.

## Design (what "smart" means concretely)

### Current state (mapped 2026-07-07)
- Diagnostics already carry `code` + optional structured `fix`
  (`compile.ml` `diagnostic_fix`, single variant `Replace_line`); the LSP
  (`editor/tesl-lsp/tesl-lsp.rkt`) already turns fixes into quickfixes,
  `source.fixAll`, and `source.organizeImports` (`diag->fix-edit`,
  `code-actions`). Gap: import-related diagnostics all ship `fix = None`.
- Good messages already exist for: stdlib fn needs import
  (`check_stdlib_fn_import_scope`), type not in scope (`check_type_names_in_scope`
  + small hardcoded `import_hint`), proof predicate not in scope, missing Bool
  import (VBOOL002). No hint at all for: generic `unknown name: x`
  (`checker.ml` EVar/api-test paths) — which is exactly where local-module and
  misc stdlib names surface.
- W050 (`linter.ml lint_unused_imports`) tracks per-name usage but emits no fix.
- Local imports resolve **same-directory only**
  (`resolve_local_import_path`); `TESL_LOGICAL_PATH` makes this work under the
  LSP's temp-copy scheme.
- `import_decl.loc` is a *point* loc just past the closing `]` (parser calls
  `current_loc` after parsing names) — unusable as an edit span.

### Work items

1. **Parser: real spans for imports.** Capture the `import` keyword loc as start
   and the post-`]` loc as stop; `imp.loc` becomes the full statement span
   (multi-line exposing included). Improves W050/import-error positions and is the
   anchor for edit spans. Adjust any diag-snapshot tests pinning old positions.

2. **Fix kinds.** Move `diagnostic_fix` down to `type_system.ml` (compile.ml
   re-exports via type equation so `Compile.Replace_line` stays valid) and add:
   - `Insert_line of { line : int; text : string }` — insert before 0-based line;
   - `Replace_span of { start_line : int; end_line : int; replacement : string }`
     — replace inclusive line range; empty replacement = delete lines.
   `type_error` gains `fix : diagnostic_fix option` (only constructed via
   `add_error` + 8 literal sites in checker.ml); `diag_of_type_error` threads it;
   `fix_to_json` serializes the new kinds.

3. **Suggestion engine** (new `compiler/lib/import_suggest.ml`):
   - *Stdlib values/fns:* `Type_system.stdlib_home_module_of`.
   - *Stdlib types/ctors:* reverse map derived from `tesl_module_exports`
     (replaces the hardcoded `import_hint` list; ambiguous names → suggest all).
   - *Folder tree:* scan the importing file's directory **recursively** for
     `.tesl` files (skip `_build`, `compiled`, `node_modules`, `.git`; cap file
     count), parse module headers, build exposed-name → (module, relpath) map.
     Same-directory hit → actionable suggestion + fix. Deeper hit → message-only
     hint naming the file and stating the same-directory resolution rule.
   - *Fix builder:* given `m.imports` + target module + name — if the module is
     already imported, `Replace_span` rewriting that import with the name
     appended (single line, or reflowed one-name-per-line when > 80 chars,
     matching `reflow_exposing_lists` layout); else `Insert_line` a new
     `import M exposing [name]` after the last import (or after the module
     header).

4. **Wire suggestions into errors:**
   - `unknown name:` (EVar inference path + api-test scope path) and
     `unknown constructor:` — append "did you mean to import" hint + fix. Needs a
     suggestion closure threaded through `ctx` (built once per `check_module`).
   - `check_stdlib_fn_import_scope`, `check_type_names_in_scope`,
     `check_proof_predicate_scope`, VBOOL002 — keep messages, attach fixes.
5. **W050 fix:** each unused-name diag carries a `Replace_span` for its import
   statement with **all** of that import's unused names removed (identical edit
   on sibling diags → LSP dedupes); all names unused → delete the import line(s).

6. **LSP (`tesl-lsp.rkt`):** extend `diag->fix-edit` for `insert_line` /
   `replace_span` (deletion = range to start of line after span, empty newText);
   dedupe identical edits when aggregating `source.fixAll` /
   `source.organizeImports` so overlapping sibling fixes don't conflict.

7. **Out of scope (follow-ups):** completion-triggered auto-import; CLI `--fix`;
   extending local import resolution beyond same-directory.

### Verification
- OCaml regression tests: suggestion engine unit tests + end-to-end
  `--check-json` fix payloads (new test file in `compiler/test/`).
- `./compile-examples.sh` (authoritative gate) + `dune test`.
- LSP smoke: drive `main.exe --check-json` on fixtures; hand-check code-action
  JSON via the rkt server.

Ship note: editor fixes reach users via the Open VSX extension / nix flake, not
a bare git push (see delivery-channels memory).
