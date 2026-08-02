# Migrate the runtime target from Racket to Go

## Background

First-pass analysis (2026-08-02) of replacing the Racket backend, driven by two goals: raw performance and security. Type safety is the compiler's job and stays unchanged — the whole OCaml pipeline (parser, checker, proof system, capability validation) is untouched by this; only `emit_racket.ml` and the `dsl/` + `tesl/` Racket runtime are in scope.

Rust was evaluated first and rejected: Tesl semantics are GC-shaped (closures, immutable ADTs, uniform values, persistent record updates), so emitted Rust degenerates into `Rc<RefCell<>>` soup that forfeits Rust's performance advantage while keeping all the borrow-checker pain in codegen; rustc's compile time (10–60s per emitted app vs ~1s today) kills the api-test/agent dev loop, which is core to Tesl's value proposition; and Rust's headline gain — memory safety — is not a gain over Racket CS, which is already memory-safe. Rust only wins if hard no-GC tail-latency requirements or embedding appear.

Go fits where Rust didn't, and a portability survey of the actual runtime confirmed feasibility: the runtime uses **no `call/cc`, no runtime `eval` of user code** (breakpoint conditions go through a hand-written evaluator, `eval-bp-condition` in `dsl/debug/checkpoint.rkt`), and `dynamic-require` only for module-cycle breaking (`dsl/web.rkt:2465`, `dsl/otel.rkt`, `tesl/agent.rkt`) — trivially replaced by direct linking. Continuation marks appear only in error paths. Nothing exotic blocks a port.

Other contenders, for the record: **OCaml** is the strongest technical fit (one toolchain, full exhaustiveness checking on emitted code, `zarith` solves the Int question natively) but its HTTP/TLS/crypto ecosystem lacks Go-stdlib audit depth; **.NET/F#** is the strongest "boring industrial" alternative (Kestrel perf, audited crypto, `BigInteger`, Native AOT) but carries platform weight and no infrastructure-culture credibility. If Int must stay bignum, the race tightens to OCaml vs .NET (see Open decisions).

## Why Go

1. **Battle-tested "for free".** A Tesl app becomes "plain Go underneath": `net/http` serving, `pgx` pooling, stdlib `crypto/*` and TLS. The load-handling question stops being "can Tesl scale?" and becomes "can Go scale?" — already answered in every ops team's head. The pool-lease (#31) and SSE-channel (#32) bug classes get outsourced to code with millions of deployments. The ops story transfers too: pprof, delve, `govulncheck`, standard k8s probes — an SRE can operate a Tesl app with knowledge they already have.
2. **Typed target verifies the emitter.** Emitted Racket is untyped; past emit bugs (newtype unwrap miss in `unwrap-non-null`, missing `ECase` arm in `emit_api_test_expr`, secret emitted before its `via` check) shipped silently and were only caught by live testing. Emitted Go is type-checked by the Go compiler — a second, independent verifier of `emit_go.ml` on every build.
3. **Eject and audit story.** Emitted Go is readable, ownable code: "if Tesl dies you hold a plain Go codebase" de-risks adoption of a niche language, and a security reviewer can actually read the output.
4. **Deployment security.** `CGO_ENABLED=0` static binary → `FROM scratch` image. This subsumes most of `roadmap/later/slimmer_and_more_secure_image_generation.md` (no shell, no package manager, no userland at all — beyond what distroless achieves for Racket) and eliminates that item's bundled-OpenSSL-1.1 supply-chain wrinkle.
5. **Performance.** 2–5x throughput on IO-bound HTTP+SQL workloads, a fraction of the RSS, ms cold start, sub-ms GC pauses. (Honest framing: Racket CS compiles natively via Chez and is not slow; the dominant wins are memory, tail latency, and startup, not raw CPU.)
6. **Dev loop survives.** Go builds small services in ~1–3s; the emit + `go build` + run cycle for api-test roughly matches current Racket timing. This was the Rust killer; Go passes.

## Architecture: transpiler, not VM

Two textbook routes exist — source-to-source (emit `.go`, shell to `go build`) or a bytecode VM/interpreter written in Go (the Tengo/Gopher-Lua pattern). For Tesl the choice is forced: **transpiler only**. The VM route would be *slower than the current backend* (a tree-walker is 10–100x below native; Racket CS already compiles to native code), loses the Go-compiler-checks-the-emit verification, and kills the "plain Go underneath" credibility (pprof would profile the dispatch loop, delve couldn't step user code). The VM's genuine advantages (hot reload, pause-anywhere) are either unneeded (1–3s builds) or already solved by instrumentation. Interpreter *islands* remain fine and normal — the breakpoint-condition evaluator already is one.

Use Go's **`//line` directives** so emitted code carries `//line foo.tesl:377` — panics, stack traces, and delve then report Tesl source positions natively. This replaces a chunk of what `source_map.ml` + `thsl-src!` do by hand today.

## The cost center: absorbing the macro layer

The Racket backend leans hard on macros: `define-record`/`define-entity`/`define-checker`/`define-api` (in `dsl/types.rkt`, `dsl/web.rkt`, `dsl/sql.rkt`) expand into codecs, SQL mapping, routing, auth/proof wiring. Go has no macros — **all of that expansion moves into `emit_go.ml`**. Expect the emit backend to grow 2–3x over `emit_racket.ml`'s ~8.7k lines, with the runtime library shrinking correspondingly. This is where the effort concentrates; the HTTP/SQL plumbing is not the hard part.

## Semantic mapping notes

- **Records**: today symbol-keyed hashes (`record-value` + `tesl-hash`). In Go: nominal structs — the checker knows every type. Perf win and type-check win. Catch: `tesl-dot/runtime` does runtime structural field resolution with checker hints (the #26/#27 machinery). Go needs 100% static resolution; any remaining runtime-fallback cases must become checker responsibilities. Flushing those out is itself a soundness improvement.
- **ADTs**: sealed-interface or tag+struct pattern via generics. Go does **not** check exhaustiveness — a real loss vs OCaml/Rust. Mitigate with the `exhaustive` linter in generated-code CI and/or emitted `default: panic` arms (the checker guarantees exhaustiveness upstream).
- **Facts / proofs / capabilities**: runtime values today (`check-ok-facts`, `ensure-named`, `define-capability`, `require-capabilities!`). Port as plain structs + registries. Must be ported faithfully — the migration itself reopens the forgery-class surface closed during 2026-07; treat the capability/proof runtime as the security-critical core of the port, and keep it small enough to audit in an afternoon and array-lookup cheap on the hot path.
- **Recursion**: Racket has TCO, Go doesn't. Recursive `tesl/list.rkt`-style ops become loops in the Go runtime; tail-recursive worker loops become `for`. Mechanical but must be systematic.
- **Concurrency**: threads/queues/SSE map to goroutines + channels, more idiomatically than to Racket threads.

## Runtime library mapping

| Today | Go |
|---|---|
| `web-server/servlet-env` (`dsl/web.rkt`) | `net/http` (stdlib) |
| Racket `db` + hand-rolled pool (`dsl/sql.rkt`) | `pgx` |
| `tesl/crypto.rkt`, `tesl/jwt.rkt` (libsodium/OpenSSL FFI) | stdlib `crypto/*` + `golang-jwt` |
| `dsl/sso.rkt` OIDC | `coreos/go-oidc` |
| Hand-rolled OTLP (~1.5k LOC: `dsl/otel.rkt`, `dsl/traces.rkt`, `dsl/metrics.rkt`, `dsl/trace-context.rkt`) | official `otel-go` SDK |
| `tesl/email.rkt` SMTP | `net/smtp` / gomail |

Of ~23k runtime LOC, roughly half evaporates into stdlib/ecosystem; half ports (proof runtime, checkers, api-test harness, debugger, domain registry).

## Debugger and api-test port

Feasible because the current design is **instrumentation-based, not Racket-magic-based**: `thsl-src!` wraps statements with source location + locals; the checkpoint table, control channel, and DAP server are ordinary code. The same technique works verbatim in emitted Go — instrumentation calls checking a breakpoint table, blocking on a channel, control channel over TCP, DAP server in Go. The condition evaluator ports directly. Release builds erase instrumentation exactly as now — and must **provably** do so, or the "plain Go underneath" claim carries an asterisk. Value-tree and the SQL lens are reimplementation work, not architecture loss.

## Design invariants (the credibility claim creates these)

The "battle-tested for free" argument holds only while these stay true — treat them as stated invariants of the backend, not accidents:

1. **Thin runtime.** Lean maximally on stdlib; if a skeptic opens emitted code and finds a thick custom framework between request and handler, the claim degrades to "Go plus a framework you've never heard of."
2. **Readable emit.** Emitted code should look like Go a person could have written.
3. **Zero instrumentation in release builds**, verifiable structurally.

Honest limit to keep in the docs: the credibility transfer covers the *runtime*, not codegen quality — emitted code can still be slow in any language (allocation churn, N+1 queries). Load tests on emitted apps are still needed.

## Open decisions (settle before writing any emit code)

1. **Int semantics — the big one.** Racket Ints are bignums; Tesl Int inherits arbitrary precision. Go options: `math/big.Int` everywhere (slow, ugly, erodes the perf win on arithmetic) or redefine Int as checked int64 (a language semantic break — precedent exists in the Int32 range-rule design, but this is a language decision, not a port detail). This decision materially affects the OCaml-vs-Go call (OCaml's `zarith` makes the problem vanish).
2. Exhaustiveness mitigation: `exhaustive` linter vs panic-default arms vs both.
3. What "release build" means structurally, so instrumentation absence is checkable.

## Migration path

1. Settle the Int decision.
2. `emit_go.ml` behind a flag; Racket stays the reference backend.
3. **Differential corpus testing**: run the entire `.tesl` corpus (`compile-examples.sh`, `tests/*.tesl`) through both backends and diff observable behavior — the existing ratchet suite becomes a cross-backend oracle. This is the main defense against the long tail of parity bugs (float formatting, string/unicode, JSON edges).
4. Port runtime lib by lib, capability/proof runtime with its own focused security review.
5. Debugger and api-test instrumentation last.
6. Retire the Racket backend only when the corpus diff has been empty across the full suite for an extended period.

Scale estimate: person-year class — roughly half the Rust estimate with ~90% of the gains.
