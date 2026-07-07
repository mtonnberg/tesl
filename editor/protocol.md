# Tesl compiler/editor protocol

## Purpose

This document defines the protocol boundary between the Tesl compiler and editor-facing tooling.

Today that primarily means:

- `tesl --check-json` from `compiler/bin/main.ml`
- the Tesl LSP in `editor/tesl-lsp/tesl-lsp.rkt`

Future compiler implementations must match this contract before editor cutover.

## Versioning

Every compiler response used by editor tooling must include a top-level `version` integer.

Current version:

```json
{ "version": 1, "diagnostics": [] }
```

A consumer that receives an unknown version must treat that as a protocol mismatch, not as a silently accepted payload.

## Diagnostic response shape

The `check`/`--check-json` path returns a top-level object:

```json
{
  "version": 1,
  "diagnostics": [ ... ]
}
```

`diagnostics` must be an array of objects.

## Definition response shape

The `--definition-json <file> <line> <col>` path returns a top-level object:

```json
{
  "version": 1,
  "definition": null
}
```

Or, when a same-file definition is found:

```json
{
  "version": 1,
  "definition": {
    "file": "/abs/path/to/file.tesl",
    "line": 8,
    "col": 2,
    "end_line": 8,
    "end_col": 7
  }
}
```

Coordinates are 0-based, matching LSP positions. Consumers must treat `definition: null` as a normal "not found" result rather than a protocol error.

## Diagnostic object

Each diagnostic object must include:

- `file`: absolute source path
- `start`: `{ "line": int, "col": int }` using 0-based coordinates
- `end`: `{ "line": int, "col": int }` using 0-based coordinates
- `severity`: `"error" | "warning" | "info"`
- `code`: machine-readable string such as `E000` or `W031`
- `message`: human-readable message
- `fix`: structured fix object or `null`
- `source`: subsystem name such as `parser` or `lint`

Optional fields may be added later, but the fields above are part of the required contract.

## Ranges

The compiler is responsible for providing the primary source range.

The editor should not need to scrape the human-readable diagnostic message to discover the main token or span when `start` and `end` are present.

For version 1, the compiler may emit single-line ranges only. Multi-line ranges can be added later without changing the envelope structure.

## Fix payload

`fix` is either `null` or a tagged object with a stable `kind` field.

Version 1 supports a minimal edit-oriented shape. Example:

```json
{
  "kind": "replace_line",
  "line": 12,
  "replacement": "  title: String"
}
```

Three kinds exist (all line numbers 0-based):

- `replace_line` — `{ "kind": "replace_line", "line": int, "replacement": string }`:
  replace one whole line.
- `insert_line` — `{ "kind": "insert_line", "line": int, "text": string }`:
  insert `text` as a new line before `line` (E1: add a missing import).
- `replace_span` — `{ "kind": "replace_span", "start_line": int, "end_line": int, "replacement": string }`:
  replace the inclusive line range; an empty `replacement` deletes the lines
  (E1: prune or remove an unused import). `replacement` may contain newlines.

Rules:

- unknown `fix.kind` values must be ignored by the editor
- diagnostics remain valid even when the editor ignores the fix payload
- fix payloads should describe edits, not compiler-internal semantic actions

## Current compiler sources

Version 1 uses at least these `source` values:

- `lint`
- `parser`
- `proof-checker`
- `type-checker`
- `validation`

Editor-facing `--check-json` responses may include both hard errors and lint warnings in the same diagnostics array. Additional sources may be added later.

## Timeout and failure expectations

For editor usage:

- `check` requests are expected to finish within 15 seconds
- `fmt` requests are expected to finish within 10 seconds
- on timeout or compiler-process failure, the editor may surface a warning diagnostic at line 0

Malformed compiler responses should be treated as protocol failures, not as normal empty-diagnostic success.

## Compatibility rules

This contract is shared across compiler implementations.

That means:

- the current OCaml compiler must conform to it
- the current Racket LSP must consume it directly
- a future compiler rewrite must preserve it unless the protocol version changes deliberately

A compiler rewrite is not an excuse to change the editor payload casually.

## Type-at response shape
The `--type-at-json <file> <line> <col>` path returns a top-level object:
```json
{
  "version": 1,
  "type_at": {
    "file": "/abs/path/to/file.tesl",
    "line": 12,
    "col": 4,
    "end_line": 12,
    "end_col": 10,
    "type": "Int"
  }
}
```
When no expression type can be resolved, the compiler returns:
```json
{
  "version": 1,
  "type_at": null
}
```

## Field-at response shape

The `--field-at-json <file> <line> <col>` path returns a top-level object:

```json
{
  "version": 1,
  "field_at": {
    "field": "name",
    "record_type": "User",
    "field_type": "String",
    "file": "/abs/path/to/file.tesl",
    "line": 9,
    "col": 33,
    "end_line": 9,
    "end_col": 37
  }
}
```

When the cursor is not on a record field access, the compiler returns:

```json
{
  "version": 1,
  "field_at": null
}
```

Coordinates are 0-based. The span covers the `.field` portion of `expr.field` (starting at the dot).

## Completions response shape

The `--completions-json <file> <line> <col>` path returns a top-level object:

```json
{
  "version": 1,
  "completions": [
    { "label": "name", "detail": "String", "kind": "field" },
    { "label": "age",  "detail": "Int",    "kind": "field" }
  ]
}
```

Two modes:

1. **After `.`** (field completion): when `char_at(line, col-1)` is `.`, returns all fields of the
   inferred type of the expression before the dot. `kind` is `"field"`.
2. **General** (identifier completion): returns all in-scope names (functions, local lets, stdlib,
   imports). `kind` is `"function"` for function types, `"variable"` for everything else.

An empty array is returned when the file has parse errors or no completions are found.

## Semantic snapshot response shape

The `--semantic-json <file>` path returns the full typed module snapshot:

```json
{
  "version": 1,
  "file": "/abs/path.tesl",
  "module_name": "Demo",
  "content_hash": "…",
  "records": [ { "name": "User", "fields": [ { "name": "email", "type": "String" } ] } ],
  "adts":    [ { "name": "Color", "params": [], "variants": [ { "constructor": "Red", "fields": [] } ] } ],
  "functions": [ { "name": "double", "kind": "fn", "type": "Int -> Int", "loc": { … } } ],
  "local_bindings": [ { "name": "n", "type": "Int", "loc": { … } } ],
  "expr_types": [ { "type": "Int", "loc": { … } } ]
}
```

All `loc` objects use the shape `{ "file", "start_line", "start_col", "end_line", "end_col" }`
with **0-based** line/column coordinates (matching LSP positions). The process exits non-zero and
emits no JSON on a parse error; consumers must treat that as "no snapshot available".

## LSP methods backed by the above flags

The Racket LSP (`editor/tesl-lsp/tesl-lsp.rkt`) advertises and implements these read-only methods.
None of them modify the compiler contract; each shells out to a frozen `--*-json` / `--fmt` flag.

- `textDocument/documentSymbol` — flat `SymbolInformation[]` built from `--semantic-json`
  (functions/checks/handlers/workers → Function, records → Struct + Field children, ADTs → Enum +
  EnumMember children). Entries without a usable `loc` are skipped. Empty array on parse error.
- `textDocument/semanticTokens/full` — delta-encoded tokens from `--semantic-json`. Each token
  covers exactly ONE declared identifier name (function names + local-binding names); tokens are
  never widened to a whole declaration body or to end-of-line, which previously over-painted the
  minimap. Legend: tokenTypes `["function","type","enum","enumMember","property","variable"]`,
  tokenModifiers `["declaration"]`.
- `textDocument/formatting` — runs `--fmt` on a temp copy of the (possibly unsaved) buffer and
  returns a single full-document `TextEdit`. Returns `[]` when the buffer is already canonical or
  when `--fmt` fails (e.g. parse error), never a partial edit.
- `textDocument/inlayHint` — inferred `let` types from `--local-bindings-json`. A hint `: T` is
  emitted after the binding name only for `let <name> = …` forms WITHOUT an explicit annotation;
  parameters and already-annotated lets are skipped. Parameter-name hints are not derivable from the
  frozen flags and are intentionally omitted.
- `textDocument/documentHighlight` — same-file occurrence ranges from `--occurrences-json`, each as
  `{ range, kind: 1 }` (Text; the flag does not distinguish read vs write).

The TextMate grammar (`editor/vscode-tesl/syntaxes/tesl.tmLanguage.json`) terminates string scopes at
end-of-line (`"end": "\"|(?=$)"`); Tesl strings are single-line, so an unterminated quote no longer
paints the string scope — and the minimap — to end-of-file.
