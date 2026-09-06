# Language tooling implementation inventory

Source audit: 2026-09-05. This inventory describes the Go server in
`runtime/go/internal/lsp/server.go` and `workspace.go`, not historical Racket implementations.
The executable fixtures are in `server_test.go`, `completion_test.go`,
`requests_test.go`, `workspace_test.go`, and `internal/tooling/session_test.go` beside those implementations.

| Surface | Compiler contract | Current boundary |
|---|---|---|
| Push/pull diagnostics | `--check-json` | Includes imported-module diagnostics; all open overlays participate; no general unopened-workspace scheduler |
| Hover | Type/field/config queries and `--doc-json` | Compiler types and stdlib docs; no proof-flow explanation graph |
| Definition/declaration | `--workspace-definition-json` | Compiler-owned project identities across imports; read-only lifted stdlib definitions; explicit incomplete-index errors |
| Type definition | `--type-definition-json` | Existing same-file type lookup |
| References | `--workspace-references-json` | Cross-file compiler identities and import/export clauses; declaration filtering; explicit completeness and per-target UTF-8/UTF-16 conversion |
| Highlights/linked editing | `--occurrences-json` | Same-file occurrences |
| Prepare rename/rename | `--workspace-references-json`, `--workspace-rename-json` | Rechecked staged project, binding/capture/type/proof checks and whole-input preconditions; requires an initially valid project and a client supporting transactional versioned edits |
| Completion/resolve | `--completions-json`, `--doc-json` | Stdlib discovery, sibling exported types, auto-imports, receiver fields, partial parsing, revision checks |
| Signature help | `--signature-help-json` | Callee parameters and active argument |
| Code actions | Diagnostic fixes | Machine-applicable compiler edits; no general proof-preserving refactor preview |
| Selection ranges | `--selection-range-json` | Nested source ranges |
| Inlay hints | `--local-bindings-json` | Inferred binding types; no general expected-type/proof hint engine |
| Document symbols and semantic tokens | `--semantic-json` | Document snapshot; full/range/delta token transport does not imply a workspace index |
| Folding and document links | Go source/URI adapter | Editor presentation, not additional name/proof resolution |
| Formatting | `--fmt` on an isolated source copy | Full-document replacement |
| Lifecycle | Open/change/save/close/watched-file notifications | Diagnostic generations and retained compiler ownership |
| Request cancellation | `$/cancelRequest` to compiler context cancellation | Active/queued cancellation, late-result rejection, bounded queue; document handlers retain arrival order |

Workspace symbols, cross-file type definitions, file/module moves, affected-module
incremental checking, call hierarchy and proof/effect explanations remain roadmap
work. The compiler index records module dependency edges and semantic use sites;
changed snapshots still invalidate the graph conservatively. Unsupported semantic
contexts and source limits return explicit incompleteness, preventing unsafe rename.
Renames in an already type/proof-invalid project are refused; diagnostic-delta
validation is still pending.

MCP exposes `tesl.agent_context`, `tesl.check`, `tesl.type_at`, `tesl.signature`,
`tesl.completions`, `tesl.definition`, `tesl.references`, and
`tesl.proof_obligations` through the same compiler query implementation. Its
`references` tool retains the same-file contract. The additional
`tesl.workspace_definition`, `tesl.workspace_references`, and
`tesl.workspace_rename` tools expose project queries and checked, read-only edit
proposals with snapshot preconditions. `tesl.debug_inspect` and
`tesl.debug_attach` use the separate authenticated runtime debugger.

The byte-framed workspace session protocol, ownership rules, compatibility switch,
bounds and stale-result handling are specified in [protocol.md](protocol.md).
The existing compact agent-context and diagnostic JSON envelopes remain version 1.

## Repeatable latency probe

From `runtime/go`, after building the compiler with the pinned toolchain:

```sh
go test ./internal/tooling -run '^$' -bench BenchmarkWorkspaceRepeatedQuery -benchtime=30x -benchmem
```

The checked-in benchmark constructs a two-module project, warms one diagnostic
query, then repeats it 30 times. Local observation on 2026-09-05, Linux amd64,
AMD Ryzen 7 5700X, Go 1.26.6:

| Adapter | Mean wall time/query | Go allocations/query |
|---|---:|---:|
| Fresh compiler + copied project | 11.39 ms | 185 |
| Retained compiler + unchanged mirror | 0.238 ms | 125 |

These are local microbenchmark observations, not CI latency or memory acceptance
thresholds. They exclude cold startup, edits and large projects. The next L0/L1
measurement gate needs recorded runner identities, p50/p95, peak compiler RSS,
large/broken snapshots, and edit/dependency invalidation workloads.
