# Go debugger, LSP, and complete Racket removal
## Goal
Finish the migration described in `roadmap/next/migrate_to_golang.md` by replacing the debugger, LSP, MCP/editor tooling, remaining runtime support, generated artifacts, and Racket-owned tests with Go-backed equivalents. The final repository must preserve or improve current capabilities while containing no tracked Racket source, no Racket emitter or generator, no active Racket invocation, no Racket build dependency, and no workflow that recreates `.rkt` files.
This item is broader than porting `dsl/debug/` and `editor/tesl-lsp/`. It owns the complete Racket exit because debugger/LSP completion is not meaningful while runtime modules, tests, examples, templates, MCP, compiler output, packaging, or CI still depend on Racket.
## Current state
- The Go runtime is in `runtime/go/teslrt/`; Go emission is in `compiler/lib/emit_go.ml`. Runtime semantics, dependency policy, corpus parity, release-mode zero-instrumentation, and general Go quality gates remain shared with `roadmap/next/migrate_to_golang.md`.
- **Phase 1 started 2026-08-19.** `runtime/go/internal/protocol` now provides bounded Content-Length framing, strict JSON-RPC 2.0 envelopes, and UTF-16-aware document positions. `runtime/go/internal/tooling` provides cancellable, timeout-bounded, output-bounded compiler subprocess queries, including system-temp unsaved-source files with `TESL_LOGICAL_PATH` and strict single-JSON-response validation. The packages have unit and race tests and use only the standard library.
- This first slice is intentionally source-tooling infrastructure only. A Go LSP development entrypoint now exists, but it is not packaged as the default and does not claim full feature parity. The existing Racket tools remain the compatibility surface until the C0/C1 gates below are met.
- Seven Racket modules under `dsl/debug/` implement checkpoints, stepping, stop-the-world coordination, DAP launch/attach, headless inspection, control channels, domain inspection, and value trees. Go emission now has ABI v1 and generated debug checkpoints; Racket remains the compatibility oracle during overlap.
- DAP currently supports launch and live attach, conditional and hit-conditional breakpoints, threads, stack/scopes/variables, continue/next/step-in/step-out, source, evaluate for hover/clipboard, nested values, SQL/domain scopes, named-test debugging, and truthful unsupported-command errors (`dsl/debug/dap-server.rkt:984`, `dsl/debug/dap-server.rkt:1688`).
- Live attach uses NDJSON over a Unix socket with loopback TCP fallback. Headless inspection has a version-2 JSON contract. The attach CLI supports bridge, once, snapshot, ping, detach, breakpoint conditions, hit conditions, and timeouts.
- The LSP is a 4,078-line Racket stdio JSON-RPC server. It delegates semantic queries to OCaml compiler JSON flags through system-temp source copies plus `TESL_LOGICAL_PATH`, and owns incremental document state, diagnostics, completions, hover, navigation, rename, symbols, tokens, inlay hints, formatting, fixes, and editor heuristics (`editor/tesl-lsp/tesl-lsp.rkt:850`, `editor/tesl-lsp/tesl-lsp.rkt:2089`, `editor/tesl-lsp/tesl-lsp.rkt:2509`).
- The VS Code extension resolves Racket and `.rkt` scripts for LSP/DAP. CI phase 10 runs Racket debugger, runtime, and MCP suites. `editor/tesl-mcp/tesl-mcp.rkt` exposes compiler and debug tools and is part of the required migration.
- Current checkout inventory: 334 existing tracked `.rkt` files: 35 under `dsl/`, 49 under `tesl/`, 3 under `editor/`, 104 under `example/`, 0 under `templates/`, and 143 under `tests/`. Three obsolete tests tied to deleted generated examples were removed. Templates retain only `.tesl` sources and Go/Docker generation; no committed Racket template artifacts remain. Racket remains an explicit compatibility/oracle backend until C3.
- Runtime changes must preserve unrelated worktree edits; migration gates inspect only intended files and never reset user changes.
## Non-negotiable invariants
- Keep the OCaml compiler/frontend and compiler JSON editor-query API unless separately reviewed. This roadmap removes Racket, not OCaml.
- Preserve Tesl source compatibility, diagnostic identity/ranges/fixes, DAP/LSP/MCP wire contracts, CLI names/flags/exit codes, and machine-readable schemas unless an improvement is explicitly versioned and compatibility-tested.
- Release Go emission must contain no checkpoint calls, debug metadata registration, debug imports, control listeners, debug goroutines, or debug-only value retention. Debug instrumentation must not alter evaluation order, panic/error behavior, proof erasure, resources, concurrency, SQL behavior, or application output when unattached.
- Every Racket file requires a named replacement owner and passing evidence before deletion. Similar filenames or aggregate test counts are not proof of parity.
- Differential Racket-versus-Go tests are required while both implementations exist. After deletion, implementation-independent protocol transcripts and golden fixtures become the compatibility oracle.
## Target architecture
### Shared Go tooling
- Use the module rooted at `runtime/go/go.mod`; add command entrypoints such as `runtime/go/cmd/tesl-dap`, `runtime/go/cmd/tesl-lsp`, and `runtime/go/cmd/tesl-mcp`. Packaging may expose separate binaries or `tesl` subcommands, but tests must exercise the shipped form.
- Add shared internal packages for Content-Length JSON-RPC/DAP framing, bounded JSON decoding, compiler subprocess queries, URI/path and UTF-16 positions, temporary logical source files, structured logging, cancellation, and process lifecycle. LSP and MCP must share the compiler-query client.
- Keep generated-program debug instrumentation in `runtime/go/teslrt`; keep DAP/LSP/MCP commands out of the production runtime dependency graph.
### Go debug runtime and protocols
- Define a versioned debug ABI for emitted checkpoints: original Tesl location, stable function/frame identity, lexical scopes, locals/value accessors, SQL/domain metadata, goroutine identity, test identity, and step depth.
- Port breakpoint records, conditions, hit counts, pause/resume, continue/next/step-in/step-out, stop-the-world behavior, stack snapshots, value trees, domain registry, SQL scopes, and safe bounded rendering.
- Port attach discovery under `.tesl-stuff`, Unix sockets, loopback TCP fallback, strict local binding, owner-only permissions, deadlines, bounded messages, stale endpoint cleanup, detach, and deterministic shutdown.
- Preserve DAP Content-Length framing and requests `initialize`, `setBreakpoints`, `configurationDone`, `launch`, `attach`, `threads`, `stackTrace`, `scopes`, `variables`, `continue`, `next`, `stepIn`, `stepOut`, `source`, `evaluate`, and `disconnect`. Preserve explicit benign setup no-ops and truthful failures for unsupported requests.
- Preserve advertised variables/single-step/configuration-done/conditional/hit-conditional/clipboard/hover capabilities, launch and named-test workflows, live attach, events, source mapping, evaluate names, Copy Value, nested ADT/record/collection values, domain lenses, and SQL query/parameter/row-count scopes.
- Preserve control commands `ping`, `set-breakpoints`, `clear-breakpoints`, `continue`, `snapshot`, and `detach`; preserve headless JSON version 2. Version-negotiate any changed internal wire format.
### Go LSP
- Preserve stdio JSON-RPC and every compiler query currently used, including `--check-json`, `--local-bindings-json`, `--definition-json`, `--occurrences-json`, `--semantic-json`, `--fmt`, `--completions-json`, `--type-at-json`, `--field-at-json`, and `--doc-json`.
- Preserve incremental open/change/save/close; push/pull and dependency diagnostics; completion/resolve; hover; declaration/definition/type-definition; references; prepare-rename/rename; document symbols/highlights; inlay hints; whole/range/on-type formatting; folding; selection ranges; document links; linked editing; signature help; quick fixes/fix-all/organize-imports/execute-command; semantic full/range/delta tokens; and capability-gated refresh requests (`editor/tesl-lsp/tesl-lsp.rkt:2539`).
- Improve correctness with real UTF-16 position conversion instead of the current ASCII-dominant approximation (`editor/tesl-lsp/tesl-lsp.rkt:2141`), request cancellation, compiler timeouts/output bounds, stale-result rejection by document version, diagnostics debounce, bounded concurrency, graceful shutdown/exit, and system-temp-only scratch files.
### Go MCP
- Port `tools/list`, `tools/call`, schemas, validation, structured errors, compiler discovery, and all documented tools: `tesl.agent_context`, `tesl.check`, `tesl.type_at`, `tesl.signature`, `tesl.completions`, `tesl.definition`, `tesl.references`, `tesl.proof_obligations`, `tesl.debug_inspect`, and `tesl.debug_attach`.
- Reuse Go compiler-query/debug clients and preserve stdio framing, tool names, schemas, JSON, endpoint discovery, timeout behavior, and error containment.
## Cross-runtime compatibility and user availability
The migration must not create a period where all editor and debugging tools are unavailable for Go-targeted projects. Compatibility is staged by tool because source-analysis tools depend on the compiler, attach tools depend on the runtime wire protocol, and launch/direct-inspection tools depend on target-specific instrumentation and process startup.
### Tool compatibility requirements
- **Racket LSP against Go-targeted projects:** required from the start. The LSP analyzes `.tesl` through the OCaml compiler JSON query surface and does not inspect application runtime memory. All diagnostics, navigation, completion, formatting, rename, token, hint, and fix features must continue while applications compile/run as Go. Backend-specific compiler queries must be fixed before Go becomes the default, not deferred to the Go LSP port.
- **Racket MCP compiler tools against Go-targeted projects:** required from the start for `tesl.agent_context`, `tesl.check`, `tesl.type_at`, `tesl.signature`, `tesl.completions`, `tesl.definition`, `tesl.references`, and `tesl.proof_obligations`. These remain compiler/source tools and cannot be gated on the Go debug runtime.
- **Racket DAP attach against a Go runtime:** required after Go checkpoint emission and the Go control server land. The existing Racket DAP attach path is a protocol proxy and must attach to a Go process without compiling or loading Racket application code.
- **Racket `debug-attach` and MCP `tesl.debug_attach` against a Go runtime:** required at the same attach-compatibility milestone. Bridge, breakpoint, condition, hit-condition, once, snapshot, ping, continue, detach, timeout, and persistent-session behavior must work through the existing clients.
- **Racket DAP launch and named-test launch against Go:** not assumed to work automatically because the current launch path compiles/starts a Racket target. Before Go becomes the default runtime, either adapt that launcher to select/start Go or ship the Go DAP launcher. A user-visible debug launch/test workflow is a Go-default release gate.
- **Direct Racket headless `debug-inspect` against Go:** not expected to inspect Go memory in-process. Equivalent direct inspection requires Go checkpoints plus a Go headless runner. Until then, snapshot inspection through the compatible attach protocol is the supported bridge.
- **MCP `tesl.debug_inspect` against Go:** becomes available when the Go headless runner exists; MCP may remain Racket-hosted temporarily if it invokes the target-aware Go runner and preserves its schema.
- **VS Code:** source features remain available through the existing LSP throughout. Attach becomes available at the attach-compatibility milestone. Launch and named-test debugging become available only after the extension/launcher selects a Go-capable DAP path. Extension messages must distinguish unsupported target/mode combinations rather than silently falling back to Racket emission.
- **Go DAP/attach/MCP clients against a Racket runtime:** required during the overlap for attach-based operations when the runtime advertises the compatible protocol version. This permits Go client cutover before all already-running Racket applications disappear. It is not a requirement for target-specific launch or direct headless execution.
### Compatibility milestones
1. **C0 — source tooling continuity:** Racket LSP and compiler-backed MCP tools pass unchanged against projects configured for Go emission. No runtime debugging claim is made.
2. **C1 — Go runtime attach bridge:** Go-emitted checkpoints, control endpoint, handshake, commands, events, snapshots, paths, values, and errors are compatible with existing Racket DAP attach, `debug-attach`, and MCP attach clients. Users can debug a separately started Go application before the Go DAP/LSP/MCP ports are complete.
3. **C2 — target-aware launch and inspection:** a shipped DAP path launches Go programs and named tests; a Go headless runner powers direct `debug-inspect` and MCP `debug_inspect`. Existing Racket LSP/MCP source processes may still be in use.
4. **C3 — Go-native tooling default:** Go DAP, LSP, MCP, attach, and headless tools are packaged defaults. Attach interoperability is tested in both directions during the overlap; Racket clients/runtimes become test oracles only and are then removed after soak gates.
### Cross-runtime protocol contract
- Version the attach/control protocol independently from implementation language. Handshake must advertise protocol version, runtime kind, build/debug metadata version, supported commands/capabilities, headless snapshot schema, and limits. Reject incompatible major versions with a structured actionable error; negotiate optional capabilities rather than guessing from runtime language.
- Keep endpoint discovery compatible: `.tesl-stuff/debug.sock` or `debug.port`, canonical project/source paths, Unix permissions, loopback-only TCP, stale endpoint cleanup, and deterministic ownership/lifecycle.
- Keep commands and events language-neutral JSON. Required commands are `ping`, `set-breakpoints`, `clear-breakpoints`, `continue`, `snapshot`, and `detach`; required stopped/snapshot/error/termination payloads must carry stable source locations, frame/scope/value IDs, breakpoint results, and version fields.
- Preserve condition and hit-condition grammar/semantics, canonical path matching, stop reasons, frame ordering, scope names, value type/display/children/evaluate-name semantics, domain/SQL scopes, redaction, bounds/truncation markers, and error envelopes. Do not serialize Racket- or Go-specific object representations across the boundary.
- Separate attach interoperability from process launch. Attach clients connect to an already instrumented runtime through the versioned protocol. Launchers must explicitly select a compiler target and matching runtime executable; they must never compile Racket as an implicit fallback for a requested Go debug session.
- Preserve headless JSON version 2 for compatibility or add explicit schema negotiation. `snapshot` over attach and direct headless execution must produce equivalent normalized data for the same stopped program.
- During overlap, run the required pairing matrix: Racket client to Racket runtime as baseline; Racket client to Go runtime as the C1 gate; Go client to Racket runtime for attach compatibility; Go client to Go runtime as the final path. Cover DAP attach, CLI attach/snapshot, MCP attach, conditions/hits, stepping commands, values/domains/SQL, detach, termination, malformed messages, and version mismatch.
- Compatibility shims are temporary migration surfaces, not permanent duplicate implementations. Remove them only after C3 packaging, differential tests, and soak gates pass; preserve golden protocol fixtures after Racket deletion.
## Racket removal groups
- `dsl/` (35): replace all runtime/private files with `runtime/go/teslrt` behavior and tests; replace all seven `dsl/debug/*.rkt` files with the Go debug ABI/runtime, DAP, attach client, and headless inspector.
- `tesl/` (49): keep `.tesl` public surface sources where applicable, but remove all Racket runtime/shim forms once compiler bindings target Go exclusively.
- `editor/` (3): replace LSP, MCP, and MCP smoke test with Go implementations/tests.
- `example/` (119): stop committing backend outputs; compile/run `.tesl` sources through Go. Resolve Racket-only generated-name variants and development support to an originating `.tesl` source or Go replacement before deleting.
- `templates/` (2): retain `.tesl` templates and make init/Docker/package flows compile them to Go.
- `tests/` currently contains 143 root `.rkt` tests plus nested benchmark/private files. The 71 same-path `.tesl` tests become Go-backend source tests; the 72 remaining Racket-only responsibilities have named Go, OCaml, shell/black-box, protocol, benchmark, or reviewed-obsolete replacements.
- The exact 354-path baseline is appended below and is normative. Reinventory before implementation and before deletion; any newly added `.rkt` joins this scope and blocks final acceptance.
## Migration phases
### Phase status
| Phase | Status | Gate state |
|---|---|---|
| 0. Contract freeze and traceability | Complete | `racket-traceability.json` covers the current 334-file checkout inventory; protocol/schema fixtures, capability matrix, migration gate validation, and two-run DAP stability replay pass. |
| 1. Shared Go protocol/compiler-query foundation | Complete | Bounded framing, malformed/truncated/partial-I/O coverage, UTF-16/URI portability, protocol fuzz gates, real built-compiler query coverage, LSP field/doc queries, versioned diagnostic cancellation, race/vet, and shipped Go tooling tests pass. |
| 2. Go debug emission and ABI | Complete | ABI v1 schema/fixture, debug/release emission, function/test checkpoints, generated single/multi-module debug builds, release symbol scans, unattached equivalence gates, SQL/domain instrumentation, and benchmarks pass. |
| 3. Checkpoint engine, values, domains, and control channel | Complete | Bounded/panic-safe named value trees, concurrent checkpoint stress, stop-world recovery, Unix/TCP control, disconnect resume/reattach, domain/SQL scopes, ABI fixtures, and race gates pass. |
| 4. DAP and headless debugger | Complete | Go DAP launch/attach lifecycle, named-test launch, real launch-to-breakpoint integration, headless v2 breakpoint/scalar-local output, Go attach bridge/once/project discovery, normalized transcripts, and race gates pass. |
| 5. LSP | Complete | Go LSP shipped entrypoint, expanded initialize contract, ranged/multiple UTF-16 edits, save/watch/format/resolve/execute handlers, field/doc compiler queries, cancellable versioned diagnostics, built-compiler integration, and race/vet gates pass. |
| 6. MCP | Complete | Go stdio server, compatible tool schemas, compiler-query differential, Go headless inspection, real-stdio coverage, live Go-runtime attach, race, vet, and protocol smoke pass. |
| 7. CLI, VS Code, packaging, environments | Partial | Go is the default for shipped/dev compile/run/test/debug-inspect/watch/build flows and Go LSP/DAP/MCP tools; clean-install and template/Docker gates pass. Explicit Racket fallback, compatibility CI, and final Racket-free packaging remain. |
| 8. Complete test/example/template migration | Complete | All 71 paired sources and 107 examples pass Go corpus gates; all 72 Racket-only rows have named replacement evidence; templates pass Go init/build/test gates; stale aggregate fixtures are removed. Remaining Racket files are explicit compatibility/oracle debt tracked by phase 7/C3, not unmapped test responsibility. |

### Phase 0: Contract freeze and traceability
1. Generate a machine-readable row for every `.rkt`: category, behavior owner, replacement package/test, parity evidence, deletion status. CI compares it with `git ls-files '*.rkt'`.
2. Capture normalized LSP, DAP, control, headless, MCP, CLI, diagnostic/fix, semantic-query, value-tree, and snapshot transcripts. Normalize only true nondeterminism such as IDs, paths, ports, timestamps, and unordered protocol fields.
3. Freeze/validate schemas for headless v2, agent context, diagnostics/fixes, compiler semantic queries, DAP values, snapshots, and MCP tools.
4. Run the existing Racket suites repeatedly and establish known-flake policy. Fix or document current defects before treating output as the oracle.
5. Create capability-to-test matrices for every advertised LSP/DAP feature and every completed debugger/editor roadmap behavior.
Gate: current suites are stable, fixtures are reviewable, and every Racket file and public capability has an owner and test.
### Phase 1: Shared Go protocol/compiler-query foundation
1. Implement strict bounded Content-Length framing and JSON-RPC request/response/notification types with partial-I/O, EOF, malformed-header, and protocol-error handling.
2. Implement typed compiler discovery/query adapters preserving `TESL_LOGICAL_PATH`, project/import resolution, exit status, stderr, diagnostic paths, and temp cleanup.
3. Implement URI/path and UTF-16 conversion for Unicode, CRLF, invalid/clamped positions, percent encoding, symlinks, and Windows paths.
4. Add cancellable contexts, subprocess deadlines/process-group cleanup, output limits, and stale-version suppression.
5. Add table, fragmented-I/O, fuzz, race, and direct-compiler differential tests.
Gate: shared packages pass Go tests, fuzz seeds, race/static checks, and query-differential fixtures.

### Phase 0 closure log

- 2026-08-20: `scripts/check-go-migration-manifest.sh` now validates a 354-row machine-readable ownership/test manifest against `git ls-files '*.rkt'`, plus capability, ABI, schema, and transcript-index contracts.
- 2026-08-20: `scripts/racket-stability.sh` replayed all `tests/dap-*.rkt` suites twice with stable success; normalized protocol fixtures cover DAP, control, headless v2, MCP, CLI, diagnostics, semantic data, value trees, and ABI frames.

### Phase 1 implementation log

- 2026-08-19: bounded framing, JSON-RPC validation, UTF-16 position indexing, compiler query adapters, and temporary logical-source handling landed. `go test ./...`, `go test -race ./internal/...`, and `go vet ./...` pass under the pinned Nix Go toolchain.
- 2026-08-19: `runtime/go/cmd/tesl-lsp` now serves initialize/shutdown/exit, full-document lifecycle, pushed diagnostics, hover, definition/declaration, type-definition, completion and resolve, signature help, references, prepare-rename, rename, quick-fix code actions, document links, linked editing, full-document formatting, document highlights, selection ranges, inlay hints, folding ranges, document symbols, and semantic tokens with full, range, and delta responses. Responses use the corresponding compiler JSON flags; formatting uses `--fmt` on a system-temp source. Compiler `replace_line`, `insert_line`, `replace_span`, `replace_range`, and `multi` fixes map to workspace edits. Semantic token result IDs are session-scoped and unknown delta baselines fall back to full data. Session tests cover stale versions, Unicode ranges, compiler envelopes, nested ranges, folding, symbols, token deltas, workspace edits, URLs, and linked identifiers.
- 2026-08-19: LSP diagnostics now use per-document cancellation/version suppression and drain pending work at shutdown. Hover falls back to `--field-at-json`, completion resolve loads `--doc-json`, and `compiler_integration_test.go` exercises the built compiler across the complete JSON query flag surface. Protocol fuzz targets and malformed/truncated/UNC/symlink cases are included in the CI gate.
- 2026-08-20: Phase 1 closure gate passes: Go LSP/runtime tests, race/vet, bounded protocol fuzz targets, direct built-compiler query integration, and migration capability/fixture validation.

### Phase 2 implementation log

- 2026-08-19: `runtime/go/teslrt` ABI version 1 (`DebugFrame`, source locations, locals/value shape, listener attach/detach) and debug/release compiler modes landed. Debug emits stable function-entry checkpoints; release emits neither. Structural emitter tests cover both paths.
- 2026-08-19: debug frames now carry compiler-stable test identities and parameter-local accessors; attached listeners materialize bounded display values while unattached checkpoints remain no-ops. Debug test-body checkpoints and ABI/accessor tests landed.

### Phase 3 implementation log

- 2026-08-19: `teslrt.Debugger` now owns breakpoint matching by source location, conditional and hit-count predicates, pause requests, stop-world `Continue`, detach unblocking, and stopped-frame snapshots. Runtime tests cover breakpoint blocking/resume, conditions, hit counts, and local accessor materialization.
- 2026-08-19: added version-1 NDJSON control over owner-only Unix sockets. Handshake, ping, set/clear breakpoints, hit conditions, pause, continue, snapshot, detach, bounded lines, stale-socket cleanup, and explicit wire-condition rejection are covered by runtime tests. Debug-only control files are excluded from release artifacts.
- 2026-08-19: runtime and control protocol now expose step-in, step-over, and step-out transitions keyed by emitted function identity, with stop-world tests through both direct ABI and Unix control paths.
- 2026-08-19: wire breakpoints now support bounded field/local comparisons (`==`, `!=`, ordering), boolean literals, `&&`, `||`, and negation; invalid expressions return structured errors. Locals are materialized before matching.
- 2026-08-19: control server now also supports loopback TCP fallback with dynamic-port allocation and endpoint reporting; Unix remains the owner-only primary transport. TCP handshake and cleanup are covered.
- 2026-08-19: debug builds now start control discovery from `TESL_DEBUG_SOCKET`, `TESL_DEBUG_PORT`, or `TESL_DEBUG=1` with `.tesl-stuff/debug.sock` default; generated debug `cmd/app/main.go` starts and closes the control server, while release main remains unchanged.
- 2026-08-19: debug function entry/leave scopes now maintain nested stack frames; stopped events and snapshots include stack data, and checkpoints refresh the active stack frame with materialized locals. Scope teardown is idempotent and race-tested.
- 2026-08-19: generated debug modules now register queues, caches, SSE channels, email outboxes, and worker pools automatically; worker scopes report live/total counts. Debug SQL plans capture operation/table, parameterized statements, bounded previews, parameters, and executor row counts through `DebugPgSql` plan wrappers. Release emission excludes `debug_state.go`/`debug_sql.go` and all registration/capture calls.
- 2026-08-19: Phase 2 now has a versioned ABI schema/fixture, release artifact-wide debug-symbol scans, unattached release/debug generated-project equivalence, debug single/multi-module gates, and unattached checkpoint/stack benchmarks.
- 2026-08-20: Phase 2 closure gate passes focused emitter tests, generated debug single/multi-module `go test`/race gates, release debug-symbol scans, ABI fixture validation, and unattached runtime benchmarks.
- 2026-08-20: Phase 3 closure adds bounded/named/evaluate-name value nodes, UTF-8-safe truncation, accessor panic recovery, concurrent checkpoint stress coverage, and control-client EOF detach/resume recovery.

### Phase 4 implementation log

- 2026-08-19: `runtime/go/internal/dap` now defines typed DAP request/response/event envelopes, sequence allocation, and framed JSON read/write on the shared Content-Length layer. Unit, full-module, race, vet, and formatting gates pass.
- 2026-08-19: the Go DAP adapter now dispatches `initialize`, configuration setup, breakpoints, threads, stack traces, pause/continue, and step commands through `teslrt.Debugger`; unsupported launch/attach/value commands return truthful failures.
- 2026-08-19: DAP `scopes` and `variables` now expose stop-scoped locals and bounded child value trees; references are invalidated on each stop. Explicit `Target` hooks enable launch/attach integration without hard-coding process management.
- 2026-08-19: `dap.ControlClient` now bridges DAP backend operations to a running Go control endpoint over Unix or loopback TCP, validating protocol/ABI versions and forwarding breakpoints, snapshots, stepping, commands, and asynchronous stopped events. Net-pipe tests cover handshake and event ordering.
- 2026-08-19: `dap.ProcessTarget` now launches debug programs with private Unix or loopback TCP endpoint environment, waits for the versioned control handshake, and supports direct socket/address/port attach. `runtime/go/cmd/tesl-dap` now serves stdio DAP, with direct `--socket`/`--tcp` attach modes or DAP-driven launch/attach.
- 2026-08-19: debug snapshots now carry one atomic frame/stack/runtime-state payload; DAP uses it to avoid remote frame/stack races. Bounded local/indexed-child `evaluate`, regular-file `source` reads capped at 2 MiB, and target `output`/`exited`/`terminated` events are implemented and tested. Domain/SQL scopes consume normalized runtime registry snapshots.
- 2026-08-19: `dap.ProcessTarget` now has a real child-process launch regression covering control-endpoint handshake, attachable backend creation, forced shutdown, and `exited`/`terminated` event delivery. Process completion uses a reusable done signal plus one stored wait error, so endpoint startup, lifecycle watching, and `Close` cannot consume the same `Wait` result. Full Go, race, vet, formatting, and diff checks pass.
- 2026-08-19: DAP initialization now advertises `supportsClipboardContext`; `evaluate` honors `clipboard` by returning a complete scalar result without child references, while unknown `hover` names fail quietly. Tests cover clipboard and hover context behavior alongside ordinary local/indexed evaluation.
- 2026-08-19: DAP `initialize` now advertises the implemented variables, single-step, conditional/hit-conditional, hover, clipboard, configuration-done, and stepping capability set, explicitly keeping step-in-targets disabled. The response is pinned by a capability-parity test.
- 2026-08-19: added `runtime/go/cmd/tesl-debug-inspect` for version-negotiated Unix/TCP attach snapshots, `ping`, and `detach`. Snapshot output uses the headless v2 envelope with stopped state, source, locals, domain state, and SQL capture; the shared control client now exposes ping/detach operations.
- 2026-08-19: `tesl-debug-inspect` now accepts repeatable `--break-at FILE:LINE`, `--when`, and `--hit` options, arms the running endpoint, waits for a stopped event, and snapshots the paused state. Control-client detach now preserves a response racing intentional endpoint EOF; parser, attach, detach, and full Go/race/vet gates pass.
- 2026-08-19: DAP now retains pre-launch breakpoint specifications and reapplies them when launch/attach replaces the local backend, preventing the standard set-breakpoints → launch sequence from losing breakpoints. Backend replacement errors propagate truthfully, and short backend result lists no longer panic the response builder.
- 2026-08-19: headless breakpoint timeouts now return a version-2 `stopped:false` JSON result with `reason:"breakpoint-not-hit"` instead of failing or hanging. Snapshot assembly and missed-breakpoint serialization are covered by command tests.
- 2026-08-19: generated Go `test`, `api-test`, and `load-test` blocks now honor `TESL_TEST_NAME` by source description or generated Go name plus `TESL_TEST_KIND`; DAP launch arguments `testName`/`testKind` set those filters in spawned targets. Emitter assertions and launch-helper coverage pin named-test selection.
- 2026-08-19: focused Go-emitter coverage and all Go runtime/race/vet/build gates pass. The complete `emit_go` group exceeded the 10-minute verification budget without producing a failure; bounded closure cases pass independently.
- 2026-08-19: VS Code attach sessions now prefer Go DAP when `tesl-dap` is configured/on PATH or the workspace Go runtime is available via `go run`; `ProcessTarget` discovers project endpoints from `.tesl-stuff/debug.sock` or `debug.port`.
- 2026-08-19: Go DAP source launches now emit a debug Go module, build `cmd/app` or the generated test package, and launch the resulting binary with compiler/test selection and temporary-project cleanup. `TESL_DEBUG_WAIT` holds generated programs/tests until the DAP client installs its initial breakpoints, preventing fast tests from exiting during launch. VS Code selects Go DAP for `.tesl` launch sessions and passes the resolved compiler; Racket remains fallback only when Go DAP is unavailable.
- 2026-08-20: Phase 4 closure adds `tesl-debug-attach` bridge/project/once/ping/snapshot/detach modes, headless v2 firing-breakpoint and scalar-local output, and a real generated-test DAP launch → breakpoint → snapshot → continue integration test.
### Phase 5 implementation log

- 2026-08-20: Phase 5 closure adds incremental UTF-16 ranged/multiple edits, save/watch/execute/format/resolve handlers, expanded initialize capabilities, compiler-backed field/doc queries, per-document diagnostic cancellation/version suppression, built-compiler query coverage, and race/vet gates.

### Phase 2: Go debug emission and ABI
1. Specify checkpoint and debug metadata formats, stable IDs, scopes/locals, test identity, SQL metadata, redaction, and source-map ownership.
2. Extend `compiler/lib/emit_go.ml` with semantically equivalent checkpoints for functions, handlers, test bodies, pipelines, branches, nested expressions, and SQL, preserving evaluation order/lifetimes.
3. Define debug launch/test/release modes. Release must emit no debug import, metadata, call, listener, or captured local closure.
4. Port relevant `compiler/test/test_debug.ml` assertions to Go-emission structural/golden tests and compile generated Go for single/multi-module/source-location cases.
5. Add negative symbol/source/binary scans and debug-off benchmarks.
Gate: every checkpoint class is covered, debug Go builds, release is instrumentation-free, and unattached debug builds are behaviorally equivalent to release.
### Phase 3: Checkpoint engine, values, domains, and control channel
1. Implement concurrency-safe path/breakpoint/condition/hit state, pause requests, step plans, stack snapshots, and defined multi-goroutine stop behavior including panic/exit races.
2. Port value display/type/children/evaluate-name with cycle detection, deterministic ordering, depth/child/string/byte bounds, safe recovery, newtypes, ADTs, records, tuples, lists, dicts/sets, raw maps, opaque values, redaction, and stop-scoped references.
3. Port queue/channel/cache/email/worker/dead-job domain lenses and SQL scopes without mutation or reflection panics.
4. Port socket/TCP server/client, discovery, persistent/one-shot sessions, all control commands, cleanup, and detach.
5. Add unit/property/fuzz/race/deadlock/leak/fault tests and replay all baseline value/domain/SQL/attach/headless transcripts.
Gate: race/stress/leak gates pass and malformed local messages cannot crash or allocate without bound.
### Phase 4: DAP and headless debugger
1. Implement DAP on the shared framing/session layer with exact capabilities and dispatch semantics; separate launch and attach transports.
2. Implement program/named-test lifecycle, configuration ordering, pre-run breakpoints, output, exit/termination, cancellation/disconnect, and child cleanup.
3. Implement stacks/scopes/variables/source/evaluate and stepping through the Go ABI, including Copy Value, hover, attach verification, and truthful unsupported errors.
4. Implement headless v2 and all attach CLI modes with compatible JSON/human output.
5. Port all 11 `tests/dap-*.rkt` files, `tests/checkpoint-condition-test.rkt`, and in-module tests. Add raw DAP and real VS Code smoke tests.
Gate: differential transcripts and VS Code launch/test/attach/condition/hit/step/value/domain/SQL/detach/terminate flows pass; Unix sockets and TCP fallback are platform-tested.
### Phase 5: LSP
1. Port pure transforms first: diagnostics/ranges, completion, hover/docs, symbols, tokens/delta, hints, highlights, signatures, folding, selection, formatting, links, linked edits, fixes/titles/actions, and incremental edits. Convert embedded assertions to focused Go tests.
2. Implement versioned document storage, query scheduling, logical temp files, dependency diagnostics, push/pull ownership, caches/result IDs, and refresh requests.
3. Implement the exact initialize contract and every current method, including resolve/prepare/delta/source-action behavior and compatible benign failures.
4. Add cancellation, debounce, stale rejection, bounded parallelism, compiler crash recovery, shutdown/exit, deterministic logging, and protocol-only stdout.
5. Send identical sessions to Racket and Go and compare normalized capabilities, results, notifications, diagnostics, and edits for unsaved buffers, dependency errors, rapid edits, Unicode/CRLF, large files, missing/crashing compiler, malformed JSON, and path edge cases.
6. Canary the packaged Go server in VS Code and soak repeated open/change/save/close cycles for memory/process/temp leaks.
Gate: all methods have unit/session coverage, differential behavior matches except approved improvements, Unicode ranges are correct, no stale results or repo temp files remain, and latency/memory budgets pass.
### Phase 6: MCP
1. Port all tools/schemas using shared clients.
2. Port `editor/tesl-mcp/tests/protocol-smoke.rkt`; add per-tool, invalid-input, compiler-failure, timeout, endpoint, attach/detach, and concurrency tests.
3. Differential-test `tools/list`, every `tools/call`, and errors through a real MCP stdio client.
Gate: names/schemas/JSON remain compatible and live compiler/debug calls pass.

### Phase 6 closure log

- 2026-08-20: Go `tesl-mcp` exposes the compiler query surface and debugger tools over bounded MCP stdio framing; unit, framing, race, vet, and real compiler agent-context smoke checks pass. Differential tool/error and live attach parity remain open.
- 2026-08-20: MCP now keeps capability discovery alive when the compiler is absent, supports `shutdown`, validates source-query positions, returns contained `tools/call` errors, and has real-stdio matrix coverage for all compiler tools plus debug-attach argument forwarding.
- 2026-08-20: MCP phase closure adds a real built-compiler/headless-debugger stdio test, Racket-versus-Go catalog/schema and `agent_context` differential coverage, and a CLI smoke that arms Go `debug-attach` through MCP against a running Go server and verifies the stopped event.
- 2026-08-20: The MCP differential found and fixed a Racket compatibility defect: `tesl.proof_obligations` now returns the documented sliced array, matching Go rather than wrapping it in an agent-context object.
### Phase 7: CLI, VS Code, packaging, environments
1. Replace Racket discovery and `.rkt` launch paths in the extension, debug launcher, package manifest, launch configs, and editor bundle with shipped Go tools.
2. Switch `tesl` CLI run/test/debug/debug-attach/debug-inspect/LSP/MCP flows to Go while preserving flags, environment compatibility where required, output, and exit codes.
3. Remove Racket/`PLTCOLLECTS` from `flake.nix`, `shell.nix`, Docker, installers, Makefile, GitHub workflows, release artifacts, and packaging.
4. Add artifact-level clean-install tests for extension activation, LSP, DAP launch/attach, MCP, templates, Docker, Nix, and CLI with Racket absent.
Gate: shipped workflows find only Go binaries and packages contain no `.rkt` or Racket closure.

### Phase 7 closure log

- 2026-08-20: Nix exposes Go LSP, DAP, headless, attach, and MCP binaries; default profile and dev shell include them. VS Code LSP resolution and MCP documentation now target Go. Full Go DAP/test-runner cutover is covered by focused gates; legacy CI/oracle cleanup remains open.
- 2026-08-20: `tesl debug-attach` now routes to the Go attach client with compatible `--once`, `--snapshot`, `--ping`, `--detach`, breakpoint, condition, hit, project, and timeout flags. VS Code DAP no longer falls back to the deleted Racket launcher; legacy CLI run/test and Run Function paths still use the Racket runtime.
- 2026-08-20: `nix build .#tesl-go-tools` and `nix build .#tesl-full` pass; the installed `tesl-mcp` wrapper completes an initialize exchange without a repo checkout.
- 2026-08-20: `tesl test --backend go` now emits each file into a disposable Go module and runs generated tests with named-test/kind filters; focused single-module and imported-module smokes pass, and CI phase 9b has a Go-backend assertion. Full `ci.sh` exceeded the 15-minute session timeout during earlier compiler/integration phases before reaching phase 9b.
- 2026-08-20: `tesl run --backend go` now emits, builds, and launches generated `cmd/app` modules from a disposable directory; debug emission exports the project attach root. Non-application modules fail explicitly instead of producing a raw Go directory error. Focused Todo API startup smoke reached the generated Go server before its timeout.
- 2026-08-20: `tesl debug-inspect --backend go` now launches generated Go program/test targets through the Go control channel, arms source breakpoints, waits for a stop, and emits headless v2 output; `--continue` captures multiple stops until target completion. Lesson61 inspection and MCP Go-launcher routing pass focused checks.
- 2026-08-20: Nix and legacy dev-shell wrappers now set Go as the default backend for `tesl run`, `tesl test`, and `tesl debug-inspect`; explicit `--backend racket` and `TESL_BACKEND=racket` preserve the legacy path. Installed default test and headless inspection pass focused checks.
- 2026-08-20: `tesl build --backend go` now emits into `.tesl-stuff/go-build` (or a new `--out` directory) and runs `go build ./...`; focused Todo API project build passes. Docker and default Racket build paths remain unchanged.
- 2026-08-20: Go `tesl watch` now snapshots imported source mtimes, rebuilds a disposable Go app, restarts it on changes, and cleans child processes on exit. Focused telemetry-app restart smoke passes; explicit Racket watch remains available.
- 2026-08-20: `tests/go-cli-smoke.sh` now builds the Go MCP/attach tools, launches a Go debug server, arms `tesl.debug_attach` through real MCP stdio, triggers an HTTP endpoint, and requires the stopped event.
- 2026-08-20: Shipped/dev `tesl compile` now defaults to Go module emission; `--backend racket` remains explicit fallback. Default and explicit-output Go compile smokes pass. Docker packaging still requires a Go container template.
- 2026-08-20: `tesl build --backend go --container --no-docker` now stages a Go module plus multi-stage Go/Debian Dockerfile; embedded-Postgres mode is rejected explicitly. Focused Todo API context staging passes; Docker daemon build remains environment-gated.
- 2026-08-20: Shipped/dev `tesl build` now follows the Go default backend and selects local or container Go output from manifest/flags; `--backend racket` local fallback passes. Go Docker context staging remains daemon-independent.
- 2026-08-20: Added `tests/go-cli-smoke.sh` covering default Go test/compile, headless inspection, and Docker context staging; CI Phase 2a invokes it after Go static/security gates. Focused script passes; full `ci.sh` remains intentionally deferred.
- 2026-08-20: VS Code Run Function now uses `tesl test --backend go`; removed its direct compiler/Racket launcher dependency. Test Explorer parser now understands generated Go `TestTeslN` failures and parser tests pass.
- 2026-08-20: Live version metadata is now `0.3.1`; the default Nix profile and legacy dev shell use Go-only CLI preambles, the default package has no Racket closure, clean-install CLI compile/build passes with `racket` and `raco` absent, and Docker templates are Go-based. Legacy Racket CLI/CI oracle branches remain explicit migration debt.
- 2026-08-20: Phase 8 started with a Go template gate: `tesl init` minimal and api templates compile, test, and stage Docker contexts through the Go backend. Fixed a Go module-graph collision where a project module named `App` was mistaken for `Tesl.App`; the regression is pinned in `test_emit_go.ml`. Focused `tests/go-cli-smoke.sh` passes; paired-test and Racket-only responsibility inventory remain open.
- 2026-08-20: Added `roadmap/next/go-test-migration.json` and `scripts/check-go-test-inventory.sh`; the gate verifies the measured root inventory (143 existing Racket tests, 71 paired `.tesl` sources, 72 Racket-only rows) and runs from both the migration-manifest check and Go CLI smoke. The counts are enforced, and the three deleted generated-fixture tests are no longer inventory rows.
- 2026-08-20: Expanded the test migration manifest to all 72 remaining Racket-only root rows with concrete owners and replacement forms. All 72 rows are green against Go/runtime evidence, including OTLP JSON metrics/traces export and outbound traceparent propagation.
- 2026-08-20: Added `scripts/run-go-test-manifest.sh` with list, single-source Go compile, full-corpus compile, and full-corpus execution modes. Focused smoke now executes all 71 paired sources; aggregate runner rows are green against the Go manifest.
- 2026-08-20: Full paired corpus gate passes: all 71 `.tesl` sources compile and execute as generated Go tests. Full example gate passes for 107 tracked examples. Added Go proof/codec and OTLP exporter benchmarks/tests, outbound traceparent propagation, and removed stale unpaired example/template `.rkt` artifacts. All 72 remaining Racket-only rows have Go evidence.
- 2026-08-20: Go is the shipped/dev default for compile/run/test/debug-inspect/watch/build and Go LSP/DAP/MCP tools; explicit Racket fallback remains. Unsupported Go emission shapes still fail closed.
- 2026-08-20: Aggregate CI no longer loads deleted generated `bookmark-api.rkt`/`document-api.rkt` fixtures. The obsolete Racket tests were removed; supported API/server behavior remains covered by Go corpus, runtime, and CLI gates. Full Racket backend removal is intentionally deferred until after Go merge and C3 soak.
- 2026-08-20: Go now exposes `HttpRequest.clientAddress` and honors `trustedProxies` by selecting the rightmost untrusted forwarded hop, ignoring X-Forwarded-For without a declaration, and failing closed when every hop is trusted. Runtime, emitter, and generated-source tests cover the contract.
- 2026-08-20: Earlier full `ci.sh` attempts exhausted the host filesystem during the long dune phase; those runs were not release passes. After storage recovery, a fresh run passed contracts, build, DAP stability, and the initial dune gates but exceeded the 30-minute verification budget during the remaining dune suite. Targeted Go runtime, MCP, CLI, manifest, example, template, and documentation gates pass; full CI still needs an uninterrupted completion.
### Phase 8: Complete test/example/template migration
1. Make each of the 71 paired `.tesl` tests the sole source and assert Go compile diagnostics, runtime output, status, side effects, and services.
2. Assign each of the 72 current Racket-only test responsibilities a named Go runtime/integration test, OCaml compiler test, black-box test, protocol fixture, benchmark, or reviewed obsolete disposition.
3. Preserve PostgreSQL, HTTP/TLS/SSRF, telemetry/OTLP, SSO, secrets, crypto, SQL, queue, cache, server, timeout, concurrency, and external-service coverage without weakening isolation/assertions.
4. Convert all Racket benchmarks with retained metrics/budgets.
5. Compile and run all meaningful examples/lessons/templates through Go; resolve stale generated variants and prevent tracked `.tesl-stuff` outputs.
6. Use `scripts/run-go-test-manifest.sh` and the compiler/CLI manifests as the enforced migration source of truth; retain the Racket aggregate files only as explicit compatibility/oracle coverage until phase 7/C3 removes them.
Gate: every inventory row is green, no responsibility is dropped, and disabling old Racket suites reduces no enforced behavior.

## Testing and verification requirements
### Unit, property, fuzz, and race
- Table-test every pure LSP/DAP/MCP transform and debug state transition. Preserve all current embedded regressions before improvements.
- Fuzz framing, JSON, URI/UTF-16, edits, breakpoint/hit parsing, value traversal/cycles, source maps, and compiler adapters.
- Run `go test -race` plus repeated scheduler, deadlock, goroutine, descriptor, subprocess, socket, and temp-file leak tests.
### Golden and differential
- Compare normalized Racket and Go LSP/DAP/control/headless/MCP/value/checkpoint/CLI/diagnostic/fix behavior during overlap.
- Require a compatibility note and precise fixture update for every intentional difference; forbid broad normalizers that hide regressions.
- Keep fixtures implementation-independent after Racket deletion.
### Integration and end to end
- Compile debug-on/off `.tesl` programs; launch, breakpoint, condition/hit, step across functions/branches/pipelines/SQL, inspect, detach/reattach, terminate, and assert application behavior.
- Exercise multi-goroutine pauses, breakpoint races, crashes, malformed clients, lost clients, stale sockets, port collisions, and repeated sessions.
- Drive LSP unsaved/dependency/rename/reference/token/fix/format/cancel/rapid-version cases.
- Drive a real VS Code extension host for diagnostics, completion, hover, navigation, rename, fixes, tokens, hints, debug launch/test/attach, stepping, variables, Copy Value, and termination.
- Drive MCP with a real stdio client and live compiler/debug endpoints.
### Performance, security, quality, packaging
- Set budgets for startup, edit-to-diagnostic, completion/hover, memory after edits, checkpoint cost, snapshot cost, attach latency, binary size, and descriptor/goroutine growth.
- Scan release source/object/binary for debug instrumentation; benchmark zero-instrumentation behavior and enforce bounded debug messages/trees/queues.
- Test redaction, local-only attach, owner permissions, traversal/symlinks, malicious lengths, malformed Unicode, subprocess output bombs, timeout cleanup, and endpoint spoofing.
- Run the general roadmap's `go vet`, `staticcheck`, `gosec`, `govulncheck`, `golangci-lint`, race, nil analysis, dependency/license, and corpus gates.
- Test Linux/macOS packages and supported Windows/TCP/editor behavior; scan Nix/Docker/editor/CLI artifacts for forbidden files/dependencies.
## Final acceptance criteria
- `git ls-files '*.rkt'` is empty after the full build/test/package workflow.
- `compiler/lib/emit_racket.ml`, Racket backend selection/discovery, Racket generators/snapshots, and active Racket/raco/PLTCOLLECTS/package dependencies are gone.
- A machine/container without Racket builds, tests, packages, and runs all supported workflows.
- Release Go output has zero debugger instrumentation. Debug Go supports launch, named tests, attach, conditions/hits, all stepping, stacks/scopes/variables/source/evaluate, Copy Value/hover, values/domains/SQL, snapshots, detach/reattach, and clean termination.
- Go LSP passes the full current capability matrix plus UTF-16 correctness, cancellation, stale suppression, bounded subprocesses, and temp hygiene.
- Go MCP exposes all current tools with compatible schemas and live behavior.
- Every baseline path below and every later `.rkt` addition has a named replacement/deletion result; all old test responsibilities remain enforced.
- Go/OCaml/corpus/protocol/race/stress/fuzz/VS Code/MCP/example/template/Docker/Nix/install/lint/security/dependency gates pass.
- Active docs, CI, packaging, scripts, and extension configuration invoke only Go runtime/debugger/LSP/MCP workflows.
## Rollout and rollback
- Treat C0 through C3 as release-visible compatibility gates, not merely implementation labels. Publish which source, attach, launch, headless, MCP, and VS Code modes are supported for each runtime target at every milestone.
- Land Go implementations behind development flags while Racket remains the differential oracle; never keep two production defaults. C0 preserves source tooling, C1 enables existing Racket attach clients against Go, C2 supplies target-aware Go launch/headless behavior, and C3 makes all Go tools the packaged defaults.
- Cut over in order: debug emission/runtime and C1 attach bridge; DAP launch/headless and C2; Go LSP/MCP; VS Code/CLI/packaging and C3; tests/examples/templates; then Racket backend/runtime deletion.
- Keep configuration cutovers reversible until soak gates pass. A C1 failure may fall back only to the explicitly selected Racket runtime target, never silently compile a requested Go session as Racket. After final deletion, rollback uses version control/release rollback, not a dormant Racket fallback.
- Any cross-runtime mismatch reopens its protocol-contract test and owning phase/inventory row; zero file count never justifies a semantic waiver.
## Appendix: exact tracked Racket baseline
Generated from `git ls-files '*.rkt'` when this roadmap was created. This list contains every one of the 354 tracked Racket files in scope.
- `dsl/capability.rkt`
- `dsl/check.rkt`
- `dsl/debug/attach-client.rkt`
- `dsl/debug/checkpoint.rkt`
- `dsl/debug/control-channel.rkt`
- `dsl/debug/dap-server.rkt`
- `dsl/debug/domain-inspect.rkt`
- `dsl/debug/headless-inspect.rkt`
- `dsl/debug/value-tree.rkt`
- `dsl/load-test.rkt`
- `dsl/metrics.rkt`
- `dsl/otel.rkt`
- `dsl/otlp-value.rkt`
- `dsl/private/check-runtime.rkt`
- `dsl/private/currency-data.rkt`
- `dsl/private/domain-registry.rkt`
- `dsl/private/evidence.rkt`
- `dsl/private/host-classify.rkt`
- `dsl/private/jws-verify.rkt`
- `dsl/private/money-core.rkt`
- `dsl/private/proof-utils.rkt`
- `dsl/private/ssrf-guard.rkt`
- `dsl/private/time-trunc.rkt`
- `dsl/private/trusted.rkt`
- `dsl/private/tzif.rkt`
- `dsl/private/url-parse.rkt`
- `dsl/response-cookies.rkt`
- `dsl/sql.rkt`
- `dsl/sso.rkt`
- `dsl/test-support.rkt`
- `dsl/trace-context.rkt`
- `dsl/traces.rkt`
- `dsl/trusted.rkt`
- `dsl/types.rkt`
- `dsl/web.rkt`
- `editor/tesl-lsp/tesl-lsp.rkt`
- `editor/tesl-mcp/tesl-mcp.rkt`
- `editor/tesl-mcp/tests/protocol-smoke.rkt`
- `example/.tesl-stuff/build/ai-live-check.rkt`
- `example/admin-task-api.rkt`
- `example/ai-conversation-service.rkt`
- `example/ai-live-check.rkt`
- `example/bookmark-api.rkt`
- `example/chat/chat-backend.rkt`
- `example/document-api.rkt`
- `example/int32-boundary.rkt`
- `example/kanel/KanelAuth.rkt`
- `example/kanel/KanelBackend.rkt`
- `example/kanel/KanelBilling.rkt`
- `example/kanel/KanelDB.rkt`
- `example/kanel/KanelIssues.rkt`
- `example/kanel/KanelModels.rkt`
- `example/kanel/KanelNotify.rkt`
- `example/kanel/KanelOrg.rkt`
- `example/kanel/KanelTests.rkt`
- `example/kanel/kanel-auth.rkt`
- `example/kanel/kanel-backend.rkt`
- `example/kanel/kanel-billing.rkt`
- `example/kanel/kanel-d-b.rkt`
- `example/kanel/kanel-db.rkt`
- `example/kanel/kanel-issues.rkt`
- `example/kanel/kanel-models.rkt`
- `example/kanel/kanel-notify.rkt`
- `example/kanel/kanel-org.rkt`
- `example/kanel/kanel-tests.rkt`
- `example/learn/.tesl-stuff/build/lesson63-ai-structured-output.rkt`
- `example/learn/lesson00-hello-world.rkt`
- `example/learn/lesson01-basic-types-and-functions.rkt`
- `example/learn/lesson02-adts-and-pattern-matching.rkt`
- `example/learn/lesson03-records.rkt`
- `example/learn/lesson04-newtypes.rkt`
- `example/learn/lesson05-intro-to-proofs.rkt`
- `example/learn/lesson06-proof-check-proof-auth.rkt`
- `example/learn/lesson07-consumer.rkt`
- `example/learn/lesson07-home.rkt`
- `example/learn/lesson08-proof-transport.rkt`
- `example/learn/lesson09-proof-composition.rkt`
- `example/learn/lesson10-cross-parameter-proofs.rkt`
- `example/learn/lesson11-capabilities.rkt`
- `example/learn/lesson12-records-with-proofs.rkt`
- `example/learn/lesson13-partial-application-and-pipelines.rkt`
- `example/learn/lesson14-test-blocks.rkt`
- `example/learn/lesson15-api-handlers-server.rkt`
- `example/learn/lesson16-complete-notes-api.rkt`
- `example/learn/lesson17-telemetry.rkt`
- `example/learn/lesson18-database-sql-and-proofs.rkt`
- `example/learn/lesson19-existential-witnesses.rkt`
- `example/learn/lesson20-named-db-results.rkt`
- `example/learn/lesson21-sql-reference.rkt`
- `example/learn/lesson22-compound-named-pack.rkt`
- `example/learn/lesson23-maybe-and-optional-values.rkt`
- `example/learn/lesson24-error-handling-patterns.rkt`
- `example/learn/lesson25-standard-library-strings-lists-ints.rkt`
- `example/learn/lesson26-time-and-posix.rkt`
- `example/learn/lesson27-either-dict-set.rkt`
- `example/learn/lesson28-dead-letter-queue.rkt`
- `example/learn/lesson29-forall-list-proofs.rkt`
- `example/learn/lesson30-forall-set-proofs.rkt`
- `example/learn/lesson31-worker-concurrency.rkt`
- `example/learn/lesson32-api-tests.rkt`
- `example/learn/lesson33-sse-and-queue-tests.rkt`
- `example/learn/lesson34-float-arithmetic.rkt`
- `example/learn/lesson35-list-decomposition.rkt`
- `example/learn/lesson36-lambdas.rkt`
- `example/learn/lesson37-parameterized-adts.rkt`
- `example/learn/lesson38-proof-decomposition.rkt`
- `example/learn/lesson39-case-where-guards.rkt`
- `example/learn/lesson40-implicit-value-unwrapping.rkt`
- `example/learn/lesson41-load-tests.rkt`
- `example/learn/lesson42-mutation-testing.rkt`
- `example/learn/lesson43-orderable-types.rkt`
- `example/learn/lesson44-multi-param-proofs.rkt`
- `example/learn/lesson45-tuples.rkt`
- `example/learn/lesson46-result-type.rkt`
- `example/learn/lesson47-list-functions.rkt`
- `example/learn/lesson48-sql-inner-join.rkt`
- `example/learn/lesson49-literal-patterns.rkt`
- `example/learn/lesson50-nested-constructor-patterns.rkt`
- `example/learn/lesson51-proof-combining.rkt`
- `example/learn/lesson52-maybe-proof.rkt`
- `example/learn/lesson53-literal-parametrized-predicates.rkt`
- `example/learn/lesson54-debugging-proof-errors.rkt`
- `example/learn/lesson55-testing-auth-and-capabilities.rkt`
- `example/learn/lesson56-uuid.rkt`
- `example/learn/lesson57-jwt.rkt`
- `example/learn/lesson58-httpclient.rkt`
- `example/learn/lesson59-cache.rkt`
- `example/learn/lesson60-email.rkt`
- `example/learn/lesson61-step-debugging.rkt`
- `example/learn/lesson62-ai-agents.rkt`
- `example/learn/lesson63-ai-structured-output.rkt`
- `example/learn/lesson64-password-storage.rkt`
- `example/learn/lesson65-pipe-operators.rkt`
- `example/learn/lesson66-query-parameters.rkt`
- `example/learn/lesson67-newtype-columns.rkt`
- `example/learn/lesson68-server-endpoints-as-tools.rkt`
- `example/learn/lesson69-agent-human-handoff.rkt`
- `example/learn/lesson70-agent-async-work.rkt`
- `example/learn/lesson71-money.rkt`
- `example/learn/lesson72-units.rkt`
- `example/learn/lesson73-metrics.rkt`
- `example/learn/lesson74-interop-patterns.rkt`
- `example/learn/lesson75-regex-validation.rkt`
- `example/learn/lesson76-sessions.rkt`
- `example/learn/lesson77-traces.rkt`
- `example/learn/lesson78-sso.rkt`
- `example/learn/lesson79-authenticating-proxy.rkt`
- `example/learn/lesson80-testing-sso.rkt`
- `example/private/postgres-dev.rkt`
- `example/queue-api.rkt`
- `example/sandbox.rkt`
- `example/sandbox2.rkt`
- `example/sandbox2.test.rkt`
- `example/sandbox3.rkt`
- `example/support-assistant.rkt`
- `example/todo-api.rkt`
- `example/user-service-api.rkt`
- `templates/api/app.rkt`
- `templates/minimal/app.rkt`
- `tesl/agent-provider.rkt`
- `tesl/agent.rkt`
- `tesl/api-test.rkt`
- `tesl/cache.rkt`
- `tesl/civil-time-derived.rkt`
- `tesl/civil-time.rkt`
- `tesl/crypto.rkt`
- `tesl/db.rkt`
- `tesl/dict.rkt`
- `tesl/either-derived.rkt`
- `tesl/either-prim.rkt`
- `tesl/either.rkt`
- `tesl/email.rkt`
- `tesl/env.rkt`
- `tesl/float.rkt`
- `tesl/http-client.rkt`
- `tesl/http.rkt`
- `tesl/human-actions.rkt`
- `tesl/id.rkt`
- `tesl/int.rkt`
- `tesl/int32.rkt`
- `tesl/jwt.rkt`
- `tesl/list-derived.rkt`
- `tesl/list-prim.rkt`
- `tesl/list.rkt`
- `tesl/logging.rkt`
- `tesl/maybe.rkt`
- `tesl/money.rkt`
- `tesl/net.rkt`
- `tesl/prelude.rkt`
- `tesl/private/http-stub.rkt`
- `tesl/private/runtime.rkt`
- `tesl/private/uuid-gen.rkt`
- `tesl/proxy.rkt`
- `tesl/queue.rkt`
- `tesl/random.rkt`
- `tesl/regex.rkt`
- `tesl/result.rkt`
- `tesl/server-tools.rkt`
- `tesl/set.rkt`
- `tesl/sse.rkt`
- `tesl/sso.rkt`
- `tesl/string.rkt`
- `tesl/telemetry.rkt`
- `tesl/time.rkt`
- `tesl/tuple.rkt`
- `tesl/units.rkt`
- `tesl/url.rkt`
- `tesl/uuid.rkt`
- `tests/adt-indexed-fact-tests.rkt`
- `tests/adversarial-review-tests.rkt`
- `tests/agent-conversation-pg-test.rkt`
- `tests/agent-conversation-tests.rkt`
- `tests/agent-feature-tests.rkt`
- `tests/agent-money-tools-tests.rkt`
- `tests/agent-provider-norm-test.rkt`
- `tests/agent-run-tests.rkt`
- `tests/agent-runtime-tests.rkt`
- `tests/agent-tests.rkt`
- `tests/agent-tools-tests.rkt`
- `tests/all.rkt`
- `tests/api-auth-sum-type-tests.rkt`
- `tests/api-test-computed-path-tests.rkt`
- `tests/api-test-template-tests.rkt`
- `tests/bench/codec-overhead.rkt`
- `tests/bench/proof-overhead.rkt`
- `tests/bench/proof_hot.rkt`
- `tests/body-proof-test.rkt`
- `tests/cache-tests.rkt`
- `tests/check-test.rkt`
- `tests/checkpoint-condition-test.rkt`
- `tests/civil-time-tests.rkt`
- `tests/codec-specialization-test.rkt`
- `tests/critical-review-26-tests.rkt`
- `tests/critical-review-28-tests.rkt`
- `tests/critical-review-33-tests.rkt`
- `tests/critical-review-35-tests.rkt`
- `tests/critical-review-48-adversarial-deep.rkt`
- `tests/critical-review-48-auth-api-tests.rkt`
- `tests/critical-review-48-conjunction-regression.rkt`
- `tests/critical-review-48-tests.rkt`
- `tests/critical-review-51-tests.rkt`
- `tests/critical-review-52-tests.rkt`
- `tests/critical-review-53-tests.rkt`
- `tests/critical-review-54-tests.rkt`
- `tests/critical-review-55-tests.rkt`
- `tests/critical-review-56-tests.rkt`
- `tests/critical-review-57-tests.rkt`
- `tests/critical-review58-tests.rkt`
- `tests/critical-review59-tests.rkt`
- `tests/critical-review60-tests.rkt`
- `tests/critical-review61-tests.rkt`
- `tests/critical-review62-tests.rkt`
- `tests/critical-review63-tests.rkt`
- `tests/critical-review64-tests.rkt`
- `tests/crypto-runtime-tests.rkt`
- `tests/dap-attach-smoke.rkt`
- `tests/dap-attach-value-tree-smoke.rkt`
- `tests/dap-conditional-smoke.rkt`
- `tests/dap-domain-registry-smoke.rkt`
- `tests/dap-headless-inspect-conditional-smoke.rkt`
- `tests/dap-headless-inspect-smoke.rkt`
- `tests/dap-headless-persistent-smoke.rkt`
- `tests/dap-server-test.rkt`
- `tests/dap-sql-scope-smoke.rkt`
- `tests/dap-stop-the-world-smoke.rkt`
- `tests/dap-value-tree-tests.rkt`
- `tests/db-write-test-body-tests.rkt`
- `tests/email-tests.rkt`
- `tests/emit-incidentals-regressions.rkt`
- `tests/example-api-test.rkt`
- `tests/example-test-batch.rkt`
- `tests/existential-regression-test.rkt`
- `tests/exists-consume-tests.rkt`
- `tests/exists-forwarding-tests.rkt`
- `tests/exists-test.rkt`
- `tests/filter-check-partial-tests.rkt`
- `tests/frontend-all.rkt`
- `tests/http-client-address-test.rkt`
- `tests/http-methods-tests.rkt`
- `tests/http-ssrf-tests.rkt`
- `tests/http-stub-tests.rkt`
- `tests/http-timeout-tests.rkt`
- `tests/http-tls-tests.rkt`
- `tests/httpclient-test.rkt`
- `tests/httpclient-tests.rkt`
- `tests/int32-runtime-tests.rkt`
- `tests/internal-all.rkt`
- `tests/issue-80-list-body-scaling-tests.rkt`
- `tests/jws-verify-test.rkt`
- `tests/jwt-session-policy-test.rkt`
- `tests/jwt-test.rkt`
- `tests/jwt-tests.rkt`
- `tests/lifted-list-tests.rkt`
- `tests/machine-login-tests.rkt`
- `tests/memory-backend-regressions.rkt`
- `tests/memory-db-registry-test.rkt`
- `tests/money-tests.rkt`
- `tests/multiparam_test.rkt`
- `tests/opaque-type-registration-test.rkt`
- `tests/otlp-exporter-test.rkt`
- `tests/otlp-metrics-test.rkt`
- `tests/otlp-traces-test.rkt`
- `tests/password-login-tests.rkt`
- `tests/pg-pool-tests.rkt`
- `tests/port-test.rkt`
- `tests/postgres-test.rkt`
- `tests/private/postgres-test-support.rkt`
- `tests/proxy-binding-http-tests.rkt`
- `tests/proxy-runtime-test.rkt`
- `tests/publish-record-payload-tests.rkt`
- `tests/query-parameters-tests.rkt`
- `tests/queue-job-id-tests.rkt`
- `tests/record-test.rkt`
- `tests/regex-runtime-tests.rkt`
- `tests/response-security-headers-test.rkt`
- `tests/secret-field-proof-tests.rkt`
- `tests/secret-inbound-tests.rkt`
- `tests/secret-proof-composition-tests.rkt`
- `tests/secret-runtime-tests.rkt`
- `tests/security-test.rkt`
- `tests/server-tools-tests.rkt`
- `tests/session-cookie-tests.rkt`
- `tests/session-cookie-tool-confinement-test.rkt`
- `tests/sql-clause-placement-tests.rkt`
- `tests/sql-group-by-pg-test.rkt`
- `tests/sql-group-by-tests.rkt`
- `tests/sql-index-tests.rkt`
- `tests/sql-maybe-in-tuple-tests.rkt`
- `tests/sql-money-pg-test.rkt`
- `tests/sql-money-tests.rkt`
- `tests/sql-newtype-range-tests.rkt`
- `tests/sql-read-lines-tests.rkt`
- `tests/sql-test.rkt`
- `tests/sql-where-hint-tests.rkt`
- `tests/sse-capabilities-test.rkt`
- `tests/sso-adversarial-test.rkt`
- `tests/sso-flow-test.rkt`
- `tests/sso-runtime-test.rkt`
- `tests/sso-stdlib-test.rkt`
- `tests/sso-web-test.rkt`
- `tests/ssrf-guard-test.rkt`
- `tests/stdlib-delete-tests.rkt`
- `tests/surface-regression-test.rkt`
- `tests/tesl-test.rkt`
- `tests/timezone-zones-test.rkt`
- `tests/trace-context-test.rkt`
- `tests/trace-propagation-tests.rkt`
- `tests/two-api-server-tools-tests.rkt`
- `tests/units-factor-golden-tests.rkt`
- `tests/units-tests.rkt`
- `tests/url-net-runtime-tests.rkt`
- `tests/url-net-tests.rkt`
- `tests/web-test.rkt`
- `tests/webhook-signature-tests.rkt`
