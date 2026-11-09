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

Run **Tesl: Migrate database** from the Command Palette or editor/explorer context
menu. Choose **Continue current draft** to refresh an undeployed revision, or
**Start next revision** to freeze the current schema before editing its next
version. The searchable picker offers compiler-generated scaffolds, applying the
ordinary proposal, or reviewing files and decisions in the panel.

For completion-driven authoring, apply **Update generated source**, place the
cursor on a generated `todo` migration decision, and press **Ctrl+Space**. Choose
a complete compiler plan; accepting it fills the multi-file scaffold and selects
the whole remaining domain placeholder for replacement. If this editor session
has not selected an application, **Set up migration choices…** opens the guided
flow first. You need only supply domain values and policies for supported plans;
imports, signatures, row mappings and migration rules are generated. Completion
uses the same stale-source and document guards as panel choices.

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
  `todo` holes remain for your values or custom code. **Use this option and update
  source** regenerates the compiler-checked proposal and updates the real files
  and open buffers; it then selects the custom-code hole and rechecks the app.
- Read-only before/after diffs of the exact retained proposal. Refresh after
  editing; stale handles cannot fetch replacement disk contents.

A **Migrate database…** / **Migration guide** / **Preview migration decisions**
CodeLens appears on application database declarations, migrations, Contracts and
`VCurrent` headers. Other schema/migration files, including frozen snapshots,
private helpers and incomplete drafts, get a file-level entry. Enable the editor's
`editor.codeLens` setting if lenses are hidden. Contextual completion offers
migration fields and constructors with help; use `Ctrl+Space` to request it.

An exact current-target byte/hash mismatch is shown as a warning squiggle while preparing
a draft, with refresh and deployed-history guidance. The compiler still refuses
to build/run stale history. Missing sources, invalid layouts and frozen-source
hash errors remain errors. The editor cannot determine deployment state.
File-level migration diagnostics underline an available character. Migration
lightbulbs offer **Migrate database…** and **Explain migration requirements**;
frozen-history `MIG013` only offers guidance. Compiler-provided mechanical fixes
remain available; migration policy choices are not applied by Fix All.

For changed primitive field proofs, **Reuse existing validators for changed field
proofs** fills calls to uniquely matching exported pure `establish` functions,
result handling, row copies, exact reverse signatures, imports and Retype/WriteBack
rules. Fill rejection policy, historical fallback and fixture values. Ambiguous
validators require the generic converter scaffold. See the
[migration guide](../../manual/migration-guide.md) for a worked workflow and limits.

**Update proposed source files** writes the reviewed proposal, including new files.
Open dirty buffers receive version-guarded editor edits and stay unsaved; their
original disk bytes and handwritten changes are preserved. Closed files use a
durable source journal. The client and server check complete buffer snapshots,
versions and document lifetimes before publication and after edits or restoration.
A normal edit acknowledgement alone never authorizes commit or rollback.

Finish custom code in the selected `todo` hole. The refreshed preview reports
remaining decisions and ordinary compiler errors. These actions prepare source;
they do not execute database migrations. Test and inspect the resulting plan
before deployment. Compiler choices are explicit user decisions and remain
excluded from ordinary automatic quick fixes.

If inputs changed after preview, refresh before choosing again. If an operation
reports an unknown outcome or recovery required, preserve your buffers and the
`.tesl-source-edit` journal. Use **Check application outcome** rather than blindly
repeating the apply. A concurrent edit is preserved, even when that requires
retaining recovery state instead of claiming automatic restoration.

These features require the updated extension **and matching Tesl toolchain**.
A checkout does not update an installed extension. Build a VSIX with
`npm ci && npm run package` in this directory, install it using
`codium --install-extension vscode-tesl-0.7.16.vsix` (or **Extensions: Install from
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

## Real extension-host migration test

`npm test` runs headless unit/protocol fixtures. To run the complete source-choice
journey inside a real VS Code/VSCodium host, first bundle the extension and build
a matching compiler and LSP, then provide these paths:

```sh
TESL_CODIUM_BINARY=/absolute/path/to/codium \
TESL_LSP_HOST_BINARY=/absolute/path/to/tesl-lsp \
DISPLAY=:99 npm run test:host
```

The display can be supplied by Xvfb. The launcher isolates user settings,
extensions and XDG directories, preserves the inherited network/TLS settings, and
retains the actual project, logs and evidence. `TESL_MIGRATION_HOST_ARTIFACTS`
selects that output directory. It tests real source-file creation, dirty-buffer
updates, stale-choice refusal, preserved handwritten edits, custom-code selection,
compiler rechecking and explicit saves; it does not substitute a command-name
assertion for editor application.
