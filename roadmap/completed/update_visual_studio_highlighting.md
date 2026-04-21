# VSCode / VSCodium Syntax Highlighting

> **Implemented** — `editor/vscode-thsl/syntaxes/thsl.tmLanguage.json` updated and works in both VS Code and VSCodium.

## What was updated

Added support for all new language constructs introduced since the initial grammar was written:

| Category | Added |
|---|---|
| Declaration keywords | `queue`, `channel`, `worker`, `workers` |
| Body keywords | `enqueue`, `publish`, `subscribe`, `websocket`, `startWorkers`, `startWebSocket`, `auth`, `capture`, `jobs`, `retry`, `maxAttempts`, `backoff`, `exponential`, `fixed`, `initialDelay`, `payload`, `database` |
| Control keywords | `with`, `transaction` |
| HTTP methods | `websocket` in endpoint context |
| Operators | `<>` (string concatenation) |
| Constants | `asc`, `desc` |
| Builtin functions | `generateId` |

## VS Code vs VSCodium compatibility

The grammar uses the standard TextMate `.tmLanguage.json` format which is identical in both editors. The `extension.js` launches the LSP server via `python3`, which works in both without modification.

## Open improvements

The grammar still uses a flat TextMate grammar rather than a Tree-sitter grammar. A Tree-sitter grammar would give:
- Precise incremental parsing
- Structural highlights (matching brackets, fold regions)
- Better performance in large files

This is tracked in `improve_language_server.md`.
