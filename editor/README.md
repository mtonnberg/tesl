# Tesl Editor Tooling

## VSCodium / VS Code Extension (`vscode-tesl`)

Provides syntax highlighting and live compiler diagnostics for `.tesl` files.

### Features

- **Syntax highlighting** via TextMate grammar: keywords, types, operators, strings, comments, proof annotations (`:::`), pipe operators (`<|`, `|>`), string interpolation (`${expr}`)
- **Language configuration**: auto-closing pairs, bracket matching, comment toggling, indentation rules, code folding
- **Live diagnostics** via Language Server Protocol: runs the tesl compiler on save and reports errors inline

### Install from source

Prerequisites: `nix-shell` (provides racket), `node`, `npm`

```bash
cd editor/vscode-tesl
npm install
vsce package --allow-missing-repository
codium --install-extension vscode-tesl-*.vsix
```

### Development

The LSP server (`tesl-lsp/tesl-lsp.rkt`) is a Racket script that runs the OCaml compiler with `--check-json` and translates the versioned diagnostic response into LSP diagnostics. The compiler/editor boundary is documented in `editor/protocol.md`.

To iterate on the grammar, edit `syntaxes/tesl.tmLanguage.json` and reload the VSCodium window.

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
