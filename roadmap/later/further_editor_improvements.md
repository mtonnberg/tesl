# Further editor improvements — deferred backlog

Carved out of `roadmap/completed/editor_target_description.md` (the platinum-editor gap
analysis) when its **do-now scope shipped** in the 2026-06 push. That doc is the historical
capability matrix + what landed; this file is everything still open, grouped by what gates it.

The 2026-06 push shipped the entire non-cross-file surface: 13 LSP methods (signatureHelp,
completion resolve+snippets, declaration, typeDefinition, read/write documentHighlight,
foldingRange, selectionRange, range+on-type formatting, semanticTokens range+delta, incremental
sync, codeAction fixAll/organizeImports, executeCommand+applyEdit, documentLink,
linkedEditingRange, pull diagnostics, config/watch, inlayHint+resolve, refresh), the full DAP
"no-magic" debugger (conditional+hit breakpoints, attach=launch, full live-domain inspection
incl. SSE clients + worker pools, deep entry drill-down, stop-the-world, SQL transparency), the
extension features (Test Explorer, doctest lens, run-function, lenses, minimap fix), 4 compiler
query flags, and the resilient semantic snapshot (Enabler 1). All gated (LSP rackunit 212; DAP
suites; ci.sh 58-lesson byte-exact 0-differ).

---

## 1. The big bucket — gated on IR-1 (retained multi-file index)

**Prerequisite — IR-1 retained, demand-driven multi-file semantic index** (the platinum
long-pole; tracked as roadmap task #27; design in `../completed/03-ir-1-semantic-layer.md`).
Today every query re-parses + re-type-checks a single file; only imported-module parses are
cached. IR-1 is the enabler for everything in this section AND for the latency budgets
(completion < 100 ms, diagnostics sub-second, no full-flush refreshes). It is large enough to
be its own program. **Nothing below lands cleanly until it does.**

Cross-file / project-wide features it unblocks:
- **Go to definition — cross-file + re-exports** (`textDocument/definition`; today same-file).
- **Find references — project-wide** + read/write/call classification (`textDocument/references`;
  today same-file via `--occurrences-json`).
- **Rename — cross-file + module rename** (`textDocument/rename`; today same-file) + conflict/
  shadowing detection.
- **Whole-workspace diagnostics** (`workspace/diagnostic`) — edit a signature → every broken
  call site re-flags, streamed via partial results; pairs with `$/progress`.
- **Project symbol search** (`workspace/symbol`) — fuzzy, persistent index, lazy location resolve.
- **Call hierarchy** (`callHierarchy/prepare` + incoming/outgoing).
- **Type hierarchy** (`typeHierarchy/prepare` + super/sub) — also needs a type/interface model.
- **Update on file move** (`workspace/willRename/didRename/didCreate/didDelete`) — return a
  `WorkspaceEdit` that fixes imports project-wide.
- **Cross-repo identity** (`textDocument/moniker` / LSIF) — out of near-term scope.
- **codeLens reference counts** (needs the cross-file index).
- **"Find all tests that call this function directly"** (cross-file call index + a references/
  callHierarchy filter for test callers).
- **`$/progress`** work-done + partial-result streaming for indexing/workspace sweeps.

## 2. Independent features (NOT IR-1-gated — do-able anytime)

- **`textDocument/inlineValue`** — LSP-native inline values while debugging. Low marginal value:
  the DAP path already shows variable values inline; only worth it for editors that prefer the
  LSP surface. (S)
- **`textDocument/documentColor` (+ presentation)** — inline color swatches/picker. Niche; add
  only if a color-like domain value warrants it. (S)
- **Coverage + mutation-survival ratio as a code lens** (`codeLens`) — plumb the existing
  mutation/coverage harness data to a per-function lens. Data source exists; the UI wiring +
  a compiler/CLI surface to emit per-target coverage/mutation stats are new. (L)
- **True remote / PID attach** (DAP `attach`) — today `attach` is a bounded alias of `launch`
  (in-process debuggee via `dynamic-require`, so there is no external process to attach to). A
  real attach needs a debuggee-side agent + a transport (socket) and a way to launch a tesl
  program with that agent enabled. (L, architectural)
- **Server ghost text** (`textDocument/inlineCompletion`) — speculative; the interesting version
  is AI proposals filtered through the type checker so only suggestions that compile are shown.
  No incremental path today. (XL, aspirational)

## 3. Gold / Platinum enhancements of already-shipped methods

The "Now" tier of these shipped in 2026-06; the richer tiers remain:
- **Completion** — expected-type ranking; postfix completions; whole-interface stubs;
  auto-import via `additionalTextEdits`. (Cross-file generation here is IR-1-gated.)
- **codeAction** — extract/inline refactors; `isPreferred`; compiler-supplied structured fixes
  replayed from diagnostic `data`; **domain refactors** unique to Tesl ("supply missing
  witness", "thread capability", "discharge obligation"); cross-file "create missing function"
  (IR-1-gated).
- **semanticTokens** — richer modifiers (readonly, deprecated); deeper meaning (params vs locals,
  types vs values); correctness-signaling color.
- **inlayHint** — generic-argument hints; implicit-coercion hints; click→navigate; density tuning.
- **Hover** — elaborated/instantiated generic types; contextual facts (effects, proven
  obligations) inline.
- **Diagnostics** — layered delivery (syntactic in ms, semantic streamed); `codeDescription` URL
  + `relatedInformation` at the cause. (Message *content* quality already shipped in
  `../completed/improve_error_messages.md`.)
- **Parser recovery (residual)** — `compiler/lib/parser.ml` recovery is coarse / top-level-only
  (`skip_to_top`); the editor-facing resilient snapshot already shipped, but widening
  in-declaration recovery would tighten error spans on mid-edit buffers. (M, nicety)

## Sequencing

1. **IR-1 first** — it is the single gate for §1 and the latency budgets; everything project-wide
   waits on it.
2. **Independent §2 features** can land opportunistically (each is small except attach/coverage).
3. **§3 enhancements** are incremental polish on shipped methods; pick by user demand.

## Verification

Same as the original doc: exercise each newly-advertised method in VSCodium against the running
server (and on a deliberately broken buffer for resilience), check responses against
`editor/protocol.md`, with compiler-side query data covered by `compiler/test` (e.g. `test_ir`)
and the `.tesl` corpus; DAP features covered by the `tests/dap-*` rackunit suites.
