# SSO / third-party auth — implementation progress

Tracks execution of `roadmap/next/ensure_sso_works.md`. That item is very large
(2560 lines, phases −2 → 5). The document itself sequences several phases that
are **independent of SSO and ship on their own merits**; this effort does those
foundational, gating phases first, then builds the SSO feature on top.

Plan: see the Warp plan "SSO / third-party auth — staged implementation".

## Environment
Nix is not auto-loaded. Run everything under
`nix develop --command bash -c '...'`.
- Build compiler: `cd compiler && dune build` → `compiler/_build/default/bin/main.exe`
- Racket unit test: `TESL_REPO_ROOT=$PWD raco test tests/<file>.rkt`
- Examples: `./compile-examples.sh`

## Status legend
DONE · IN PROGRESS · TODO

---

## Stage 1 — foundational, SSO-independent phases
**Validation: the full `ci.sh` suite (19 phases, ~11 min) is GREEN** with all three phases below — compiler build, every example compiling, integration tests (httpclient under the TLS change), all Racket suites (incl. the 3 new ones), `tests/all.rkt`, boot smoke, and playground parity.

### Phase −1 — authenticate the TLS peer — DONE
Live MITM defect: `tesl/http-client.rkt` opened TLS with a bare `#:ssl? #t`
(Racket default client context), verifying neither certificate chain nor
hostname, for every outbound HTTPS call (webhooks, payment APIs, agent providers,
future SSO exchange).

Changes (`tesl/http-client.rkt`):
- Added `(only-in openssl ssl-secure-client-context)`.
- `secure-client-context` — memoized verifying context (chain + hostname).
- `tls-mode host use-ssl?` — returns the `#:ssl?` argument: `#f` for http, the
  verifying context for https, or the non-verifying default **only** under the
  single loopback-only development escape.
- Both `http-conn-open` call sites now pass `(tls-mode host use-ssl?)`.
- The single development escape `TESL_HTTP_TLS_INSECURE_DEV`: environment-level,
  engages for loopback hosts only, refuses in a deployed build (`TESL_DEPLOYED`),
  warns loudly once. No per-call flag; ratchet forbids a second opt-out.
- Comment records that this makes TLS *correct*, not *sufficient* (the
  interception-middlebox argument).

Tests: `tests/http-tls-tests.rkt` (5 cases, all pass) — ratchet (no bare
`#:ssl? #t`), self-signed loopback peer refused by default, dev-escape gating
(loopback-only, env-gated, refused when deployed), dev-escape connects to a
self-signed loopback server, `host-loopback?` classification. Registered in
`ci.sh` `RKT_SUITES`. Existing `httpclient-test`, `http-timeout-tests`,
`httpclient-tests`, `http-stub-tests` still green.

Note: full "single development gate" unification (also covering `publicOrigin`'s
localhost carve-out and the deploy-target build signal) folds in with Phase −2/3
once that surface exists; the TLS portion is implemented as that one gate today.

### Phase 0 — pin `JWT.decode` array-valued claims (blocker 6) — DONE
`JWT.decode` is typed `Dict String String`, but a JWT payload is arbitrary JSON
(`aud`/`amr` arrays, `exp`/`iat` numbers), so `string->jsexpr` handed the Tesl
surface non-String values — the declared type a lie.

Changes (`tesl/jwt.rkt`): `jwt-claim-value->string` coerces every claim value to
its string form under a stated, deterministic rule (string→itself; number/bool→
JSON text; null→`"null"`; array/object→compact JSON text); `jwt-claims->tesl-dict`
applies it and fail-closes if the payload is not a JSON object. Applied **only**
at the `JWT.decode` surface (the verify/renew path keeps raw numeric `iat` for its
arithmetic). A Risk 18 note warns that a decoded array claim is substring-matchable
JSON text and must not be used for authorization (that is the SSO typed-claims
path). No compiler change (the `Dict String String` type is now honest).

Tests: two cases appended to `tests/jwt-test.rkt` (array/number/bool coercion;
non-object payload rejected). Full suite 91/91 pass.
### Phase −2 (partial) — response security header baseline in `dsl/web.rkt` — DONE
The tree emitted only `X-Content-Type-Options: nosniff`, and the two paths that
serve the app's own HTML — the static-file responder and the SPA fallback —
passed `'()` headers (no security headers at all).

Changes (`dsl/web.rkt`): `security-response-headers`, `add-security-headers`
(adds the set without overriding a producer's own header) and `harden-servlet`
(wraps the servlet so **every** response — static, SPA-fallback, JSON, 500 —
carries the set). Headers: `X-Content-Type-Options: nosniff`,
`Referrer-Policy: no-referrer`, `X-Frame-Options: DENY` on every response;
`Strict-Transport-Security: max-age=31536000` only when the configured public
origin is `https` (never from the request, Risk 44), suppressed for loopback;
a `Content-Security-Policy` on served HTML only (default `frame-ancestors 'none'`
— non-breaking; full policy via `TESL_CSP`; final default is Open Question 17).
Public origin runtime source is `TESL_PUBLIC_ORIGIN` until the `publicOrigin`
server clause lands (Stage 2).

Tests: `tests/response-security-headers-test.rkt` (8 cases, all pass), registered
in `ci.sh`. `web-test` (102) and `sse-capabilities-test` (6) still green.

Deferred to Stage 2 (need compiler surface): `listenAddress` server setting +
the header-trust compile-time discharge (`Proxy.verifyBinding` witness); the
`publicOrigin` clause that will validate + feed the HSTS origin; `Host`
validation and `Sec-Fetch-Site` refusal; the CSP default value (Open Question 17).

---

## Stage 2 — SSO feature phases — IN PROGRESS

### SSO-independent runtime halves (in `tesl/jwt.rkt`) — DONE
The spec says the runtime halves of `SessionPolicy`, `ssoPreviousKey` and
`sessionRevoked` are independent of SSO and may land ahead of the server-clause
surface. All three are implemented as boot-time Racket parameters that default
to today's exact behaviour:
- **SessionPolicy** — `session-policy` struct + `standard-session` (1h/12h, the
  default) and `short-session` (15min/8h); `current-session-policy` parameter;
  `policy-ttl-seconds`/`policy-absolute-max-seconds`. `JWT.sign`/`JWT.renew` read
  the active policy; the absolute cap is named per policy, **not** derived as a
  TTL multiple (a 15-min TTL under the old `* 12` would give a wrong 3h cap).
- **Session-key rotation** — `current-previous-session-key` parameter; `JWT.verify`
  accepts a token signed by the current **or** previous key (each its own
  constant-time compare), `JWT.sign`/renew always use current, so the previous
  slot drains on its own. This is the rotate-without-mass-logout / kill-switch
  mechanism.
- **Revocation at the renewal boundary** — `current-session-revoked-hook`
  parameter, consulted **only** in `JWT.renew` (verify path byte-identical),
  fail-closed (a `#t` result or a raising hook denies), keyed on `(sub, iat)` so
  "log out everything issued before T" is expressible.

Tests: `tests/jwt-session-policy-test.rkt` (11 cases) — policy TTL/cap, cap-not-a-
multiple, rotation accept/reject/drain, revocation deny/allow/raise/verify-no-read.
Registered in `ci.sh`. `tests/jwt-test.rkt` still 91/91.

Deferred to Phase 3 (compiler surface): the `sessionPolicy` / `ssoSessionKey` +
`ssoPreviousKey` / `sessionRevoked` server clauses that set these parameters at
boot, the `SessionPolicy` baked ADT, and wiring the cookie `Max-Age` to the
active policy (today it derives from the Standard TTL constant, which is a safe
over-estimate under ShortSession — an expired token is a 401 regardless).

### Phase 1 down-payment — SSRF containment (`dsl/private/ssrf-guard.rkt`) — DONE
The security-critical, pure decision core of Risk 47: classify a **resolved
address** and refuse loopback / link-local / unique-local / RFC1918 / CGNAT /
`0.0.0.0/8` / multicast **and their IPv4-mapped IPv6 spellings**
(`::ffff:127.0.0.1`, `::ffff:7f00:1`), failing closed on anything unparseable.
`ip-address-forbidden?` / `ip-forbidden-reason` / `normalize-ip`.

Tests: `tests/ssrf-guard-test.rkt` (7 cases, incl. the `169.254.169.254` metadata
payoff and the IPv4-mapped bypass), registered in `ci.sh`.

The resolve + **connect-time pinning** wrapper (resolve once, refuse if any
address is forbidden, then dial the checked address so a re-resolution cannot
rebind) lands with the `dsl/sso.rkt` / http-client integration in the rest of
Phase 1.

### Phases 1 & 2 — `dsl/sso.rkt` OIDC + plain-OAuth2 runtime — DONE
The full flow runtime, split into a PURE security layer (where the
account-takeover-class bugs live, so it is the most heavily tested) and an
ORCHESTRATION layer driven through the outbound-HTTP stub (no network, no live
provider). The third-party identity is exchanged ONCE at the callback for an
`SsoIdentity`; every existing session/proof surface is untouched.

Pure layer:
- **PKCE S256** (`pkce-challenge`) — `plain` never produced.
- **Injective `SsoSubjectKey`** — length-prefixed `(issuer, subject)` then
  SHA-256, so the cross-issuer collision (Risk 59) is impossible; opaque hex with
  no email inside (the `PasswordHash` opacity precedent).
- **`EmailClaim`** (`email-claim`) — `'verified` reachable ONLY on a real boolean
  `#t`; a string `"true"`, `'null`, or absence is `'unverified` (the nOAuth /
  Entra containment as a rule).
- **Domain restriction** — `allowedEmailDomains` satisfiable only by a
  `'verified` email; `allowedHostedDomains` refuses an absent `hd` claim;
  case-insensitive.
- **OIDC claim validation** (`validate-oidc-claims`) — `iss` exact-or-templated,
  the **Entra multi-tenant issuer trap** (templated issuer refused without
  `allowedTenants`; `tid` membership + `iss`=substituted-issuer both required),
  `aud`/`azp`, constant-time `nonce`, `exp`/`iat` with leeway and flow-start.
- **`__Host-oauth` cookie** (`oauth-cookie-seal`/`open`) — payload authenticated
  under a domain-separated subkey of the session key (never the raw JWT key,
  Risk 58), verified against `[current, previous]` (rotation overlap), bound to
  the route segment; nothing trusted before the MAC verifies; forgery/tamper/
  wrong-segment/wrong-key all refused.
- **`sso-defaults`** (Google=OIDC, GitHub/Discord=OAuth2) with **minimal** scopes;
  **synthesized issuer** (scheme+host of userinfo URL) for the OAuth2 family;
  **`extraAuthorizeParams`** reserved-name rejection + percent-encoding;
  per-process single-use `state`.

Orchestration: discovery (issuer-match + S256-advertised), token exchange
(`client_secret_basic`, secret in the header never a URL), OIDC id_token claim
path and OAuth2 userinfo path, runtime-enforced domain restriction **before** any
identity is returned, every leg https-only + SSRF-preflighted, provider
`error`/`error_description` strings NEVER reflected.

Tests: `tests/sso-runtime-test.rkt` (17 pure cases incl. the injectivity,
nOAuth, Entra-trap and cookie-forgery attacks) and `tests/sso-flow-test.rkt`
(6 end-to-end cases: OIDC + OAuth2 happy paths, nonce mismatch, discovery-issuer
mismatch, unverified-email domain refusal, SSRF token endpoint). Registered in
`ci.sh`; full CI green.

Honest limitations inside this runtime (each tracked below):
- **ID-token signatures are NOT yet verified** — the interim rests on
  Phase −1's authenticated TLS + OIDC §3.1.3.7; Phase 2.5 (below) closes it.
- **SSRF is literal-IP preflight only** — DNS-resolve + connect-time pinning is
  the remaining http-client socket integration (the classifier it will call,
  `dsl/private/ssrf-guard.rkt`, is done and tested).
- **Domain folding is ASCII-case only** — IDNA/punycode A-label unification
  (Risk 62) is not applied (a homoglyph is still correctly a different domain).
- GitHub's second `/user/emails` call for the verified primary is not made
  (email from `/user` is treated as unverified — the safe default).

### Phase 2.5 — RS256/ES256 ID-token signature verification + JWKS — DONE
`dsl/private/jws-verify.rkt` — a verify-only asymmetric backend over
`openssl/libcrypto` (libsodium has no RSA/P-256). The public key is built from
the JWK by DER-encoding a SubjectPublicKeyInfo and handing it to `d2i_PUBKEY`,
which sidesteps the low-level key APIs OpenSSL 3.x deprecates (one path for
1.1.1 and 3.x). RSA verifies raw PKCS#1 v1.5; ES256 converts the JWS raw
`r||s` to a DER `ECDSA-Sig-Value` first. `EVP_DigestVerify` with SHA-256.

Fail-closed refusals (each tested): `alg:none`; an HMAC alg on an ID token
(sign-with-the-public-key); an `alg` outside the pinned set; a header that
NOMINATES its own key (`jwk`/`jku`/`x5u`/`x5c`) or carries `crit`; a JWE
(five-segment) token; an unknown `kid`; an RSA modulus below 2048 bits; and a
tampered payload.

Wired into `finish-oidc` (`dsl/sso.rkt`): the id_token signature is verified
against the discovery `jwks_uri` **before any claim is read**, with `alg` pinned
from discovery's `id_token_signing_alg_values_supported` ∩ `{RS256, ES256}`, and
a verification failure is terminal — **the §3.1.3.7 interim downgrade is gone**.

Tests: `tests/jws-verify-test.rkt` (11 cases, valid RS256 + ES256 via
openssl-generated fixtures plus the full adversarial set); the OIDC path in
`tests/sso-flow-test.rkt` now verifies a real RS256 signature end-to-end.
Registered in `ci.sh`; full CI green.

Not included (correctly): the single rate-limited JWKS refetch on unknown `kid`
(a caching/amplification refinement) and the userinfo `sub` cross-check for the
OIDC-connection-with-userinfo case (v1 OIDC does not call userinfo). Both are
small follow-ons noted for Phase 3 wiring.

### Phase 3 — the compiler surface (`sso` clause + friends) — DONE
**Landed this pass — the `Tesl.Sso` stdlib module (the "provider is a value"
foundation the `sso` clause consumes), fully wired through the compiler and
green across every gate:**
- `type_system.ml`: opaque TCons `SsoConnection` / `SsoSubjectKey` (no ctor row
  -> nominal wall, the `Secret`/`PasswordHash` precedent); function rows
  `Sso.defaults : String -> String -> Secret -> SsoConnection` and
  `Sso.keyText : SsoSubjectKey -> String`; a `Tesl.Sso` module export row.
- `emit_racket.ml`: the `Tesl.Sso -> tesl/sso.rkt` module-path row.
- `stdlib_config_names.ml`: the two opaque type names in `require_suppressed`
  (valid in type position, erased at runtime).
- `stdlib_docs_entries.ml`: doc entries for all four names (the coverage gate).
- runtime `tesl/sso.rkt`: a thin wrapper over `dsl/sso.rkt` providing
  `Sso.defaults` / `Sso.keyText` (v1 provider is a `String` name; unknown
  provider is a hard error).

A `.tesl` program can now `import Tesl.Sso` and write
`Sso.defaults "github" clientId clientSecret : SsoConnection` and
`Sso.keyText key : String` — it type-checks clean, and the opaque types stand
as a nominal wall. Gates confirmed green: the OCaml suite (stdlib **seam** +
**docs-coverage** + **signature-coverage** + the new 8-case
`test_sso_surface.ml`), the Racket `tests/sso-stdlib-test.rkt` (5 cases), and
the lifted-stdlib + lesson-catalog snapshot checks.

**First two `server`-block clauses landed end-to-end — `sessionPolicy` and `publicOrigin`.**
A `.tesl` author can now write `sessionPolicy ShortSession` (or
`StandardSession`) in a `server` block. It is a **closed keyword set** enforced
in the parser (an unknown name cannot express an unsafe duration — it simply
takes no effect), threaded through a new `server_form.session_policy` AST field,
and emitted as a boot-time `(current-session-policy short-session)` set that the
already-tested JWT runtime consumes (15min/8h vs 1h/12h). Verified end-to-end:
the sessions lesson with the clause type-checks clean, emits the policy set +
the `__tjwt_` require, and the emitted Racket **compiles/loads** (`raco make`
green). Tests: 4 new emit-assertion cases in `test_sso_surface.ml` (ShortSession
/ StandardSession set the policy; no clause sets none; an unknown name takes no
effect) — 12 cases total, and the full OCaml suite (496+8+145) stays green.

`publicOrigin "https://app.example.com"` followed the same pattern (a second
`server_form.public_origin` field + parser branch on a STRING literal + emit).
Its runtime is `dsl/web.rkt`'s new `current-public-origin` parameter, which
`public-origin-value` now prefers over the `TESL_PUBLIC_ORIGIN` env var — so the
clause feeds the already-wired HSTS origin (never a request header, Risk 44).
Emitted as a boot-time `(current-public-origin "…")` set; the combined
`sessionPolicy` + `publicOrigin` server emits and **`raco make`-loads** green.
Tests: 3 more cases in `test_sso_surface.ml` (15 total) — publicOrigin set, no
clause sets none, and both clauses coexist. Note: compile-time https/absolute
validation of `publicOrigin` lands with the `sso` clause (which uses it for
`redirect_uri`); today it only feeds HSTS, which self-guards on https.

**The flagship `sso` clause — parse + fail-closed validation landed (route
emission is the next step).** `sso "<seg>" connection <fn> onIdentity <fn>` is
now recognized in a `server` block (new `server_form.sso_clauses` field +
parser branch, `connection`/`onIdentity` as contextual keywords) and
**validated fail-closed** in the checker: an unknown connection or onIdentity
function is a compile error, an empty route segment is an error, and two
clauses for the same segment (route collision) is an error. Tests: 4 more
cases in `test_sso_surface.ml` (**19 total**) — a well-formed clause validates,
and each of the three fail-closed conditions is rejected. Full OCaml suite
(496+18+10+145+8) green.

**The runtime-owned SSO routes now exist in `dsl/web.rkt` (the big unknown,
resolved).** The two blockers the Tesl handler surface deliberately lacks are
now implemented in the runtime:
- `sso-redirect-response` — a **303** with `Location`, `Cache-Control: no-store`
  and any number of **`Set-Cookie`** lines (blockers 1 & 2), which `harden-servlet`
  then layers `Referrer-Policy: no-referrer` onto.
- `sso-cookie-line` — a `__Host-` cookie (`Path=/; HttpOnly; Secure;
  SameSite=Lax`), used for `__Host-oauth` (short Max-Age) and `__Host-session`.
- `find-sso-match` + a new first branch in the servlet dispatch (guarded by an
  empty `sso-routes`, so existing serving is byte-identical), and `#:sso-routes`
  on `serve`.
- `handle-sso-request`: **login** -> `sso-begin-login` -> 303 to the authorize
  URL + sealed `__Host-oauth`; **callback** -> `sso-handle-callback` -> the app's
  `on-identity` mapping -> a `mint-session` closure -> `__Host-session` + 303 to
  `after-login`; any failure -> a fixed 401 page that clears `__Host-oauth`
  (never the provider's text). Session minting stays OUT of `web.rkt` — the route
  carries a `mint-session` closure (emitted under the app's jwt/time capabilities),
  so `web.rkt` touches neither JWT nor the capability system.
- `make-sso-route` / `sso-route` — the per-clause config the emitted server passes
  to `serve` via `#:sso-routes`.

To avoid a compile-time require cycle (`web -> sso -> http-client -> traces ->
web`), `dsl/sso.rkt` and `tesl/jwt.rkt` are loaded LAZILY (`define-runtime-path`
+ `dynamic-require`, with positional wrappers `sso-begin-login*`/
`sso-handle-callback*` added to `dsl/sso.rkt`), and base64url is inlined locally.

Tests: `tests/sso-web-test.rkt` (6 cases) — route matching, the cookie + 303
primitives, login (303 to authorize + `__Host-oauth`), a fail-closed cookieless
callback, and a **full login -> callback -> `__Host-session`** flow driven
through the outbound-HTTP stub (plain OAuth2, no network). `web-test` (102),
`response-security-headers` (8), `sse-capabilities` (6) all still green.

**The `sso` clause is now END-TO-END, with a working example.** `emit_server`
emits, per `sso` clause, a `register-sso-routes!` side effect carrying a
`make-sso-route` — the connection fn wrapped as a thunk, the `onIdentity` fn as
`on-identity`, a `mint-session` closure calling the self-granting
`sso-session-cookie-value` (jwt.rkt), a deferred `session-key-bytes` thunk
(`secret->bytes` of the `ssoSessionKey` env secret), `publicOrigin` and
`afterLogin`. Registration (not a `serve` keyword) keeps every server WITHOUT
an `sso` clause **byte-identical** — the `example/learn/*.rkt` exact-match
snapshots are unchanged (verified: lesson17 re-emits identical). `serve` reads
the registry by server name.

Supporting surface added this pass: the `ssoSessionKey "ENV_VAR"` and
`afterLogin "/path"` string clauses (parser + fail-closed validation: a server
with `sso` clauses MUST declare `publicOrigin` + `ssoSessionKey`, and
`afterLogin` must be a relative path); the `SsoIdentity` opaque type +
`Sso.subject` stdlib fn (for the `onIdentity` body); and the runtime helpers
`Crypto.secret->bytes` and `JWT.sso-session-cookie-value`.

**End-to-end example: `example/sso-demo.tesl`.** A `server` with
`sso "github" connection githubConn onIdentity linkUser`, `publicOrigin`,
`ssoSessionKey`, `afterLogin`, `sessionPolicy ShortSession`, and
`sessionRevoked revoked`. It **type-checks
clean (0/0)**, **emits** the `register-sso-routes!` + `make-sso-route`, and the
emitted Racket **`raco make`-loads** — so `/auth/github/login` (303 to GitHub +
`__Host-oauth`) and `/auth/github/callback` (code exchange → `onIdentity` →
`__Host-session` + 303) are wired to the runtime whose behaviour
`tests/sso-web-test.rkt` proves. Full OCaml suite (18+10+499+8+145) and all
seven SSO Racket suites (76 cases) green.

**`sessionRevoked <fn>` landed end-to-end.** The `server`-block clause
`sessionRevoked revoked` installs the app's revocation predicate as the
renewal-time `current-session-revoked-hook` (the JWT runtime half already built
and tested in Stage 1). The emit sets the hook at boot to a plain fn reference —
no env/caps at load — wrapped in an adapter that converts the runtime's epoch
**seconds** iat to the Tesl fn's `(String, PosixMillis) -> Bool` contract via
`Time.secondsToPosix`. Fail-closed: validation errors if the named fn is not
defined. Emitted require broadened to include `current-session-revoked-hook`
(and `Time.secondsToPosix`), gated on the clause's presence so non-sso servers
stay byte-identical. Tests: 3 more cases in `test_sso_surface.ml` (now 22 total)
— hook installed, no clause → no hook, unknown fn → compile error. `sso-demo`
extended and still `raco make`-loads.

While landing this, two **pre-existing seam tests** (from the prior `Tesl.Sso`
module turn) were red and are now fixed: `Tesl.Sso` was added to
`type_system.ml`'s `tesl_known_module_names` (it was in `stdlib_home_module`
but not the known-modules list), and the three `Tesl.Sso` opaque identity types
(`SsoConnection`/`SsoSubjectKey`/`SsoIdentity`) were added to the pinned
`pre_refactor_literal` in `test_config_only_type_positions.ml` (they are
require-suppressed like `PasswordHash`/`Secret`). Full OCaml suite is green
again.

**`ssoPreviousKey "ENV_VAR"` landed end-to-end.** The clause sets
`current-previous-session-key` at boot so `JWT.verify` accepts a token signed by
EITHER the current or previous session key — the rotation overlap that lets a
leaked `SESSION_KEY` be rotated without logging every user out (emptying the
slot is the global kill switch). The runtime half was built and tested in
Stage 1. The Secret is read from the environment at module load, so the emit
wraps the set in `with-env-bootstrap` (the sanctioned one-time provider read;
`raco make` compiles but never runs it, so an unset var raises only at real
boot). Fail-closed validation: a `ssoPreviousKey` without an `ssoSessionKey`
(the current key it rotates) is a compile error. Emitted `__tjwt_` require
broadened to include `current-previous-session-key`; the `__tenv_requireSecret`
+ `with-env-bootstrap` requires are gated on the clause's presence. Tests: 3
more in `test_sso_surface.ml` (now 25 total). `sso-demo` extended and still
`raco make`-loads.

**`listenAddress Loopback | AllInterfaces` landed end-to-end.** A CLOSED
keyword-set clause (like `sessionPolicy`) that binds the server to a specific
interface: `Loopback` → `127.0.0.1` only (put the app behind a reverse proxy so
it is never directly reachable — the Item-A binding stance); `AllInterfaces` →
the previous default. Wired through a new `listen-address-registry` in
`dsl/web.rkt` (mirrors `sso-routes-registry`): `serve` now reads
`#:listen-ip` from the registry by server name instead of the hardcoded `#f`, so
the EMITTED `serve` call is unchanged and non-`listenAddress` servers stay
byte-identical; the clause emits a top-level `register-listen-address!` only when
present. Tests: 4 more in `test_sso_surface.ml` (now 29 total) — Loopback →
127.0.0.1, AllInterfaces → #f, absent → nothing, unknown keyword → no effect.
`web.rkt` `raco make`s and `tests/sso-web-test.rkt` (6) +
`tests/response-security-headers-test.rkt` (8) stay green; `sso-demo` extended.

**`loginMethods [Sso] | [Sso, Password via <fn>] | [Sso, Proxy]` landed (core,
fail-closed).** The clause is a CLOSED keyword set that declares which
session-establishment methods a server allows. The enforcement sits on the one
function the spec's sixth review identifies as the unique session-minting
chokepoint — `Http.setSessionCookie` — plus the `Crypto.checkPassword` /
`Crypto.hashPassword` backstop. A new module-wide scan in
`validation_structural.ml` collects every occurrence of those three calls
(matching both the `EVar "Mod.fn"` and `EField (EConstructor Mod).fn` AST
spellings); it OVER-approximates ("any occurrence anywhere", not call-graph
reachability) because a security allowlist must err toward rejecting. The rules,
all fail-closed:
- Under `loginMethods` WITHOUT `Password`, ANY app `Http.setSessionCookie` or
  password call is a compile error — the only sanctioned minting site is the
  runtime-owned SSO callback, which is not app code. This is exactly the sentence
  an enterprise reviewer reads `loginMethods [Sso]` to mean: *no code path in
  this program can produce a session cookie except the SSO callback.*
- Method keywords are the closed set `Sso | Password | Proxy`; unknown → error;
  the list must include `Sso`; `Password` must carry `via <fn>` and that fn must
  be defined.
Tests: 7 more in `test_sso_surface.ml` (now 36 total) — SSO-only compiles with no
minting site; SSO-only rejects a real `Http.setSessionCookie` handler; mixed mode
requires the policy fn; missing `via`; unknown fn; unknown keyword; missing Sso.
`sso-demo` carries `loginMethods [Sso]` and type-checks 0/0.

**Deferred (Open Questions 15/18):** the mixed-mode `Password` per-site
attribution. The spec requires a Password-attributed `setSessionCookie` site to
present a kernel-minted witness (candidate `Auth.passwordLogin`, OQ15) so the
attribution cannot be forged, and the site-attribution spelling is OQ18. Those
runtime/type surfaces are not yet designed, so mixed mode currently enforces only
that the policy function exists — a `[Sso, Password via <fn>]` server does NOT
yet reject an unattributed minting site. This is the one honest gap in Phase 3;
it is called out here so it is not mistaken for complete. Everything else
(SSO-only) is fully sound with no new type needed.

Then Phase 4 (lesson/template/LANGUAGE-SPEC) and Phase 5 (containerised IdP +
headless browser + conformance).

**Phase 3 is complete.** Every `server`-block clause the spec names is parsed,
validated fail-closed, and emitted end-to-end, and `example/sso-demo.tesl`
exercises the whole surface (type-checks 0/0, `raco make`-loads):
- the repeatable `sso "<seg>" connection … onIdentity …` clause (route minting
  `/auth/<seg>/login|callback` via the runtime registry, route-collision +
  unknown-fn validation), and `publicOrigin`;
- the `Tesl.Sso` stdlib module (baked/opaque types + `Sso.defaults`/`Sso.keyText`/
  `Sso.subject`), `sessionPolicy`, `ssoSessionKey`;
- `ssoPreviousKey` (rotation → `current-previous-session-key` under
  `with-env-bootstrap`), `sessionRevoked` (→ `current-session-revoked-hook`),
  `listenAddress` (→ serve `#:listen-ip` via a registry, non-sso servers stay
  byte-identical);
- **`loginMethods`** — the fail-closed allowlist keyed on the
  `Http.setSessionCookie` minting chokepoint + the `Crypto.checkPassword`/
  `hashPassword` backstop, delivering "no app session-minting site except the SSO
  callback" for `[Sso]`. The witness-gated mixed-mode `Password` per-site
  attribution (Open Questions 15/18) is the one documented deferral.

Verification held green throughout: full OCaml `dune test`; all 7 SSO Racket
suites; 36 cases in `test_sso_surface.ml`; 81/81 exact-match `.rkt` snapshots
byte-identical; lifted-stdlib + lesson-index checks pass.

**Researched wiring plan (so Phase 3 can be executed deliberately, not
guessed).** The mechanisms this touches, from reading the tree:
- **Baked ADTs** (`SessionPolicy`, `SsoProvider`, `EmailClaim`) follow the
  `TimeZone`/`Currency` pattern exactly: a `TCon` + nullary/positional
  constructor rows in `type_system.ml stdlib_env`, the type + ctor names added to
  the module's row in `tesl_module_exports`, and **inline lowering** in
  `emit_racket.ml` next to the `Utc`/`FixedOffset`/Currency cases (~:2071) — baked
  ctors are NOT runtime provides, so the stdlib seam test does not gate them.
- **Opaque types** (`SsoConnection`, `SsoIdentity`, `SsoSubjectKey`) follow the
  `PasswordHash`/`Secret` precedent (a `TCon` with **no** constructor row, so
  `SsoSubjectKey "x"` is an unknown-ctor error); `SsoSubjectKey` is additionally
  redacted like `PasswordHash`.
- **`Sso.defaults`/`Sso.keyText`** are ordinary stdlib functions: type rows +
  a `Tesl.Sso` module row (module→file resolves by kebab-case) + a runtime
  `tesl/sso.rkt`-shaped module that `provide`s the exact names (seam test checks
  this via `module->exports`) — the runtime already exists in `dsl/sso.rkt` and
  would be re-exported/wrapped.
- **The `server` block clauses** (`sso "seg" connection … onIdentity …`,
  `publicOrigin`, `afterLogin`, `sessionPolicy`, `ssoSessionKey`/`ssoPreviousKey`,
  `sessionRevoked`, `listenAddress`, `loginMethods`) are the parser/AST core:
  `compiler/lib/parser.ml` (server-block grammar), `ast.ml` (server form),
  `checker.ml`/`validation_*.ml` (route minting `/auth/<seg>/login|callback`,
  route-collision, client-gen exclusion, and the `loginMethods` allowlist over
  `Http.setSessionCookie` call sites + `auth` blocks), and `emit_racket.ml`
  (`build-server-spec`/`define-server` emit that calls `sso-begin-login`/
  `sso-handle-callback` and sets `current-session-policy` /
  `current-previous-session-key` / `current-session-revoked-hook` at boot).
- **Risk:** this is the one part that edits the parser/AST, where a partial change
  reddens the whole compiler build (which gates every test). It should be landed
  as its own focused effort with the same compile-after-every-edit discipline used
  for the runtime — not interleaved with other work.

**Two Phase-2.5 follow-ons to wire here:** the single rate-limited JWKS refetch on
an unknown `kid`, and the userinfo `sub` cross-check (OIDC §5.3.2) for the
escape-hatch case where an OIDC connection also calls userinfo.

### Phase 4 — surface polish — DONE (docs + example), plus review-driven surface upgrades
**Learn lesson `example/learn/lesson78-sso.tesl`** (track=stdlib, order=800,
needs=lesson76-sessions): a full compiling walk-through — provider connection,
`onIdentity` mapping to the durable subject, `sessionRevoked`, an `auth` block
that rebuilds a `User` record from the verified `sub`, and a protected `GET /me`.
Type-checks 0/0, fmt-clean, committed `.rkt` snapshot re-emits byte-identically,
`raco make`-loads; registered in `manual/lessons.md` (80 lessons).

**LANGUAGE-SPEC §23** ("Single sign-on (SSO) and third-party auth"): both trust
arguments written separately (OIDC signature+claims vs plain-OAuth2
PKCE/state/single-use-code/server-side-userinfo), the account-linking rule
`(issuer, subject)`, the §3.1.3.7 history + middlebox argument, the multi-tenant
issuer rule, the Entra reference path (single-tenant issuer, `tid` checked, NO
email linking + the nOAuth reason), `loginMethods` as the "prove only SSO can
log in" answer, plus the provider-ADT + capability-flows-to-`main` note. Added to
the ToC.

**`tesl help manual sso`**: a focused `manual/sso.md` page (auto-embedded via the
gen_docs promote rule), wired into the `section_to_embedded_key` resolver
(`sso`/`auth`) and the `manual/MANUAL.md` index. `tesl help manual language-spec`
also carries §23.

**Review-driven surface upgrades (landed this pass, all green):**
- **Provider is an ADT.** `Sso.defaults`' first arg is the baked `SsoProvider`
  ADT (`Github`/`Google`/`Entra`) — nullary ctors that inline-lower to the
  runtime provider string (the `Utc`/`Currency` pattern), import-gated on
  Tesl.Sso, require-suppressed + rejected-in-type-position + in the pinned
  `config_only` literal. A String provider is now a compile error.
- **Capabilities flow to `main` (compile time).** `validation_capabilities.ml`
  now checks every server-referenced fn — `connection`, `onIdentity`,
  `sessionRevoked` — `caps ⊆ main_grant` (the handler shape; servers inherit
  main's grant via `serve #:capabilities`), and forces an `sso` server's `main`
  to grant `httpClient` for the flow's network I/O. Matches the queue/worker
  `⊆ main` precedent.
- **Capabilities enforced at runtime.** `handle-sso-request` now runs the
  connection/onIdentity/mint-session app code under
  `(parameterize ([current-capabilities (expand-capabilities capabilities)]) …)`,
  threaded from `serve #:capabilities` — the same move `dispatch-request` makes.
- **`Sso.subject` stays `-> String` (deliberate).** Reviewed making it opaque;
  rejected because the subject must serialize through the JWT `sub` and an
  opaque type with no constructor cannot be rebuilt at the `auth` boundary — the
  nominal principal is the app's own `User` record, reconstructed from the
  verified `sub` (shown in the lesson).
Tests: `test_sso_surface.ml` now 40 cases (added provider-is-not-a-String,
Github-ctor-builds, connection-cap-flows-to-main, sso-forces-httpClient); the
seam tests (`config_only`, `stdlib_docs`, `stdlib_runtime_binding`) updated for
the new names; `sso-web-test` updated to pass caps via `#:capabilities`. Full
OCaml suite + all SSO Racket suites + exact-match snapshots + lesson/stdlib index
checks all green.

**Deferred:** the three-button login HTML template (a static-asset scaffold) —
the compiling `lesson78`/`sso-demo` examples + the manual page cover the teaching
surface; the template is a UI nicety, not a compiler/runtime gap.

### Phase 5 — adversarial review + exit — RUNTIME + COMPILE-TIME PASSES DONE; external-infra exit remains
**Compile-time adversarial pass (NEW this session — the half Phase 3 unlocked).**
`compiler/test/test_sso_adversarial.ml` (8 cases, registered in
`compiler/test/dune`) drives the spec's §Login-methods bypass list against a real
`.tesl` program: under `loginMethods [Sso]` a direct `Http.setSessionCookie`, a
magic-link mint, and an API-key login mint are each refused as an unattributable
minting site; `Crypto.hashPassword`/`Crypto.checkPassword` are refused by the
backstop; an off-origin `afterLogin` is refused; and two positive controls
confirm SSO-only-with-no-minting-site compiles and mixed mode
(`[Sso, Password via <fn>]`) still compiles (the documented deferral). The point
the suite pins: a magic-link/API-key/hand-rolled path is caught because it
reaches the chokepoint, NOT by password-call spelling. All 8 green; the runtime
adversarial suites stay green after the Phase-4 R3 capability-threading change
(re-ran: sso-adversarial 20, jws-verify 11, sso-runtime 17, sso-flow 6).

The mandatory adversarial review pass over the runtime is implemented as a large,
pointed suite, `tests/sso-adversarial-test.rkt` (20 cases), walking the spec's own
attack list against the real runtime through the stub: client-secret never in a
URL/body (Basic header only), a provider 200-with-error body never reflected, a
broken signature refused (MITM/wrong-key), PKCE-downgrade (only-`plain`) refused
at discovery, `http://` discovery and an SSRF `jwks_uri` refused, `state`
cross-swap and a cookieless callback refused, unverified-email takeover and
absent-`hd` refused, subject absent/empty/number refused, the clock trio (past
`exp`, future `iat`, `iat` predating the flow) refused, a flattened-`claims`
substring unable to match an array, the Entra multi-tenant trap (templated issuer
+ empty tenants / `tid` outside / `iss`↔`tid` disagreement), `extraAuthorizeParams`
reserved-name + `&`/`=` smuggling, and identity-key stability/injectivity. Plus
the Phase 2.5 adversarial set in `tests/jws-verify-test.rkt`.

**Still required by the spec's exit — and these need resources not available in
this environment (Docker, a real browser, an external conformance harness, a
human reviewer), so they are flagged rather than faked:**
- one **containerised IdP** (Keycloak/dex) for a real discovery/JWKS/key-rotation
  run against the live flow (the `.tesl` surface that drives it now exists —
  `example/sso-demo.tesl` — so this is startable once a Docker-enabled CI job is
  added);
- one **headless-browser** pass (the `__Host-`/`SameSite`/`HttpOnly`/CSP
  guarantees are browser behaviours a unit test cannot observe);
- one **OIDC conformance** run against the certification suite;
- an **external review** of the new checker rules (`loginMethods` allowlist,
  capability-flows-to-`main`) — a human sign-off, not an automatable check.
These are the honest remaining exit gates; everything expressible as a Tesl
program or a runtime unit test is now covered.

### Phase 5 exit infra — real browser/IdP e2e (in progress) + a bug CLASS closed
**Generic OIDC connection `Sso.oidc`** (shipped): `Sso.oidc "<issuer>" clientId
secret` builds a connection for any spec-compliant OIDC issuer (self-hosted
Keycloak/dex, Okta, Auth0, single-tenant Entra), discovered at runtime. This was
the prerequisite that unblocked any LOCAL e2e (the baked providers hardcode
real-world issuers and can't point at a test IdP). The unbacked `Entra` provider
ctor (it needs a tenant `Sso.defaults` can't carry) was dropped — single-tenant
Entra is now `Sso.oidc` with the concrete tenant issuer. 41 `test_sso_surface`
cases green; seam/docs tests updated.

**Nix e2e harness** `e2e/sso/` (`nix run .#sso-e2e` / `bash e2e/sso/run.sh`):
boots **real dex** over loopback HTTPS (self-signed), compiles+boots the Tesl
backend (`Sso.oidc` against dex, loopback TLS dev escape), a static sandbox
frontend, and a Playwright headless-browser spec. A `SSO_E2E_SMOKE=1` mode drives
the discovery+authorize half with curl.

**The full headless-browser e2e PASSES against real dex** (verified on a WSL2 Nix
sandbox, Chromium via `playwright-driver.browsers`): a real browser clicks "Log
in with dex" → dex's login form (`alice@example.com`) → callback → the runtime's
code exchange + RS256 JWKS signature verify + userinfo → `__Host-session` cookie
(Secure + HttpOnly) → back to `/` → `/me` shows the subject; plus the negative
(`/me` → 401). First time the flow ran against a real IdP through a browser; it
surfaced three bugs (below) before going green. The Playwright config launches
the Nix chromium directly via `executablePath` (project-o's approach) to sidestep
the runner/bundle revision coupling, `--no-sandbox` for the WSL sandbox.

**Three bugs found — all instances of ONE class, now closed systemically.**
The class: *the SSO emit↔runtime glue was only ever validated by compile-time
checks (`--check`, `raco make`) and runtime STUB tests that bypass the emitted
wiring — never by executing a compiled Tesl program through the real
serve/handler path.* `raco make` compiles but does not instantiate/run handlers.
- **Registry key symbol/string mismatch.** The emit registers SSO routes /
  listenAddress under a STRING server name; `build-server-spec` stores the name
  as a SYMBOL and `serve` looked it up by symbol → silent miss → routes never
  mounted (SPA fallback). `sso-web-test` missed it because it calls
  `handle-sso-request` directly, bypassing `serve`'s registry lookup. Fixed by
  normalizing the key (`sso-registry-key`) on both the register and lookup sides
  of both registries.
- **Opaque non-newtype stdlib types had no runtime predicate.** The `define/pow`
  return check is FAIL-CLOSED: a type whose name resolves to no runtime predicate
  is rejected. `Secret`/`JwtToken`/… are `define-newtype`s that AUTO-register one;
  the SSO types (`SsoConnection`/`SsoIdentity`/`SsoSubjectKey`) are the first
  opaque types that are NOT newtypes, so nothing registered a predicate → a
  `-> SsoConnection` fn compiled and `raco make`-loaded but rejected its own
  return at runtime. Fixed by `register-runtime-type/runtime!` for the three in
  `tesl/sso.rkt`.
- **`Secret` newtype reaching `string-append`.** `basic-auth`
  (client_secret_basic) did `(string-append client-id ":" client-secret)`, but
  `client-secret` arrives as a `Secret` newtype-value (from `requireSecret`), not
  a raw string → contract violation → callback 500. Would have hit `Sso.defaults`
  (github/google) too; the stub tests pass a plain string, so it only showed with
  a REAL secret. Fixed by unwrapping the `Secret` at the HTTP boundary ONLY (the
  connection hash keeps the redaction-protected `Secret` everywhere else).

Also: the callback wrapped its work in a `with-handlers` that **silently
swallowed** the exception — a fail-closed flow with no server-side diagnostic.
Fixed to log the real reason/exn-message to the handler error port (client still
gets the fixed page; nothing leaks), which is what let each bug be diagnosed.

**Systemic closure (not whack-a-mole).**
- `tests/opaque-type-registration-test.rkt` (new, in `ci.sh` RKT_SUITES) pins the
  invariant: every opaque/nominal stdlib type usable in a checked position must
  resolve a runtime predicate. It would have failed the moment the SSO types were
  added, and fails for any future non-newtype opaque type — closing that class.
- The registry-key class is closed by normalizing the key at the boundary (both
  registries) rather than per-call; and the deeper "compiled program never
  executed through serve" gap is closed by the e2e harness itself, which is the
  standing guard that a real request traverses the real emit→serve→handler path.

### Item A / Phase A / −1.5 — NOT DONE
The authenticating-proxy pattern docs + the compile-time header-trust discharge
(`Proxy.verifyBinding` witness, needs Phase 3 surface); the CSRF no-mutating-GET
linter (`Sec-Fetch-Site` runtime refusal landed conceptually with Phase −2).

## Bottom line
The full SSO **runtime** is implemented and tested (Phases −2..2.5: TLS peer
auth, JWT decode, header baseline, session-control runtime halves, SSRF core, the
OIDC + plain-OAuth2 flow, RS256/ES256 signature verification), plus the Phase 5
adversarial suite. The **compiler surface** (Phase 3) is now under way and no
longer entirely behind the language surface: the `Tesl.Sso` stdlib module
(`SsoConnection`/`SsoSubjectKey`, `Sso.defaults`/`Sso.keyText`) and the first
`server`-block clause (`sessionPolicy`) are landed end-to-end and green.

Remaining: the rest of the Phase 3 server clauses (the flagship `sso` clause,
`publicOrigin`, `ssoSessionKey`/`ssoPreviousKey`, `sessionRevoked`,
`listenAddress`, `loginMethods`) which expose the built runtime to `.tesl`
authors, then Phase 4/5 (docs/template/lesson and the real-IdP + headless-browser
+ OIDC-conformance exit). Per the spec's own rule, this is progress toward a
gold-standard SSO **flow**; it is not yet a shipped gold-standard SSO feature.

## Close-out batches (executing plan e46f4c04)

### Batch A1 — surface rename (OQ13) — DONE
Renamed the two server-block clause keywords `ssoSessionKey` → `sessionKey`
and `ssoPreviousKey` → `sessionPreviousKey` (the `sso`-prefix was redundant
inside an `sso` server; SSO still *requires* `sessionKey`, like `publicOrigin`).
Surface-only: internal AST fields (`sso_session_key_env`/`sso_previous_key_env`)
and the env-var VALUE strings (e.g. `SESSION_KEY`) are unchanged, so emitted
`.rkt` is byte-identical (lesson78 snapshot verified identical). Touched
`parser.ml`, `validation_structural.ml`, comments in `emit_racket.ml`/`ast.ml`,
`example/sso-demo.tesl`, `example/learn/lesson78-sso.tesl`, `e2e/sso/backend.tesl`,
`LANGUAGE-SPEC.md` §23, `manual/sso.md`, `test_sso_surface.ml`,
`test_sso_adversarial.ml`; `embedded_docs.ml` regenerated via promote.
Green: `dune build`, `test_sso_surface` (41) + `test_sso_adversarial` (8),
all three example type-checks, lesson78 snapshot identical, `gen-lesson-index
--check`, `gen-stdlib-rkt --check`, `opaque-type-registration-test` (2),
`bash -n ci.sh`.

### Batch A2 — publicOrigin inline OR fromEnv (OQ11) — DONE
`publicOrigin` now accepts either an inline literal
(`publicOrigin "https://app.example.com"`) or a 12-factor env read
(`publicOrigin fromEnv "PUBLIC_ORIGIN"`).  Both resolve to the SAME validated
origin; the env form is read + validated ONCE at boot (fail-closed on a
missing/invalid value), NEVER from a request.  A single validity rule (absolute
`https`, or `http` only for a loopback host; no path beyond `/`, no query, no
fragment) is enforced at compile time for the literal (`valid_public_origin` in
`validation_structural.ml`) and at boot for the env form (`valid-public-origin?`
in `dsl/web.rkt`) — the two mirror each other.  New AST `public_origin_src`
(`POLiteral`/`POEnv`).  Emit is byte-identical for the literal
(lesson78 snapshot verified); the env form emits
`(current-public-origin (public-origin-from-env "VAR"))` at boot and threads
`(current-public-origin)` into the sso-route.  Docs updated
(`LANGUAGE-SPEC.md` §23 grammar, `manual/sso.md`).
Green: `dune build`, `test_sso_surface` (44, +3), `test_sso_adversarial` (8),
all SSO Racket suites incl. `sso-web` (8, +2 covering the rule + boot read),
lesson78 snapshot identical, `gen-lesson-index`/`gen-stdlib` `--check`,
`bash -n ci.sh`.

## Downstream security issues #47–#50 (folded into the close-out plan)
The plan (e46f4c04) was revised to incorporate four downstream issues from a team
building a third-party app ecosystem on Tesl. #47 TLS is already fixed; #48 reframes
SSRF onto HttpClient (default-on); #49 is a new base64 Signature transport; #50
refines per-route framing (C) and a machine-credential loginMethods member (D).

### Issue #47 — TLS peer verification — ALREADY FIXED; regression strengthened
TLS chain+hostname verification landed in Phase −1 (`ssl-secure-client-context` in
`tesl/http-client.rkt`, with a single loopback-only, env-gated dev escape; a ratchet
test forbids any new bare `#:ssl? #t`). The existing `tests/http-tls-tests.rkt`
already proved self-signed refusal hermetically. Added the issue's SECOND scenario —
a chain-valid cert served for the WRONG host — as a hermetic test: a self-signed
`wrong.example` cert is trusted as a root (removing chain as a variable), then a
connect to `127.0.0.1` must be refused on hostname. Suite now 6 tests (was 5), green,
and already wired into `ci.sh`. Issue #47 can be closed.

### Issue #48 — SSRF containment moved onto Tesl.HttpClient (default-on) — DONE (core)
Containment now lives on the client (`tesl/http-client.rkt`), so EVERY outbound
call is protected, not just SSO. `ssrf-pinned-http-conn-open` resolves+connects
atomically via `tcp-connect` (one resolution → no check-then-connect rebind gap),
reads the peer address it actually reached with `tcp-addresses`, and judges it with
the existing `dsl/private/ssrf-guard.rkt` classifier BEFORE any TLS handshake or
request byte. Cloud metadata (169.254/16), RFC1918, CGNAT (100.64/10), unique-local,
link-local and 0.0.0.0/8 are refused always; public is allowed; loopback is allowed
in a non-deployed build and denied under `TESL_DEPLOYED` unless
`TESL_HTTP_ALLOW_LOOPBACK_EGRESS` opts in (the issue's "dev needs loopback" escape).
For https the pinned ports are TLS-wrapped with the SAME verifying context +
`#:hostname` as the direct path (`ports->ssl-ports` does `SSL_set1_host`), so #47's
chain+hostname verification is preserved — confirmed by the TLS suite still green
through the new path. Body-size + wall-clock caps already existed; `net/http-client`
does not auto-follow redirects (a 30x is returned, and any app re-request re-enters
the guard), so per-hop checking is inherent. Both the request and streaming-POST
connect sites are pinned; dead `tls-mode` removed. New suite `tests/http-ssrf-tests.rkt`
(4 tests: the pure decision matrix + end-to-end deploy-gated loopback refuse/allow),
wired into `ci.sh`. Regression-checked green: http-tls (6), http-timeout (9),
httpclient (21+9), http-stub (18), and all SSO suites (stub path unaffected).
Deferred (optional polish): a runtime-minted `SafeEgress` witness to make URL
validation visible in a signature — the default-on containment already satisfies the
issue's core ask ("safe egress a property of HttpClient") without app changes.

### Issue #49 — base64 Signature transport — DONE
Added `Crypto.signatureBase64 : Signature -> String` and
`Crypto.signatureFromBase64 : String -> Signature`, the base64 transport pair
Standard Webhooks needs (`webhook-signature: v1,<base64>`). Pure transport
encoding of an already-public MAC tag — no new cryptographic decision, so it
respects §21.7 (algorithm stays HMAC-SHA256, invisible to the caller). Runtime
in `tesl/crypto.rkt` (re-encodes the same MAC bytes the hex pair uses);
registered in `type_system.ml` (both the signature table and the `Tesl.Crypto`
module name list); the SEC004 timing-unsafe-MAC lint now also flags comparing a
`signatureBase64` result; docs in `stdlib_docs_entries.ml` (→ `tesl help`) and
the `LANGUAGE-SPEC.md` §Crypto table. Green: the issue's repro typechecks; a
base64 round-trip test (crypto-runtime-tests, now 46) verifies + proves the same
MAC bytes as hex + the 44-char shape; SEC004 fires on a base64 compare; and
test_security_lints / test_stdlib_{consistency,docs,signature_coverage,runtime_binding}
/ test_config_only_type_positions all green. Issue #49 can be closed.

### Issue #51 — client address + trusted-proxy edge declaration — PLANNED (folded in)
`HttpRequest` exposes no client address and there is no trusted-proxy concept,
yet the reference cluster runs nginx in front — so nothing downstream can
attribute a request. This is the single missing declaration several plan items
reduce to (auth-event `peerAddress` Risk 21/65, `Host` validation, Sec-Fetch-Site,
Item A discharge, and deferred rate limiting). Folded into the plan: a
server-level edge declaration (trusted proxy addresses / hop count; whether
`X-Forwarded-For`/`Forwarded` may be believed) + one derived value
`request.clientAddress` computed as: no declaration ⇒ socket peer; declaration ⇒
the rightmost untrusted hop; refuse (not guess) when the header disagrees. NOT
TLS termination (explicitly declined, consistent with Crypto's no-key-custody
stance). Slots in Batch B/D as their shared foundation.


### Issue #51 — request.clientAddress + trustedProxies edge declaration — DONE
`HttpRequest` now exposes `request.clientAddress` (a `String`), gated by a new
server-level `trustedProxies [ "10.0.0.1", ... ]` edge declaration. Computed
fail-closed: no declaration => the socket peer (X-Forwarded-For ignored,
unspoofable); declaration => the RIGHTMOST-UNTRUSTED hop of [XFF..., socket-peer]
(walk from the right, skip declared proxies, stop at the first non-proxy). A
prepended/spoofed XFF entry sits to the LEFT of the real chain and is never
reached; a chain with no untrusted hop is refused, not guessed. NOT TLS
termination (explicitly declined by the issue).
Compiler surface: AST `server_form.trusted_proxies`; parser `trustedProxies [..]`
clause; validation (non-empty entries); emit `(void (current-trusted-proxies
(list ...)))` (byte-identical when absent — lesson78 snapshot verified);
`checker.ml` whitelists the `clientAddress` field (permissive type, like
headers/cookies). Runtime `dsl/web.rkt`: `current-trusted-proxies` parameter +
`client-address-of` (from socket peer via `request-client-ip` + XFF) wired into
the HttpRequest field-access registry. Docs: LANGUAGE-SPEC §Http request fields +
§23 grammar, `manual/sso.md`, stdlib HttpRequest field list.
Green: `test_sso_surface` (46, +2 trustedProxies emit tests), new
`tests/http-client-address-test.rkt` (5: no-decl peer, single/multi proxy,
spoof-resistance, fail-closed refuse) wired to CI, `request.clientAddress`
typechecks, lesson78 snapshot identical, sso-web (8) / response-security-headers
(8) / web-test (102) / test_stdlib_docs (10) green, gen-lesson-index +
gen-stdlib `--check` pass. Note: this is the shared foundation the auth-event log
(Risk 21/65), Host/Sec-Fetch reasoning, Item A discharge and deferred rate
limiting build on. Follow-up (optional): a fact-carrying ClientAddress witness so
"we know the client" is visible in a signature.

## Batch B (security) — in progress
### Sec-Fetch-Site cross-site refusal (Risk 49/61) — DONE
`dispatch-request` (dsl/web.rkt) now refuses a STATE-CHANGING request
(POST/PUT/DELETE/PATCH) that the browser labels an explicit cross-site fetch
(`Sec-Fetch-Site: cross-site`) with a 403 — a token-free, per-route-free CSRF
defence. An ABSENT header allows (old browsers / non-browser clients) and only
the literal `cross-site` is refused (`same-origin`/`same-site`/`none` pass);
safe methods (GET/HEAD/OPTIONS) are never refused. Near-zero blast radius (only
mutating requests carrying the explicit header). Tests: web-test (now 105, +3:
refuse cross-site POST, allow same-origin POST, don't refuse a cross-site GET);
sso-web/response-security-headers/sse-capabilities all still green.

### GET-write linter (Risk 39) — IN PROGRESS
Next B item: a lint flagging a write-capable operation reachable from a handler
bound to a GET (or other safe-method) endpoint — a GET must be side-effect-free
(safe/idempotent per HTTP semantics; also the target of the Sec-Fetch-Site and
CSRF reasoning, which only guards mutating methods).

### GET-write linter (Risk 39) — DONE (SEC005)
New security lint SEC005: a state-changing capability (`dbWrite`/`queueWrite`)
reachable from a handler bound to a GET endpoint. A GET must be safe/idempotent
(HTTP semantics), and it is the one method the Sec-Fetch-Site cross-site refusal
does NOT guard, so a write behind a GET is reachable cross-site.
PRECISION (the governing rule — a clean corpus must be COMPLETELY silent): the
lint keys on the handler body's ACTUAL write usage via
`Validation_common.collect_needed_capabilities` (+ the capability `implies`
closure), NOT on the handler's declared `requires`. This matters — a first draft
using declared caps false-positived on `lesson74`'s `exportDocuments`, a GET that
declares the coarse `documentStore` capability (`implies dbWrite`) but only
`select`s. Server bindings pair with non-SSE endpoints POSITIONALLY (the api
endpoint `name` is synthetic), mirroring the checker.
Registered in `error_codes.ml` (SEC005, deep-linked to best-practices#security)
and `linter.ml` (`sec005_get_write` in `lint_security`). Tests in
`test_security_lints.ml`: positive (a DB insert behind a GET fires), two honest
negatives (same write on POST is silent; a read-only GET is silent), plus the
shipped-corpus-silent precision test now green (7 tests). `test_linter` (14) /
`test_linter_w080` (13) and the "every SEC code explains + deep-links" + "`tesl
help codes`" index tests all green.

### Auth-event log (Risk 21/65) — DONE
Added `tesl-log-auth-event!` to `tesl/logging.rkt` (category "AUTH", emitted via
the existing `tesl-emit!` → stderr under TESL_VERBOSE + the OTLP telemetry sink).
Wired into `dsl/web.rkt` `handle-sso-callback` at all three outcomes: SUCCESS
(after minting) and both DENIAL paths (missing code/cookie; a rejected exchange).
The event carries provenance — outcome, provider segment, issuer, subject, tenant
— plus the #51 `request.clientAddress`, and NEVER a token, authorization code,
state or PKCE verifier (those are the credential). Emission is gated on
`tesl-log-active?`, so it is zero-overhead and silent when neither verbose nor a
sink is set (no interference with other tests). Tests: `sso-web-test` (now 10,
+2) installs a capturing telemetry sink and asserts a full callback emits exactly
one AUTH success event (outcome/provider/subject correct) that does NOT contain
the code, the session token, or the oauth cookie; and that a no-code/cookie
callback emits an AUTH denied event. Green: sso-web (10), sso-flow (6),
sso-runtime (17), sso-adversarial (20), web-test (105) — no regressions.

## Batch B remaining
Host validation (Risk 50/60, needs a probe-path clause + publicOrigin gating),
JWKS unknown-kid rate-limited refetch (Risk 27), userinfo sub cross-check
(Risk 52, likely N/A by design since the OIDC path is id_token-authoritative and
does not consult userinfo), GitHub /user/emails verified-email (Risk 2), and
IDNA/case domain normalization (Risk 62; case+trim already done in normalize-domain).

### Domain normalization (Risk 62) — IN PROGRESS
Next: harden `normalize-domain` (case+trim already done) against the domain-allowlist bypass class — trailing FQDN dot, and confirm the fail-closed behavior for non-ASCII/homograph domains against an ASCII allowlist.

### Domain normalization (Risk 62) — DONE
`normalize-domain` (dsl/sso.rkt) now canonicalises the FQDN root — strips a
trailing dot so `example.com.` ≡ `example.com` — on top of the existing
case-fold + trim. Both the incoming domain and every allow-list entry pass
through it, so the homoglyph class stays fail-closed (a Cyrillic-`а` label is a
DIFFERENT domain and is refused against an ASCII allow-list). Full IDNA/punycode
A-label↔U-label folding remains a documented gap (security direction is safe;
only a legitimate IDN in the other form would be a false negative). Tests added
to `sso-runtime-test` (17): trailing-dot equivalence on either side, and a
homoglyph (U+0430) refusal, for both `allowedEmailDomains` and
`allowedHostedDomains`. sso-adversarial (20) still green.

### userinfo sub cross-check (Risk 52) — DONE (N/A by design, documented)
Verified `finish-oidc` fetches ONLY the JWKS (for signature verification) and
never the UserInfo endpoint — subject/email/claims all come from the
signature-verified id_token. So OIDC Core §5.3.2 (UserInfo `sub` must equal
id_token `sub`) has no second `sub` to disagree with; the plain-OAuth2 path uses
UserInfo but has no id_token. Documented at the `finish-oidc` call site with a
guard instruction: if a UserInfo fetch is ever added there, it must assert the
`sub` match. No behavior change; sso.rkt compiles.

### GitHub /user/emails verified email (Risk 2) — DONE
`finish-oauth2` (dsl/sso.rkt) now makes the documented second call to a
connection's `emails-url` (already configured for GitHub in `sso-defaults`) via
new `verified-primary-email`: it fetches the emails array with the access token
and takes the PRIMARY + VERIFIED entry as the verified email. That is the only
address domain restriction (VerifiedEmail-only) may trust — previously GitHub's
`/user` email was public/unverified, so `allowedEmailDomains` could never accept
a GitHub identity. No primary+verified row ⇒ #f, falling back to the unverified
userinfo email rather than fabricating verification (fail-closed). Other
providers are unchanged (no `emails-url` ⇒ the call is skipped). Tests in
`sso-flow-test` (now 8, +2): the emails-url call selects the primary+verified
address (not the public /user email, not a verified-but-secondary, not an
unverified-primary); and `allowedEmailDomains` now ACCEPTS that verified primary.
All SSO suites green (flow 8, runtime 17, web 10, adversarial 20, stdlib 5).

## Batch B remaining
Host validation (Risk 50/60 — needs a probe-path clause + publicOrigin gating)
and JWKS unknown-kid rate-limited refetch (Risk 27).

### JWKS unknown-kid refetch (Risk 27) — IN PROGRESS
Investigating: finish-oidc currently fetches JWKS fresh per callback (no cache, so rotation already works but every login hits the JWKS endpoint). Assess a bounded TTL cache + single rate-limited refetch on unknown kid.

### JWKS unknown-kid rate-limited refetch (Risk 27) — DONE
Added a bounded, TTL'd JWKS cache to `dsl/sso.rkt` keyed by jwks_uri
(`jwks-for`/`jwks-entry`/`jwks-cache`). `finish-oidc` now verifies against the
cache instead of an unconditional per-callback fetch: a fresh entry that already
has the token's `kid` uses no network (removes the login-time IdP-fetch
amplification vector); an absent/expired entry, or an unknown `kid` once the
per-url rate window (60s) has elapsed, triggers exactly ONE refetch (TTL 300s);
an unknown `kid` WITHIN the window returns the cached set so the verifier fails
"no key matches kid" fail-closed with NO extra fetch — an attacker sending random
kids cannot amplify. Cache is size-bounded (64 urls) so it can't be a memory
primitive. The token `kid` is read from the JWS header (`id-token-kid`). Rotation
still propagates (post-window refetch / TTL expiry). Exposed `jwks-cache-reset!`
+ `jwks-for` as a test seam. Test in `sso-flow-test` (now 9, +1): fetch-once
cache hit, rate-limited unknown-kid (no second fetch), and a post-window refetch.
No regressions: sso-flow (9), sso-runtime (17), sso-web (10), sso-adversarial (20).

## Batch B — only Host validation remains
Host validation (Risk 50/60): validate the `Host` header against `publicOrigin`
with exactly one declared health-probe path exempt. Needs a new server clause
(the probe path) + `dispatch-request` gating (only when publicOrigin is set, so
zero blast radius on non-SSO servers / unit tests).

### Host validation (Risk 50/60) — DONE
`dispatch-request` (dsl/web.rkt) now validates the request `Host` against the
configured public origin: when `publicOrigin` is set (clause or
`TESL_PUBLIC_ORIGIN`), the `Host` header's host must equal the origin's host
(case-insensitive, port-stripped via `host-of`); a mismatch or absent Host is a
421. This blocks a Host-header attack from making the app mint links/cookies for
another origin. GATED on publicOrigin being set, so a server without one — and
every existing unit test — is unaffected (zero blast radius). New server clause
`healthProbePath "/healthz"` declares exactly ONE path exempt (a load balancer
probes host-blind); full surface: AST `server_form.health_probe_path`, parser
clause, validation (absolute path), emit `(void (current-health-probe-path ..))`,
runtime `current-health-probe-path` parameter. Emit byte-identical when the
clause is absent (lesson78 snapshot verified identical). Docs: LANGUAGE-SPEC §23
grammar + manual/sso.md. Tests: `test_sso_surface` (47, +1 emit), `web-test`
(110, +5: matching Host passes, mismatch/absent → 421, probe-path exempt,
no-publicOrigin unaffected). Green with sso-web (10), response-security-headers
(8), and the lint/docs/config compiler suites.

## Batch B (security) — COMPLETE
All items landed + green: SSRF egress on HttpClient (#48), auth-event log
(21/65), Host validation (50/60), Sec-Fetch-Site refusal (49/61), GET-write lint
SEC005 (39), JWKS unknown-kid refetch (27), userinfo sub (52, N/A by design),
GitHub verified email (2), domain normalization (62). Next: Batch C
(typed-identity + domain-restriction surface + per-route CSP/framing, #50.1),
then Batch D (Item A + machine-credential discharge #50.2 + Password witness
gate). The spec file stays in roadmap/next/ pending the human gates E (OIDC
conformance run + external security review).

## Batch C (typed identity + domain-restriction surface + per-route CSP/framing) — IN PROGRESS
Starting with the typed-identity surface: expose EmailClaim ADT / claims / tenant on SsoIdentity (runtime pure layer already computes them).

### C.2 Domain-restriction connection surface (Risk 17/53) — DONE
Surfaced the three connection builders that were already enforced by the runtime
(Batch B hardened the matching) but not settable from Tesl:
`Sso.allowedEmailDomains`, `Sso.allowedHostedDomains`, `Sso.allowedTenants`, each
`SsoConnection -> List String -> SsoConnection` (a pure record-update). The
runtime `build-identity` already checks these at the callback BEFORE onIdentity,
VerifiedEmail-only. Registered across `type_system.ml` (signatures + the Tesl.Sso
module row), `stdlib_docs_entries.ml` (docs → `tesl help`), and `tesl/sso.rkt`
(defs, `hash-set` the `allowed-*` fields). Green: a program using the builders
typechecks; the stdlib consistency suites (signature-coverage/docs/runtime-
binding/consistency) all pass; and `sso-flow-test` (now 10, +1) proves the
`Sso.allowedEmailDomains` builder is enforced END-TO-END (a verified primary in
the allow-list is accepted; out of it is refused with a `domain` reason).

## Batch C remaining
- C.1 typed-identity surface: expose `EmailClaim` ADT (VerifiedEmail|Unverified
  Email|NoEmail), `claims: Dict String Json`, and `tenant` on `SsoIdentity` (the
  runtime pure layer already computes these) — the largest piece, since a
  matchable ADT must be surfaced (type + constructors + emit lowering).
- C.3 per-route / per-static-mount CSP + framing (#50.1): default `default-src
  'self'` + frame-deny, overridable per route so an extension host can serve
  bundle routes `frame-ancestors <host>` while product pages stay `'none'`.

### C.1 Typed-identity accessors (Risk 2/3/18/32, OQ12) — DONE (safe Maybe surface; ADT deferred)
Exposed three `SsoIdentity` accessors on the Tesl surface (`type_system.ml`
signatures + Tesl.Sso module row; `stdlib_docs_entries.ml`; `tesl/sso.rkt`):
- `Sso.email : SsoIdentity -> Maybe String` — the VERIFIED address ONLY
  (Something iff the provider verified it; Nothing for unverified/absent). There
  is deliberately NO way to read an unverified email, so `onIdentity` cannot
  trust one for an identity decision — the strongest form of Risk 2/3, closed by
  construction rather than by a distinction the caller must remember.
- `Sso.tenant : SsoIdentity -> Maybe String` — the OIDC `tid` / Google `hd`
  (Risk 18/32 multi-tenant), pairs with `Sso.allowedTenants`.
- `Sso.claim : SsoIdentity -> String -> Maybe String` — any single string claim
  by name.
Uses the existing `Maybe` machinery (Something/Nothing from dsl/types.rkt), so no
new pattern-matcher/emit integration. Green: the stdlib consistency suites all
pass; a program `case Sso.email id of Something e -> … Nothing -> …` typechecks;
`sso-runtime-test` (now 18, +1) verifies verified-only email, tenant, and claim.
DEFERRED (documented): the full 3-way `EmailClaim` ADT (VerifiedEmail|Unverified
Email|NoEmail) and `claims: Dict String Json` — a matchable baked ADT + a
Dict/Json surface is a larger, riskier integration (the constructor-scope
machinery + emit lowering), and the SECURITY property (never trust an unverified
email) is already met by the verified-only Maybe.

## Batch C remaining
Only C.3: per-route / per-static-mount CSP + framing (#50.1).

### C.3 per-route/per-mount CSP + framing (#50.1) — IN PROGRESS
Investigating the current CSP/framing runtime (html-csp-value / security-response-headers / try-serve-static) to design a per-route/per-static-mount policy with an OQ17 default of default-src 'self' + frame-deny.

### C.3 CSP / framing surface (#50.1, OQ17) — DONE (config surface + per-response; per-static-mount deferred)
Two findings shaped this: (1) `add-security-headers` (dsl/web.rkt) ALREADY
preserves a producer-set `Content-Security-Policy`/`X-Frame-Options`, so a handler
can already set a PER-ROUTE CSP that wins — the per-route form #50.1 wants exists
for handler responses; (2) the missing pieces were a typed program-stated default
(OQ17) and per-STATIC-mount framing (which #50.1 notes the team has a workaround
for — bundles from a separate static server).
Landed the config surface: a `contentSecurityPolicy "<policy>"` server clause
setting the HTML-response default CSP. Precedence in `html-csp-value`: clause >
`TESL_CSP` env > the safe non-breaking default `frame-ancestors 'none'` (kept as
default deliberately — `default-src 'self'` can break an SPA's inline scripts, so
it is opt-in via the clause, not forced). Full surface: runtime
`current-content-security-policy` parameter; AST `server_form.content_security_
policy`; parser clause; emit `(void (current-content-security-policy ..))`
(byte-identical when absent — lesson78 snapshot verified). Docs: LANGUAGE-SPEC §23
grammar + manual/sso.md (documents the per-response override as the per-route
form). Green: `test_sso_surface` (48, +1 emit), `response-security-headers-test`
(10, +2: clause sets + precedes env; a handler-set CSP still wins per response
without duplication), web-test (110) / sso-web (10), gen-lesson-index/gen-stdlib
--check, `bash -n ci.sh`.
DEFERRED (documented): per-STATIC-mount framing (a static bundle mount framable
by `frame-ancestors <host>` with X-Frame-Options dropped for that mount) — needs
request-path→policy threading into the static-serving header path; the team's
stated workaround (serve bundles from a separate static server) covers it.

## Batch C — COMPLETE
C.1 typed-identity accessors, C.2 domain-restriction connection surface, C.3
CSP/framing config surface all landed + green. Remaining: Batch D (Item A +
machine-credential discharge #50.2 + Password witness gate). File stays in
roadmap/next/ pending human gates E (OIDC conformance + external review).

## Batch D (Item A + machine-credential discharge + Password witness gate) — IN PROGRESS
Investigating the current loginMethods / session-minting enforcement to scope a bounded first sub-item (the Machine/ServiceCredential loginMethods member, #50.2).

### D.1 Machine loginMethods member (#50.2) — DONE
Added `Machine` to the closed `loginMethods` keyword set (`Sso | Password via
<fn> | Proxy | Machine`) in `validation_structural.ml`. It licenses the app-side
session-minting chokepoint (`Http.setSessionCookie` + the password/signature
check) the SAME way `Password` does — for a per-installation MACHINE credential
(a bearer token the app verifies against stored material), which is neither Sso,
Password, nor Proxy. The fail-closed refusal now fires only when NEITHER Password
NOR Machine is present (`licenses_minting`). The parser already accepts any
`UIDENT` member, so no parser change; no emit change (compile-time gate only —
lesson78 snapshot verified identical). Docs: LANGUAGE-SPEC §23 grammar
(`<method>` adds `Machine`) + manual/sso.md. Tests: `test_sso_surface` (49, +1 —
`loginMethods [Sso, Machine]` compiles WITH an `Http.setSessionCookie` site,
whereas `[Sso]` still refuses it); `test_sso_adversarial` (8) still green;
gen-lesson-index/gen-stdlib `--check` pass.

## Batch D remaining (design-heaviest — proof-kernel work)
- Item A: `Proxy.verifyBinding` runtime returning KERNEL-MINTED `ProxyBound`
  evidence + the header-trust `auth` discharge, with the #50.2 dataflow
  discriminator (a mint that compares a header against stored material —
  checkSignature/checkPassword/hashed-token lookup — needs NO topology claim;
  only a bare `X-Auth-User`-style assertion needs the loopback/proxy-witness/ack
  discharge).  `Machine` above is the surface member this discriminator will
  attribute the "verified-against-stored-material" mint to.
- The mixed-mode Password witness gate: `Auth.passwordLogin` returning kernel
  evidence (not Bool), per-site setSessionCookie/auth-block method attribution,
  and set-side (reset/signup) gating (OQ15/18).
These touch the GDP proof kernel + the checker's auth/evidence machinery and are
best done as a focused effort; the surface member (D.1) is the tractable piece
that unblocks the extension-host team's per-installation-token auth today.

### D.2 Authenticating-proxy pattern docs (Item A) — DONE
Added a "Behind a reverse proxy (the authenticating-proxy pattern)" section to
`manual/sso.md` (auto-embedded → `tesl help manual sso`). It ties together the
pieces this effort built into the coherent operator pattern: `listenAddress
Loopback` (the topology half, enforced at boot), `trustedProxies` →
`request.clientAddress` (#51), `publicOrigin` + Host validation + `healthProbePath`
(Risk 50/60), and a "Trusting a header for identity" subsection that states the
#50.2 discriminator in prose: a header that IS the assertion (`X-Auth-User`)
needs the loopback topology claim, whereas a header VERIFIED against stored
material (bearer→`Crypto.checkSignature`/`checkPassword`/hashed-token lookup) needs
NO topology claim and is declared `loginMethods [Sso, Machine]`. Also extended the
`loginMethods` paragraph to explain `Password via <fn>` vs `Machine`. Green:
build clean; `test_stdlib_docs` (10); gen-lesson-index/gen-stdlib `--check`;
`bash -n ci.sh`; `tesl help manual sso` renders the new section.

Item A status: the CSRF/GET-write linter (SEC005), the `Machine` loginMethods
member (D.1), `listenAddress` (topology discharge), and the pattern docs (D.2)
are DONE. Remaining Item A: the COMPILE-TIME enforcement — `Proxy.verifyBinding`
returning kernel-minted `ProxyBound` evidence and the checker's header-trust
`auth` discharge with the dataflow discriminator. Both integrate a new fact into
the GDP proof kernel (the check→fact machinery, separate from type signatures and
data tables — confirmed by inspection), so they are soundness-critical and
scheduled as focused proof-kernel work, together with the mixed-mode Password
witness gate (`Auth.passwordLogin` → kernel evidence, OQ15/18).

### D.3 Kernel-minted ProxyBound evidence — Proxy.verifyBinding (Item A) — DONE
Integrated a NEW fact into the GDP proof kernel, following the
`Crypto.checkSignature`→`Authentic` precedent exactly (data-driven, not new
kernel surgery):
- `Validation_common.stdlib_func_infos`: a check-shaped entry
  `Proxy.verifyBinding : (config: Secret) (presented: String)` with
  `fi_return = RetAttached { ProxyBound presented }` — so `check
  Proxy.verifyBinding c p` mints `ProxyBound p`.
- `proof_checker.ml`: `ProxyBound` added to the stdlib-owned predicate list
  (minted ONLY by its check fn; deliberately NOT in `proof_discharge`'s
  `stdlib_auto_preds`, so a hand-written `::: ProxyBound` is refused — fail-closed).
- `type_system.ml`: the `Proxy.verifyBinding` signature, a new `Tesl.Proxy`
  module export row (`ProxyBound` + `Proxy.verifyBinding`), and `Tesl.Proxy` in
  `tesl_known_module_names`.
- `emit_racket.ml`: `Tesl.Proxy` → `tesl/proxy.rkt` module-file map.
- Runtime `tesl/proxy.rkt`: `Proxy.verifyBinding` constant-time compares the
  presented header value against the configured `Secret` (reusing crypto's
  `constant-time-bytes=?` + `attach-proof-to`), returns `check-ok` minting
  `ProxyBound` on a match and `check-fail` (401) on a mismatch; `ProxyBound` is a
  proof-layer symbol (erased at runtime, like Crypto's `Authentic`). Exported
  `attach-proof-to`/`constant-time-bytes=?` from `tesl/crypto.rkt` for reuse.
- Docs: `stdlib_docs_entries.ml` (→ `tesl help`) for both names; `manual/sso.md`
  "Trusting a header for identity" now points at `Proxy.verifyBinding` as the way
  to turn a topology-assumed header into unforgeable verified-against-stored-material
  evidence.
SOUNDNESS verified end-to-end: `check Proxy.verifyBinding` yields a usable
`ProxyBound` (POSITIVE compiles); a plain fn declaring `::: ProxyBound` is refused
(fact ownership); demanding `ProxyBound` WITHOUT the check is refused (does not
statically satisfy). Tests: `test_sso_adversarial` (11, +3 compile-time
positive/forge/skip), new `tests/proxy-runtime-test.rkt` (3, mint-on-match /
fail-on-mismatch / empty) wired into `ci.sh`. Regression green: sso-runtime (18),
sso-flow (10), sso-web (10), sso-adversarial-rkt (20), crypto-runtime (46); the
stdlib consistency + docs + runtime-binding suites; lesson78 snapshot identical;
gen-lesson-index/gen-stdlib `--check`; `bash -n ci.sh`.

## Batch D remaining
- The header-trust `auth` DISCHARGE integration (wiring the ProxyBound witness +
  the loopback `listenAddress` topology claim into the checker's `auth`-block
  discharge decision, with the #50.2 dataflow discriminator) — the evidence
  primitive (D.3) and the surface member `Machine` (D.1) now exist; this is the
  checker rule that consumes them.
- The mixed-mode Password witness gate: `Auth.passwordLogin` → kernel evidence
  (not Bool), per-site setSessionCookie/auth-block method attribution, set-side
  gating (OQ15/18) — the same GDP-kernel + checker-attribution machinery.

### D.3b Worked ProxyBound example (Item A usability) — DONE
Added `example/proxy-binding-demo.tesl` — a shipped, human-readable template for
the authenticating-proxy pattern: `authorizeInternal` runs
`check Proxy.verifyBinding proxySecret presentedBinding` and hands the result to
`internalOnly(bound: String ::: ProxyBound bound)`, which DEMANDS the fact. It
demonstrates in real code that a request which did not pass through the proxy is
a COMPILE error, not a runtime gap. Typechecks (`ok: True`) and emits; it is a
lib-style module (no `main`), which is established precedent among top-level
examples (user-service-api, support-assistant, …) and is auto-compile-checked by
`ci.sh`'s `example/*.tesl` glob.

## Batch D remaining — a precise design plan for the checker-dataflow pieces
These are the hardest, soundness-critical parts; the enabling PRIMITIVES all now
exist (ProxyBound evidence D.3, the `Machine` member D.1, `listenAddress`
Loopback). What remains is the checker RULE that consumes them, which needs sound
dataflow — deferred rather than rushed because an imprecise version is either
unsound (misses a real header-trust) or noisy (violates the "SEC lint silent on
clean code" rule, since a legitimate `establish` reads the session COOKIE that is
verified by JWT.verify → Authentic).

1. Header-trust `auth` discharge (Item A enforcement). Sketch: in the checker,
   for an `auth`/`establish` block that mints an identity fact, run a small
   backward dataflow from the established subject: it is DISCHARGED if the value
   is control-dependent on a fact-producing check (Authentic via JWT.verify /
   checkSignature, PasswordVerified, or ProxyBound) — the "verified against
   stored material" arm; otherwise (the subject traces to a raw `request.headers`
   read) it requires a topology claim: the server declares `listenAddress
   Loopback`, or a written-acknowledgement clause.  Cookies are NOT special-cased
   by name — the discriminator is "did the value pass through a check", which
   makes the session-cookie path pass (it goes through JWT.verify) with no false
   positive.  Reuse `Validation_common.collect_needed_capabilities`'s traversal
   style + the check-shaped registry (already central).
2. Mixed-mode Password witness gate (OQ15/18): make the `Password via <fn>`
   policy return kernel evidence (a fact) instead of `Bool`, and have the
   `Http.setSessionCookie` site DEMAND the matching method fact (Sso callback /
   Password-policy / Machine) — per-site method attribution.  Same GDP-kernel +
   check-shaped machinery as D.3; the hard half is the setSessionCookie-site
   attribution dataflow.

Both should get a focused session; the D.3 evidence work proved the kernel
integration is data-driven and sound, so these are "wire the consumer", not new
kernel surgery.

### D.3c Lesson 79 — authenticating proxy (tutorial-track coverage) — DONE
Added `example/learn/lesson79-authenticating-proxy.tesl` (track=stdlib order=810,
needs=lesson78-sso) teaching the `Proxy.verifyBinding` → `ProxyBound` pattern: the
two ways to trust the edge (topology via `listenAddress Loopback` vs a verified
binding), the #50.2 discriminator, and that `internalOnly(bound ::: ProxyBound)`
makes a proxy-skipping request a COMPILE error. Lib-style module (no `main`, like
lessons 00–08). Committed the `.rkt` snapshot (re-emit canon-identical);
`gen-lesson-index.sh` regenerated `manual/lessons.md` (81 lessons) and `--check`
passes; the lesson appears at order 810 with lesson78-sso as its prerequisite.

Lesson scope decision (in answer to "do the recent changes need lessons?"): the
NEW distinct capability — the Tesl.Proxy GDP pattern — now has a lesson. The rest
of the recent surface is either (a) BEHIND-THE-SCENES runtime hardening with no
author-written surface (SSRF/TLS/Sec-Fetch/Host/auth-log/JWKS/GitHub-emails/domain
normalization) → no lesson, or (b) EXTENSIONS of the existing SSO topic (the new
server clauses trustedProxies/healthProbePath/contentSecurityPolicy, request.
clientAddress, the Sso.* accessors/builders, Crypto.signatureBase64, loginMethods
[Sso, Machine]) already covered by the heavily-expanded `manual/sso.md`, `tesl
help` (stdlib_docs), and LANGUAGE-SPEC §23 — a per-feature lesson would duplicate
those, so they stay in the reference docs rather than the tutorial track.

### D — header-trust discharge: SEC006 advisory lint PROTOTYPED, then BACKED OFF
Attempted the advisory first step toward header-trust `auth` discharge as a
linter WARNING (SEC006): flag an `auth`/`establish` block whose `ok <v> ::: Fact`
value `v` is tainted by a request field (cookies/headers/queryParameters) with no
verifying `check` between, discharged either by a verifying head (JWT.verify /
Crypto.checkSignature / checkPassword / Proxy.verifyBinding — the SEC001 taint
model already clears under these) OR module-wide by `listenAddress Loopback`.

Built green, but a full shipped-corpus sweep produced **27 hits across 13 files**,
and inspection showed the lint is fundamentally too imprecise to ship:
- It fires on the ordinary, CORRECT `establish` idiom — e.g. `lesson66
  parseSearch` minting `ValidSearch` from `req.queryParameters`. Taking untrusted
  input, validating it, and minting a *domain-validation* fact is exactly what
  `establish` is for; there is no crypto `check`, and none is warranted.
- It fires on the tutorial's own canonical teaching `auth` blocks (`lesson15
  cookieAuth`, `human-actions-tests adminAuth`) that intentionally read a
  plaintext cookie as identity for pedagogical simplicity.

The linter cannot tell an authentication fact from a validation fact — fact names
(`Authenticated`, `ValidSearch`) are conventions, not guarantees — so any lint
keyed on "tainted request value flows into `ok … ::: Fact`" hits both. That
violates the governing precision rule (a security lint that fires on clean /
canonical code trains people to ignore the whole category; the corpus must be
COMPLETELY silent, and Tesl has no suppression mechanism), and degrading the
teaching corpus to satisfy the lint is out of scope and wrong.

**Decision:** reverted all SEC006 edits (`compiler/lib/linter.ml`,
`compiler/lib/error_codes.ml`; the test file was never touched). Build clean and
`test_security_lints` fully green again, incl. the corpus-silence precision test.
The reusable taint machinery (`sec_tainted` / `sec_taint_fixpoint` /
`sec_verifying_heads`) stays as-is for SEC001. Header-trust discharge therefore
remains DEFERRED to the focused whole-module dataflow design (auth-fn → server
`listenAddress`), which is the only sound way to distinguish a loopback-proxy-
trusted header from a spoofable one without noise — a hard error gated on
topology, not an advisory taint heuristic.

### D — mixed-mode Password/Machine session witness gate (OQ15/18): ATTEMPTED, found UNSOUND as scoped, REVERTED
Implemented the session-witness gate as a type/proof DEMAND on the minting
chokepoint: `Http.setSessionCookie` gains a `subject ::: LoggedIn subject`
argument, with `LoggedIn` owned by a new `Tesl.Auth` module and minted only by
check-shaped combinators (`Auth.passwordSession` from `PasswordVerified`,
`Auth.machineSession` from a bearer `PasswordVerified`, `Auth.proxySession` from
`ProxyBound`) or the runtime-owned SSO callback — never in `proof_discharge`
auto-preds (fail-closed). Landed across type_system / validation_common /
proof_checker / validation_structural (per-method attribution) / emit_racket +
runtime `tesl/auth.rkt` + a 2-arg `tesl/http.rkt` `setSessionCookie`; built green.

The mechanism worked for the *bound* case: an honest
`check Crypto.checkPassword` -> `check Auth.passwordSession` ->
`Http.setSessionCookie subject token` compiled; a bare request value as subject
was refused (`argument subject does not statically satisfy declared proof
LoggedIn`); and the old 1-arg `setSessionCookie token` became a hard type error
(closing a partial-application bypass by placing the proof-carrying subject
first).

**But it is UNSOUND as scoped, and the hole is exactly the deferred "hard half"
(credential -> subject binding).** `Crypto.checkPassword` mints
`PasswordVerified stored` bound to the stored HASH, not to any subject. So
`Auth.passwordSession verified subject` takes the subject as an INDEPENDENT
argument, and:
```
let verified = check Crypto.checkPassword attackerHash attackerPassword
let subject  = check Auth.passwordSession verified "admin"   -- LoggedIn "admin"
let _        = Http.setSessionCookie subject token
```
type-checks `ok:true` (demonstrated) — an attacker verifies their OWN password
and mints a session for `"admin"`. Privilege escalation. Shipping this would be
WORSE than the current documented gap: a sound-LOOKING session witness that is
forgeable. So the whole attempt was reverted to the green baseline (D.3
`Tesl.Proxy` intact; `test_session_cookie` 22, `test_sso_surface` 49,
`test_sso_adversarial` 11 all green; `lesson76` type-checks again).

**Sharpened recommendation for the focused session.** The gate is only sound if
the credential fact is bound to the *subject identity*, not to opaque key
material:
- The JWT/SSO path is already soundly bindable: `JWT.verify` mints `Authentic
  claims`, and an `Auth.verifiedSession` that DERIVES the subject from the
  verified claims (the `sub`) mints `LoggedIn subject` with no independent
  subject argument. This covers session refresh and the SSO callback.
- The fresh-password path needs the missing piece: a typed credential-store
  lookup that mints a subject-bound fact (e.g. `CredentialFor subject`), or a
  `Crypto.checkPassword`-style primitive that takes and binds the claimed
  subject so `PasswordVerified` is *about a subject*. Only then can
  `Auth.passwordSession` mint `LoggedIn subject` without the escalation.
Until that binding exists, `loginMethods [Sso, Password via <fn>]` keeps its
current, honestly-documented limitation (the policy fn must exist; the per-site
mint is not yet witness-gated). This confirms the spec's own decision to defer
OQ15/18 to a focused design session.
