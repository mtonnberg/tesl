# Tesl Editor Tooling

## Setting up the editor extension

**Installing or configuring the VSCodium / VS Code extension?** See
[`vscode-tesl/README.md`](vscode-tesl/README.md) — the canonical setup door
(features, install via Nix, requirements, debugging, and extension settings).

## Development

The Go LSP is available as `tesl-lsp` or with `nix develop --command go run ./runtime/go/cmd/tesl-lsp`; set `TESL_COMPILER` when the compiler executable is not on `PATH`. It supports initialize/shutdown/exit, full-document open/change/close, pushed diagnostics, hover, definition/declaration, type-definition, completion and resolve, signature help, references, prepare-rename, rename, quick-fix code actions, document links, linked editing, full-document formatting, document highlights, selection ranges, inlay hints, folding ranges, document symbols, and semantic tokens with full, range, and delta responses. The compiler/editor boundary is documented in `editor/protocol.md`.

To iterate on the grammar, edit `vscode-tesl/syntaxes/tesl.tmLanguage.json` and reload the VSCodium window. To build the extension from source: `cd vscode-tesl && npm install && vsce package --allow-missing-repository`, then `codium --install-extension vscode-tesl-*.vsix`.

## Architecture

```
editor/
  vscode-tesl/           VSCodium extension
    package.json         Extension manifest
    extension.js         Extension entry point (starts LSP client)
    syntaxes/            TextMate grammar
    language-configuration/
  tesl-lsp/              Legacy compatibility sources
  ../runtime/go/cmd/tesl-lsp/
                         Go LSP development entrypoint
```
