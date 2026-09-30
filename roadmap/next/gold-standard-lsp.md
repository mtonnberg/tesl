# Gold-standard language tooling

Status: in progress, 2026-09-05. Completion and retained-session foundations are
implemented; the full roadmap and release gates are not complete.

Implemented so far:
- Versioned retained compiler sessions shared by the Go LSP and MCP, with the
  same query implementation as one-shot CLI calls. Private project mirrors write
  changed files only; parsed modules, checked types and query results are cached
  within bounded caches. Whole-query answers and the binding graph are revision
  bound; parsed and checked modules survive unrelated changes. Checked metadata
  keys include exact source and transitive import bytes, including selected
  stdlib sources. Missing/recreated imports and resolver precedence are tested.
- Cancellation, crash/restart, process cleanup, LF/CRLF query equivalence and
  disk/overlay/save/close/delete/recreate transitions have regression fixtures.
  The protocol and remaining limitations are in [`editor/protocol.md`](../../editor/protocol.md).
- LSP `$/cancelRequest` reaches active compiler queries and skips canceled queued
  queries. Late successful results cannot publish edits; bounded queues preserve
  document ordering and fail explicitly on overload. Native parity includes the
  full LSP race suite and its cancellation/ID-reuse fixtures.
- Compiler-owned standard-library completion, public sibling-module types,
  import hints, source replacement ranges, documentation, and automatic import
  insertion/extension when a completion is accepted.
- Broken-buffer recovery, comment-preserving imports, LF/CRLF and UTF-16 edit
  handling, local-name precedence, and stale completion rejection after entry,
  overlay, or notified disk changes.
- Content-aware, bounded import parse caching; changed, missing, recreated, and
  repaired imports no longer reuse a path-only cached parse.
- Regression coverage in [`test_completion.ml`](../../compiler/test/test_completion.ml),
  [`test_import_cache.ml`](../../compiler/test/test_import_cache.ml), and
  [`completion_test.go`](../../runtime/go/internal/lsp/completion_test.go), including
  selecting a completion, applying its edits, and checking the resulting program.
- The compiler now owns a bounded workspace binding index, cross-file definition
  and references, and a checked rename proposal. The shared LSP/MCP adapters use
  those semantic identities, validate source hashes and coordinates, and refuse
  incomplete or stale edits. Rename checks import exposure, visibility, capture
  and binding identity, then type/proof-checks the candidate workspace. Navigation
  includes read-only stdlib declarations; rename cannot modify them.
- [`test_workspace_index.ml`](../../compiler/test/test_workspace_index.ml) and
  Go tooling/LSP/MCP fixtures cover imported callers, exported types and
  constructors, shadowing, interpolation, Unicode/CRLF, and stale inputs.
  LSP rename is offered only to clients supporting versioned document changes
  with transactional failure handling. Already-invalid workspaces currently
  receive a refusal rather than a diagnostic-delta rename.

Still required: proactive checking of affected unopened modules, the remaining cross-file
operations, expected-type/proof-aware ranking, proof/effect explanations, and
measured latency/memory gates. The binding index is rebuilt after snapshot changes;
per-module checking reuses unchanged dependency inputs on demand.

Make editing a Tesl project dependable across files, useful while code is
unfinished, and unusually good at explaining proofs. Editors and coding agents
must get their answers from the same compiler semantics.

## Current state and the actual gap

The implementation is the OCaml compiler plus Go tooling, with a VS Code/VSCodium
extension. The old Racket capability lists are historical evidence, not the
acceptance checklist for the current server.

An explicit pain point today is poor discoverability of standard-library
functions and types. Users should not need to know an exact symbol name or its
module before finding useful functionality. Completion must help users discover
what Tesl provides, alongside helping them enter names they already know.

| Area | Current implementation | Work this roadmap owns |
|---|---|---|
| Compiler queries | One-shot JSON queries in [`compile.ml`](../../compiler/lib/compile.ml), including types, definitions, occurrences, completions, and proof obligations | Retain semantic state and answer project queries from a consistent snapshot |
| Unsaved imports | A bounded private mirror applies changed files; retained sessions cache answers for complete snapshots | Add a compiler-owned dependency index so unrelated modules remain checked after edits |
| Editor features | [`server.go`](../../runtime/go/internal/lsp/server.go) provides diagnostics, hover, signature help, navigation, same-file references/rename, fixes, formatting, symbols, hints, and tokens | Audit actual behavior, then extend it across the workspace |
| Completion | Public stdlib functions/types, sibling exported types, import edits, signatures/docs, record fields, and partial parse recovery | Complete lexical scope, expected types, proof-aware ranking, and all contextual syntax |
| Agent access | Compiler JSON and [`MCP`](../../editor/tesl-mcp/README.md) expose targeted queries | Equivalent project queries, explanations, and edit previews without requiring an editor |

This is the active plan for the remaining work described in
[`03-ir-1-semantic-layer.md`](../completed/03-ir-1-semantic-layer.md) and
[`further_editor_improvements.md`](../discarded/further_editor_improvements.md).
Their folder/status labels do not establish that a retained project index exists.
Do not restart the completed Go migration or count previously shipped methods as
new features.

## Outcomes

1. Changing an exported signature updates affected callers, including unopened
   files. Definition, references, rename, and symbol search agree about identity.
2. Completion helps finish real code: a half-written call, a field access, an
   import, a pattern, or an argument requiring a proof.
3. A programmer can discover standard-library functions and types through
   contextual editor completion, including symbols not yet imported, and see
   how to use them without inspecting the library's source.
4. A programmer can see why a proof is available or missing, what effects a call
   requires, and what a proposed edit changes before accepting it.
5. An agent can request that same information as compact, versioned JSON and
   apply the same checked edits using explicit snapshot preconditions.

## Design constraints

### One semantic engine, several clients

- Retain declarations, resolved use sites, inferred and expected types, import
  origins, proof flow, and capability requirements in the compiler. LSP and MCP
  translate these answers; they must not implement independent name resolution
  or proof reasoning.
- Introduce a compiler workspace session over a versioned local protocol. The Go
  tools own session lifecycle, cancellation, and restart. One-shot CLI queries
  remain available and use the same query implementation; an agent session can
  supply overlays without attaching to an editor's private session.
- Identify results by workspace revision, compiler/protocol version, document
  versions/content hashes, and dependency inputs. A changed import invalidates
  dependent answers even when the entry file's content hash is unchanged.
- Preserve the existing compact `agent-context` and LSP diagnostic shapes in
  [`editor/protocol.md`](../../editor/protocol.md). Add explicitly versioned
  project envelopes; do not silently redefine same-file flags or turn every
  targeted query into a full `--semantic-json` dump.

### A correct workspace model

- Follow the compiler's manifest, import, and stdlib resolution rules. Handle
  loose files, nested projects, and multiple workspace folders without merging
  unrelated projects merely because their symbols have the same name.
- Open buffers override disk, including unsaved imported modules. Track reverse
  dependencies and invalidate on edits, save/close, create/delete/move, manifest
  changes, and toolchain changes. Preserve import-cycle and missing-module errors.
- Give declarations semantic identities, not spelling-based identities. Define
  their lifetime across revisions and reject stale identity handles.
- Keep last-good information useful during syntax errors, but label its revision
  and completeness. Never return stale facts as current proof evidence or an
  incomplete reference set as a safe rename.
- Bound indexing, memory, queues, and subprocesses. Exclude generated/build
  directories. Report progress and limits; cancellation or index failure must
  not become a successful empty answer.
- Centralize source-coordinate conversion. Cover UTF-8 compiler offsets,
  negotiated LSP positions (including UTF-16), CRLF, escaped URIs, symlinks, and
  Windows paths. Use the source text of each target file for range conversion.

### Edits are reviewable transactions

Return all edits with their source versions/hashes, affected files, and reasons.
Check rename conflicts, shadowing, visibility, and import ambiguity. Read-only
dependencies are navigable but cannot be edited as part of a workspace rename.
Preview and recheck the candidate snapshot; if it was already broken, distinguish
existing diagnostics from newly introduced ones. Revalidate preconditions at
application time, including hashes of unopened files. Clients unable to enforce
the required preconditions receive a preview or an explicit refusal.

Passing type/proof checks establishes the compiler's guarantees for that snapshot.
It does not establish that a refactoring preserves every intended behavior.
Label generated placeholders and remaining obligations accordingly.

## Delivery plan

### L0 — Freeze contracts and measure the baseline

- [ ] Finish the [implementation inventory](../../editor/language-tooling-status.md)
  against extension commands and executable fixtures for Go LSP methods, compiler
  flags and MCP tools. Record historical claims that are
  absent or narrower in the current implementation.
- [ ] Specify workspace sessions, snapshot identity, partial/stale results,
  cancellation, coordinate encoding, edit preconditions, and compatibility.
- [ ] Capture correctness and latency on a checked-in multi-module fixture and
  a recorded CI runner. Include broken and unsaved buffers from the start.

Exit: a reviewed protocol and capability matrix, reproducible baseline numbers,
and failing fixtures for the missing outcomes. No new advertised capability
without a corresponding test.

### L1 — Retain semantics and make incremental results trustworthy

- [ ] Build the compiler-owned module/dependency index and session lifecycle.
  Cache parsing/checking by semantic inputs, with conservative invalidation
  before optimizing export/interface changes.
- [ ] Retain expected-type and proof metadata already computed by the checker.
  Recover inside declarations so an unfinished expression does not erase
  unrelated declarations or lexical scope.
- [x] Carry all unsaved overlays through each snapshot; publish only results
  that still match the requesting revision. Rebuild deterministically after a
  compiler-session crash.
- [x] Route current LSP and agent queries through the shared engine. Keep the
  existing bounded temporary-project path as a compatibility fallback during
  rollout (`TESL_COMPILER_SESSION=0`), with no competing semantic rules.
- [x] Support active/queued LSP request cancellation, reject late results, and
  bound pending message count/bytes without silently losing document changes.

Exit: incremental results match a fresh compile of the same complete snapshot
after edit/save/close/import-change sequences. Unrelated files remain cached;
stale work never overwrites newer diagnostics.

### L2 — Complete the project-wide editing loop

- [x] Compiler-owned cross-file definition and references, including declaration
  identity and explicit completeness, through LSP and CLI/session/MCP.
- [ ] Cross-file type-definition, use-kind filtering, and pagination for large
  reference sets where supported by the client.
- [ ] Conflict-checked rename across imports and callers; file/module moves
  produce import updates under the same edit-precondition rules.
- [ ] Workspace symbol search and diagnostics for affected unopened files,
  with bounded partial results, progress, and clearing of obsolete diagnostics.
- [ ] Incoming/outgoing call navigation using resolved calls; explicitly mark
  unknown or indirect targets instead of inventing a complete call graph.
- [ ] Expose the same project operations through targeted CLI/session and MCP
  queries. Paginate large reference/diagnostic sets and report completeness.

Exit: rename an exported function in an unsaved module, preview every caller,
apply the edit, and recheck the project from both an editor and an agent client.
Shadowed locals, comments, and strings remain unaffected.

### L3 — Contextual completion and standard-library discovery

| Context | Required behavior |
|---|---|
| Expressions and calls | In-scope locals/parameters first, instantiated signatures, argument labels, pipeline-compatible candidates, expected-type ranking |
| Fields and records | Fields from the receiver's resolved type; missing record fields; no fields from an unrelated same-named type |
| Imports and qualified names | Resolvable modules/exports, documentation, and a single previewable auto-import edit without duplicates or ambiguous names |
| Standard-library discovery | Complete public modules, functions, and types without requiring a prior import; show module origin, documentation, and how to bring a result into scope |
| Type positions | Suggest standard-library types with type parameters, descriptions, and usage examples; mark auto-import candidates and automatically add or extend the required import when a type is selected; expose public constructors and record fields where applicable, while respecting opaque types |
| Patterns and declarations | ADT constructors and missing case arms; syntax-aware templates for supported Tesl declarations/configuration |
| Proof-bearing arguments | Show required/available facts and applicable checks; distinguish a candidate needing validation from one usable immediately |
| Incomplete source | Useful results after a trailing dot, half-written argument, missing delimiter, or an error in a neighboring declaration |

- [ ] Supply stable ranking, replacement ranges, lazy documentation, and snippet
  tab stops, with plain-text fallbacks for clients without snippet support.
- [ ] Return structured type/proof/capability requirements to agents as well as
  editor labels. Snippet insertion and auto-import must use one snapshot.
- [ ] Derive standard-library completion from the compiler's public API and
  documentation sources, keyed to the selected toolchain version.
  Cover every public function and type; surface missing documentation as a
  coverage gap rather than maintaining a separate hand-written symbol list.
- [ ] Show signatures, type parameters, descriptions, short checked examples,
  required imports, and relevant proof/capability requirements in discovery
  results and completion details. Keep local symbols prominent and distinguish
  unimported library candidates so discoverability does not create a noisy list.
- [ ] Provide the same targeted completion/detail queries through CLI/session
  and MCP, with offline documentation from the installed toolchain.
  Standard-library discovery must also work in a new project with no imports.
- [ ] Test accepted insertions in their intended context. Templates with holes
  identify those holes; they must not be presented as fully checked programs.
- [x] Selecting an unimported type completes its name and adds/extends its import
  as one completion action, with the source module and auto-import hint visible
  before selection. Test fresh imports, existing exposing lists, wholesale
  imports, duplicate prevention, name conflicts, and stale-buffer rejection.

Exit: golden completion fixtures cover every row, including negative candidates,
scope/shadowing, generic types, and broken-buffer recovery. Add editor and agent
scenarios that start with an incomplete expression or type annotation, discover an
unimported standard-library function and a type, inspect examples, insert/import
them, and successfully recheck the result. Verify completion coverage against the
compiler's public API and ensure results match the installed library version.

The browser-based searchable catalog and Hoogle-style search belong to the
separate playground work. This roadmap reuses shared compiler metadata where
appropriate but does not implement that UI or duplicate its search engine.

### L4 — Three Tesl-specific productivity features

| Feature | Human experience | Agent equivalent and acceptance evidence |
|---|---|---|
| Explain this proof | Follow a required fact to the check/branch/value that supplies it, or to the point where evidence is missing | A bounded evidence graph with source locations, available/required facts, and unresolved steps; positive and negative proof fixtures agree with compiler diagnostics |
| Explain this effect | Hover or navigate from a call's capability/auth requirement to the declaration and relevant call path | Structured requirements and known propagation paths; indirect/unknown paths are explicit, and viewing the explanation executes no application code |
| Preview a proof-preserving change | Generate a missing case skeleton or apply a compiler-supported proof repair, then inspect changed files and the diagnostic delta | The same edit plan and recheck result; a repair never fabricates a witness, removes an auth requirement, or weakens a signature merely to clear an error |

- [ ] Ship all three through standard hover, code actions, links, and optional
  hints, with richer extension presentation where useful. Keep hints adjustable.
- [ ] Include one end-to-end demonstration per feature in editor documentation
  and one matching agent example. Tie every claim to a source snapshot.

Exit: each feature saves an identifiable navigation/editing step and works through
both clients. Rechecking a suggested repair must leave any unproven obligation
visible rather than declaring success from syntax alone.

## Verification and performance

Extend compiler tests, Go LSP/tooling/MCP protocol tests, and the extension tests.
Add real VS Code and VSCodium extension-host scenarios for the outcomes above;
mocked API tests alone cannot prove the integrated experience. Preserve the
existing authoritative [`ci.sh`](../../ci.sh) gate.

Required adversarial cases include two dirty imported buffers, unopened callers,
import cycles, duplicate names, edits during rename/resolve, cancellation, process
crashes, malformed protocol replies, Unicode/CRLF, and repeated workspace changes.
Property-test incremental results against cold snapshots and check for temporary
file, process, and memory growth after repeated sessions.

Initial performance targets, to be measured and frozen with runner details in L0:

| Operation on a 100-module / roughly 20,000-line fixture | Target |
|---|---|
| Warm completion | p95 at most 100 ms |
| Warm hover/definition | p95 at most 150 ms |
| Edit to affected semantic diagnostics | p95 at most 750 ms |
| Cold workspace ready | At most 5 seconds |
| Combined retained compiler and LSP memory after warm-up | At most 512 MiB, with no sustained growth after repeated edit cycles |

Include transport, queueing, and debounce time; publish the sample count and
fixture revision. A separate larger stress fixture verifies bounded behavior
and progress. These are proposed release targets, not measurements of today's
implementation; revisions require an explicit tradeoff, not hidden test skips.

## Boundaries and completion

Package discovery, installation, and toolchain version matching belong to
[`mainstream_installation.md`](mainstream_installation.md). Native path, process,
and editor integration belongs to [`windows_support.md`](windows_support.md).
The semantic model must support those platforms from L1; Linux/macOS delivery
does not wait for the Windows installer.

Defer speculative AI ghost text, cross-repository indexing, color pickers, and
type hierarchies without a corresponding Tesl language model. Debugger runtime
features remain in the existing DAP tooling; do not duplicate them in LSP.

Complete when L0–L4 pass, current capabilities remain compatible, and the same
project query/edit scenarios work for humans and agents. Update `AGENTS.md`,
`editor/protocol.md`, editor/MCP setup docs, and stale roadmap links to describe
the shipped scope. Do not leave two active plans for the retained semantic index.
