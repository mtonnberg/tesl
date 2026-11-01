# Tesl Language — VS Code Extension

Syntax highlighting, live type-checking, go-to-definition, hover types, completions, and occurrence highlighting for the [Tesl](https://github.com/mtonnberg/tesl) language.

Tesl is an beta-stage language for building web APIs where validation, auth, and side effects are enforced by the compiler rather than by convention.

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
- Click the **▶ Run** / **🐛 Debug** CodeLens above any test block.

CodeLens **Run** is offered for `test`, `api-test`, `load-test`, and `doctest`
blocks; **Debug** is offered for `test`, `api-test`, and `doctest` blocks.
A `load-test` is run-only — it is a throughput benchmark, so stepping through it
is not meaningful.

Behind the scenes the adapter starts the file with `tesl run --debug`, runs the
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

## Migration authoring

Use **Tesl: Migration Guide** from the Command Palette for an overview and
step-by-step proof, row, queue and rollout guidance. Expand each option or
**More help** for its conditions and limitations. The guide distinguishes adding
a first proof with `Revalidate` from changing an existing historical proof, which
requires a supported explicit conversion rather than `Same`.

**Tesl: Preview Migration Decisions** uses the matching language server and
compiler to inspect the application and all open project buffers. When invoked
from a schema or migration file, choose the application entry file; multiple
reachable databases get an explicit picker. The preview shows:

- An overview of proposed files and every compiler diagnostic.
- One review item at a time, with **Previous**/**Next**, source locations and
  expandable help.
- Compiler-proposed templates where a supported route was checked. Explicit
  `todo` holes remain for your values or custom code; copying a template never
  applies it or establishes that the completed migration is safe.
- Read-only before/after diffs of the exact retained proposal. Refresh after
  editing; stale handles cannot fetch replacement disk contents.

A **Migration guide** / **Preview migration decisions** CodeLens appears above
`migration = Migration { ... }` and `VCurrent` module headers. Enable the editor's
`editor.codeLens` setting if lenses are hidden. Contextual completion offers
migration fields and constructors with help; use `Ctrl+Space` to request it.

An exact current-target byte/hash mismatch is shown as information while preparing
a draft, with refresh and deployed-history guidance. The compiler still refuses
to build/run stale history. Missing sources, invalid layouts and frozen-source
hash errors remain errors. The editor cannot determine deployment state.

The editor preview does not apply multi-file changes. Complete source preparation
with `tesl migrate app.tesl`, then recheck, test and inspect the generated plan.
Editor application remains disabled until its buffer-snapshot and recovery guards
are complete; migration decisions are never ordinary automatic quick fixes.

These features require the updated extension **and matching Tesl toolchain**.
A checkout does not update an installed extension. Build a VSIX with
`npm ci && npm run package` in this directory, install it using
`codium --install-extension vscode-tesl-0.7.14.vsix` (or **Extensions: Install from
VSIX...**), then reload the window. Toolchain development settings follow below.

When using this PR from a checkout, rebuild the compiler, CLI and LSP from that
same checkout. After `cd compiler && dune build`, build the Go components from the
repository root (inside the repository development environment):

```sh
(cd runtime/go && go build -o ../../.tesl-stuff/tesl ./cmd/tesl)
(cd runtime/go && go build -o ../../.tesl-stuff/tesl-lsp ./cmd/tesl-lsp)
```

Set `tesl.compilerBinary` to the rebuilt compiler and `tesl.lspBinary` to the rebuilt
LSP in User Settings, then reload the window. Use the rebuilt CLI for
`tesl migrate`; an older globally installed CLI/LSP does not gain these features
from rebuilding only the compiler or reinstalling only the VSIX.

---

## Requirements

The extension needs the Tesl language server (`tesl-lsp`) to provide diagnostics and editor intelligence.

**Recommended: install via Nix**

```bash
nix profile install github:mtonnberg/tesl
```

This puts both `tesl` and `tesl-lsp` on your PATH. The extension finds `tesl-lsp` automatically — no configuration needed.

**Alternative: repo checkout**

If you have Tesl installed with Nix, the extension finds the Go `tesl-lsp` binary from PATH.

---

## Extension settings

| Setting | Default | Description |
|---|---|---|
| `tesl.lspBinary` | `""` | Advanced override: absolute path to the Go `tesl-lsp` binary. Leave empty to use `tesl-lsp` from PATH. |
| `tesl.compilerBinary` | `""` | User Settings only: absolute path to a development compiler. Overrides the installed compiler for language features, tests and debugging. Reload the window after changing it. |

When developing Tesl with an official version also installed, build with
`cd compiler && dune build`, then add this to VS Code's **User Settings (JSON)**:

```json
{
  "tesl.compilerBinary": "/absolute/path/to/tesl/compiler/_build/default/bin/main.exe"
}
```

The extension uses that compiler and its checkout's standard library. Rebuilding
the same binary updates the compiler used for subsequent checks. Workspace
settings cannot set this override: a repository must not choose an executable
merely by being opened. An explicit `TESL_COMPILER` environment override also
remains supported. Clear the setting to return to the installed compiler.

---

## Known limitations

- **Beta stage** — breaking changes are expected; the extension tracks the language version
- **Nix only** — standalone binaries for non-Nix users are on the roadmap
- **Linux / macOS only** — Windows native is not supported; WSL2 with Nix works

---

## Feedback and issues

[github.com/mtonnberg/tesl/issues](https://github.com/mtonnberg/tesl/issues)
