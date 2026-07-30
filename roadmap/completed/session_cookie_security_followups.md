# Session-cookie security follow-ups (adversarial review, 2026-07-30)

> **Status: COMPLETE 2026-07-30.** Findings from an adversarial review of the
> session/cookie/JWT/renew work (`roadmap/completed/response_metadata_and_cookies.md` + the
> `JWT.renew` addition). The cryptographic core held under attack — no Set-Cookie injection, no
> header/alg confusion, no reserved-claim bypass, no cross-request cookie leak, constant-time
> compare intact. What follows is what did NOT hold, ranked. **F1–F4 were fixed at review time**
> (see "Already fixed"); **F5, F6, F7 and F9 are now fixed too** (see "What shipped"), and F8 is an
> accepted deployment note, not a defect.
>
> ## What shipped (F5–F9)
>
> **F5 — `JWT.renew`'s `iat` guard is now a shape rule, not `real?`** (`tesl/jwt.rkt`). A new
> `usable-iat?` predicate demands an `exact-nonnegative-integer?` dated no more than
> `jwt-max-clock-skew-seconds` (60) ahead of the clock; `JWT.renew`'s branch calls it instead of
> `real?`. Both halves guard the 12h cap rather than the format: a huge float makes `now - iat`
> hugely negative so the cap check passes forever, and a future `iat` widens the cap by its
> distance ahead — and either survives every renewal, since `iat` is preserved. One message for
> every unusable `iat` (absent, wrong shape, future), because distinguishing them tells a token
> holder how the claim was rejected without telling a legitimate user anything actionable. Six
> regression tests in `tests/jwt-test.rkt` §11 (both forges, the float shape rule, a negative
> `iat`, skew still tolerated, and a Tesl-minted token unaffected); mutation-checked — restoring
> `real?` fails three of them. Closed **before** `roadmap/next/ensure_sso_works.md`, as required.
>
> **F6 — capabilities are wired on the SSE path** (`dsl/web.rkt`, `handle-sse-request`). The
> finding understated it: `current-capabilities` was never parameterized for a subscribe, so it was
> not only `Http.setSessionCookie` that could not run there — ANY `auth` block or `capture` check
> carrying a `requires` row (the common case, e.g. the shipped `cookieAuth` reading the DB) failed
> `call-with-declared-capabilities`'s subset assertion with "Missing capabilities" and 500'd every
> subscribe. Masked in tests because the api-test path runs inside the test's own
> `with-capabilities` scope. `handle-sse-request` now takes `#:capabilities` from the same `serve`
> grant the HTTP path gets and parameterizes it beside the cookie scope, so code and comment agree
> and the scope is reachable. The extent covers auth, the capture checks and the response
> construction — not the streaming loop, which outlives the call and needs no capability.
>
> **F7 — the `kid` trade is written down** (`tesl/jwt.rkt` header, `tesl/crypto.rkt`
> `Crypto.keyFingerprint`). Both notes now state what "safe to log" costs: a 64-bit function of the
> signing key published in every token is an offline key-guess oracle at one SHA-256 per candidate
> (irrelevant against a generated `Secret`, cheaper than before against a guessable one), and two
> deployments emitting the same `kid` demonstrably share a key. Both accepted; the stamp stays.
>
> **F9 — a credentialed SSE response no longer claims `Access-Control-Allow-Origin: *`**
> (`dsl/web.rkt`). The wildcard is emitted only when the response carries no `Set-Cookie`; the
> ordinary uncredentialed subscribe is unchanged. Resolved with F6, as the finding directed.
>
> Regression suite `tests/sse-capabilities-test.rkt` (6 cases: auth and capture under a grant, the
> fail-closed mutation guard, the cookie reaching the response, the wildcard yielding to it, the
> wildcard surviving without it, and no scope leaking past the subscribe), wired into the `ci.sh`
> "Racket suites" phase list beside the F1 confinement test. Mutation-checked in both directions — dropping the capability parameterize
> errors three cases, restoring the unconditional wildcard fails the F9 assertion. Documented in
> LANGUAGE-SPEC §21.2 (what "usable `iat`" means and why) and §21.8 (SSE auth may set a cookie;
> the CORS rule).

## F5 — FIXED. LOW→MEDIUM (latent; live once a key is shared): `JWT.renew`'s `iat` check was `real?`

`tesl/jwt.rkt` accepts any `real?` `iat`. With the signing key, a forged `iat` in the future or a huge
float (`1e300`) renews and is **preserved** across renewals → an effectively immortal session; a
fast-clocked replica minting a future `iat` widens the cap the same way under clock skew. Not
attacker-reachable today (needs the key; `JWT.sign`'s guards are total). It becomes reachable the
moment a Tesl verifier shares an HS256 secret with a foreign minter — exactly what
`roadmap/next/ensure_sso_works.md` plans — so **close this before the SSO work lands.** Fix:
`exact-nonnegative-integer?` for `iat`, plus reject `iat > now + small-skew`.

## F6 — FIXED. LOW (understated — see above): the SSE cookie scope was unreachable, and using it hit the F2 leak

`dsl/web.rkt:2000` scopes `current-response-cookies` for the SSE path and the comment says an SSE auth
block may write a cookie — but `current-capabilities` is never parameterized on the SSE path (only in
`invoke-handler`/`dispatch-request`), so `Http.setSessionCookie` in an SSE auth raises
`Missing capabilities`, uncaught by the SSE `check-fail?` handler → the F2 stack-trace 500.
Fail-closed, but code and comment disagree. Either wire capabilities on the SSE path so the scope is
usable, or drop the SSE cookie scope and the comment and state that SSE auth cannot set a cookie.

## F7 — FIXED (documented). LOW: `kid` publishes a 64-bit function of the signing key in every token

`kid = SHA-256(label ‖ key)[0:8]` (`tesl/jwt.rkt` + `tesl/crypto.rkt:477`). New as of this diff, it
gives (a) an offline key-guess oracle needing no signed payload (one SHA-256 per candidate, cheaper
than HMAC's two compressions) — so a low-entropy `SESSION_KEY` is cheaper to confirm — and (b)
key-sharing linkability (two deployments with the same `kid` demonstrably share a key). Both marginal
and deliberate, but the "safe to log" note in the header should state them so the trade is explicit.

## F8 — INFORMATIONAL (deployment note): `JWT.sign`/`JWT.renew` now hard-depend on libsodium on the login path

The HMAC is OpenSSL, but the `kid` stamp calls `Crypto.keyFingerprint` → libsodium. A program that
previously used only `Tesl.JWT` now 500s on every login without libsodium. Fails loud, libsodium is
in the flake and both `tesl build` images — deployment note, not a hole. (Same root as the templates'
new libsodium dependency; see `roadmap/completed/playground_polish_and_adoption.md`'s sibling notes.)

This is ok, libsodium is a fundamental dependency.

## F9 — FIXED. INFORMATIONAL: SSE 200s carried `Set-Cookie` beside `Access-Control-Allow-Origin: *`

`dsl/web.rkt:2052-2057`. Not exploitable (browsers reject `ACAO: *` for credentialed requests, and
`SameSite=Lax` withholds the cookie from EventSource subresources), but a session cookie on a response
that also says "any origin may read this" is worth not shipping. Resolve with F6.

## Already fixed at review time (recorded so the follow-up is not re-opened)

- **F1 — HIGH: an agent tool could rewrite the caller's session cookie (confused deputy).** A tool
  body ran in the outer request's dynamic extent with the cookie accumulator live, so a tool-invoked
  `Http.setSessionCookie` (driven by model output = prompt injection) appended to the OUTER response
  — silent re-auth as another subject, or forced logout. Fixed: `parameterize
  ([current-response-cookies #f])` around the single tool-dispatch chokepoint in `run-tool-call`
  (`tesl/agent.rkt`) — which every `asTool` fn AND every `serverTools` endpoint reaches via
  `tool-spec-dispatch`, so both vectors close at one point. A tool-side cookie write now hits the
  "no HTTP response" error the accumulator already promises, contained by the tool `with-handlers`
  as a 500 tool_result, never a browser `Set-Cookie`. Regression test
  `tests/session-cookie-tool-confinement-test.rkt` drives the real agent loop inside a live scope and
  asserts the outer accumulator stays empty; mutation-checked (reverting the reset fails it).
- **F2 — MEDIUM: an exception in an `auth` block leaked a stack trace + absolute paths.** `run-auth`
  ran outside `invoke-handler`'s sanitizer and `serve/servlet` had no `#:servlet-responder`, so a
  raise on the auth path fell to the web server's default responder (message + trace + source paths).
  Fixed in two layers (`dsl/web.rkt`): the auth+dispatch tail is now wrapped in the SAME
  `with-handlers` the handler body uses (full detail logged server-side, sanitized 500 to the client,
  pool-timeout→503 parity), and an explicit `#:servlet-responder` sanitizes anything that still
  escapes the servlet lambda. Regression test in `tests/session-cookie-tests.tesl` (a deliberately
  misused auth block raises → the client sees a generic 500, not the exception text);
  mutation-checked. NOT done (deferred): making `Http.setSessionCookie`'s wire-format rejection a
  `check-fail` rather than a raise — see `roadmap/next/check_binding_gap.md`.
- **F3 — the absolute cap was 13h, not the documented 12h.** `JWT.renew` granted a full fresh TTL
  (`+ now ttl`) with no clamp, so a token renewed at the cap boundary lived to `iat + max + ttl`.
  Fixed: `exp` is clamped to `min(now + ttl, iat + max)` (`tesl/jwt.rkt`), so the ceiling is exactly
  `max` from the original login. Test strengthened to assert the renewed `exp`, not just the
  preserved `iat` (`tests/jwt-test.rkt`), and mutation-checked. This made the "12 hours" claim in
  four places (jwt.rkt, lesson76, stdlib_docs_entries.ml, session-cookie-tests.tesl) true rather than
  aspirational.
- **F4 — lesson76's logout note said the captured-token trade is "bounded at one hour."** True for a
  plain session, false for the sliding pattern the same lesson recommends (bounded by the 12h cap,
  and logout does not shorten it). Corrected in `example/learn/lesson76-sessions.tesl`.

## Refuted (attempted and could not break — recorded so they are not re-litigated)

Set-Cookie header injection (regex + Racket's strict `$` + constant attributes); alg/kid/header
confusion (verify recomputes HMAC over `header.payload` verbatim, never parses the header);
reserved-claim guards (`exp`/`iat` rejected across every dict/key shape, JSON-escape-proof);
cross-request/thread leak (per-request `parameterize`, `#f` default is a loud error, per-thread cells
fail closed) — the ONE exception was the tool-dispatch boundary, now fixed (F1); the 2xx-only rule
(`json-response` is the single `dsl-response` constructor in the tree); capability gating of the
writers; session fixation at login (`__Host-` forbids `Domain`/enforces `Path=/`+`Secure`, login
overwrites); timing/exhaustion.

## Related

- `roadmap/completed/response_metadata_and_cookies.md`, LANGUAGE-SPEC §21.2 (`JWT.renew`) + §21.8.
- `tesl/agent.rkt`, `dsl/web.rkt`, `dsl/response-cookies.rkt` (F1, F2 fixes); `dsl/web.rkt` SSE path
  (F6).
- `roadmap/next/ensure_sso_works.md` — F5 must be closed before this lands (shared HS256 secret).
- `roadmap/next/check_binding_gap.md` — the unchecked-`let` gap; also where the deferred half of F2
  (make `Http.setSessionCookie`'s rejection a `check-fail`) belongs.
