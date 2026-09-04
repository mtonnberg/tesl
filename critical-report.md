# Critical Technical and Product Audit of Tesl

**Audited revision:** `b80264f2a36df179d1f2ca2176b133a4095a17d6` (`improve-ergonomics-and-hardening`)  
**Audit date:** 2026-09-04  
**Scope:** language thesis, compiler and proof boundary, Go runtime, PostgreSQL resources, editor and agent interfaces, security posture, product maturity, and funding readiness.

## Post-Audit Remediation Status

The findings below describe the audited revision. A remediation pass in the working tree on 2026-09-04 fixed every confirmed non-migration technical finding and added regressions for the observed protocol, concurrency, ordering, security, compiler, and editor failures.

| Finding area | Current status |
|---|---|
| MCP transport and malformed-frame handling | **Fixed.** MCP now uses bounded newline-delimited JSON; LSP/DAP retain `Content-Length` framing. |
| Cross-file agent/LSP diagnostics | **Fixed.** Diagnostic file identity is preserved and open importers are rechecked after source and watched-file changes. |
| Queue/email ownership | **Fixed.** Runtime-owned UUIDv7 claim tokens fence every completion, retry, failure, dead-letter, and unlock outcome. |
| SSE reconnect recovery | **Fixed.** Commit-ordered dispatch sequences replace allocation-order delivery cursors, with bounded query, batch, and memory costs. |
| PostgreSQL initialization and runtime binding | **Fixed.** Initialization is single-flight and database scopes are serialized and goroutine-reentrant. |
| Memory transaction rollback | **Fixed.** Concurrent writers are gated so rollback cannot erase another writer's committed update. |
| Debugger isolation and stop barrier | **Fixed.** Stacks and SQL are execution-scoped; quiescent lifecycle scopes do not deadlock live handler stops. |
| CSRF and editor command execution | **Fixed.** State-changing requests require exact public origin and VS Code launches use argument-vector process execution under Workspace Trust. |
| Compiler/editor contracts | **Fixed.** JSON APIs are total and schema-validated, status is consistent, complexity is bounded, accepted exports are backend-supported, and LSP capabilities match handlers. |
| Documentation and test integrity | **Fixed.** Current architecture is documented as direct Go emission; stale and tautological known-gap tests were removed. |
| Application schema and queue-payload evolution | **Deferred by explicit scope.** No general migration framework was implemented. Runtime-internal idempotent columns used for claim fencing and SSE dispatch do not provide application schema evolution. |

Post-remediation verification completed in one authoritative run:

```text
./ci.sh
22/22 phases OK
754 seconds
```

Focused Go race tests, live PostgreSQL schedule tests, compiler tests, MCP/LSP/DAP tests, and all 18 VS Code extension tests also passed. The product, adoption, concentration, distribution, and funding conclusions remain unchanged; technical remediation does not establish product-market fit or production lifecycle safety without schema and payload evolution.

## 1. Bottom Line

Tesl has a credible technical core: a proof-carrying API language can preserve validation and authorization evidence across ordinary program structure better than middleware conventions, and Tesl implements meaningful whole-language invariants that a host-language library cannot enforce. The small abstract proof kernel, explicit proof-admission boundary, generated-code inspection, stable diagnostics, and unusually broad CI gate are substantial work rather than a prototype facade.

That does not make the current system production-ready or the broad company thesis validated.

The audit found one Critical integration defect, four High technical defects, and multiple Medium operational, security, compiler, and tooling defects. The standard MCP transport is incompatible with the protocol it claims to implement. Durable queue and email claims are not fenced, allowing stale workers to interfere with replacement attempts. Production schema evolution does not exist. Cross-file errors are either misattributed by `agent-context` or hidden by the LSP. Several runtime debugging claims are stronger than the implementation. No proof-kernel bypass, SQL injection, remote-code-execution path, or critical authentication bypass was confirmed.

The proof claim also requires precise wording. Tesl does not prove that arbitrary business predicates are mathematically true. It restricts who may assert a fact and then statically tracks that asserted evidence. User-authored `check`, `auth`, and `establish` declarations are trusted boundaries; checks still run at their boundaries, but proof evidence and downstream re-checks are erased. The result is useful proof continuity, not end-to-end theorem verification.

**Investment recommendation:** do not fund Tesl now as a broad mainstream API platform. A small, milestone-based pre-seed investment may be justified around the narrower thesis of compiler-enforced proof continuity for APIs, conditional on independent demand, lifecycle safety, protocol interoperability, distribution, and operational evidence.

## 2. Decisions

| Question | Decision | Confidence |
|---|---|---|
| Is the core proof-carrying API thesis technically credible? | **Yes, with an explicit trusted-boundary qualification.** | High |
| Is the compiler merely a demo? | **No.** It has a serious checker, proof kernel, emitter, diagnostics surface, and adversarial suite. | High |
| Is the audited release safe to present as production-ready? | **No.** Queue ownership, schema evolution, concurrency, and cross-file tooling are not ready. | High |
| Does the advertised MCP integration work with conforming clients? | **No at this revision.** | High |
| Has product-market fit been demonstrated? | **No public evidence found.** | Medium; private evidence was not available |
| Should the project receive broad platform funding now? | **No.** Use milestone-gated funding if pursuing the narrow thesis. | High |

## 3. What Was Verified

The audit combined source review with independent adversarial probes. It reviewed compiler admission and diagnostic paths, runtime concurrency and request boundaries, PostgreSQL behavior, MCP/LSP/DAP transport and discovery, extension command construction, documentation, roadmap state, repository history, and public project signals.

The authoritative project gate completed successfully:

```text
./ci.sh
22/22 phases OK
564 seconds
```

That run included OCaml tests, Go runtime and generated-code gates, fuzzing, race checks, documentation integrity, 574-test metamorphic coverage, exact generated snapshots, a live PostgreSQL backend, mutation testing, integration tests, a Nix clean install, CLI portability, boot smoke, OpenAPI DAST, browser/compiler parity, and browser SSO end-to-end tests. One nested portability check skipped a Racket ratchet because `racket` was not on `PATH`; the phase and complete gate passed.

Additional focused checks included:

- `dune runtest --ignore-promoted-rules`
- `go test ./...`
- focused `go test -race` across runtime, protocol, tooling, LSP, DAP, and MCP packages
- VS Code extension tests, 14/14 passing
- direct MCP wire probes using newline-delimited and `Content-Length` messages
- live PostgreSQL schedules for stale leases, delayed SSE commits, and concurrent initialization
- malformed compiler-input probes, imported-module diagnostic probes, deep-expression stress tests, and shell-substitution probes
- `go vet`, `staticcheck`, and `govulncheck` during focused runtime review

The repository was clean before report creation. Adversarial fixtures and generated probes remained under `/tmp/nix-shell.lGEHGH/opencode/` and were not added to the product test suite.

## 4. The Technical Thesis

### 4.1 What Tesl Actually Guarantees

Tesl's strongest differentiation is the combination described in `LANGUAGE-SPEC.md:84-123`:

1. Proof evidence is erased as the sole normal runtime mode.
2. Name shadowing is forbidden program-wide, protecting the identity of proof subjects.
3. `:::` proof fabrication is restricted to trusted declaration kinds and framework-owned sources.

The compiler centralizes admissions in an LCF-style kernel. `compiler/lib/proof_kernel.ml:1-21` keeps `proven_fact` abstract outside the module and permits boundary minting only for `CheckKind`, `AuthKind`, and `EstablishKind`; ordinary functions, handlers, workers, and `main` are refused. The invariant registry exercised all 13 specified soundness invariants, and adversarial tests rejected proof fabrication, subject retargeting, existential escape, missing capabilities, and non-exhaustive cases.

This supports the claim that Tesl makes proof flow mechanically auditable and prevents ordinary code from inventing evidence.

### 4.2 The Necessary Qualification

The word "proof" can invite a stronger interpretation than the implementation supports. A `check` body is trusted to perform the validation its return fact claims. The compiler verifies that evidence originates at an allowed boundary and remains attached to the correct subject; it generally does not derive the semantic truth of a user predicate from the body. `auth` and `establish` are similarly privileged. Framework-provided predicates and storage assumptions add further trusted inputs.

The trusted computing base therefore includes:

- the compiler and proof checker;
- all user and framework `check`, `auth`, and `establish` implementations;
- framework provenance and imported metadata;
- compiler-to-emitter agreement;
- generated runtime boundary behavior;
- Memory/PostgreSQL semantic agreement where tests and production use different stores.

`LANGUAGE-SPEC.md:49-51` explicitly says proofs and capabilities are erased and have no runtime re-check. That is a coherent design and removes runtime proof machinery, but it makes every compiler acceptance defect load-bearing. The prior internal review confirms this risk: a predicate-name-only bug once let a guest proof satisfy an admin declaration before being fixed (`language-review-executive.md:7-19`).

The fair claim is therefore:

> Tesl statically preserves evidence introduced by explicit trusted boundaries and rejects unauthorized evidence flow.

It should not be marketed as proving arbitrary check implementations or all application correctness.

### 4.3 Why the Thesis Still Matters

Within that boundary, the design has real value. Validation and authorization requirements become visible in signatures, proof identity survives refactoring, effect capabilities are explicit, and callers cannot casually bypass the evidence path. Stable diagnostics and compact semantic queries also provide agents with a better correction oracle than logs or generated-code errors alone. This is more defensible than a generic "AI-first language" claim.

## 5. Technical Findings

Severity describes impact at the audited revision, not exploitability alone. Product-blocking interoperability and correctness failures can be Critical or High without being remote security vulnerabilities.

### C1. MCP Uses the Wrong Stdio Transport

**Severity: Critical**

`runtime/go/cmd/tesl-mcp/main.go:44-47` constructs the shared LSP/DAP `Content-Length` reader and writer. That reader explicitly implements LSP/DAP framing at `runtime/go/internal/protocol/framing.go:29-40`. MCP protocol version 2024-11-05 specifies newline-delimited JSON-RPC for stdio, not LSP headers.

**Verified effect:** a conforming newline-delimited `initialize` request produced zero stdout bytes. The same request wrapped in `Content-Length` framing produced a valid response. The documentation claims that any MCP-capable agent can register the server at `editor/tesl-mcp/README.md:3-10,111-153`, but a standard client cannot complete initialization.

The defect survives CI because both the unit test and smoke test implement the same private protocol on the client side (`runtime/go/cmd/tesl-mcp/main_test.go:173-225`; `tests/go-cli-smoke.sh:161-168`). This is a systemic oracle problem: implementation and test agree with each other but not with the external contract.

**General remediation:** create a separate bounded newline-delimited MCP transport rather than sharing LSP/DAP framing. Add conformance tests driven by an official MCP SDK or an independently implemented raw client. Treat external protocol specifications, not internal round trips, as the oracle.

Reference: <https://modelcontextprotocol.io/specification/2024-11-05/basic/transports>

### H1. Durable Queue and Email Claims Have No Fencing Identity

**Severity: High**

PostgreSQL queue claims record status, timestamp, and instance, but completion and failure operate by row ID alone (`runtime/go/teslrt/pgstores.go:382-472`). Email outcome updates have the same ownership problem (`runtime/go/teslrt/pgstores.go:665-697`). Once a visibility timeout expires, another worker can reclaim the row while the old worker still runs. The old worker can then delete, retry, mark, or unlock the replacement's active attempt.

**Verified effect:** live PostgreSQL probes demonstrated an old queue worker deleting a job held by its replacement and an old email worker clearing the replacement's lock. Race detection remains green because this is a distributed ownership bug, not a Go memory race.

**General remediation:** assign a unique claim token or monotonically increasing generation on every claim. Every complete, fail, retry, dead-letter, and unlock statement must include both row ID and claim identity. Zero affected rows means the lease expired and the result must be discarded. Add optional heartbeat renewal for long-running work. Apply the same lease primitive to every durable worker resource rather than fixing queue and email independently.

The roadmap already identifies `claim_seq` as an independent prerequisite at `roadmap/later/queue-payload-migrations.md:21-25`.

### H2. Production Schema Evolution Is Not Implemented

**Severity: High**

Runtime bootstrap creates schemas, tables, and indexes only when absent. Existing tables are deliberately left unchanged (`runtime/go/teslrt/postgres.go:222-260`). The extensive migration document is explicitly a target design and delivery plan, not an implemented feature (`roadmap/later/database-migrations.md:14-24`).

This blocks a normal production lifecycle. Stateful APIs change columns, constraints, indexes, codecs, and deployed code versions. Without an implemented compatibility protocol, users must perform changes outside Tesl's proof and deployment model, exactly where production data risk is greatest.

Queue payloads compound this gap. Any instance can claim a job emitted by another deployed version; an incompatible payload is quarantined forever (`runtime/go/teslrt/pgstores.go:396-423`; `roadmap/later/queue-payload-migrations.md:11-25`).

**General remediation:** until safe evolution ships, compile or deploy must refuse unsupported schema and durable-payload changes. Then implement versioned schemas, compatibility checks for rolling deployments, typed migration functions, durable migration state, and tested crash/resume semantics. Do not describe all durable typed data as deployment-safe before both table and queue evolution are covered.

### H3. Cross-File Errors Are Misattributed by `agent-context`

**Severity: High**

Whole-program checking includes dependency errors (`compiler/lib/compile.ml:4182-4193`), but the compact diagnostic serializer removes file identity (`compiler/lib/compile.ml:4041-4068`) because it assumes a single-file snapshot.

**Verified effect:** `--check-json` correctly identified a `T001` in a temporary `lib.tesl`; `agent-context` labeled the snapshot as `main.tesl` and returned the dependency's line number without its file. An editing agent is therefore directed to the wrong file, undermining the core compiler-guided edit loop.

**General remediation:** preserve `file` whenever it differs from the requested file, or group diagnostics by source file while omitting only redundant same-file paths. Add an imported-error conformance fixture to every agent interface.

### H4. LSP Silently Drops Dependency Diagnostics

**Severity: High**

The LSP asks the compiler for whole-program diagnostics at `runtime/go/internal/lsp/server.go:1682-1696`, then discards every diagnostic whose path differs from the open entry document at `runtime/go/internal/lsp/server.go:1697-1702`.

**Verified effect:** the compiler reported `T001` in an imported module while the LSP published an empty diagnostic set. An editor can therefore present a clean project that `tesl check` rejects.

**General remediation:** publish diagnostics grouped by their actual document URI and invalidate dependents when an imported document changes. Before full workspace indexing exists, at minimum publish an entry-file diagnostic that identifies the broken dependency. Test compiler, LSP, and agent views against one shared multi-file fixture.

### M1. PostgreSQL Initialization and Global Database Binding Are Not Concurrency-Safe

**Severity: Medium**

Initialization and process-global binding at `runtime/go/teslrt/postgres.go:98-131,226-260` and `runtime/go/teslrt/database.go:37-44,84-97` allow duplicate pools, bootstrap races, and overlapping scopes that unbind each other.

With 32 concurrent calls for one configuration, probes observed 22 distinct pools and 10 bootstrap traps; under race instrumentation, 23 pools and 9 traps. A deterministic overlapping `WithDatabase` probe first removed a still-active binding and then left a stale one.

**Remediation:** single-flight initialization per configuration, close losing pools, and avoid process-global scoped database state. Associate transactions and requests explicitly with their database.

### M2. SSE Recovery Can Permanently Skip a Committed Event

**Severity: Medium**

The PostgreSQL pub/sub sweep advances an allocation-order ID cursor. A transaction that reserves a low ID but commits after a higher ID can become visible below the cursor. The implementation documents that losing its commit notification during reconnect makes the event unrecoverable (`runtime/go/teslrt/pgpubsub.go:499-535`).

A live schedule committed row 14 after the cursor reached 15 while LISTEN reconnected; later sweeps never delivered row 14.

**Remediation:** do not treat allocation order as commit order. Poll retained undelivered rows with durable deduplication, or use a dispatcher that assigns delivery order only after commit visibility.

### M3. Debug Snapshots Are Not Stop-the-World or Request-Isolated

**Severity: Medium**

Debug state is globally aggregated in `runtime/go/teslrt/debug.go:223-240,275-304,335-386`, `debug_state.go:48-94`, and `debug_sql.go:8-37`. Documentation says breakpoints pause all threads and snapshots are stop-the-world (`README.md:128-129`; `editor/tesl-mcp/README.md:46-49`).

Probes showed unrelated application work continuing while paused, independent request goroutines appearing as a single nested stack, and one query's row count attaching to another query's SQL capture.

**Remediation:** key call stacks and SQL capture by execution context; bind completion callbacks to immutable capture identities; use a cooperative process-wide pause barrier before collecting state. Otherwise rename and document the output as a non-atomic observation.

### M4. Same-Site Sibling Origins Bypass Exact-Origin CSRF Validation

**Severity: Medium**

The CSRF path at `runtime/go/teslrt/serve.go:509-550` returns early for `Sec-Fetch-Site: same-site`, without requiring exact origin equality. Sibling subdomains are same-site, so a compromised or attacker-controlled sibling can submit authenticated state-changing requests.

A POST to `app.example.test` with `Origin: https://evil.example.test` and `Sec-Fetch-Site: same-site` reached the handler and returned 200.

**Remediation:** permit `same-origin`; reject `cross-site`; validate `Origin` exactly against configured public origins for `same-site`, or reject same-site by default. Do not treat unknown nonempty Fetch Metadata values as trusted.

### M5. VS Code Terminal Commands Permit Shell Substitution

**Severity: Medium**

Several extension commands interpolate file paths, test names, or launch paths into shell text (`editor/vscode-tesl/extension.js:489-498,578-585,639-656,1153-1165`). Double quotes and `JSON.stringify` do not neutralize `$()` or backticks in a shell.

A path containing `$(touch .../injected-marker)` created the marker when the user invoked the command. Exploitation requires command invocation, but repositories commonly control paths and test names. Test Explorer's argument-vector `spawn` path is safer.

**Remediation:** use VS Code task/process APIs or `spawn` with an argument array everywhere. Enforce workspace trust for execution commands. Do not attempt one cross-platform hand-written shell escaper.

### M6. Compiler JSON APIs Fail Their Machine Contract on Lexer Errors

**Severity: Medium**

Several semantic-query commands can escape through the outer exception handler and print plain text (`compiler/bin/main.ml:1114-1242,1592-1595`; reparse at `compiler/lib/compile.ml:4182-4191`). A NUL byte caused plain-text errors from `agent-context`, type, completion, binding, and selection queries, while `--check-json` correctly returned structured `E000`.

**Remediation:** convert lexer and parser failures into each command's documented JSON envelope. Reuse the checked parse result rather than reparsing for symbols. Add malformed-byte contract tests for every JSON command.

### M7. `agent-context` Status and Exit Code Disagree

**Severity: Medium**

For lint-only errors, `agent-context` serializes the combined diagnostic result but computes process status from a separate compiler-only result (`compiler/bin/main.ml:1125-1131`). A tab-indentation fixture returned `ok:false` with `E010` and exit code 0; `--check-json` exited 1.

**Remediation:** derive output and exit status from one diagnostic collection. Contract-test every severity combination.

### M8. Valid Deep Expressions Have Superlinear Cost

**Severity: Medium**

Valid nested lambdas exhibit severe growth. A 1,000-lambda, 23,990-byte file took about 0.90 seconds and 70 MB under `--check`; 2,000 lambdas took about 9.07 seconds and 222 MB. `agent-context` took about twice as long because it repeats checking (`compiler/bin/main.ml:1126-1129`; `compiler/lib/compile.ml:4182-4193`).

**Remediation:** eliminate duplicate checks, profile substitution/unification and type rendering, and enforce a documented AST depth or complexity budget for interactive tools.

### M9. The Checker Accepts Standard-Library Exports the Go Backend Cannot Emit

**Severity: Medium**

The compiler advertises approximately 60 exports that the sole backend refuses, including common collection higher-order functions and conversions (`compiler/test/test_go_stdlib_export_seam.ml:76-111`). A `Dict.map` program returned `agent-context` `ok:true`, then Go emission failed closed with `V001`.

This is not proof unsoundness, and the seam inventory test prevents silent drift, but editor-green/build-red is a material completeness failure.

**Remediation:** implement the exports, remove them from the backend-visible environment, or make backend availability part of checking.

### M10. Agent Debug Tool Timeouts and Defaults Contradict Their Contract

**Severity: Medium**

MCP compiler subprocesses inherit a fixed 15-second timeout (`runtime/go/internal/tooling/compiler.go:18,40-49`), including debug operations (`runtime/go/cmd/tesl-mcp/main.go:147,205`). Documentation permits a 30-second `debug_attach.timeout_ms`. A 20-second helper requested with 30 seconds failed at exactly 15 seconds.

`tesl.debug_attach` also documents `once` and nearest-project discovery as defaults (`editor/tesl-mcp/README.md:66-76`), while implementation defaults to `snapshot`, does not find the nearest `tesl.toml`, and accepts schema-valid `{}`.

**Remediation:** propagate requested timeout plus startup margin and align implementation, schema, and documentation around one explicit default/discovery contract.

### M11. LSP Advertises and Implements Different Feature Sets

**Severity: Medium**

Declaration, type definition, document link, linked editing, pull diagnostics, and semantic range/delta handlers exist but are absent or incorrectly shaped in server capabilities (`runtime/go/internal/lsp/server.go:145-315`). Conversely, `tesl.applyFix` is advertised but no-op, and unsupported source action kinds are advertised. Range and on-type formatting are advertised but return whole-document edits (`runtime/go/internal/lsp/server.go:1089-1113`).

**Remediation:** maintain a tested LSP 3.17 capability-to-handler matrix. Remove unsupported commands and formatting modes until semantics match the protocol.

### M12. Tooling Schemas Fail Open

**Severity: Medium**

The LSP decodes compiler output into zero-valued structs and validates only the protocol version (`runtime/go/internal/lsp/server.go:1690-1696`). `{"version":1}` appeared as a clean check; a diagnostic object with no fields became a blank information diagnostic at `0:0`.

**Remediation:** validate required keys, field types, enums, nonempty codes/messages, and ranges before accepting compiler output. Publish a visible `TESL-COMPILER` failure when schemas are invalid.

### Lower-Severity and Documented Limits

- **Low:** unauthenticated debug handshakes have no pre-auth read deadline or connection cap (`runtime/go/teslrt/debug_control.go:328-343,398-442`); 64 silent connections retained at least 60 goroutines.
- **Low:** long workspace paths can exceed Unix socket limits and fail DAP/debug launch (`runtime/go/internal/dap/target.go:149-157,453-490`; `runtime/go/teslrt/debug_control.go:133-135`).
- **Low:** malformed LSP/MCP frames can desynchronize the stream because the process continues after errors without necessarily consuming the body (`runtime/go/cmd/tesl-mcp/main.go:47-53`; `runtime/go/internal/lsp/server.go:71-82`).
- **Low:** hover coverage is narrower than documented; typed declaration/binding positions can return null.
- **Low:** unused phantom type parameters receive no warning, allowing misleading type applications.
- **Low/process:** several historical antagonistic tests have stale "known gap" names or always-pass assertions even though newer tests cover the corrected behavior.
- **Documented limitation:** Memory transaction rollback restores whole-table snapshots and can erase another goroutine's committed write (`runtime/go/teslrt/table.go:722-793`; `LANGUAGE-SPEC.md:1955`). Do not infer concurrent transaction isolation from Memory-backed tests.

## 6. Systemic Root Causes

The findings cluster into a smaller set of engineering problems:

1. **Self-consistent tests without independent oracles.** MCP tests validate the implementation against another copy of the same mistaken framing assumption. Capability responses and JSON schemas have similar gaps.
2. **Identity is weaker than ownership duration.** Queue/email rows identify work, but not a specific attempt. SSE IDs identify allocation order, not commit order. Debug state identifies neither request nor query execution.
3. **Single-file abstractions are used for whole-program results.** The compiler sees dependency errors, while agent and editor adapters either strip or discard their source identity.
4. **Process-global state substitutes for execution context.** Database binding, debug stacks, and SQL capture break under otherwise race-free concurrency.
5. **Acceptance surfaces drift.** Checker versus backend exports, LSP handlers versus advertised capabilities, and documentation versus debug defaults are not generated from one source of truth.
6. **Feature breadth outruns lifecycle depth.** Tesl supports many runtime services but has not closed schema evolution, rolling-deploy payload compatibility, or distributed lease ownership.

General fixes should target these families, not only each observed schedule.

## 7. Strengths

The negative findings should not obscure the project's strongest evidence:

- The proof kernel is small, abstract, fail-closed, and auditable (`compiler/lib/proof_kernel.ml`).
- The 13 specification invariants are executable and currently exercised; attempted proof forgery and capability bypasses were rejected.
- The compiler combines type, proof, and validation diagnostics and provides stable codes, spans, explanations, and often fixes.
- SQL values remain parameterized and identifier quoting is centralized.
- Session, JWT/JWS, Argon2id, SSO state, SSRF redirect/dial enforcement, secret redaction, static-file containment, request bounds, JSON integer handling, and panic containment are materially hardened.
- PostgreSQL queues, cache, email, and pub/sub are durable and transaction-aware, notwithstanding the ownership and ordering defects above.
- The project has an unusually comprehensive CI gate for its size: all 22 audited phases passed.
- Exact generated snapshots, mutation testing, fuzzing, race detection, DAST, browser SSO, documentation integrity, and live PostgreSQL tests reduce common compiler/runtime regression risks.
- The project is unusually candid about beta status, breaking changes, unsupported installation paths, migration gaps, and prior defects (`README.md:9-12,132-136`; roadmap documents; `language-review.md`).
- Generated Go is inspectable, dependency-pinned, and fails closed for unsupported standard-library shapes.

## 8. Product and Funding Assessment

### 8.1 Credible Wedge

The defensible wedge is narrow: compiler-enforced proof continuity for validation, authorization, and effects in APIs, with diagnostics designed to guide both humans and coding agents. That can plausibly reduce review burden and classes of forgotten-boundary checks.

The less defensible framing is a complete mainstream API platform "for the AI era." The repository does not provide comparative evidence that agents produce Tesl systems faster or more safely than Go, Kotlin, Rust, Haskell, or TypeScript with established schemas and policy tooling.

### 8.2 Market Evidence

No repository evidence was found for production customers, design partners, retention, willingness to pay, or measured defect reduction. A public GitHub API snapshot on 2026-09-04 showed 3 stars, 0 forks, no tags or releases, and effectively one contributor identity. These signals are weak and do not rule out private traction, but no private evidence was available to this audit.

The correct conclusion is "demand unproven," not "no demand exists."

### 8.3 Adoption Friction

Nix is the only supported installation path (`README.md:53-81`; `INSTALL.md:1-24,156-163`). Standalone binaries, Homebrew/APT, native Windows, and VS Code Marketplace distribution are not available; the project does document an Open VSX path. There are no tagged releases.

Tesl also deliberately omits an FFI, subprocess access, arbitrary filesystem access, and a reusable package ecosystem. External functionality must often be added to the trusted runtime or moved behind HTTP services. This protects the language model but creates a central maintainer bottleneck and raises the cost of ordinary integrations.

### 8.4 Scope and Team Risk

The platform owns a compiler, proof model, Go emitter/runtime, auth, SQL, two stores, transactions, queues, cache, email, SSE, SSO, telemetry, AI providers, OpenAPI, DAST, LSP, DAP, MCP, deployment, documentation, and editor distribution. Public history indicates key-person concentration, while `roadmap/next/` does not communicate a narrow near-term delivery sequence.

The breadth is technically impressive but commercially dangerous. Each built-in service creates compatibility, security, and operational obligations, and the audit found defects specifically at their seams.

### 8.5 Documentation Integrity

The documentation is extensive and generally candid, but the normative specification contains stale Racket lowering/runtime descriptions at `LANGUAGE-SPEC.md:125-153` while its opening correctly describes the Go emitter at `LANGUAGE-SPEC.md:49-51`. Debug stop-the-world and MCP compatibility claims are also stronger than observed behavior. A source of truth must distinguish current implementation, target design, and historical architecture consistently.

## 9. Funding Recommendation and Gates

**Recommendation: no broad platform investment at this stage. Consider only a small milestone-based investment into the narrow proof-continuity thesis.**

Funding should be released against evidence, in this order:

1. **Interoperability:** ship a standard MCP transport and protocol conformance suite; correct cross-file LSP/agent diagnostics; remove shell interpolation from the extension.
2. **Distributed correctness:** add claim fencing to queue and email; fix SSE recovery; make database initialization and request state concurrency-safe.
3. **Lifecycle safety:** refuse unsafe schema/payload changes before implementing typed, crash-resumable, rolling-deploy-compatible evolution.
4. **Focused product:** identify one ICP and one high-value workflow; freeze unrelated platform expansion for a six-month roadmap.
5. **Demand:** obtain several independent design partners running non-demo services and credible paid pilot commitments.
6. **Distribution:** publish signed/versioned Linux and macOS releases with a non-Nix route and repeatable installation telemetry.
7. **Operational proof:** exercise upgrades, restarts, rolling deployments, schema changes, queue retries, dependency failures, and recovery on multiple real services.
8. **Independent assurance:** commission an external compiler/proof-boundary and runtime security review against a tagged release.
9. **Measured value:** compare validation/auth defects, review time, and agent correction loops against a credible established stack.
10. **Team resilience:** add at least one regular compiler/runtime contributor and document release, security, and incident ownership.

Suggested stop conditions are equally important. Do not continue platform funding if design partners do not sustain usage, if schema and queue evolution remain outside the safety model, or if the project cannot narrow its trusted runtime surface enough for the team to maintain independently.

## 10. Recommended Engineering Order

### Immediate

1. Replace MCP framing and add an independent conformance client.
2. Add claim tokens to every durable lease outcome.
3. Publish dependency diagnostics under their actual file in both LSP and agent responses.
4. Replace extension shell strings with argument-vector process execution.
5. Correct stop-the-world documentation or implement the required pause and request isolation.

### Before Production Pilots

1. Refuse unsupported schema and durable-payload changes.
2. Fix PostgreSQL initialization, global binding, SSE ordering, and exact-origin CSRF checks.
3. Make compiler JSON envelopes total and align `ok`, diagnostics, and exit codes.
4. Make checker acceptance backend-aware.
5. Add adversarial regressions for every confirmed schedule and protocol failure.

### Quality-System Changes

1. Test public protocols against independent implementations.
2. Generate advertised capabilities and tool schemas from handler definitions where feasible.
3. Establish one cross-layer fixture set for compiler, agent context, LSP, emitter, and runtime.
4. Model leases with an explicit reusable ownership type: resource ID plus attempt identity plus expiry.
5. Treat global mutable runtime state as a design-review trigger even when `-race` is green.
6. Track target designs separately from shipped guarantees and remove stale architecture text.

## 11. Audit Limits

- The review applies only to commit `b80264f2a36df179d1f2ca2176b133a4095a17d6`.
- It was a source-assisted adversarial audit, not a mathematical verification of the compiler or generated runtime.
- No production deployment, network partition, multi-host PostgreSQL cluster, long-duration load campaign, Windows-native run, macOS-native run, or complete editor GUI session was performed.
- Public adoption signals are a point-in-time snapshot and cannot reveal private users or commercial discussions.
- The original ad hoc fixtures remain outside the repository; the confirmed failures addressed in the remediation pass were converted into focused regression tests.
- A green CI gate establishes strong regression discipline over covered behavior; it does not establish external protocol conformance or distributed correctness for schedules absent from the suite.

## 12. Final Assessment

Tesl is a technically serious beta compiler with a real idea at its center. Its proof-flow model, diagnostic design, and quality discipline merit continued investigation. The strongest version of the project is a focused language for auditable API invariants, not a sprawling replacement for the web platform.

At the audited revision, the gap between that core and a dependable product remains large. Critical agent interoperability is broken, durable ownership and schema lifecycle are incomplete, cross-file feedback can lie by omission or attribution, and adoption evidence is absent. Those are fixable engineering and validation problems, but they must be resolved before production or broad funding claims are justified.
