# Tesl Security & Performance Review

**Date:** 2026-08-02
**Scope:** Full-repo review focused on the runtime edges: SSO/OIDC, secrets handling, HTTP hardening, injection classes, supply chain, and performance. The compiler's core type/proof system (checker.ml, proof_kernel.ml, proof_discharge.ml, validation_capabilities.ml) has already been through multiple dedicated review rounds (see `roadmap/completed/`) and was only spot-checked here for regressions, not re-audited from scratch.
**Method:** Six independent focused passes (auth/SSO edges, injection, secrets/crypto, web hardening, supply chain, performance), each reading actual source rather than trusting prior documentation. All file:line references below were verified against the current tree.

## Verdict

Tesl's runtime has clearly been through real hardening work, and it shows: parameterized SQL everywhere, a whitelist-validated identifier path, resolve-then-connect SSRF pinning, path-traversal-safe static file serving, secure-by-default session cookies, Argon2id password hashing, CSPRNG used consistently, security headers applied to every response without author action, and a shared redacting renderer for all telemetry signals. This is well above the baseline for a code-generation framework.

The gaps that remain are concentrated exactly where you'd expect for a project that has iterated hardening feature-by-feature: a couple of SSO defense-in-depth layers that were built and tested but never wired into the actual call path, no TLS by default, a data-typing gap in the `Secret` struct that depends on every future code path remembering a rule instead of the compiler enforcing it, and zero built-in brute-force protection. None of these are currently exploitable end-to-end in the strongest case (SSO), but they are real, verified gaps, not nitpicks.

**No Critical findings.** Two High, seven Medium, six Low/Informational — **four items (H2, M1, M4, L4) have since been fixed and verified; see "Fixed" markers below.**

---

## Findings

### HIGH

**H1. No rate limiting or lockout on authentication endpoints.**
`Crypto.checkPassword` is constant-time and enumeration-safe (verifies against a dummy hash when the user doesn't exist), but nothing in `dsl/web.rkt` or the runtime limits request rate per-IP or per-account. There is no built-in 429/lockout/backoff mechanism at all — a Tesl author must build this themselves with zero framework support or warning.
*Impact:* any deployed Tesl app with a login endpoint is brute-forceable at whatever rate the network allows, unless the author independently adds protection.
*Fix:* ship an opt-out (not opt-in) rate limiter for auth-tagged routes, or at minimum emit a build-time warning when an `auth` capability route has no rate-limit wired.

**H2. CI trusts floating `@main` refs for third-party GitHub Actions. — FIXED.**
`.github/workflows/ci.yml:46,52` and `playground.yml:60,66` pinned `DeterminateSystems/nix-installer-action@main` and `magic-nix-cache-action@main` — the literal branch head, not even a version tag. A compromise of either upstream action repo would have been arbitrary code execution in CI on every run (repo checkout, and for `playground.yml`, Pages-deploy write access), silently.
*Fix applied:* both refs pinned to a commit SHA with a version comment: `nix-installer-action@ef8a148080ab6020fd15196c2084a2eea5ff2d25 # v22`, `magic-nix-cache-action@6221693898146dc97e38ad0e013488a16477a4c4 # v9`, in both workflow files.

### MEDIUM

**M1. SSO success path never cleared the `__Host-oauth` cookie; the single-use `state` replay guard was dead code. — FIXED.**
`dsl/web.rkt:2622-2639` (success branch of `handle-sso-callback`) set `__Host-session` but never cleared `__Host-oauth`, unlike the failure branch (`dsl/web.rkt:2540-2547`), which does clear it. Separately, `state-spend!`/`make-spent-state-set` (`dsl/sso.rkt:316-338`) were fully implemented and unit-tested (`tests/sso-runtime-test.rkt:173-176`) but had **zero call sites** in the actual callback orchestration (`sso-handle-callback`) — confirmed by repo-wide grep.
The design doc `roadmap/completed/ensure_sso_works.md` explicitly states both behaviors as intended invariants (cookie cleared on every path; state single-use enforced), so this was a regression/gap against the project's own stated spec, not an ambiguous area.
*Impact (pre-fix):* the `__Host-oauth` cookie (sealed PKCE verifier/nonce/state) remained live up to 600s after a successful login instead of being invalidated immediately, and the documented "in-process replay fails" compensating control did not exist in the shipped binary. The primary defense (provider-side single-use authorization code + PKCE binding) still held, so this was defense-in-depth that was missing, not a live bypass.
*Fix applied:*
- `dsl/sso.rkt`: added a process-wide `default-spent-states` instance and a `sso-spent-states-reset!` test hook; `sso-handle-callback` now spends the cookie's `state` value (via `state-spend!`) right after the presented-state/cookie match check and before the token exchange, failing closed with `"state already used"` on replay.
- `dsl/web.rkt`: the success branch of `handle-sso-callback` now also emits `Set-Cookie: __Host-oauth=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0` alongside the new `__Host-session` cookie, matching the failure branch's clearing behavior.
- Updated `tests/sso-flow-test.rkt` and `tests/sso-adversarial-test.rkt` (which reuse fixed `state` literals like `"s"` across independent test cases) to call `sso-spent-states-reset!` between cases — a real server never calls this reset function; it exists only to give tests process-level isolation, the same pattern already used for the JWKS cache (`jwks-cache-reset!`).
- Verified: all 66 SSO tests pass (`tests/sso-runtime-test.rkt`, `sso-flow-test.rkt`, `sso-adversarial-test.rkt`, `sso-web-test.rkt`, `sso-stdlib-test.rkt`), plus `session-cookie-tests.rkt` (14), `session-cookie-tool-confinement-test.rkt` (3), and `web-test.rkt` (127) — no regressions. `raco make dsl/sso.rkt dsl/web.rkt` compiles clean.

**M2. `Secret`/`PasswordHash` redaction is renderer-specific, not enforced by the base struct.**
`newtype-value` (`dsl/types.rkt:333`) is declared `#:transparent`. Enforcement that a `Secret` never reaches logs/telemetry/generated output relies entirely on the compile-time checker (`checker.ml:2036-2041`, "no eliminator" rule) plus explicit `secret-value?` checks inside each of the three telemetry renderers and the debugger's value-tree. There is no universal `gen:custom-write` guard on the struct itself (contrast: `secret-header-value` does have one, `dsl/types.rkt:~418`). This is the same bug *class* as the previously-fixed "secret-wrapped-credentials" issue — the fix pattern (custom-write override) was applied to the header-value wrapper but not to the base secret struct.
*Impact:* no live exploit path found in the current renderer set (all four consumers — Logs/Traces/Metrics/Debugger — correctly check for it), but any future or overlooked raw `~a`/`displayln`/`error`-formatting code path touching a `Secret` value would print plaintext with no type-level backstop.
*Fix:* add `#:property prop:custom-write` (or `gen:custom-write`) directly on `newtype-value` for secret-kind newtypes so redaction is a struct-level guarantee instead of a per-call-site convention.

**M3. No TLS in the built-in HTTP server; no warning about the plaintext default.**
`serve/servlet` in `dsl/web.rkt:2713-2830` is called with no `#:ssl?`/`#:ssl-cert`/`#:ssl-key` arguments, and there is no Tesl surface syntax to opt in. Every Tesl app is plaintext HTTP unless the operator independently puts a TLS-terminating proxy in front, and nothing in the compiler or docs flags this as a requirement.
*Impact:* silent gap rather than a documented decision — a Tesl app deployed directly (bare VM/container with the port exposed) ships session cookies and `Authorization` headers in cleartext.
*Fix:* either support terminating TLS directly, or add an explicit build-time/doc warning that a reverse proxy is mandatory.

**M4. Docker templates ran the app as root. — FIXED.**
`templates/docker/Dockerfile.app-only.tmpl` and `Dockerfile.all-in-one.tmpl` had no `USER` directive for the Tesl app process (the all-in-one entrypoint already dropped Postgres itself to a `postgres` OS user, but the network-facing app stayed root).
*Fix applied:*
- `Dockerfile.app-only.tmpl`: creates a system user `tesl`, chowns `/opt/tesl`, and sets `USER tesl` before `ENTRYPOINT` — the whole process now runs unprivileged.
- `Dockerfile.all-in-one.tmpl` / `entrypoint.sh.tmpl`: the entrypoint script itself must stay root (it bootstraps the embedded Postgres cluster via `su postgres`), but the final app launch now runs as the new `tesl` user (`su "$APP_USER" -c "exec racket '$APP_RKT'"` instead of a bare `exec racket`), with `/opt/tesl/app` and the runtime collections chowned to `tesl`.
- Verified by actually building and running both images end-to-end (not just reading the Dockerfile): `docker run --entrypoint id` on the app-only image shows `uid=999(tesl) gid=999(tesl)`; in the all-in-one image, `ps -eo user,pid,cmd` inside a running container shows Postgres processes under `postgres`, the entrypoint shell under `root`, and `racket /opt/tesl/app/app.rkt` under `tesl` — confirming the privilege drop actually takes effect for the network-facing process, not just that the Dockerfile parses.

**M5. Embedded-Postgres Docker image bakes in a default weak credential.**
`ENV TESL_POSTGRES_PASSWORD=app` is the shipped default in `Dockerfile.all-in-one.tmpl`/`entrypoint.sh.tmpl`. Mitigated by `listen_addresses='127.0.0.1'` (not exposed outside the container), and it's overridable, but it's a real default secret baked into image layers/env if left unchanged.
*Fix:* generate a random password at first boot if unset, or fail the build/boot with a loud warning if the default is still in place.

**M6. CSRF defense fails open when `Sec-Fetch-Site` is absent (acknowledged tradeoff, but worth flagging explicitly).**
`sec-fetch-cross-site-refusal` (`dsl/web.rkt:2263-2273`) only refuses state-changing requests when the header is literally `cross-site`. An absent header (older browsers, non-browser HTTP clients, some proxies) passes through with no CSRF protection at all — there is no fallback token-based CSRF scheme. This is a deliberate, documented design choice (paired with Host-header pinning), reasonable for modern-browser traffic, but it's a real residual gap for anything else.
*Fix:* consider a token-based CSRF fallback for state-changing routes when the `Sec-Fetch-Site` header is missing, at least behind a stricter-mode flag.

**M7. Request body is fully buffered into memory before the size cap is checked.**
`max-body-bytes` (default 1 MiB, `TESL_MAX_BODY_BYTES`) is enforced in `parse-json-body` (`dsl/web.rkt:1503`), but `request-post-data/raw` inside `request->dsl-request` (`dsl/web.rkt:1282`) already reads the full body into memory before that check runs. The 413 rejection is real but happens after the memory cost is paid.
*Fix:* enforce the cap at the transport-read level (streaming/chunked read with an early abort), not after full buffering.

### LOW / INFORMATIONAL

**L1. `like?.`/`ilike?.` don't escape SQL wildcard metacharacters (`%`, `_`) in the pattern value.**
`dsl/sql.rkt:1690-1703, 1283-1293`. Values are still passed as bound parameters (not classic SQL injection), but an unescaped `%`/`_` in user input can broaden a match far beyond intent. Only a real risk if a `.tesl` author uses `like?.` on a security-sensitive field (token, tenant key) rather than free-text search — no such usage found in the runtime itself.
*Fix:* provide an escaping helper for exact-substring matching, or document the caveat.

**L2. `request-id` generation uses non-CSPRNG `random`.**
`dsl/web.rkt:2010`: `(random 1000000)`. Used only for log/span correlation, not as a security token — low impact, flagged only because it sits next to code that correctly uses `crypto-random-bytes` elsewhere.

**L3. Stale comment overstates a still-open SSRF gap that is actually closed.**
`dsl/sso.rkt:340-345` comments that DNS-rebinding SSRF defense is "tracked as remaining Phase-1 work," but `tesl/http-client.rkt:153-206` (issue #48) already implements resolve-then-connect IP pinning end-to-end, including for the SSO HTTP legs. No live risk, but a misleading comment risks wasted effort or an accidental regression later.

**L4. `.gitignore` had no explicit `.env`/`*.pem`/`*.key` patterns. — FIXED.**
No such files were committed (verified), so no active leak, but nothing structurally prevented a future accidental commit.
*Fix applied:* added `.env`, `.env.*`, `*.pem`, `*.key` to `.gitignore`. Deliberately did **not** add a blanket `*secret*` pattern as originally considered — "Secret" is the language's own domain type name (`Tesl.Secret`), and several legitimately-tracked test files (`tests/secret-*-tests.rkt/.tesl`, `compiler/test/test_secret_surface.ml`, `roadmap/completed/secret_wrapped_credentials.md`) would have matched and been silently excluded from git. Confirmed no existing tracked file matches the patterns actually added (`git ls-files | grep -E '\.pem$|\.key$|^\.env'` → only the unrelated `.envrc`, which the patterns don't match).

**L5. npm audit: `brace-expansion` DoS advisory reachable via a production dependency chain in `editor/vscode-tesl`.**
Traced: `vscode-tesl → vscode-languageclient@9.0.1 → minimatch@5.1.9 → brace-expansion@2.0.2`. Fix available via `npm audit fix`. (`example/frontend-ts` audited clean.)

**L6. Example deploy workflow installs Tesl unpinned.**
`github-deploy.yml.example`: `nix profile install github:mtonnberg/tesl` has no rev/hash pin, and uses floating major-version action tags (`cachix/install-nix-action@v27`, `actions/checkout@v4`) rather than SHA pins. Lower severity than H2 since this is a copy-paste template, not live CI.

### Clean / well-defended (verified, not assumed)

- **SQL injection:** every query-building path (`dsl/sql.rkt`) passes runtime values as bound `$n` parameters; dynamic table/column/schema names are routed through a whitelist-regex validator (`identifier-value->string`) before quoting; `ORDER BY`/`LIMIT`/`OFFSET` are type-checked, not string-built from arbitrary input.
- **Path traversal:** static file serving validates every path segment against `.`/`..`/separators pre-dispatch, and re-validates the resolved absolute path stays under the static root as defense-in-depth.
- **XSS / header injection:** no route echoes request-derived content into an HTML response; all dynamic JSON output goes through a proper encoder; the only dynamically-built header values are non-user-controlled (crypto-random cookies, minted JWTs, server-side OAuth URLs).
- **Shell/code injection:** the only `Sys.command`/process-exec calls are compiler-tooling (`raco make/test/exe`) on compiler-generated, quoted temp paths — not reachable from a deployed app's request path. No `subprocess`/`system` call exists anywhere in `dsl/*.rkt`.
- **SSRF:** outbound `HttpClient.*` calls resolve-then-connect and judge the actual peer IP against RFC1918/CGNAT/link-local/loopback/metadata ranges, including IPv4-mapped-IPv6 bypass forms; deny-by-default when deployed.
- **SSE resource leak (issue #32):** fixed — kill-safe janitor thread, bounded per-connection buffers, unregistration on every exit path.
- **DB pool backpressure (issue #31):** fixed — bounded pool with timeout-based lease, mapped to HTTP 503 rather than hanging or failing fast.
- **Security headers:** `nosniff`, `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY`, HSTS (on https origins), and a default CSP on HTML responses are applied to every response without author action.
- **CORS:** no default wildcard `Access-Control-Allow-Origin`; the one wildcard use (SSE subscribe) is deliberately gated to only fire when no session cookie is set, specifically to avoid the classic ACAO:* + credentials misconfiguration.
- **Session cookies:** always `Secure; HttpOnly; SameSite=Lax`, `__Host-`-prefixed, with no author-facing way to weaken this.
- **Password hashing:** Argon2id via libsodium (`crypto_pwhash_str`), fresh random salt, capped input size to bound memory-hard-hash DoS; SHA/HMAC misuse for passwords is lint-flagged.
- **Randomness:** CSPRNG (`crypto-random-bytes`) used consistently for all security-sensitive tokens (session, SSO state/PKCE, UUIDs, trace/span IDs) — the one exception is the non-sensitive request-id (L2).
- **Logging/telemetry:** HTTP/auth logging is metadata-only by design (method/path/status/duration; auth logger explicitly never logs tokens/codes/verifiers); all three telemetry signals plus the debugger share one redacting renderer; metrics cardinality is capped at 2000 per instrument with graceful overflow folding, closing the "high-cardinality label leak" class.
- **Error handling:** unhandled exceptions never leak stack traces or paths by default; only surfaced under an explicit verbose env flag.
- **Supply chain — Nix:** `flake.lock` pins `nixpkgs` and all inputs to specific commits; no floating refs in the lockfile.
- **Supply chain — general:** no hardcoded real secrets found in the repo (the one credential-shaped string hit is a deliberate self-signed test fixture for TLS-rejection tests); Docker base image is version-pinned, not `latest`.

---

## Performance Findings

**P1 (Medium — compiler scaling, not runtime).** `checker.ml`'s type environment (`type_system.ml:1286-1288`) is an O(n) assoc-list, flattened to include every imported function/record/ctor/ADT per file (`checker.ml:6894-6923`), and every variable/call-head lookup does a linear scan of it. This makes a single file's checker pass scale with total imported-declaration count, worse as a project's shared "core" modules grow — an O(exprNodes × importedDeclCount) pattern. Import parsing itself is memoized, so this is specifically about env-lookup cost, not re-parsing. Worth fixing with a hashtable-backed env if `tesl check` visibly slows down on large multi-module projects.

**P2 (Medium, debug-path only).** The debugger's value-tree renderer (`dsl/debug/value-tree.rkt`) correctly bounds depth/children for the cyclic-hang case (still verified present), but before truncation it materializes and `length`s the full child list, and hash-key sorting calls `~a` per-comparison rather than caching keys (`#:cache-keys? #t` is not set). For a large in-memory cache/queue paused in the debugger, this means unnecessary O(n log n) formatting work to display 200 rows. Confined to debug pauses, not the production request path — cheap fix (slice before format/sort).

**P3 (Low).** `emit_racket.ml:8373-8379` dedups capability lists via `List.mem`-in-a-fold (O(n²) pattern), but the lists involved are small in practice (per-declaration capability counts) — flagged as the textbook anti-pattern the review looked for, not a real bottleneck at current scale.

**Handled well:**
- DB connection pooling is genuinely bounded with timeout-based lease and 503 on exhaustion, with wait-time/timeout metrics recorded.
- Request dispatch is not serialized — no global lock on the hot path; the only shared mutable structures are built once at boot and read-only thereafter.
- Telemetry export never blocks a request on the network — bounded drop-oldest queues drained by a background flusher thread.
- Metrics recording is O(1) per call with a hard cardinality cap; only the exporter snapshot path is O(n), and that's off the request hot path.

---

## Priority Recommendations

1. ~~Wire up `state-spend!` and clear `__Host-oauth` on the SSO success path (M1)~~ — **done**.
2. Add rate limiting for auth routes, even a minimal default (H1) — currently zero protection by default. Not done — needs a design decision (per-route vs. global, storage for counters), not a quick edit.
3. ~~Pin CI action refs to commit SHAs (H2)~~ — **done**.
4. Add `custom-write` guard directly to the `Secret`/`PasswordHash` struct (M2) — turns a convention into a type-level guarantee. Not done.
5. Decide and document a TLS story (M3) — either native support or a hard requirement + warning for a fronting proxy. Not done — needs a decision, not just an edit.
6. ~~Non-root `USER` in both Docker templates (M4)~~ — **done**, verified by building and running both images.
7. Everything else (M5-M7 except M4, L1, L2, L3, L5, L6, P1-P3) is real but lower urgency — track as a backlog. ~~L4 (.gitignore patterns)~~ — **done**.
