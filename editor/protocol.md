# Tesl compiler/editor protocol

## Purpose

This document defines the protocol boundary between the Tesl compiler and editor-facing tooling.

Today that primarily means:

- `tesl --check-json` from `compiler/bin/main.ml`
- the Go Tesl LSP in `runtime/go/cmd/tesl-lsp`

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
  "replacement": "  title: String",
  "title": "Replace line"
}
```

Five kinds exist (all line and column numbers are 0-based):

- `replace_line` — `{ "kind": "replace_line", "line": int, "replacement": string }`:
  replace one whole line.
- `insert_line` — `{ "kind": "insert_line", "line": int, "text": string }`:
  insert `text` as a new line before `line` (E1: add a missing import).
- `replace_span` — `{ "kind": "replace_span", "start_line": int, "end_line": int, "replacement": string }`:
  replace the inclusive line range; an empty `replacement` deletes the lines
  (E1: prune or remove an unused import). `replacement` may contain newlines.
- `replace_range` — `{ "kind": "replace_range", "start_line": int, "start_col": int, "end_line": int, "end_col": int, "replacement": string }`:
  replace the ordered source range.
- `multi` — `{ "kind": "multi", "edits": [fix, ...] }`: apply one or more
  recursively validated edits as one action.

Rules:

- the top-level fix has a non-empty `title`; nested `multi` edits do not
- all required positions are non-negative and ranges are ordered
- replacement and insertion fields are strings; empty replacement strings are valid
- unknown or malformed fix kinds make the compiler response malformed, rather than producing an empty or partial edit
- consumers bound recursive depth and total nested edit count
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
Consumers must validate required fields and their JSON types, diagnostic severity
values, non-empty diagnostic identity/message fields, and non-negative ordered
ranges. A version-only object such as `{ "version": 1 }` is not a successful
empty response.
Validation applies recursively to members used by tooling: agent-context
diagnostics, symbols, and proof obligations must carry their documented
identity, text, and position fields; semantic records, fields, ADTs, variants,
functions, local bindings, and any supplied locations must have valid member
types and ordered ranges.

Whole-program checks may return diagnostics for imported files. LSP consumers
must group push diagnostics by `file` and publish each group under that file's
actual `file:` URI. The entry document still receives an empty publication when
all errors belong to dependencies, so stale entry diagnostics are cleared. Pull
diagnostic reports expose dependency groups through `relatedDocuments`.
Until a project import index exists, text changes, saves, and watched-file
notifications conservatively recheck every open document. This ensures an
importer's owned dependency groups are replaced or cleared after an imported
file changes instead of leaving stale diagnostics behind.

Source queries use a bounded, per-query shadow project rooted at the nearest
`tesl.toml` (or the entry file's directory when no manifest exists). Disk `.tesl`
files and manifests form the baseline and open buffers under that root replace them, so unsaved
imports participate in diagnostics and semantic queries without changing disk.
The implementation currently permits at most 256 open overlays, 4096 disk project
files, 16384 traversed directories, 4096-byte relative paths, 64 MiB of staged
source, and the compiler client's existing 8 MiB default output cap. Build, VCS, and
dependency-cache directories are skipped. Open files outside the entry project
are ignored, compiler paths are mapped back to real workspace paths, and every
temporary shadow tree is removed after its query.

## Compatibility rules

This contract is shared across compiler implementations.

That means:

- the current OCaml compiler must conform to it
- the current Go LSP must consume it directly
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

Completion is prefix-filtered and deterministic. It supports record fields (including
partial field names), standard-library modules and import exposing lists, type
annotations, and general identifiers. Public library candidates include functions,
types, constructors, facts, and capabilities; unavailable backend exports and
configuration-only type names are excluded. Local declarations take precedence
over library candidates with the same name.

Version 1 accepts these additive item fields (older three-field items remain valid):

| Field | Shape and meaning |
| --- | --- |
| `module` | Nullable string: declaring library module; empty string for ambient names |
| `documentation` | Nullable string: documentation for this candidate |
| `requires_import` | Boolean: selecting this name needs an import |
| `sort_text` | Nullable string: stable ordering, locals before imports before out-of-scope names |
| `text_edit` | Nullable `replace_range` diagnostic-fix payload replacing the current identifier |
| `import_edit` | Nullable `insert_line`, `replace_span`, or `replace_range` diagnostic-fix payload |

Edits use original-buffer zero-based **UTF-8 byte columns**, carry a `title` as
specified by the diagnostic-fix contract, and are applied together. The LSP
converts them to UTF-16 `textEdit` and `additionalTextEdits`, preserves CRLF, and
shows the originating module and an import-required hint. Accepting a type or
function completion inserts or extends its import automatically. Existing whole
module imports, explicit names, and `Type(..)` imports do not produce duplicates.

Unfinished buffers retain discoverable library candidates through parser recovery;
when the import structure cannot be parsed safely, `import_edit` is null. Comments,
string literals, invalid positions, and unmatched prefixes return an empty list.
The LSP refuses malformed/overlapping edits and returns `ContentModified` (-32801)
if an item is resolved after its document version changes, the document closes,
an open dependency's content changes, or a watched disk change is received.
Exported sibling-module types participate using the same source overlays as other
compiler queries. Discovery currently scans at most 200 regular sibling `.tesl`
files (1 MiB per file, 8 MiB total); full workspace discovery belongs to the
retained project index. Files beyond these limits are not advertised as complete
workspace search results.
MCP `tesl.completions` exposes the same compiler metadata and edits.

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

The Go LSP advertises and implements these read-only methods.
They consume the shared compiler query contracts below. Source queries use retained sessions by default; formatting still uses an isolated `--fmt` call.

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

## Retained compiler sessions (workspace protocol 1)

The shipped Go LSP and MCP clients retain one compiler process and private project
mirror. The compiler entry point is `tesl-compiler --workspace-session`; normal
one-shot flags remain available and call the same `Compiler_query.run` function.
Set `TESL_COMPILER_SESSION=0` in the frontend environment to use the older bounded
one-shot adapter. A failed handshake reports this option; it does not silently
interpret malformed responses as support for a different protocol.

This is a local byte-framed protocol, independent of LSP framing. A frame is an
unsigned, big-endian 32-bit byte length followed by exactly that many bytes.
The compiler first writes a framed UTF-8 JSON handshake:

```json
{"version":1,"protocol":"tesl-workspace","invalidation":"whole-snapshot"}
```

Each request contains five consecutive frames, in this order:

| Field | Limit | Meaning |
|---|---|---|
| Snapshot | 128 bytes | Nonempty identity of the complete staged input tree |
| Flag | 64 bytes | One supported source-query flag |
| Path | 4096 bytes | Absolute filename inside the owner's private mirror |
| Line | 20 bytes | Nonnegative decimal, or empty for a file query |
| Column | 20 bytes | Nonnegative UTF-8 byte column, or empty for a file query |

The response is one framed JSON value, at most 8 MiB:

```json
{"version":1,"snapshot":"INPUT_ID","exit_code":0,
 "result":{"version":1,"diagnostics":[]},"error":null,
 "cache_hits":2,"cache_misses":3}
```

`result` retains the selected flag's existing schema. Diagnostic failures have
`exit_code: 1` with a usable result. Failed queries have `result: null` and an
explicit `error`; they are never successful empty results. Cache counters are
optional process-lifetime measurements. A malformed/truncated frame terminates
the session. EOF between requests is a normal shutdown. This protocol accepts
read-only queries; it cannot execute compiler build commands or modify files.

The owner hashes sorted paths and exact source/manifest bytes using SHA-256.
All relevant open buffers override disk, including new unsaved files. Disk bytes
are reread on each request, so equal timestamps and lengths cannot hide edits.
Only changed files are written to the mirror; closing/deleting an overlay
restores the disk file or removes the staged file. Existing overlay file, byte,
document and directory limits still apply. Symlinks and nonregular disk sources
are excluded. Source paths in locations and diagnostic hints map back to the
project. Different roots or changed toolchain configuration restart the process.

The mirror stays immutable during a query. The compiler retains parsed modules,
checked type metadata and query answers within that snapshot, with entry and
byte limits. Any different snapshot clears semantic caches. Bundled `.tesl`
source libraries are additional compiler-owned inputs: changed bytes or missing/
created files invalidate answers even if project inputs are unchanged. This is
conservative invalidation, not yet a reverse-dependency index or incremental
checking of only affected modules.

A client serializes exchanges and includes waiting time in its request deadline.
Cancellation/timeout kills and reaps the owned process tree, closes its pipes,
and waits for I/O to finish. A crash fails the active request; the next request
reconstructs the compiler from the current complete mirror. Responses with a
wrong revision, unsupported version, missing payload, or invalid query schema
are rejected. The LSP cancels outstanding diagnostics and closes the session on
exit/EOF; MCP closes it on EOF. Cross-file semantic identity and transaction-safe
workspace rename remain separate work.

Regression tests: `compiler/test/test_workspace_session.ml`,
`runtime/go/internal/tooling/session_test.go`, and the real-compiler completion
fixtures in `runtime/go/internal/lsp/completion_test.go`.

### LSP request cancellation and queue ownership

The Go LSP reads `$/cancelRequest` while a query is running. Request handlers and
document notifications still execute in arrival order under one owner; reading
a later edit does not mutate an earlier query's source snapshot. Cancellation
reaches active compiler queries and prevents canceled queued queries from starting.
Detected client cancellation returns one `RequestCancelled` (-32800) response,
including when a compiler races with cancellation and returns a successful result.
Such a response contains no completion, import, formatting or rename edits.
This follows the [LSP cancellation contract](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#cancelRequest).

Request IDs are 32-bit integers or strings. Integer `1` and string `"1"` are
distinct; escaped spellings of the same string share identity. Unknown, malformed,
or late cancellation notifications are ignored. A completed ID may be reused
without inheriting its predecessor's cancellation. A duplicate outstanding ID
terminates the connection with an explicit protocol error.

The reader permits 64 queued messages and at most 16 MiB of pending message bodies,
including the active message. Each frame retains the protocol's 8 MiB bound.
Exceeding either queue bound cancels owned work and terminates with an explicit
error; it never silently drops a document change. Cancellation notifications
bypass the queue. `Run` owns its input for the session; blocking inputs must support
`Close` (as stdio does) so exit or parent-context cancellation releases the reader.
Ordinary EOF drains preceding messages before closing the compiler session.

Regression fixtures in `runtime/go/internal/lsp/requests_test.go` cover active and
queued cancellation, late successful results, string/integer identities, ID reuse,
document ordering, limits, concurrent response claims and input cleanup.
