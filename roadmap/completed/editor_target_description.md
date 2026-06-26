# Platinum-tier editor experience — LSP capability target & gap analysis

> **Status:** ✅ **Completed (do-now scope) — 2026-06 platinum push.** The entire
> non-cross-file capability surface shipped (see "Shipped 2026-06" below). The remaining
> backlog — the IR-1-gated cross-file cluster, a few independent niche features, and the
> Gold/Platinum tiers of shipped methods — is tracked in
> [`../later/further_editor_improvements.md`](../later/further_editor_improvements.md). This
> file is retained as the historical capability target + gap analysis.
>
> **Where we are:** a working Racket LSP server + VSCode/VSCodium extension + DAP debugger
> already clear Baseline across diagnostics, hover, completion, go-to-definition,
> references, rename, quick-fixes, and step-debugging.
> - ✅ Shipped (incl. the 2026-06 platinum push — see "Shipped 2026-06" below):
>   **LSP** — push **+ pull** diagnostics (resultId/unchanged); type-aware hover;
>   `.`-completion with **snippets + completionItem/resolve**; **signatureHelp**;
>   same-file definition + **declaration + typeDefinition**; same-file references + rename;
>   **read/write documentHighlight**; quick-fix + **source.fixAll / organizeImports** code
>   actions; **executeCommand + applyEdit**; documentSymbol; **semanticTokens full + range +
>   delta**; **inlayHint (+resolve)**; **foldingRange**; **selectionRange**; **documentLink**;
>   **linkedEditingRange**; **whole-file + range + on-type formatting**; **incremental
>   didChange**; didChangeConfiguration/WatchedFiles + refresh; resilient semantic snapshot
>   (Enabler 1).
>   **DAP** — breakpoints + step + variable inspection; **conditional + hit-conditional
>   breakpoints**; attach (= launch); **full live-domain inspection** (queues / caches /
>   **connected SSE clients** / email outbox / **worker pools**) with **deep drill-down into
>   queue jobs, cache values & email fields**; **stop-the-world pause** (freeze all
>   workers/timers/mail/SSE on a breakpoint, thaw on resume); **SQL transparency** (exact
>   parameterized SQL + bound params + escaped read-only preview when paused on a query).
>   **Extension** — Test Explorer, doctest lens, run-function-with-input, file-level
>   run/debug lenses, minimap grammar fix. **Compiler** — 4 new query flags backing the above.
> - 🟡 Partial: cross-file features are same-file-only today (definition / references / rename).
> - ⬜ Remaining — all gated on **IR-1** (the retained multi-file index; the platinum
>   long-pole, tracked separately): project-wide definition/references, workspace/symbol,
>   workspace/diagnostic, call/type hierarchy, cross-file + module rename, file-move import
>   fixups, codeLens reference counts, `$/progress` indexing.

## Shipped 2026-06 (platinum push)

The do-now (non-cross-file) capability surface landed in one wave, gated at every step
(LSP rackunit 212; DAP suites green; ci.sh 58-lesson byte-exact 0-differ). Per surface:

- **Compiler query flags** — `--signature-help-json`, `--selection-range-json`,
  `--type-definition-json`, and a read/write `kind` on `--occurrences-json`.
- **LSP (`editor/tesl-lsp`)** — 13 new/upgraded methods: signatureHelp; completion
  resolve + snippets + sortText; declaration; typeDefinition; documentHighlight kinds;
  foldingRange; selectionRange; range + on-type formatting; semanticTokens range +
  full/delta; incremental didChange; codeAction `source.fixAll`/`organizeImports`;
  executeCommand + applyEdit; documentLink; linkedEditingRange; pull diagnostics;
  didChangeConfiguration/didChangeWatchedFiles; inlayHint/resolve; refresh.
- **DAP debugger (`dsl/debug`) — the "no magic" story** — conditional + hit-conditional
  breakpoints; attach; a global domain registry so a paused session inspects EVERY live
  queue / cache / connected SSE client / email outbox / worker pool (not just locals), with
  recursive drill-down into the actual job payloads, cache key→value→ttl entries, and email
  fields; **stop-the-world** (suspend all background threads on a breakpoint, resume on
  continue — excludes the breakpoint + adapter threads; caveat: suspend-not-time-freeze for
  timers); and a **SQL scope** showing the exact parameterized statement, bound params, and
  an escaped read-only preview of what the driver runs.
- **Extension (`editor/vscode-tesl`)** — Test Explorer (TestController), doctest code lens,
  "run function with input", file-level run/debug-all lenses, and the minimap grammar fix.

**The one remaining bucket is IR-1** (the retained, demand-driven multi-file semantic index).
Every ⬜ item above needs it; it is the platinum long-pole, large enough to be its own
program, and is tracked separately (roadmap task #27 / `../completed/03-ir-1-semantic-layer.md`).

> **Deferred backlog moved out:** the full remaining to-do list — the IR-1 cross-file cluster,
> the independent niche features (inlineValue, documentColor, inlineCompletion, coverage/mutation
> lens, true remote attach), and the Gold/Platinum enhancements of the shipped methods — now
> lives in [`../later/further_editor_improvements.md`](../later/further_editor_improvements.md).
> The capability matrix below is retained as the historical gap analysis: its **"Now" column
> reflects the pre-2026-06 baseline** — see the ✅ summary + "Shipped 2026-06" above for what
> actually shipped, and the Gold/Platinum columns are the deferred backlog.

## Why now

The editor is the daily surface of the language, and we are past the hard part: **the
language server is our code**, and VSCodium (an identical client to VS Code) consumes
whatever capabilities we advertise — none of this touches a proprietary layer. The compiler
already exposes the semantic data (typed queries via `--*-json`, the IR-1 `--semantic-json`
snapshot) that most unshipped capabilities need. So the path to "platinum" is mostly
**advertising more LSP methods backed by data we already compute**, gated behind two
foundational enablers (resilient parsing + retained semantics).

This doc is the **capability target and gap analysis**, organized by LSP method — the menu
of what can be built. The earlier DX execution wave (`../completed/improved_devx.md`) has
shipped, so closing the remaining platinum gaps needs **new** work items rather than a live
sibling; retained semantics live in `../completed/03-ir-1-semantic-layer.md`. This file is
the north star they aim at.

## Goals & success criteria

- **Platinum across the LSP surface**, backed by IR-1 retained semantics rather than
  per-keystroke recompiles.
- **Latency budgets met on real projects**: completion < 100 ms, diagnostics sub-second,
  no full-flush refreshes.
- **Resilient**: every capability still answers on a mid-edit/broken buffer (today most
  queries fail the moment the file doesn't parse).
- **Cross-file correct**: definition/references/rename span the whole project, not one file.

## Current state — what ships today

| Layer | Where | What it does |
|---|---|---|
| LSP server | `editor/tesl-lsp/tesl-lsp.rkt` | hover, completion, definition, references, rename, codeAction, push diagnostics, did-open/change/save/close |
| Query flags | `compiler/bin/main.ml` | `--check-json`, `--type-at-json`, `--field-at-json`, `--definition-json`, `--occurrences-json` (same-file), `--completions-json`, `--local-bindings-json`, `--semantic-json`; also `--fmt`, `--lint`, `--ir` |
| Extension | `editor/vscode-tesl/` | TextMate grammar, language-configuration, run/debug-test code lenses, DAP wiring |
| Debugger | `dsl/debug/dap-server.rkt`, `checkpoint.rkt` | breakpoints, continue/step-in/over, variable inspection (proof-unwrapped) |
| Contract | `editor/protocol.md` | versioned compiler↔editor JSON protocol |

## Capability matrix (LSP surface → Now / Gold / Platinum)

Legend: ✅ shipped · 🟡 partial · ⬜ absent. "Now" reflects the current server/extension.

### 1. Diagnostics — pre-compile feedback
| Feature | LSP method | Now | Gold | Platinum |
|---|---|---|---|---|
| Error/warning reporting | `textDocument/publishDiagnostics` (push) | ✅ on open/save/change | Live (debounced); severity tags; `codeDescription` URL; `relatedInformation` at the cause | Teaching-grade messages with carets + machine-applicable fixes in `data`; layered (syntactic in ms, semantic streamed) |
| Client-pulled diagnostics | `textDocument/diagnostic` (3.17 pull) | ⬜ | Client controls freshness | Result-ID caching → unchanged files return "no change" cheaply |
| Whole-workspace diagnostics | `workspace/diagnostic` | ⬜ | Project-wide on demand with progress | Edit a signature → every broken call site re-flags instantly, streamed via partial results |

### 2. Completion
| Feature | LSP method | Now | Gold | Platinum |
|---|---|---|---|---|
| Autocomplete | `textDocument/completion` | 🟡 type-aware members after `.`; kinds + detail + docs | + snippet inserts (`f($0)`); auto-import via `additionalTextEdits`; good sort/filter text | Expected-type ranking; postfix completions; works on broken/mid-edit buffers; whole-interface stubs |
| Lazy detail | `completionItem/resolve` | ⬜ | Docs/edits computed only for the highlighted item | Heavy auto-import edits resolved lazily |
| Server ghost text | `textDocument/inlineCompletion` | ⬜ | Predict obvious next tokens from types | AI proposals filtered through the type checker (only suggestions that compile) |

### 3. At-a-glance information
| Feature | LSP method | Now | Gold | Platinum |
|---|---|---|---|---|
| Hover | `textDocument/hover` | ✅ type + docs + def link; sub-expression & `.field` types | (met) | Elaborated/instantiated generic types; contextual facts (effects, proven obligations) |
| Parameter hints | `textDocument/signatureHelp` | ⬜ | Active-param highlight tracking commas; per-param docs | Overload set narrows as args are typed; live generic inference; correct through nested calls |
| Inline annotations | `textDocument/inlayHint` (+ resolve) | ⬜ (data exists: `--local-bindings-json`, `--type-at-json`) | Inferred `let` types + parameter-name hints | Generic args, implicit coercions; interactive (click→navigate); density-tuned |
| Debug-time values | `textDocument/inlineValue` | 🟡 values shown via DAP, not LSP inlineValue | Show variable values inline while debugging | Computed/expression values, not just variables |

### 4. Navigation & comprehension
| Feature | LSP method | Now | Gold | Platinum |
|---|---|---|---|---|
| Go to definition | `textDocument/definition` | 🟡 same-file | Cross-file, re-exports | Correct through generated code/desugaring |
| Declaration / type / impl | `…/declaration`, `…/typeDefinition`, `…/implementation` | ⬜ | Implemented | Resolved through interface/dispatch |
| Find references | `textDocument/references` | 🟡 same-file (`--occurrences-json`) | Project-wide; classified read/write/call | Through dynamic dispatch |
| Occurrence highlight | `textDocument/documentHighlight` | ⬜ (derivable from occurrences) | Highlight every use under cursor | Write-vs-read coloring |
| Clickable links | `textDocument/documentLink` (+ resolve) | ⬜ | URLs/paths + intra-project symbol links clickable | Resolve targets lazily |
| Cross-repo identity | `textDocument/moniker` | ⬜ | — | Stable monikers for cross-repo / LSIF navigation |

### 5. Structure & hierarchy
| Feature | LSP method | Now | Gold | Platinum |
|---|---|---|---|---|
| Outline / breadcrumbs | `textDocument/documentSymbol` | ⬜ (data in `--semantic-json`) | Hierarchical tree with ranges + detail | Stable across edits; drives sticky-scroll cleanly |
| Project symbol search | `workspace/symbol` (+ resolve) | ⬜ | Fuzzy, persistent index | Instant on huge repos; lazy location resolve |
| Folding | `textDocument/foldingRange` | 🟡 grammar markers (not semantic LSP) | Syntax-aware regions, comments | Custom semantic regions |
| Smart selection | `textDocument/selectionRange` | ⬜ | Semantic-aware expansion | expression→statement→block by syntax node |
| Call hierarchy | `callHierarchy/prepare` + in/out | ⬜ | Incoming/outgoing tree | Accurate through dispatch |
| Type hierarchy | `typeHierarchy/prepare` + super/sub | ⬜ | Super/subtype graph | (met) |

### 6. Editing, fixes & refactoring (`Ctrl+.`)
| Feature | LSP method | Now | Gold | Platinum |
|---|---|---|---|---|
| Quick fixes & refactors | `textDocument/codeAction` (+ resolve) | ✅ fixes from diagnostics | `source.fixAll` on save; organizeImports; extract/inline; `isPreferred` | Compiler-supplied structured fixes replayed from diagnostic `data`; cross-file generation ("create missing function"); domain refactors ("supply missing witness", "thread capability") |
| Actionable annotations | `textDocument/codeLens` (+ resolve) | ✅ run/debug-test (extension) | Reference counts; Run/Debug above tests | Domain actions (discharge obligation, run doctest); resolve lazily |
| Rename | `textDocument/rename` + `prepareRename` | 🟡 semantic, same-file | Cross-file; updates imports; `prepareRename` validates cursor | Conflict/shadowing detection; rename-after-extract |
| Formatting | `…/formatting`, `…/rangeFormatting`, `…/onTypeFormatting` | ⬜ over LSP (`--fmt` exists, unwired) | On-save, on-type, range-safe | Fast on keystroke; never corrupts on invalid input |
| Paired editing | `textDocument/linkedEditingRange` | ⬜ | Edit open/close together | Rename-linked identifiers live |
| Update on file move | `workspace/willRename/didRename/didCreate/didDelete Files` | ⬜ | Renaming a file fixes its imports project-wide | Returns a `WorkspaceEdit` atomically |

### 7. Visual semantics
| Feature | LSP method | Now | Gold | Platinum |
|---|---|---|---|---|
| Semantic highlighting | `textDocument/semanticTokens/full` (+ range, delta) | ⬜ regex grammar only | Meaning-based (params vs locals, types vs values) + modifiers (readonly, deprecated) | Correctness-signaling color; delta updates → flicker-free |
| Color swatches | `textDocument/documentColor` (+ presentation) | ⬜ | Inline swatches + picker for color literals | Custom domain "color-like" values |

### 8. Cross-cutting / lifecycle
| Feature | LSP method | Now | Gold | Platinum |
|---|---|---|---|---|
| Custom commands | `workspace/executeCommand` | 🟡 extension-side commands | Server-side actions from code actions/CodeLens | Arbitrary safe ops with workspace edits |
| Apply server edits | `workspace/applyEdit` | 🟡 via rename/codeAction | Multi-file edits from commands | Atomic, undo-grouped, with preview |
| Config & file watching | `…/didChangeConfiguration`, `…/didChangeWatchedFiles` | ⬜ | React live to settings + external changes | Fine-grained re-index of only affected files |
| Long-task feedback | `$/progress` (work-done + partial) | ⬜ | Progress bar for indexing | Stream results as computed (findings mid-sweep) |
| Freshness signals | `workspace/{semanticTokens,inlayHint,codeLens,diagnostic}/refresh` | ⬜ | Server asks client to re-pull on state change | Surgical refresh, never full-flush |
| Incremental sync | `textDocument/didChange` (incremental) | 🟡 incremental or full recheck | Incremental ranges | Drives query-engine invalidation |

## The two enablers the matrix doesn't show

The protocol surface is *what* we can expose; these two decide *which tier* we actually hit,
regardless of how many methods we implement:

1. **Resilient parsing (error recovery). — ✅ core SHIPPED (2026-06).** The editor-facing
   enabler has landed: `Compile.semantic_json_source` now returns **partial** data on parse
   failure instead of `None` (the resilient semantic snapshot — partial JSON on parse error),
   so a mid-edit buffer yields a usable snapshot for the methods above. Residual nicety (no
   longer a Gold+ precondition): `compiler/lib/parser.ml`'s in-declaration recovery is still
   **coarse / top-level-only** (`skip_to_top` resynchronizes at the next top-level keyword),
   so error spans can be wider than ideal — widening parser recovery would tighten them.
2. **Incremental, demand-driven recomputation (IR-1 retained semantics).** Without it we
   can't meet the latency budgets on real projects, so we degrade to Baseline under load.
   Today every query re-parses and re-type-checks; only imported-module parses are cached.
   Owned by `../completed/03-ir-1-semantic-layer.md`.

## Tesl-specific wishlist (mapped to the surface)

| Want | LSP/DAP surface | Notes / overlap |
|---|---|---|
| Inspect queues/workers/email/cache when paused | DAP `variables` | Extends current variable inspection; overlaps `../completed/improved_devx.md` WS1 |
| Conditional breakpoints | DAP `setBreakpoints` (condition) | Deferred Phase in `../completed/improved_devx.md` WS1 |
| Run doctest(s) via code lens | `codeLens` + `executeCommand` | Mirrors the existing run/debug-test lenses |
| REPL-like "run a function with input" | `executeCommand` + terminal/DAP | New command |
| Test Explorer integration | client test API + lenses | Builds on existing test code lenses |
| Coverage + mutation-survival ratio as code lens | `codeLens` | Data from the mutation/test harness |
| Attach to a running process | DAP `attach` | New DAP mode (today launch-only) |
| Rename variables/functions/**modules** | `rename` | Vars/fns same-file today; module rename + cross-file ⬜ |
| "Find all tests that call this function directly" | `references` / `callHierarchy` | Needs cross-file index (IR-1) |
| Minimap rows oversized near `check` | `semanticTokens` / grammar bug | Concrete bug; likely a TextMate scope spanning too far — fix when semantic tokens land or in the grammar |

## Sequencing

1. **Enablers first** — resilient parsing + IR-1 retained semantics. They unblock Gold+
   everywhere and the latency budgets. (IR-1 is its own item; coordinate.)
2. **Cheap wins that advertise data we already compute** — `documentSymbol` (from
   `--semantic-json`), `semanticTokens` (from types; also fixes the minimap bug),
   `formatting` (wire `--fmt`), `inlayHint` (from `--local-bindings-json`/`--type-at-json`),
   `signatureHelp`, `documentHighlight` (from occurrences).
3. **Cross-file nav** — promote definition/references/rename to project-wide (needs the
   IR-1 multi-file index); module rename.
4. **Diagnostics depth** — pull + workspace diagnostics with result-ID caching; `$/progress`
   and `refresh`.
5. **Hierarchy & richer actions** — call/type hierarchy; codeLens reference counts;
   structured/cross-file code actions keyed off stable error codes (`../completed/improved_devx.md` WS4).
6. **Debugger & testing polish** — conditional breakpoints, attach, doctest/REPL run,
   Test Explorer, coverage/mutation code lenses.

## Out of scope

- Error-message *content* quality — shipped in `../completed/improve_error_messages.md`;
  this doc only consumes stable codes/`data` for code actions.
- Any proprietary VS Code surface — not needed; the VSCodium client is identical, so the
  whole LSP surface is reachable.
- The retained-semantics engine itself — designed in `../completed/03-ir-1-semantic-layer.md`.

## Critical files

- `editor/tesl-lsp/tesl-lsp.rkt` — advertised capabilities + method handlers.
- `editor/vscode-tesl/extension.js`, `syntaxes/tesl.tmLanguage.json`, `debug/` — client,
  grammar (minimap bug), DAP wiring.
- `editor/protocol.md` — versioned contract for any new query.
- `compiler/bin/main.ml` — query flags; `compiler/lib/compile.ml` (`semantic_json_of_module`,
  and `semantic_json_source:2468` — make it return partial data on parse `Err`: the real
  resilience enabler).
- `compiler/lib/parser.ml` — coarse/top-level-only recovery (`skip_to_top:5095`); widening
  it helps but is not the editor-facing block on its own.
- `dsl/debug/dap-server.rkt`, `dsl/debug/checkpoint.rkt` — debugger features.
- Related: `../completed/improved_devx.md`, `../completed/03-ir-1-semantic-layer.md`.

## Verification

Editor capabilities are verified by exercising them in VSCodium against the running server:
each newly-advertised method tested on a real `.tesl` file (and on a deliberately broken
buffer for resilience), responses checked against `editor/protocol.md`, with compiler-side
query flags covered by `compiler/test` (e.g. `test_ir`) and the `.tesl` corpus.
