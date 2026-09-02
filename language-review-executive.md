# Tesl Go-runtime migration: executive summary

**Reviewed:** commit `286e2ed` "Go migration (#82)", 2026-09-02. Racket runtime and emitter replaced by a Go runtime and a Go emitter (~16.5k runtime lines, ~16k emitter lines, 996 files changed).
**Question asked:** is the generated code safe, correct, performant and secure, and can a Tesl author be certain their app is secure?
**How:** compiler rebuilt from the commit; six parallel deep-dives (HTTP, auth/crypto/SSO/outbound, database, runtime core and debugger, LLM agent surface, migration parity and CI) plus a direct emitter review; ~60 new Go probe tests and ~25 Tesl probe programs; every High and the key Medium findings re-run independently. Full report: `language-review.md`.

## Status after remediation (same day)

Every High and the listed Medium/Low findings were fixed with regression tests the same day; see `language-review.md` §9 and `CHANGELOG.md`. Deferred: Postgres-backed queue/cache/outbox (now flagged by lint W097 instead of silent), auth rate limiting, a standing Memory/Postgres differential suite, vet/lint of the emitted corpus in CI. The verdict below is the pre-remediation one.

## Whitebox attack campaign (same day, after remediation)

Six source-level attackers wrote Tesl programs plus the attacks that exploit them. Eight confirmed issues, all closed with tests (`language-review.md` §10): four High — `via` boundary checks compared proof predicates by name only (a "guest" check satisfied an "admin" declaration: authorization bypass), `== Nothing` on a `Maybe` column matched on the Memory store and never on Postgres (a revocation filter that passed tests and did nothing in production), two module names folding to one Go package let a dependency silently replace another module's code, and the decimal-digit cap missed path captures and `String.toInt` (unauthenticated CPU DoS); plus a binder-shadowing drift, a contention miss in the new `updateAndReturnOne`, an agent budget overshoot, and two codegen name collisions. The proof kernel, SQL parameterisation, session/CSRF/Host guards, secret redaction, SSRF and the agent tool boundary held.

## Bottom line (pre-remediation)

**Not yet.** The migration is strong exactly where migrations usually fail (crypto, SQL parameterisation, request hardening, supply chain) and weak in the seams: two SQL emission bugs that return silently wrong rows, a server timeout that kills every live-event stream after a minute, durability features that the spec promises and the runtime quietly does not provide, two ways to crash or pin the process from ordinary input, and a test/CI process that cannot see any of it. None of the nine High findings is a design flaw; all are bounded fixes with exact locations. Until they are closed the runtime should not be described as production-secure.

**No Critical findings.** No SQL injection, no proof-system bypass, no authentication bypass, no remote code execution. The compile-time proof and capability system held against every forgery attempt made.

## What is solid (verified, not assumed)

- SQL text is compile-time; every runtime operand is a bound parameter; identifiers are quote-escaped.
- Argon2id with sane parameters, constant-time compares, timing equaliser; JWT header never parsed (no `alg` confusion); JWS refuses every dangerous header; OIDC claims validated correctly; `__Host-`/HttpOnly/Secure/SameSite=Lax cookies written only on 2xx; `crypto/rand` throughout; secrets redacted in every ordinary print path.
- SSRF guard applied in the dialer on the resolved address and on every redirect hop; TLS verified; outbound response and request bodies capped.
- Handler panics become sanitized 500s; security header floor present; Host validation resists every spoof tried; path traversal blocked.
- Arbitrary-precision `Int` with a checked fast path; division requires a compile-time non-zero proof.
- Emitted modules vendor the runtime and pin and checksum their two external dependencies; runtime CI runs race detection, vet, static analysis and fuzzing with no waivers.
- The debugger is compiled only into `--debug` builds.

## High findings (fix before calling it secure)

| # | Finding | Effect | Where |
|---|---------|--------|-------|
| H1 | `inList`/`notInList` with a non-literal list compiles to a constant `where true`/`where false` | An exclusion filter (`notInList t.id blocked`) returns the blocked rows; tests agree with production so nothing catches it | `sql_query.ml:136-149` |
| H2 | `updateAndReturnOne` updates one row on the Memory backend, all matching rows on Postgres | Production mutates extra rows; dev/test store hides it | `table.go:375`, `emit_go.ml:9301` |
| H3 | Every SSE stream is cut by the server at exactly 60 s (WriteTimeout never cleared for streams) | All live-event clients reconnect every minute; events in the gap are lost; test harness has no timeouts so the corpus is blind | `serve.go:63-66`, `sse_http.go` |
| H4 | `queue`/`cache`/`email` declared on a Postgres database are emitted as in-process memory, no diagnostic | Jobs and mail lost on restart; replicas disjoint; `retry: backoff` is a no-op; spec promises otherwise | `emit_go.ml:10490-10532` |
| H5 | Email worker writes by stale slice index after releasing its lock; no SMTP deadline | Process crash from a prune/reset race; a stalled SMTP server halts all mail forever | `email.go:162-227` |
| H6 | `Int.pow` unbounded, no proof required | Client-controlled exponent pins a core for tens of seconds (3^2e8 = 38 s) | `int.go:233`, `emit_go.ml:13444` |
| H7 | Debug TCP control channel has no authentication (debug builds with `TESL_DEBUG_PORT` only) | Any local user can pause the process and read every local incl. session cookies | `debug_control.go:124-133` |
| H8 | Embedded runtime copy has no drift gate; four runtime files are not dune deps | A fix to the queue worker loop can pass CI and not ship in emitted programs | `compiler/lib/dune:36-42`, `ci.sh:704` |
| H9 | ~60% of the hand-written test estate deleted with no drop ledger | Outbound TLS verification has zero tests; pool-timeout 503 and agent cookie confinement untested | roadmap `:868` requirement unmet |

## Medium findings (21; the ones that matter most)

- **Auth:** SSO callback skips the `state` check when the parameter is absent (login CSRF for plain-OAuth2 providers that ignore PKCE). Outbound HTTP follows redirects and forwards custom secret headers to another host, and follows https→http.
- **HTTP:** non-finite floats produce invalid JSON in a 200; `:param` routes silently shadow later literal routes; static serving follows symlinks out of the root, serves dotfiles (`.env`, `.git/config`) and answers `index.html` for unknown mounted-API paths; CSRF relies on `Sec-Fetch-Site` alone (fine for the runtime's own cookie, not for program-defined cookies).
- **Language/emitter:** handler-to-route pairing is positional, so reordering a server block silently swaps same-shape handlers (an authorization change with no diagnostic); the Go backend refuses 589 shapes the checker accepts, so `--check` and the LSP are green for programs the build rejects.
- **Database parity:** `transaction {}` does not roll back on Memory; Postgres-targeted tests are not isolated and one trap kills the test binary; the Memory backend deadlocks on a same-table subquery in `set`/`where`; a NULL numeric decodes as `0` into a non-`Maybe Int`; pool exhaustion waits 30 s / 5 min and answers 500 (spec: 10 s, 503).
- **LLM agent:** tool calls per step, tool-result bytes and tokens are unbounded (2000 tool calls, 2 GB fed back, in one step); persisted transcripts are trusted verbatim (system-prompt injection on OpenAI-wire providers, per-conversation DoS on Anthropic); provider calls inherit the 30 s generic timeout and a timeout discards the turn after side effects ran.
- **Growth:** metric series, telemetry events, regex cache and cache entries are all unbounded (spec promises a 2000-series metric cap).
- **Process:** no Memory/Postgres differential oracle; emitted code is built but never vetted or linted in CI (roadmap says it is); 217 stale Racket references including a broken MCP recipe in `AGENTS.md`; breaking language changes shipped without a changelog.

## Design-level conclusion

Erasing proofs and capabilities at runtime (Rust-style) is the right choice and the checker earned it. The cost is that soundness now rests on two things the review found weak: agreement between the Memory backend developers test against and the Postgres backend production runs on, and agreement between what the checker accepts and what the emitter can render. Both should become gated invariants. The test story has a structural blind spot: api-tests run against a timeout-free test server on an in-memory store, and the emitted test binaries are never raced or vetted, so "passes test, fails live" appears four times in this report.

## Recommended order

1. **Week one:** H1, H2, H3, H6, H5, the two Medium auth items (SSO `state`, redirects), static-file hardening, non-finite floats.
2. **Week two:** H4 (refuse Postgres-declared queue/cache/email until implemented, like `transaction {}`), the Memory/Postgres parity set, route shadowing and named handler binding, agent budgets and transcript validation, bounded stores.
3. **In parallel:** H8 drift gate, H9 drop ledger and TLS tests, differential suite, vet/lint the emitted corpus, run emitted tests under `-race`, route api-tests through the production handler, fix the docs and add a changelog, token handshake for TCP debug.

All probes, logs and per-area reports are listed in Appendix A of `language-review.md` and can be re-run against the checkout.
