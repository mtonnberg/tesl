# Tesl Language — VS Code Extension

Syntax highlighting, live type-checking, go-to-definition, hover types, completions, and occurrence highlighting for the [Tesl](https://github.com/mtonnberg/tesl) language.

Tesl is an alpha-stage language for building web APIs where validation, auth, and side effects are enforced by the compiler rather than by convention.

---

## Features

- **Syntax highlighting** — keywords, types, proof annotations (`:::`), operators, string interpolation
- **Live diagnostics** — type errors and lint warnings appear inline as you type
- **Go-to-definition** — jump to where a name is declared
- **Hover types** — see the inferred type of any expression
- **Completions** — context-aware field and identifier suggestions
- **Occurrence highlighting** — all uses of a symbol highlighted on cursor

---

## Requirements

The extension needs the Tesl language server (`tesl-lsp`) to provide diagnostics and editor intelligence.

**Recommended: install via Nix**

```bash
nix profile install github:mtonnberg/tesl
```

This puts both `tesl` and `tesl-lsp` on your PATH. The extension finds `tesl-lsp` automatically — no configuration needed.

**Alternative: repo checkout**

If you have the Tesl repository open as your workspace and have run `nix develop` (or `nix-shell`), the extension finds `tesl-lsp.rkt` in the repo automatically.

---

## Extension settings

| Setting | Default | Description |
|---|---|---|
| `tesl.lspScript` | `""` | Advanced override: absolute path to `tesl-lsp.rkt`. Leave empty to use the `tesl-lsp` binary from PATH or auto-detect from the workspace. |

---

## Known limitations

- **Alpha language** — breaking changes are expected; the extension tracks the language version
- **Nix only** — standalone binaries for non-Nix users are on the roadmap
- **Linux / macOS only** — Windows native is not supported; WSL2 with Nix works

---

## Feedback and issues

[github.com/mtonnberg/tesl/issues](https://github.com/mtonnberg/tesl/issues)
