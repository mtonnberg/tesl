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

Run **Tesl: Migrate database/queues** from the Command Palette or editor/explorer
context menu. The welcome page has a short explanation and one **Start migration**
button; opening it does not request a compiler preview or change files.

**Press Start before editing your schema.** Start prepares the next source
revision, such as V14 after V13. Only after the page says **Draft V14 prepared —
Now edit your schema** should you edit the opened `v-current.tesl`. Then press
**Review my changes**, choose a plan, and **Generate this plan**. Fill the selected
domain placeholders, then press the primary **Recheck and continue** button.
Editing source replaces stale hole-navigation instructions with this recheck action.
If cleanup is required, **Review cleanup** previews
`vN-contract.tesl`, then **Add reviewed cleanup source** writes and checks it.
The last step offers **Save and run application tests** after source checks pass.
The guide shows progress while tests run, then reports the Test Explorer runner's
result. Failed, cancelled, empty or unreported runs never display a passing result.
Source edits during the run require another test run.

After successful tests, **Finish and close** becomes the primary button. Finish
saves and rechecks source, keeps all migration files, and clears the active draft
and its cancellation backup. Reopening then offers **Start migration** for the
next revision. Closing the tab after a confirmed successful run also remembers
authoring as complete. **Start next migration** is available directly on the final
page. These actions do not deploy the migration.

Drafts remembered by an older extension may still say **Continue migration V14**.
Continue once and use **Finish and close**, or choose the now-visible **Start a new
migration instead**. Starting still compiler-checks the existing revision before
freezing it. Closing an unfinished workflow continues to preserve its draft.

Each page shows the draft number and phase with one highlighted next action.
Background and compiler details are collapsed. A remembered draft offers
**Continue migration V14** on reopening; a draft prepared elsewhere can be resumed
through **Already have a draft?**. Continuing verifies the recorded revision.
Early schema edits block Start with recovery guidance instead of silently
refreshing the previous migration.

**Back** keeps your edits and returns to the previous step. **Cancel migration**
shows a discard confirmation, then restores the selected schema/migration family's
Tesl files from a private pre-Start backup, including pre-existing dirty buffers,
and removes new draft files. It preserves unrelated application edits. Backups
survive reloads and are retained if restoration fails; a later revision or active
source transaction blocks cancellation. Older drafts without a Start backup can
only be closed with their files kept. This is source cancellation, not a rollback
of a deployed database.

For `Maybe String` → `String`, the compiler now offers **Keep existing values and
fill in missing ones**. You supply the missing-value string; existing strings are
preserved. Imports, row copies, historical write-back and storage rules are
generated. Where a unique historical constructor is available, it also fills
fixture boilerplate, leaving only representative example inputs. Remaining
placeholders report **Migration needs a value** rather than `unknown name: todo`.

Version 0.7.20 expands generated plans to explicit column renames, removed-column
compatibility values, added/retyped fields in one row mapping, stored records,
concrete ADT variants, JSON codec changes and nested `Maybe`/`List` values. Queue
payload changes receive a separate pure helper module; the editor selects its
remaining domain inputs. Whole-queue retirement has an explicit empty-queue plan.
Cancel removes these new helpers and cleanup files too. Starting again at the same
revision reloads fresh source and restores normal Tesl language support.

For completion-driven authoring, expand **Details and source changes** and apply
**Write proposal without choosing a plan**, place the
cursor on a generated `todo` migration decision, and press **Ctrl+Space**. Choose
a complete compiler plan; accepting it fills the multi-file scaffold and selects
the whole remaining domain placeholder for replacement. If this editor session
has not selected an application, **Set up migration choices…** opens the guided
flow first. You need only supply domain values and policies for supported plans;
imports, signatures, row mappings and migration rules are generated. Completion
uses the same stale-source and document guards as panel choices.

Use **Migrate database/queues…** CodeLens from the active source file. It reads the nearest
`tesl.toml`'s `[project].entrypoint`, so a schema under
`example/db-migration-example/` selects `todo-app.tesl` even when the whole
repository is open. Without a configured entrypoint, discovery is limited to
that project. General background is a separate **Tesl: Migration Reference**
command. More permissive checks are explicitly described as changed proofs:
old values may pass forwards while new values fail the old check in reverse.

The low-level `tesl.previewMigration` command uses the matching language server and
compiler to inspect the application and all open project buffers. When invoked
from a schema or migration file, the nearest manifest supplies the entry file;
without one, choose the application entry file. Multiple
reachable databases get an explicit picker. The preview shows:

- An overview of proposed files and distinct compiler diagnostics (duplicates are collapsed).
- One review item at a time, with **Previous**/**Next**, source locations and
  expandable help.
- Compiler-proposed templates where a supported route was checked. Explicit
  `todo` holes remain for your values or custom code. **Generate this plan**
  regenerates the compiler-checked proposal and updates the real files
  and open buffers; it then selects the custom-code hole and rechecks the app.
- Read-only before/after diffs of the exact retained proposal. Refresh after
  editing; stale handles cannot fetch replacement disk contents.

A single **Migrate database/queues…** CodeLens appears on application database declarations, migrations, Contracts and
`VCurrent` headers. Other schema/migration files, including frozen snapshots,
private helpers and incomplete drafts, get a file-level entry. Enable the editor's
`editor.codeLens` setting if lenses are hidden. Contextual completion offers
migration fields and constructors with help; use `Ctrl+Space` to request it.

An exact current-target byte/hash mismatch is shown as a warning squiggle while preparing
a draft, with refresh and deployed-history guidance. The compiler still refuses
to build/run stale history. Missing sources, invalid layouts and frozen-source
hash errors remain errors. The editor cannot determine deployment state.
File-level migration diagnostics underline an available character. Migration
lightbulbs offer **Migrate database/queues** and **Inspect migration source diagnostics**;
frozen-history `MIG013` only offers guidance. Compiler-provided mechanical fixes
remain available; migration policy choices are not applied by Fix All.

For supported field proof changes, validator-based plans fill calls to uniquely
matching exported pure `establish` functions,
result handling, row copies, exact reverse signatures, imports and Retype/WriteBack
rules. This includes multiple primitive fields and record-valued field proofs.
Fill rejection policy, historical fallback and fixture values. Ambiguous validators
leave explicit typed conversion holes. Table/key changes, cross-field reverse
proofs, inaccessible historical APIs and generic stored ADT conversions have no
automatic plan. Row and queue-payload changes require separate revisions; partial
job-kind removal/renaming is unsupported. See the
[migration guide](../../manual/migration-guide.md#supported-changes-and-your-remaining-inputs)
for the capability matrix, examples and cleanup requirements.

With a matching updated compiler, historical write-back uses ordinary `Maybe`:
`Something` carries the exact old value/proof; `Nothing` refuses incompatible
writes until old storage is retired. A fallback can be validated through the old
validator using an ordinary exhaustive case. The special literal evaluator and
exhaustiveness exception have been removed.

The **Delete obsolete rows and convert the rest** plan adds an explicit predicate
and reason using `RowChange` (`KeepRow`, `DeleteRow`, `RejectRow`). The Worker
performs guarded physical deletion; request reads of pending deletions report
that Worker processing is required. See the guide's
[write-back](../../manual/migration-guide.md#fallible-historical-write-back) and
[row-deletion](../../manual/migration-guide.md#explicit-row-deletion) semantics.

**Write migration files** (or **Write proposal without choosing a plan** under
details) writes the reviewed proposal, including new files.
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
`codium --install-extension vscode-tesl-0.7.19.vsix` (or **Extensions: Install from
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
selects that output directory. It checks that welcome makes no source changes,
then tests real source-file creation, dirty-buffer updates, stale-choice refusal,
preserved handwritten edits, custom-code selection, compiler rechecking and
explicit saves. A temporary copy of `example/db-migration-example` exercises
V13 → Start → V14 → `Maybe String` to `String` → missing-value and fixture inputs
→ source ready → Back → Cancel. It verifies exact schema/history restoration,
new-file deletion and preservation of unrelated dirty application edits. The
original example is not edited by this test.
