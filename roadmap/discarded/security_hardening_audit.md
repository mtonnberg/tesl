# Security — auditing & hardening the compiler and runtime

> **Status (2026-06-30, core_polish):** the bounded secure-by-default **runtime**
> slice of Phase 2 SHIPPED — path traversal, body/JSON limits, error info-leak,
> CSPRNG ids, email/HTTP-header CRLF, cache `LIKE`/TTL, SSE auth-raise bug — see
> `completed/security_hardening_runtime_fixes.md` (+ `tests/security-test.rkt`).
> This document is retained as the **detailed audit reference** (findings tables
> with `file:line`, threat model, layer model). The remaining
> unbounded/architectural work (TCB gates, default-deny, SSRF allowlist, TLS
> verification, SSE per-key authz, lints-as-policy, SBOM, L1–L7) is tracked as a
> prioritized backlog in `security_hardening_program.md`.

## Context

Tesl's promise to its users is **security by design**: write an app, get strong guarantees
(typed boundaries, proof-carrying values, capabilities, parameterized SQL) without thinking
about them. But that promise rests entirely on two things being true:

1. **The trusted computing base (TCB) is sound** — the OCaml compiler (especially the proof
   checker and the Racket emitter) and the Racket runtime (`dsl/`) must not have holes that
   let an "accepted" program violate the very invariants it claims.
2. **The generated app is secure by default** — the runtime that user code compiles to must
   be safe out of the box, with no footguns the developer has to remember to disable.

This item is the audit + hardening program for both, plus the **structural, automated
security testing** that keeps them true over time. The goal is unchanged from the seed:
*people should get great security without any effort* — which means the effort moves into
the TCB and its test harness, where we can pay it once.

### The key realization

"Secure by design" is a statement about the **TCB and the defaults**, not about user code.
Two facts make this sharp:

- **Proofs are erased by default.** `TESL_ZERO_COST_PROOFS` defaults to on
  (`dsl/private/check-runtime.rkt:~915`), so runtime re-checks
  (`validate-runtime-argument`, `dsl/private/check-runtime.rkt:~763`) are *not* emitted. The
  **static proof checker is then the sole guarantor** of every proof obligation. A gap in
  `compiler/lib/proof_checker.ml` or a mistake in the trusted emitter
  (`compiler/lib/emit_racket.ml`) silently produces an unsound-but-accepted program.
- **The defaults are the security.** A developer who forgets to add `Auth`, set a body
  limit, or pin CORS gets whatever the runtime does by default. So every default in
  `dsl/web.rkt` is a security decision.

Therefore the work is: (a) make the TCB demonstrably sound and keep it that way with
standing tests; (b) make the runtime defaults safe; and (c) build the automated harness that
proves both continuously.

## Current posture — verified by read-only audit

> Findings below carry `file:line` pointers from a read-only audit. The **strengths** are
> confirmed in source. Rows tagged **[code-reviewed]** were verified by reading the actual
> implementation (2026-06-25); the rest remain *candidates to validate*. No exploit was run,
> but where a row says "assessed exploitable" the data-flow was traced end to end by
> inspection.

### Strengths (already secure-by-design)

| Area | Evidence | Why it's good |
|---|---|---|
| SQL injection **[code-reviewed]** | `dsl/sql.rkt` — values via `$1,$2…` placeholders; identifiers validated `^[A-Za-z_][A-Za-z0-9_]*$` then double-quoted (`:139-151`); regression tests `SQL-INJ-001..010` | Injection is structurally impossible, and guarded by adversarial tests (`roadmap/completed/sql_injection_protection.md`) |
| JWT **[code-reviewed]** | `tesl/jwt.rkt` — `alg` pinned to HS256 in a constant header, not read from token; constant-time signature compare (length guard + XOR/OR fold, `~:85-89`); verification mandatory (`~:90`); expiry checked (`~:101`) | No `alg:none` / algorithm-confusion; no timing oracle |
| Randomness (UUID) | `tesl/uuid.rkt` — v4/v7 from `crypto-random-bytes` (CSPRNG) (`~87-122`) | Unguessable IDs where it uses UUIDs |
| Request logging | `tesl/logging.rkt` — logs only `method path status ms`; no body/headers/tokens; off unless `TESL_VERBOSE=1` | Secrets not logged by default |
| Compiler supply chain | `compiler/dune-project` / `compiler/lib/dune` — only `str`, `unix` (OCaml stdlib); `flake.nix` + `flake.lock` pin nixpkgs/Racket | Tiny, hermetic, pinned TCB |
| Proof-logic testing | `roadmap/completed/built-in-mutation-testing.md` — `tesl --mutate` kills operator mutants in check/auth/establish | Proofs are tested to actually constrain |

### Gaps & risks (audit candidates, by severity)

| # | Finding | Pointer | Severity | Class |
|---|---|---|---|---|
| 5 | **[code-reviewed] Static-file path traversal — assessed exploitable.** `try-serve-static` joins request URL segments with `build-path` and serves any `file-exists?` match; nothing strips `..` and there is no containment check. `GET /%2e%2e/%2e%2e/etc/passwd` yields segments `("..","..",…)` → `static-dir/../../etc/passwd`, which `file->bytes` resolves — **unauthenticated arbitrary file read** (also follows symlinks). Runs *before* auth/dispatch. Only triggers when `serve` is given `#:static-dir`. | `dsl/web.rkt:2030-2044` (pre-auth at `:2061`) | **High** | Path traversal |
| 4 | **[code-reviewed] Internal exception text leaked to clients.** Every handler exception returns `(exn-message exn)` in the 500 `details`, **unconditionally** (not gated by `TESL_VERBOSE`); the typed-decoder path likewise returns `(exn-message exn)` on a 400. Leaks DB/schema/SQL fragments, file paths, internal identifiers. (Note: the *JSON parse* path is already sanitized — generic "Malformed JSON payload".) | `dsl/web.rkt:1880-1882` (500), `:1348` (decoder 400) | Med | Info-leak |
| 1 | **[code-reviewed] No request body size limit; unbounded `bytes->jsexpr`.** `request-post-data/raw` read whole; full body parsed with no length cap. | `dsl/web.rkt:1245,1291` | High | DoS |
| 2 | No JSON nesting-depth limit in the recursive decoder (`bytes->jsexpr` + `jsexpr->typed-value` both recurse unbounded). | `dsl/types.rkt:~1071` | Med | DoS |
| 3 | Auth is opt-in, not default-deny — an endpoint without `Auth` is public. | `dsl/web.rkt:~922,~1909` | High | AuthZ |
| 6 | **[code-reviewed] `generatePrefixedId` uses non-crypto `random` (≤1e6) + guessable `current-seconds`** — predictable/brute-forceable if used as a token. Contrast `tesl/uuid.rkt`, which correctly uses `crypto-random-bytes`. | `tesl/private/runtime.rkt:91-92` | Med | Predictable ID |
| 7 | SQL params (possibly secrets) logged under `TESL_VERBOSE=1`. | `tesl/logging.rkt:~52-60` | Med | Secret-leak |
| 8 | **[code-reviewed]** Only `nosniff`/`no-store` set on responses; no HSTS/CSP/X-Frame-Options; no configurable CORS (wildcard on SSE only). JSON content-type + required `application/json` body blunts classic form-CSRF. | `dsl/web.rkt:1277-1278` (`,~1985` SSE) | Med | Headers/CORS |
| 9 | Capabilities live in a dynamic parameter (`current-capabilities`). **[code-reviewed]** It *is* set per-request via `parameterize` around the synchronous handler (`dsl/web.rkt:1862`), so the normal path is thread-isolated — **no hijack found**. Residual risk: capabilities won't auto-propagate into threads/continuations a handler spawns. | `dsl/capability.rkt:~15,~49-67`; `dsl/web.rkt:1862` | Low-Med | Context-binding |
| 10 | Secrets (DB/SMTP/JWT) not redacted from error text. | `dsl/sql.rkt:~1683`, `tesl/email.rkt` | Med | Secret-leak |
| 11 | No password-hashing primitive (apps roll their own). | (absent) | Med | Missing primitive |
| 12 | Proof erasure default-on; no completeness proof for the static checker; differential parity exists as a one-time audit, not a standing gate. | `dsl/private/check-runtime.rkt:~915`; `roadmap/completed/actually-zero-cost-runtime-proofs.md` | High (TCB) | Soundness |
| 13 | Emitter is trusted; golden `.rkt` exist for lessons but not for security constructs; no emitter-mutation test. | `compiler/lib/emit_racket.ml` | Med-High (TCB) | Soundness |
| 14 | No SBOM; dependency-advisory scanning not automated (deps are minimal/pinned). | `flake.lock` | Low | Supply chain |

> Rows are ordered by triage priority (5 → 4 → 1 → …), not by number. A `[code-reviewed]`
> tag means the implementation was read directly on 2026-06-25.

### Data-layer & messaging findings — Postgres usage + email queue [code-reviewed 2026-06-25]

A focused review of how the runtime uses PostgreSQL (storage, cache, queues/pub-sub, email
outbox) and the SMTP path. **Headline: SQL injection is well-closed** — across all four
subsystems user/request values are bound as `$1,$2…` parameters, the schema is always
explicitly qualified, and entity identifiers are regex-validated. No request data is
concatenated into SQL. The residual issues are at the edges:

| # | Subsystem | Finding | Pointer | Severity |
|---|---|---|---|---|
| D1 | Email (SMTP) | **CRLF header injection.** RFC2822 header built by raw concat of `to`/`subject`; a `\r\n` in either (user-influenced recipient/subject) injects arbitrary headers — `Bcc:` exfiltration / spam-relay, spoofing, body injection. No CRLF strip/validation. | `tesl/email.rkt:194-201` | **Med-High** |
| D2 | Email (SMTP) | **TLS without cert/hostname verification.** `ports->ssl-ports … #:encrypt 'tls` uses a default client context that doesn't verify the peer → MITM can steal SMTP creds. | `tesl/email.rkt:212-216` | Med |
| D3 | Cache | **`LIKE` wildcard over-invalidation.** Invalidate prefix is bound (`$1 || '%'`) but `%`/`_` are not escaped, so a prefix containing `%` matches far more keys than intended (`%` ⇒ whole namespace). Not injection — cache integrity/DoS. | `tesl/cache.rkt:169-172` | Low-Med |
| D4 | Cache | **TTL interpolated, not bound.** `interval '~a seconds'` injects `ttl` directly; safe *only* because the type checker guarantees `Int` (and erasure makes the checker the sole guarantor). Queues/email bind the analogous interval (`queue.rkt:645-652`, `email.rkt:300-306`) — cache is the inconsistent one. | `tesl/cache.rkt:153-158` | Low-Med (latent) |
| D5 | Storage / all | **No TLS on the Postgres connection.** `postgresql-connect` (and the dedicated LISTEN conns) pass no `#:ssl`, so Racket defaults to none → cleartext password + data on a remote DB (fine for localhost/socket). | `dsl/sql.rkt:1691`; `tesl/queue.rkt:169` | Med (remote DB) |
| D6 | All | **Unvalidated identifier interpolation.** `pg-table` and `LISTEN "tesl_queue_<name>"` interpolate schema/table/channel identifiers, bypassing the entity-identifier regex. Server/config-derived today (not request-reachable), so defense-in-depth. | `tesl/cache.rkt:76`, `queue.rkt:161,806,1013`, `email.rkt:93` | Low |
| D7 | Queues | **`__type` deserialization trust.** Dequeue instantiates whatever record type the stored `__type` names; storage is server-only and serialize overwrites `__type`, so contrived type-confusion only. | `tesl/queue.rkt:194-202` | Low |

**Fixes:** D1 — strip/reject CR/LF in all header-bound fields + validate addresses + MIME-encode headers; D2 — SSL context with peer+hostname verification; D3 — escape `%`/`_` (`LIKE … ESCAPE`) or `left(key, length($1)) = $1`; D4 — bind as `$N * interval '1 second'`; D5 — `#:ssl 'yes` with verification (or document socket-only); D6 — route these identifiers through `identifier-value->string`; D7 — keep `__type` reserved (already overwritten on serialize).

### Server-Sent Events (SSE) findings [code-reviewed 2026-06-25]

SSE streams server→client over plain HTTP on the API port (`tesl/sse.rkt`,
`dsl/web.rkt:1937-1986`). The data plane is safe — event payloads are JSON-encoded before
`data: …\n\n`, so attacker-controlled content can't forge extra SSE frames. The problems are
in **authorization** and **CORS/DoS**:

| # | Finding | Pointer | Severity |
|---|---|---|---|
| S1 | **No per-key authorization (IDOR/BOLA).** The auther proves *identity*; the channel **key is then taken from the URL path** and used to subscribe with no check that this user may access *that* key. Any authenticated user subscribes to any key (`/events/rooms/<otherRoomId>`) and receives its events. Insecure by default for per-room/per-user streams; the framework gives no key→authz hook. | `dsl/web.rkt:1955-1966` | **High** |
| S2 | **Auth-failure path bug — confirmed.** `(raise (auth-result))` *calls* the `check-fail` value as a procedure, but `check-fail` has no `prop:procedure` (`dsl/private/evidence.rkt:35`) → raises `application: not a procedure`, which the `check-fail?` guard in `serve` (`:2054`) does **not** catch → escapes as a default 500 (stack-trace leak) instead of a clean 401. Fail-closed for access, but wrong status + info-leak. | `dsl/web.rkt:1966` | Med |
| S3 | **Hardcoded wildcard CORS** (`Access-Control-Allow-Origin: *`) on streams — the only CORS in the codebase, no allowlist, no `Allow-Credentials`. URL-keyed/unauthenticated streams become readable by any origin (cookie-credentialed cross-origin reads are still browser-blocked under `*`). | `dsl/web.rkt:1985` | Med |
| S4 | **No connection/thread/listener cap → DoS.** Each stream holds a thread + listener for minutes with no per-IP/global limit; every `publish-event!` iterates all listeners and each `on-event` waits up to `sync/timeout 1` — slow/dead connections amplify publish latency for everyone. | `dsl/web.rkt:1955-1986`, `tesl/sse.rkt:38-87` | Med |
| S5 | **SSE auth is opt-in** — a route with no `auth-fn` streams to anyone (same default-deny gap as #3 in the web table). | `dsl/web.rkt:1963` | Low |

**Fixes:** S1 — pass the resolved channel key into the authorizer and require an explicit,
proof-carrying allow decision for *that* key (same discipline as handler auth); S2 —
`(raise auth-result)` (drop the parens) or build the 401 directly; S3 — configurable Origin
allowlist + correct `Allow-Credentials` instead of `*`; S4 — cap concurrent streams (per-IP +
global) and bound/parallelize fan-out; S5 — covered by the default-deny work (#3).

### Outbound HTTP client (`HttpClient`) — SSRF & transport [code-reviewed 2026-06-25]

`HttpClient.get/post/put/delete` (`tesl/http-client.rkt`, spec §21.3) take a URL + headers
and call `net/http-client`'s `http-sendrecv`. The teaching handler is literally
`fetchJson(url: String)` — the URL is caller-supplied — and the `httpClient` capability gates
*that* you may call out, not *where*. Confirmed sub-findings:

| # | Finding | Pointer | Severity |
|---|---|---|---|
| H1 | **SSRF — no host/IP/scheme allowlist.** A request-derived URL reaches `http://169.254.169.254/…` (cloud metadata), `localhost`, decimal-IP (`http://2130706433`), or private ranges. No deny-list, no scheme pinning. | `tesl/http-client.rkt:42-81,104-125` | **High** |
| H2 | **TLS not verified.** `http-sendrecv #:ssl? use-ssl?` uses Racket's default client context, which does not verify the server cert/hostname → MITM of outbound HTTPS (mirrors SMTP D2). *(Confirm against the Racket version.)* | `tesl/http-client.rkt:113-125` | Med-High |
| H3 | **Outbound header CRLF injection.** `header-bytes` = `name ": " val` from the caller's header list; a `\r\n` in a value splits the request (mirrors email D1). | `tesl/http-client.rkt:108-112` | Med |
| H4 | **No request timeout.** A hung/slow upstream (or an SSRF target) ties up the handler thread indefinitely → DoS. | `tesl/http-client.rkt:120-125` | Med |
| H5 | **Unbounded response read.** `port->bytes` reads the entire upstream body with no cap → memory exhaustion from a large/hostile response. | `tesl/http-client.rkt:135` | Med |

**Fixes:** H1 — URL allowlist + deny RFC1918/loopback/link-local/metadata IPs (resolve then
check), pin scheme to `http(s)`; H2 — verified TLS context (peer + hostname); H3 — reject CR/LF
in header names/values; H4 — connect/read timeouts; H5 — cap response size. (`http-sendrecv`
does **not** auto-follow redirects, so redirect-pivot SSRF isn't automatic — a small plus.)

### Language-surface & trust-model areas to audit [reviewed 2026-06-25]

Surfaced by reading `LANGUAGE-SPEC.md` + `example/learn/*.tesl`. These are mostly *design
gaps / areas to audit* rather than single line-level bugs, but they shape the "secure by
design" guarantee:

| # | Area | What / threat | Pointer | Kind |
|---|---|---|---|---|
| L1 | **`establish` trust escape hatch** | App authors can assert a `fact` **unconditionally, with no proof** (`establish f(n) -> Fact (P n) = P n`); with proofs erased by default a wrong assertion is unguarded. §7.12 (no `:::` fabrication outside trusted kinds) and P001 proof-ownership bound it well, but inside the owning module `establish` is unrestricted. | spec §10, §7.12; `lesson06`,`lesson51`; emitter `define-trusted` | Design gap — needs lint/audit-boundary + mutation coverage |
| L2 | **`auth` is a crypto-free trust root; insecure session pattern** | `auth` mints authz proofs purely from request data; the proof is unforgeable *downstream*, but the auth fn is the unverified root. Examples model a plaintext, unsigned, guessable session cookie (`cookies "user" == "admin"`, `cookie {"session":"alice"}`). No built-in signed-session / secure-cookie primitive. | spec §10; `lesson06`,`lesson55` | Missing primitive + guidance |
| L3 | **No contextual output escaping** | `++` / `${…}` never escape. SQL (parameterized) and JSON responses (encoded) are safe, but strings flowing to other sinks — outbound URL/headers (H1/H3), email headers (D1), HTML/static bodies, logs, file paths — have none, and a `ValidX` proof validates *shape*, not sink-safety (false sense of security). | spec string-interp; `lesson25` | Design gap — escaping helpers / taint-lint |
| L4 | **Telemetry — ungated data-egress sink** | The one effect exempt from capabilities: ambient, always-on, emits arbitrary key/values to the OTel exporter (leaves the process). No redaction of PII/secrets, no capability friction. | spec §5.3; `lesson17`; `dsl/otel.rkt` | Needs audit (exporter dest/transport) + redaction |
| L5 | **Codec / deserialization of untrusted input** | User-defined codec blocks + `register-type-codec!` + ADT `__type` run on attacker JSON at the HTTP boundary; combines with the missing JSON depth limit (#2) and `__type` trust (D7). | spec §11.12; `dsl/types.rkt` | Needs audit (type-confusion / decoder cost / historical-format fallbacks) |
| L6 | **Resource exhaustion via unbounded computation** | Arbitrary-precision ints remove classic overflow (good), but `Int.pow 2 n` / large list-string ops with `n` from input → memory/CPU DoS; raw float `/0` → `inf` unless proof-guarded. | `lesson25`,`lesson34` | Hardening — bound user-influenced sizes |
| L7 | **Auto-migration DDL at startup** | `ensure-database-ready!` generates + executes DDL from entity/field names (regex-validated, source-derived). Check the destructive-migration path. | `dsl/sql.rkt` | Low — needs audit |

**Surface notes (narrowing factors):** there is **no user-facing FFI / `eval` / `comptime` /
`foreign`** (`foreign fn` is only a roadmap proposal), so app code can't reach arbitrary host
code; and **proof ownership (P001) + detach/attach subject-identity are compiler-enforced** —
forging a proof for another value, or minting another module's predicate, is rejected. Both
should get a confirmatory test pass but are currently strengths, not gaps.

## Threat model & TCB

**Trusted (a bug here breaks the guarantee):** `compiler/lib/proof_checker.ml` (proof
soundness), `compiler/lib/checker.ml` (types), `compiler/lib/emit_racket.ml` (codegen),
`dsl/private/trusted.rkt` (the one intentional unchecked assertion, reachable only from
`establish`), `dsl/private/check-runtime.rkt` (proof machinery), the Racket runtime, and the
nix build.

**Untrusted:** all HTTP request input, DB contents, env-provided config values, and user
Tesl source (which the compiler must accept-or-reject correctly).

| TCB component | Assumption | Failure mode | Today's mitigation |
|---|---|---|---|
| `proof_checker.ml` | Proof validation is sound & complete-enough | Unsound program compiles & runs (erased → no net) | Mutation tests (partial); integration tests; **no formal analysis** |
| `emit_racket.ml` | Emits faithful Racket for typed AST | Proofs/types corrupted silently | Golden `.rkt` (lessons); differential parity (one-time) |
| erasure gate | Static checker ⇒ runtime safe | Any checker gap is unguarded | Opt-in net via `TESL_ZERO_COST_PROOFS=0` |
| runtime defaults | Safe out of the box | Footgun becomes the default | partial (see gaps 1–11) |
| build | Pinned & hermetic | Compromised dep | `flake.lock`; zero-dep compiler |

## Working structurally with automated hardening / security tests

This is the heart of the item: security that survives contact with a moving codebase has to
be **continuous and structural**, not a one-off pen-test. The doctrine mirrors the project's
existing "compiling is not testing" stance and the `SQL-INJ-001..010` precedent: **every
hardening fix lands with the automated test that fails if the fix regresses.** Below is a
layered model that plugs into the harnesses Tesl already has (`compiler/ci.sh`,
`compile-examples.sh`, mutation testing, the differential parity net, the golden `.rkt`
corpus, the `.tesl` example corpus).

### The layers

1. **Adversarial regression corpus (per vulnerability class).** Generalize `SQL-INJ-*` into
   a maintained `tests/security/` suite with one *attack + expected-safe-behaviour* case per
   class: injection, path traversal, oversized body, deep JSON, auth bypass, JWT
   `alg:none`/tampering, info-leak in errors, predictable IDs, secret-in-log. **Rule:** a new
   finding is not "fixed" until a corpus entry reproduces it and then passes. This is the
   anti-regression backbone and runs in CI.

2. **Property-based / fuzz testing of the untrusted boundary.** Tesl's *typed* request
   boundary makes generators tractable. Fuzz `jsexpr->typed-value` and the parser with
   malformed / huge / deeply-nested inputs and assert *invariants*, not outputs: the server
   never crashes, time/memory stay bounded, internals never appear in responses. Fuzz the SQL
   builder with hostile values and assert the emitted SQL is always parameterized (the value
   never reaches the SQL string). Property tests catch the class; the corpus pins the
   instance.

3. **Differential parity as a standing soundness gate.** Promote the
   `TESL_ZERO_COST_PROOFS=0` vs `=1` comparison from the one-time erasure audit to a
   **continuous CI gate** over the whole corpus: erased and net-on builds must be
   behaviour-identical. This is the structural guard that erasure never silently drops a
   check — the single most important TCB test given gap #12.

4. **Proof-checker assurance.** Pair the differential gate with (a) the existing mutation
   testing (a surviving mutant in a check/auth/establish ⇒ the proof didn't constrain ⇒ CI
   fails) and (b) a growing **adversarial proof corpus** of programs that *should be rejected*
   (almost-valid proofs, subject mix-ups, conjunction reorderings) asserting the checker says
   no. Longer term: formal analysis of the checker's core. This is how we earn the right to
   erase.

5. **Emitter trust via golden + mutation.** Extend the golden `.rkt` byte-comparison
   (`compiler/ci.sh`) to cover security-relevant constructs (auth, establish/trusted-proof,
   capability-gated calls), and add **emitter mutation testing**: mutate `emit_racket.ml` and
   require some test to fail — proving the net actually covers the trusted code generator
   (closes gap #13).

6. **Lints as executable security policy.** The strongest "zero-effort" mechanism: turn
   secure-by-default expectations into **compile-time lints** (building on
   `roadmap/completed/opinionated-linter-built-in.md`). Candidate rules: unauthenticated
   endpoint without an explicit `#[public]`-style opt-in; raw error/`exn-message` returned to
   a client; secret-typed value flowing into a log; missing body-size limit on a body-taking
   endpoint; non-CSPRNG ID used as a token. A lint *prevents* the vuln class at author time —
   which is exactly "great security without effort."

7. **Supply-chain CI.** Generate an SBOM, assert `flake.lock` is the pinned source of truth,
   verify reproducible builds, and scan the (small) dependency set for advisories. Cheap
   given the zero-dep compiler + pinned nix.

8. **Coverage matrix + completeness critic.** Maintain a table mapping *vuln class → layer
   that tests it → location → CI gate*, so untested classes are visible. Periodically run a
   "what has no automated test?" review (the completeness critic) and convert each gap into a
   corpus/property/lint entry. Silence is not coverage.

### How a vulnerability class maps to layers

| Vuln class | Primary layer | Backed by |
|---|---|---|
| SQL injection | corpus (`SQL-INJ-*`) | property (always-parameterized) |
| Email/SMTP header injection (D1) | corpus (CRLF in to/subject) | property (no `\r\n` reaches a header) |
| `LIKE` wildcard over-invalidation (D3) | corpus (`%`/`_` in prefix) | property (prefix matched literally) |
| Auth bypass / missing auth | lint (default-deny opt-in) | corpus + differential |
| SSE per-key authz / IDOR (S1) | corpus (cross-key subscribe denied) | property (no stream without key-authz) |
| SSRF — outbound URL (H1) | corpus (metadata/loopback/private denied) | property (resolved IP not in deny-set) |
| Output-context injection (L3) | corpus per sink (URL/header/HTML/log) | property (no `\r\n`/metachar reaches a sink) |
| Telemetry egress / PII (L4) | corpus (no flagged field exported) | redaction lint |
| `establish` misuse (L1) | audit boundary + mutation over establish bodies | lint (inventory each `establish`) |
| DoS (body/JSON/parse) | property/fuzz | corpus (limits enforced) |
| Info-leak in errors | lint (no raw error to client) | corpus |
| Proof unsoundness | differential parity gate | mutation + adversarial proof corpus |
| Emitter miscompile | golden `.rkt` | emitter mutation |
| Weak/predictable IDs & secrets | corpus | lint (CSPRNG/secret-flow) |
| TLS not verified (DB D5 / SMTP D2) | config/integration test | startup assertion |
| Supply chain | SBOM/advisory CI | reproducible-build check |

## Plan (phased)

- **Phase 0 — Stand up the harness first.** Create `tests/security/`, wire the differential
  parity gate and a fuzz target into CI, seed the coverage matrix. You harden *against tests*;
  build them before fixing.
- **Phase 1 — TCB soundness gates.** Differential parity as a standing gate; emitter golden +
  mutation for security constructs; adversarial proof corpus. Decide the erasure policy: keep
  default-on but *gated by a green differential corpus*, or expose a first-class
  "safety-net build" mode.
- **Phase 2 — Secure-by-default runtime.** Fix gaps 1–11, the data-layer/messaging
  findings D1–D7, and the SSE findings S1–S5, **each with a Phase-0 corpus test**: body/JSON limits; generic client
  errors + internal-only detail logging; default security headers + explicit (non-wildcard)
  CORS; cookie helpers (Secure/HttpOnly/SameSite); static path normalization; CSPRNG for all
  ID generation; secret redaction; a password-hashing primitive (Argon2id/bcrypt);
  **email header-field CRLF rejection + address validation (D1)**; **verified TLS for SMTP
  (D2) and Postgres (D5)**; **`LIKE`-escape / literal prefix match for cache invalidation
  (D3)**; **bind the cache TTL interval (D4)**; **SSE per-key authorization (S1)** + auth-failure raise fix (S2) + configurable SSE CORS (S3) + SSE connection caps (S4); **HttpClient SSRF allowlist + verified TLS + CRLF-safe headers + timeouts + response cap (H1–H5)**; **output-escaping helpers for non-SQL sinks (L3)**; **a signed-session / secure-cookie primitive (L2)**; **telemetry redaction (L4)**.
- **Phase 3 — Lints as policy.** Ship the security lint rules (layer 6) so the defaults are
  enforced at author time — including an **`establish` inventory/audit lint (L1)**, an
  **output-sink escaping lint (L3)**, and a **telemetry-redaction lint (L4)**.
- **Phase 4 — Supply chain.** SBOM + advisory scan + reproducible-build verification.
- **Ongoing.** Grow the fuzz/corpus; run the completeness critic each cycle; every new
  finding → a regression test before the fix.

## Weighted pros and cons

**Pros**
- **Protects the core value proposition.** "Secure by design" is only credible if the TCB is
  tested to be sound; this makes it so and keeps it so.
- **Zero user effort.** Safe defaults + compile-time lints push security into the language,
  not the developer's checklist.
- **Regression-proof.** Structural tests mean a fixed class stays fixed.

**Cons / risks**
- **Security scope is unbounded** — needs explicit prioritization (severity table) and a
  "done for now" line, or it sprawls.
- **TCB fixes touch trusted code** (emitter/runtime); they must ride the differential +
  golden + mutation gates to avoid introducing the very unsoundness we're guarding against.
- **Erasure policy is sensitive** — re-enabling a net trades performance for safety; resolve
  with data (the differential gate + benchmarks), not by reflex.
- **Over-eager lints annoy** — security lints need the same false-positive discipline the
  existing linter already applies.

## Critical files

- Runtime web surface: `dsl/web.rkt` (request decode/limits, error→response, headers/CORS,
  static serving, auth enforcement).
- Data & crypto: `dsl/sql.rkt` (connection/TLS at `:1691`), `tesl/jwt.rkt`, `tesl/uuid.rkt`,
  `tesl/random.rkt`, `tesl/private/runtime.rkt` (ID generation), `tesl/logging.rkt`.
- Messaging / data-layer (findings D1–D7): `tesl/email.rkt` (SMTP header build `:194-201`,
  TLS `:212-216`, outbox SQL), `tesl/cache.rkt` (`LIKE` `:169-172`, TTL `:153-158`),
  `tesl/queue.rkt` (jobs/pub-sub SQL, LISTEN channel interpolation).
- SSE (findings S1–S5): `tesl/sse.rkt` (stream loop, fan-out), `dsl/web.rkt:1937-1986`
  (SSE routing, auth, key extraction, wildcard CORS).
- Outbound HTTP (H1–H5): `tesl/http-client.rkt` (`parse-url-parts:42`, `do-http-request:104`,
  TLS `:120`, response read `:135`).
- Language-surface / trust model (L1–L7): `dsl/otel.rkt` (telemetry egress, L4),
  `dsl/types.rkt` (codecs/deserialization, L5), `dsl/sql.rkt` (`ensure-database-ready!`
  auto-migration, L7), and the compiler `establish`/`auth` lowering (`define-trusted`,
  `define-auther`) for L1/L2; `LANGUAGE-SPEC.md` §5.3/§7.12/§10/§11.12 for the surface
  contracts; `example/learn/lesson{06,17,25,55,58}.tesl` as the demonstrating examples.
- AuthZ: `dsl/capability.rkt`.
- TCB: `compiler/lib/proof_checker.ml`, `compiler/lib/checker.ml`,
  `compiler/lib/emit_racket.ml`, `dsl/private/{trusted,check-runtime,evidence}.rkt`.
- Test harness: `compiler/ci.sh`, `compile-examples.sh`, `tests/` (new `tests/security/`),
  the golden `.rkt` corpus, mutation testing.
- Build: `flake.nix`, `flake.lock`, `compiler/dune-project`.
- Related: `roadmap/completed/sql_injection_protection.md`,
  `roadmap/completed/built-in-mutation-testing.md`,
  `roadmap/completed/actually-zero-cost-runtime-proofs.md`,
  `roadmap/completed/opinionated-linter-built-in.md`,
  `roadmap/discarded/rate-limiting.md`.

## Verification

The automated security harness above *is* the verification, run under `compiler/ci.sh` /
`compile-examples.sh`:

1. **Corpus green** — every `tests/security/*` attack case behaves safely.
2. **Differential parity** — `TESL_ZERO_COST_PROOFS=0` vs `=1` behaviour-identical across the
   corpus (the standing soundness gate).
3. **Proof integrity** — mutation testing kills all check/auth/establish mutants; the
   adversarial proof corpus is rejected as expected.
4. **Emitter trust** — golden `.rkt` byte-identical for security constructs; emitter mutants
   are caught.
5. **Fuzz invariants hold** — no crash, bounded resources, no internal leakage on hostile
   input.
6. **Supply chain** — SBOM emitted, `flake.lock` authoritative, build reproducible.

## Out of scope

- The correctness of an app's *own* authorization logic — we provide safe defaults, primitives
  (hashing, CSPRNG), and lints, but the developer's policy is theirs.
- Language-level rate limiting — previously declined (`roadmap/discarded/rate-limiting.md`)
  because per-instance counters don't survive horizontal scaling; address via deployment
  guidance instead.
- Full formal verification of the entire compiler — aspirational; this item pursues
  *confidence* (tests, differential gates, targeted formal analysis of the proof checker), not
  a total proof.
