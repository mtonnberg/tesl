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

## Incremental adoption in Go shops (near-free win)

The transpiler design already solves "how does a Go shop introduce Tesl incrementally" — no FFI needed. A Tesl app compiles to a plain Go service that deploys next to existing services with the same CI, pprof, delve, `govulncheck`, and k8s probes; the service boundary is the integration point, and Go shops overwhelmingly run microservices or at least a handful of services already. This is an adoption argument, not an engineering cost — the work is small ergonomics that make it land:

- Emit a proper `go.mod` and a readable package layout, so the emitted service is a normal module in their monorepo/CI.
- Generate typed Go client stubs for Tesl API endpoints, so neighboring Go services call the Tesl service with a typed client instead of hand-rolled HTTP.
- Optionally: consume existing OpenAPI/proto definitions so the Tesl service can call its Go neighbors typed in the other direction.

**FFI is deliberately not the adoption mechanism.** An arbitrary Go call from Tesl is an unchecked effect — it bypasses the capability system and reopens the fail-open surface closed during 2026-07; every FFI import is an unverified axiom. If FFI ever ships, it comes in two tiers: (1) curated, capability-gated leaf modules first — the existing `*-prim.rkt` lift pattern *is* this model, with the runtime team writing Go leaves and users seeing Tesl modules — and (2) open capability-declared `extern` as a separate decision, only after the Racket backend retires, because any `.tesl` file using Go FFI cannot run through the differential cross-backend oracle (Migration path step 4).

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
- **Cyclic imports — solved by design, not an open decision.** Tesl allows import cycles among pure declarations (cycles containing config decls are already a compile error — `cycle_unsafe_decl_reason`, `compile.ml`). Racket forbids cyclic `require` too, so the emitter already handles this: the cyclic-SCC inliner (`emit_racket.ml`, "Inline declarations from cyclic SCC modules") textually inlines a cycle's declarations into the importing module. The Go mapping is *cleaner*: collapse each cyclic SCC into one Go package with **one file per member module** — files within a Go package reference each other freely (no ordering, no forward declarations), so mutual recursion works without textual inlining, and `//line` keeps each file mapped to its own `.tesl` source. Two mechanical items: module-prefixed name mangling inside merged packages (collision dedup, as the inliner's `emitted_names` table does today), and a seam test that const-*value* cycles are checker-rejected (Go rejects initializer cycles as a loud build error anyway — fail-closed). For the readable-emit invariant, the merged package's comment should say "import cycle collapsed to one package" so a Go reviewer isn't puzzled by two modules sharing a package.

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

## Pre-migration: lift Racket stdlib into Tesl first

A third bucket exists besides "evaporates" and "ports by hand": Racket runtime code that could be **rewritten in Tesl itself before any Go work starts**. Anything living in a `.tesl` file needs no porting at all — `emit_go.ml` compiles it like user code — and the lifted modules double as differential-corpus material for the cross-backend oracle (step 3 below).

The pattern is already proven in-tree: `tesl/list.tesl` and `tesl/either.tesl` compile at build time into `list-derived.rkt` / `either-derived.rkt`, with the hand-written Racket core shrunk to small `*-prim.rkt` leaf modules. The pre-migration work is applying that same lift to the remaining pure-logic modules.

Good lift candidates (pure combinators over small primitive leaves):

- `tesl/dict.rkt` (~270 LOC) and `tesl/set.rkt` (~175) — same shape as list/either: keep the hash-backed leaves (`empty`/`insert`/`lookup`/`member`), lift `insertWith`, `union`, `merge`, and the fold-style ops.
- `tesl/int32.rkt` (~200) — the whole range rule ("closed ⇒ Int32, overflow-possible ⇒ Maybe Int32") is pure logic over Int leaves. Near-ideal lift.
- `tesl/money.rkt` (~470) — explicitly "Pure module: no capability"; exact-integer minor units and half-even rounding lift cleanly. Keep `dsl/private/money-core.rkt` (structs + display) and the generated currency table as leaves.
- `tesl/agent-provider.rkt` (~590) plus parts of `tesl/agent.rkt` (~850) — provider request/response normalization is pure JSON reshaping between provider dialects, and the agent loop's control flow lifts over http/tool-dispatch leaves. This is the single biggest prize: it sits squarely in the "ports by hand" bucket — no Go ecosystem library absorbs it.
- `tesl/jwt.rkt` (~750), partial — claims validation (exp/nbf/iss/aud) and header/payload construction lift; HMAC sign/verify stays a crypto leaf.
- `tesl/tuple.rkt`, `maybe.rkt`, `result.rkt`, and parts of `string.rkt`/`float.rkt`/`int.rkt` — small and mostly leaves already; marginal gain, do opportunistically.

Deliberately NOT lifted:

- `dsl/sso.rkt` and the OTel family (`dsl/otel.rkt`/`traces.rkt`/`metrics.rkt`/`trace-context.rkt`) — the plan above maps these to `go-oidc` / `otel-go`; lifting them to Tesl would preserve hand-rolled implementations exactly where the point is to delete them for battle-tested libraries.
- The proof/capability runtime (`check-runtime.rkt`, `capability.rkt`, `evidence.rkt`) — chicken-and-egg (it enforces Tesl's own guarantees), and the port plan wants it as a small hand-audited Go core anyway.
- `web.rkt`, `sql.rkt`, `queue.rkt`, `http-client.rkt`, the debugger — these ARE the primitives Tesl code sits on.

Rough payoff: of the ~13k non-test runtime LOC in the "ports by hand" half, roughly 2–3k lifts to Tesl. Suggested order: dict/set/int32 (mechanical, proves the pattern scales), then money, then agent-provider/agent (largest win; needs care around tool-dispatch and capability leaves).

Caveat: lifted code goes through the emitter, so Go's no-TCO recursion issue applies to it — but that is a general `emit_go.ml` obligation for user code anyway, so it adds no extra cost.

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

1. Lift the pure-logic stdlib modules into Tesl (see "Pre-migration" above) — this is useful on its own and can start immediately, before any Go decision is final.
2. Settle the Int decision.
3. `emit_go.ml` behind a flag; Racket stays the reference backend.
4. **Differential corpus testing**: run the entire `.tesl` corpus (`compile-examples.sh`, `tests/*.tesl`, plus the lifted stdlib `.tesl` modules) through both backends and diff observable behavior — the existing ratchet suite becomes a cross-backend oracle. This is the main defense against the long tail of parity bugs (float formatting, string/unicode, JSON edges).
5. Port runtime lib by lib, capability/proof runtime with its own focused security review.
6. Debugger and api-test instrumentation last.
7. Retire the Racket backend only when the corpus diff has been empty across the full suite for an extended period.

Scale estimate: person-year class — roughly half the Rust estimate with ~90% of the gains.

## Another benifit

We will get enterprise levels SAST tooling/support as well. Some DAST-tools are also "designed" for Go.

Other tools(that might or might not be suitable for us):
- The Race Detector (go test -race)
- Uber's goleak
- Uber's nilaway
- Google's ko (even though I would rather like a non-google distributed base image)
- Sigstore Cosign
- GitHub CodeQL
- Semgrep

## Loose thoughts on hardening

We should/could include widely adopted Go tools to ensure that our Go code follows best practices and are quite hardened. Below is some loose thoughts on different tools. I think we should include them all / as many as possible to create as close to air-tight runtime as possible.

Beyond govulncheck, the Go ecosystem offers a robust suite of tools that target different stages of the development lifecycle—from the code editor to compiler flags and web middleware. Because Go compiles into a single, static binary, its hardening ecosystem focuses heavily on static analysis and toolchain optimizations.
1. Static Application Security Testing (SAST)

While govulncheck focuses on vulnerabilities in dependencies, SAST tools look for security flaws in the code you write.

    gosec (Go Security Checker): The undisputed open-source standard for Go code auditing. It parses your code's Abstract Syntax Tree (AST) to look for structural flaws. It catches issues like SQL injection via string concatenation, weak TLS configurations, hardcoded credentials, and dangerous uses of the unsafe package.

    golangci-lint + staticcheck: Rather than running separate linters, most Go teams use golangci-lint to run everything concurrently. Inside it, you can enable gosec alongside staticcheck. While staticcheck is technically a correctness linter, it catches critical bugs like nil pointer dereferences, incorrect context usage, and goroutine leaks that frequently turn into runtime Denial of Service (DoS) exploits.

2. Native Toolchain Hardening (Built-in to Go)

Go's core engineering team has built powerful hardening features directly into the compiler and test tools. You don't even need to download third-party packages for these:

    Native Fuzzing (go test -fuzz): Go natively supports fuzz testing. Fuzzing injects millions of randomly mutated inputs into your parsing and data-handling logic to find edge cases that cause panics or hangs. It is highly recommended for any Go app that parses user-supplied JSON, text, or network packets.

    Security-Focused Compiler Flags: When running go build for production, you can pass specific flags to harden the resulting binary:

        -trimpath: Removes all absolute file-system paths, directory layouts, and developer usernames from the compiled binary. This minimizes the data available to someone attempting to reverse-engineer your code.

        -buildmode=pie: Compiles the binary as a Position-Independent Executable (PIE). This enables Address Space Layout Randomization (ASLR) at the operating system level, protecting the application from execution-flow hijacking.

3. Supply Chain Security & Compliance

Securing your open-source dependencies is crucial to preventing malicious code injection.

    cyclonedx-gomod / spdx-sbom-generator: These tools generate a Software Bill of Materials (SBOM) for your Go modules. An SBOM acts as a comprehensive "ingredient list" of your software, allowing security teams to immediately audit what packages you are deploying to production.

    OpenSSF Scorecard: An automated tool that evaluates your repository and its dependencies against crucial supply-chain security practices, checking if the packages use branch protection, pinning, or have active, vetted maintainers.

4. Runtime & Middleware Hardening (For Web APIs)

If you are building web applications or REST APIs, there are highly trusted, lightweight middleware libraries to manage standard defense-in-depth measures:

    secure (unrolled/secure): A popular HTTP middleware that automatically injects essential security headers into web responses. With a few lines of code, you can enforce HTTP Strict Transport Security (HSTS), Content Security Policies (CSP), and X-Frame-Options to stop clickjacking.

    gorilla/csrf: The gold-standard middleware for preventing Cross-Site Request Forgery (CSRF) in Go applications, using secure, authenticated cookies.