# Remove `#lang tesl`

**Status: COMPLETED 2026-07-29.** Parser rejects HASH_LANG with repurposed E002 + Replace_span delete-line fix (parse_module; recover path stays tolerant for the LSP); 154 .tesl files stripped + all committed .rkt snapshots regenerated; ~2,350 OCaml fixture occurrences + Racket/LSP harness fixtures stripped with position expectations re-baselined; formatter/linter/tmLanguage/docs updated; dead Racket reader tree (lang/, tesl/lang/) deleted with flake.nix / extension.js / cli-body probes / docker templates updated. Editor extension needs a re-publish to ship the grammar change.

## Background

Tesl files may optionally start with `#lang tesl`. The line is historical
baggage from the abandoned Racket `#lang`-reader integration (`lang/` +
`tesl/lang/`, a reader that shells out to the compiler — nothing in the repo
uses it). Every tracked `.tesl` file still carries the pragma, the lexer/parser
skip it, the formatter preserves it, and the spec documents it — all for a line
that provides no value.

## Goal

The pragma is gone: the compiler **rejects** any file containing `#lang`
(clear diagnostic + auto-fix that deletes the line), all repo sources drop the
line, and the dead Racket reader collection is removed.

## Design

- Parser: where the pragma is currently skipped (`parse_module`,
  `parse_module_header`, `parse_module_recover`), emit an error —
  "`#lang tesl` is no longer part of Tesl; delete this line" — carrying a
  delete-line fix through the parser fix channel. The recover path (LSP)
  records the error and continues so editor features keep working on legacy
  files.
- Lexer keeps producing `HASH_LANG` so the parser can point at the exact span
  (rejecting in the lexer would lose the fix channel).
- Retired lint code E002 ("missing `#lang tesl`") is repurposed for the new
  rejection so `explain` has a page for it.
- Formatter: drop the `#lang ` verbatim-preservation case (keep `#!` shebang).
- Delete `lang/` and `tesl/lang/` (Racket reader tree); update `flake.nix`
  packaging list, `editor/vscode-tesl/extension.js` collection setup, and the
  docker template README require-line.
- Editor grammar: remove the `lang-line` rule from `tesl.tmLanguage.json`
  (extension re-publish needed — a git push alone does not ship editor fixes).

## Migration (mechanical, large)

- Strip line 1 from all 154 tracked `.tesl` files; regenerate committed `.rkt`
  snapshots (lesson snapshots are byte-exact CI-gated) — all line numbers
  shift by one.
- Strip the pragma from inline fixtures: ~2,350 occurrences across 136 OCaml
  test files, ~230 in `tests/tesl-test.rkt`, ~10 in `editor/tesl-lsp/tesl-lsp.rkt`
  fixture buffers; fix location-sensitive expectations (off-by-one).
- Invert `test_lexer.ml` `test_hash_lang` and the E002 diag snapshot into
  rejection tests.
- Docs: LANGUAGE-SPEC §8.1 prologue + grammar + §17 examples,
  `manual/GETTING-STARTED.md`, `INSTALL.md`, `dev-docs/01-overview.md`,
  `dev-docs/02-parser.md`, `dev-docs/09-adding-tests.md`;
  `embedded_docs.ml` regenerates on build.

## Verification

- New tests: file starting with `#lang tesl` => error with delete-line fix;
  fix applies and recompiles clean; `#lang` on a non-first line also rejected;
  LSP recover path still returns a module.
- `./compile-examples.sh` green; `dune test` green; Racket suite green.
