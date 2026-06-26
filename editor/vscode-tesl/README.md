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
- **Interactive debugging** — set breakpoints on `.tesl` lines, step through
  execution, and inspect locals with their compile-time **proof** annotations
  (e.g. `port = 8080 : Int ::: ValidPort port`)

---

## Debugging

The extension contributes a `tesl` debug type. To debug a `.tesl` file:

- Open the file, set breakpoints in the gutter, and press **F5**, or
- Right-click the file → **Debug Tesl Program** / **Debug Tesl Tests**, or
- Click the **🐛 Debug test** CodeLens above any `test "…" { … }` block.

Behind the scenes the adapter compiles the file with `tesl --debug`, runs the
chosen `main` (program mode) or `test` blocks (test mode), and pauses at your
breakpoints. The **Variables** panel shows each local's raw runtime value
overlaid with its **compile-time type and proof** — the proof annotation is
recovered from the compiler (it is erased from the runtime, by design), so a
proof-carrying value reads e.g. `port = 8080 : Int ::: ValidPort port`. Records,
newtypes, ADTs, tuples, and lists are formatted readably.

A reference `launch.json` lives in `.vscode/launch.json`; the same
configurations are offered automatically via **Run → Add Configuration… →
Tesl**. Set `"mode": "test"` plus an optional `"testName"` to debug a single
test block.

For diagnostics, set the `TESL_DAP_LOG` environment variable to a file path
(or `stderr`) before launching VS Code to capture an adapter trace.

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
