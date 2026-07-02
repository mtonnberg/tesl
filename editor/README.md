# Tesl Editor Tooling

## Setting up the editor extension

**Installing or configuring the VSCodium / VS Code extension?** See
[`vscode-tesl/README.md`](vscode-tesl/README.md) — the canonical setup door
(features, install via Nix, requirements, debugging, and extension settings).

## Development

The LSP server (`tesl-lsp/tesl-lsp.rkt`) is a Racket script that runs the OCaml compiler with `--check-json` and translates the versioned diagnostic response into LSP diagnostics. The compiler/editor boundary is documented in `editor/protocol.md`.

To iterate on the grammar, edit `vscode-tesl/syntaxes/tesl.tmLanguage.json` and reload the VSCodium window. To build the extension from source: `cd vscode-tesl && npm install && vsce package --allow-missing-repository`, then `codium --install-extension vscode-tesl-*.vsix`.

## Architecture

```
editor/
  vscode-tesl/           VSCodium extension
    package.json         Extension manifest
    extension.js         Extension entry point (starts LSP client)
    syntaxes/            TextMate grammar
    language-configuration/
  tesl-lsp/              Language Server
    tesl-lsp.rkt         Racket LSP server (JSON-RPC over stdio)
```
