# Improved Tooling

## Status snapshot

This item is no longer about preparing for the OCaml rewrite. The current architecture is already live:

- compiler: `compiler/` (OCaml)
- editor extension: `editor/vscode-tesl/extension.js`
- language server: `editor/tesl-lsp/tesl-lsp.rkt`
- compiler/editor protocol contract: `editor/protocol.md`

The tooling work has advanced substantially since the original rewrite-era framing. The important roadmap task now is to record what is already shipped, what is partially shipped, and what semantic tooling slices still remain.

## Completed slices

- [x] OCaml compiler rewrite is complete.
- [x] Versioned compiler diagnostics are live through `--check-json`.
- [x] Formatter and linter commands are live (`--fmt`, `--fmt-check`, `--lint`).
- [x] Repo-root wiring is aligned on `TESL_REPO_ROOT` across the extension, LSP, and compiler.
- [x] Initial structured fixes are emitted by the compiler and surfaced as code actions in the Racket LSP.
- [x] Compiler-backed local binding metadata is available for hover/local inspection.
- [x] Compiler-backed same-file go-to-definition is implemented.
- [x] Compiler-backed same-file occurrences is implemented.
- [x] Compiler-backed same-file references is implemented.
- [x] Compiler-backed `type_at` is implemented (`--type-at-json` CLI command and protocol shape in
  `editor/protocol.md`). Not yet wired to the LSP hover layer; replacing hover heuristics with
  `type_at` is tracked under the "replace remaining editor-side heuristics" remaining slice.
- [x] Compiler-backed single-file rename is implemented.
- [x] Rename/code-action JSON serialization issues in the LSP have been fixed.
- [x] Rename correctness fixes for precise declaration spans and let-RHS symbol selection have landed.
- [x] Codec `via` references now participate in occurrences/rename correctly instead of corrupting the whole codec block.
- [x] Compiler semantic traversal now covers codec internals and capture parser/checker references rather than treating those declarations as opaque.
- [x] Codecs that refer to unknown target types now produce diagnostics instead of silently slipping through.

## Remaining slices

The remaining work in Item 05 is now narrower and more semantic-query driven.

- [x] Expand compiler-emitted fix payload coverage beyond the current safe starter set.
  - T001 "bare record literal" diagnostic now includes a `replace_line` fix that prefixes `{` with the
    inferred type name when the expected type is known from the bidirectional checker context.
- [x] Add compiler-backed `field_at` / field-target semantic query support.
  - `--field-at-json <file> <line> <col>` returns `{"version":1,"field_at":{"field":…,"record_type":…,"field_type":…,…}}`.
  - Backed by `field_access_info` collector in `checker.ml`.
- [x] Add compiler-backed type-driven field/member completion after `.`.
  - `--completions-json <file> <line> <col>` returns field completions when cursor is after `.`, or
    general in-scope name completions otherwise.
- [ ] Replace any remaining editor-side semantic heuristics with compiler-backed answers where practical.
- [ ] Decide the contract for multi-file/workspace references and rename, then implement it.
- [ ] Move the more advanced tooling features onto IR-1 once Item 04 stabilizes checker metadata.

## Current recommended next slices

If Item 05 continues before Item 04 is finished, the low-risk slices are:

- [ ] widen the fix/code-action set in a compiler-owned way
- [ ] add a small compiler-backed `field_at` query
- [ ] use that query to support safer field/member completions

The larger semantic/editor features should wait for the checker/IR work below.

## Dependencies and sequencing

### Item 04 dependency

`roadmap/next/04-add-bidirectional-type-checking.md` still matters because the long-term semantic tooling should be built on stable checker metadata, not on temporary inference-only structure.

That means:

- simple compiler-owned query additions can continue now
- advanced semantic tooling should not harden until Item 04 is further along

### Item 03 dependency

`roadmap/next/03-ir-1-semantic-layer.md` remains the foundation for the next tier of tooling:

- richer semantic queries
- workspace-aware references/rename
- type-directed completions
- compiler-backed field diagnostics
- proof/capability-aware editor behavior

## Out of scope for this item revision

- redoing already-completed rewrite work
- reintroducing Python-LSP-era tasks as active work
- growing editor-side heuristics instead of compiler-backed queries
- treating Item 05 as if the remaining work were still mostly wiring

## Success criteria

The roadmap now reflects reality. Remaining open semantic slices:

- [x] compiler-backed `field_at` / field-target semantic queries
- [x] broader fix/code-action coverage
- [x] type-driven field/member completions after `.`
- [ ] LSP hover backed by `type_at` rather than editor heuristics
- [ ] workspace-aware references and rename
- [ ] advanced tooling built on stable checker metadata and IR-1
