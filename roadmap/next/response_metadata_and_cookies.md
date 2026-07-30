# Sessions over secure cookies — close the crypto/session/cookie surface

> **Status:** Next · **Effort:** M.
> Rewritten 2026-07-30 after a second analysis pass. Supersedes the earlier "response metadata"
> framing of this file: the survey found that a *general* response-metadata feature is not needed
> to close the security story, and that shipping one would add exactly the kind of optional
> surface Tesl exists to avoid. This item now closes audit **L2** completely
> (`roadmap/discarded/security_hardening_audit.md`) with the smallest possible language change,
> and removes the session-shaped duplication that has crept into the stdlib and the lessons.

## The one-way rule, applied

Tesl's promise is one way of doing things, and that way correct, secure and vetted. A survey of
the current tree (2026-07-30) against that promise:

| Concern | State today | Verdict |
|---|---|---|
| Session credential | `Tesl.JWT` — HS256, fixed 1h expiry, no knobs, mints `Authentic`, 401 constant-time | **Keep. This IS the session primitive.** Spec already says so: *"a JWT in Tesl is a session token"* (§21.2) |
| A second session module (`Session.sign`/`Session.verify`, the old Phase-5 sketch) | Not built | **Do not build.** It would duplicate `Tesl.JWT` field for field — same algorithm, same fixed expiry, same fact, same fail mode |
| Key type | **Two**: `Secret` (`tesl/crypto.rkt:186`) and `JwtSecret` (`tesl/jwt.rkt:100`), no conversion between them | **Unify on `Secret`, delete `JwtSecret`.** The split is not cosmetic: `Env.requireSecret` returns `Secret`, `JWT.sign/verify` demand `JwtSecret`, so the shipped examples route the signing key through a plain `String` — `JwtSecret (requireEnv "SESSION_JWT_SECRET")` (`example/admin-task-api.tesl:70`, `ai-conversation-service.tesl:112`) — which defeats the redaction `Secret` exists to guarantee. `lesson57:184` even points at `Env.requireSecret`, which cannot typecheck against `JwtSecret` — the docs already assume the unified world |
| Session idiom in the teaching material | **Two**: lesson06 hand-assembles a two-cookie scheme (`session` + `sessionSig`) from `Crypto.signWith`/`checkSignature`; lesson55/57 and both example APIs use a single JWT cookie | **Consolidate on the JWT cookie.** lesson06 keeps teaching the `Crypto` primitives (they are its subject) but stops presenting its construction as *the session pattern* |
| Cookie **read** | ✓ `Dict.lookup "k" request.cookies` (`tesl/private/runtime.rkt:109`) | Keep |
| Cookie **write** | ✗ nothing. `grep -c Set-Cookie dsl/web.rkt` → 0 | **The one genuinely missing capability. Build it.** |
| DB-backed session entity pattern | Spec mentions of `Session` (§ upsert, §14.7) are illustrative entity names only; no example app hand-rolls DB sessions | Nothing to remove. Long-lived revocable credentials stay `Crypto.randomToken` + stored `Crypto.fingerprint`, as §21.2 already prescribes |

So sessions and cookies are **not** two ways of achieving the same thing — the JWT is the
credential, the cookie is its transport — but the tree does contain real duplication (two key
types, two taught idioms, one proposed duplicate module), and this item removes all of it while
adding the missing transport.

## Decisions

1. **Ordinary imported functions, not new syntax and not ambient forms.**
   `Http.setSessionCookie : JwtToken -> Unit` and `Http.clearSessionCookie : () -> Unit`, both
   imported from `Tesl.Http` and both gated by the new `cookieCap` capability. Nothing about
   them is ambient: the *names* arrive only via `import Tesl.Http exposing [...]` (the stdlib
   binding-existence seam test applies), and the *right to call them* arrives only via
   `cookieCap` in a `requires` list. The precedent is `Email.send` / `JWT.sign` — Unit-returning,
   capability-gated stdlib functions usable in statement position — so there is **no parser, AST
   or desugar work at all**: two rows in the function→capability table
   (`type_system.ml:1553`, beside `"JWT.sign", ["jwt"; "time"]`), signatures in the stdlib env,
   and real `provide`s in `tesl/http.rkt`. The handler's return type — and therefore every
   generated TS/Elm client and every api-test — is completely unchanged.
2. **The effect is threaded through a request-scoped runtime parameter, invisible to the
   language.** `invoke-handler` already `parameterize`s per-request effect state
   (`dsl/web.rkt:1817`); the cookie functions write to a `current-response-cookies` parameter
   there, and the response builder consults it. The plumbing on that side half-exists:
   `dsl-response` has a `headers` field (`dsl/web.rkt:121`) and `dsl-response->http-response`
   already appends it (`dsl/web.rkt:1255`). This parameter is an implementation detail of the
   runtime, not user-visible surface — no new ambient anything in the language.
3. **No general response headers, no success statuses other than 200.** The original version of
   this file scoped "set any response header / any status". Discarded: the only *proven* need is
   `Set-Cookie`, every additional writable header is a knob (CORS, caching, sniffing) with a
   foot-gun attached, and `fail`'s minimalism (`LANGUAGE-SPEC.md:2269`) stays intact. If a real
   need for another header ever appears, it is a new roadmap item with its own justification.
4. **The capability is `cookieCap`, provided by `Tesl.Http`.** Named after the `emailCap`
   precedent. Provider row `"Tesl.Http", [("cookieCap", [])]` in `tesl_stdlib_cap_map`
   (`validation_common.ml:1730`), `(define-capability cookieCap)` + `provide` in
   `tesl/http.rkt` (pattern: `tesl/time.rkt:40`), `require-capabilities!` inside both runtime
   functions as the usual second enforcement layer. Reading `request.cookies` stays ungated —
   it is pure request data, not an effect.
5. **`Http.setSessionCookie` takes a `JwtToken`, not a `String`.** The type system, not a
   lesson, guarantees a session cookie is always a signed value. There is no way to set an
   unsigned cookie, and no other cookie-writing function. Client-side preferences and similar
   non-credential state are explicitly not this feature's job (see "Explicitly not building").
6. **Every cookie attribute is fixed; the name too.** `__Host-session`, `HttpOnly`, `Secure`,
   `SameSite=Lax`, `Path=/`, `Max-Age` = the JWT TTL (imported from `jwt-ttl-seconds`, single
   source — the cookie can never outlive the token). Rule 1: no options. A caller who can pass
   `SameSite=None` will. The `__Host-` prefix makes the browser itself enforce Secure + Path=/ +
   no Domain — a plain-HTTP deployment on a non-localhost origin will visibly fail to store the
   session, and that is the correct behavior ("session over plaintext" is not a configuration).
   Browsers accept Secure cookies on `http://localhost`, so local dev is unaffected; api-tests
   and curl ignore attributes entirely.
7. **`Http.clearSessionCookie`** is the same mechanism with `Max-Age=0` — the logout half, same
   attributes, same capability. Within one request, the last call wins.
8. **Cookies attach to 2xx responses only.** A handler that sets a cookie and then `fail`s sends
   no `Set-Cookie` — no session minted on an error path. (SSE `response/output` gets the same
   append so a cookie set before subscribing is not silently dropped; a handler invoked as an
   agent tool has no HTTP response and the effect is discarded — a login handler does not belong
   in `serverTools` anyway.)
9. **Reader for symmetry: `Http.sessionToken : HttpRequest -> Maybe JwtToken`.** Reads the fixed
   cookie name and wraps the `JwtToken`, so the stringly `Dict.lookup "__Host-session"`
   (typo → permanent 401) never appears in user code. Pure, ungated, imported like everything
   else. Writer takes `JwtToken`, reader yields `JwtToken`; `JWT.verify` sits between them.
10. **Key id from day one, derived not chosen.** `JWT.sign` stamps `kid` =
    `Crypto.keyFingerprint key` (exists, domain-separated, 16 hex, safe to log) in the JOSE
    header — its RFC 7515 home. Safe today: `JWT.verify` never parses the header (it recomputes
    the HMAC over `header.payload` verbatim), so foreign tokens and old Tesl tokens are
    unaffected. This answers "which tenant key verified" and makes rotation expressible later
    without a flag day (Tink's lesson). No accessor in v1 — stamping is the part that is
    expensive to retrofit.
11. **`JwtSecret` is deleted, not aliased** — a clean break, same policy as the 2026-07-29 `exp`
    unit fix. `JWT.sign/verify` take `Secret`. `Env.requireSecret "SESSION_KEY"` then feeds
    `JWT.verify` directly and **no `String` ever holds key material**; per-tenant keys come from
    a `secret` column or a KMS fetch, unchanged. `JwtToken` stays — it is the non-secret wire
    value, and its nominal identity is what lets `Http.setSessionCookie` demand a signed value.

## The blessed session story (target state, one screen)

```tesl
import Tesl.Http exposing [HttpRequest, cookieCap,
                           Http.setSessionCookie, Http.clearSessionCookie, Http.sessionToken]
import Tesl.JWT  exposing [jwt, JwtToken, JWT.sign, JWT.verify, Authentic]
import Tesl.Env  exposing [envRead, requireSecret]
import Tesl.Time exposing [time]

capability sessions implies jwt, time, envRead, cookieCap

handler login(credentials: Login) -> LoginOk requires [sessions, dbRead] =
  # ... Crypto.checkPassword against the stored PasswordHash ...
  let token = JWT.sign (Dict.singleton "sub" user.id) (requireSecret "SESSION_KEY")
  Http.setSessionCookie token     # __Host-session; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=3600
  { ok: True }

auth sessionOwner(request: HttpRequest) -> user: User ::: Authenticated user
  requires [sessions, dbRead] =
  case Http.sessionToken request of
    Nothing    -> fail 401 "no session"
    Something token ->
      let claims = check JWT.verify token (requireSecret "SESSION_KEY")
      # claims ::: Authentic claims — one establish beside a real verification
      ...

handler logout() -> LogoutOk requires [cookieCap] =
  Http.clearSessionCookie
  { ok: True }
```

CSRF note for the lesson, not for machinery: `SameSite=Lax` + Tesl's existing 415 on
non-`application/json` bodies + no CORS headers on JSON routes means a cross-site form or fetch
cannot reach a state-changing handler. The one obligation this leaves the author is the one Tesl
already teaches: GET handlers do not mutate.

## Horizontal scaling

This design is the horizontally-scalable one, deliberately. The session is **stateless**: the
credential is self-contained and signed, so *any* replica holding `SESSION_KEY` verifies it. No
sticky sessions at the load balancer, no shared session store, no session table to migrate, no
cross-replica invalidation traffic. This is precisely why the blessed pattern is
JWT-in-a-cookie rather than a DB-backed session entity.

What horizontal deployment actually requires, and how each is covered:

- **Same key on every replica.** The key comes from one source (`Env.requireSecret`, a `secret`
  column, or a KMS fetch) shared by the deployment. A replica with the wrong key rejects
  sessions with 401 — and the `kid` stamped in every token (= `Crypto.keyFingerprint`) makes
  that mismatch diagnosable from logs instead of a mystery.
- **TLS termination at a proxy/LB.** Cookie attributes are evaluated by the *browser* against
  the public origin, which is `https://` — `Secure` and `__Host-` work unchanged behind a
  TLS-terminating load balancer regardless of the backend hop's scheme.
- **Clock agreement.** `exp` is epoch seconds; replicas need ordinary NTP sanity, nothing more.

The honest trade to document in the lesson: **logout removes the browser's cookie; it does not
invalidate the token.** A captured token stays verifiable until `exp` — bounded at one hour by
the fixed TTL, which is the reason the TTL is fixed and short. Instant server-side revocation is
a *stateful* design with a shared store and is exactly what this design avoids; if it is ever
truly needed it is a new roadmap item, and the revocable-credential path that already exists
(`Crypto.randomToken` + stored `Crypto.fingerprint`) is the answer for long-lived credentials
today.

## Implementation map

**Phase 0 — key unification (independent; do first).** `JWT.sign/verify` accept `Secret`;
delete `define-secret-newtype JwtSecret` + its provide (`tesl/jwt.rkt`); sweep `JwtSecret` from
the checker's stdlib signatures, `stdlib_docs_entries.ml`, both example APIs, lessons 55/57/58/61,
templates, spec §21.2 + §10 module list, and the Racket test helpers
(`tests/tesl-test.rkt` `signed-session-cookie`). Grep for `JwtSecret` must end at zero. Secret
literals in tests become `Secret "test-key"`.

**Phase 1 — `kid`.** `jwt-header-b64` stops being a constant and is computed per key
(`{"alg":"HS256","typ":"JWT","kid":"<keyFingerprint>"}`). Verify path untouched.

**Phase 2 — the transport.** All library-level, no new syntax:
`tesl/http.rkt` gains `(define-capability cookieCap)`, `Http.setSessionCookie`,
`Http.clearSessionCookie` (both `require-capabilities!`-guarded) and `Http.sessionToken`
(requires `jwt.rkt` for the `JwtToken` constructor — no cycle, `jwt.rkt` does not require
`http.rkt`). Checker side: stdlib-env signatures + two rows in the function→capability table
(`type_system.ml:1553`) + the `cookieCap` provider row (`validation_common.ml:1730`).
Runtime: a `current-response-cookies` parameter set up in `invoke-handler`
(`dsl/web.rkt:1817`), consulted where 2xx responses are built (`json-response`,
`dsl-response->http-response`, the SSE path); `Max-Age` from `jwt-ttl-seconds`. Verify a bare
Unit-returning stdlib call is accepted in intermediate statement position in a handler body
(the `let _ =` statement arms at `emit_racket.ml:2569` list `ERuntimeCall`; `Email.send` shows
tail position works) — if intermediate position needs a small allowance, that is a checker/emit
tweak, not a new form. Verify the api-test `HttpResponse.headers` field (`LANGUAGE-SPEC.md:902`)
actually carries response headers through `dispatch-request` (`dsl/web.rkt:1782`) and wire it if
it does not — the api-test grammar itself needs **no** change (requests already take
`cookie <string>`). Add one `Tesl.ApiTest` helper, `responseCookie : HttpResponse -> Maybe
String`, so round-trip tests do not parse `Set-Cookie` by hand.

**Phase 3 — one idiom in the docs.** New `lesson76-sessions.tesl` (login → protected endpoint →
logout, the screen above, plus the CSRF paragraph and the logout/revocation trade); spec section
for the three functions + `cookieCap` + the fixed attributes; lesson06 keeps its
`Crypto.signWith` teaching but gets a forward pointer and stops calling its cookies the session
pattern (rename its cookie keys away from `session` so a grep for the blessed idiom has one
answer); both example APIs' `auth` blocks move to `Http.sessionToken` + `requireSecret`; audit
L2 marked closed.

## Explicitly not building

- A `Tesl.Session` module — `Tesl.JWT` already is one, to the letter.
- New syntax or ambient forms — the whole feature is imported functions plus one capability.
- General response-header or response-status setting — no proven need; every header is a knob.
- Cookie options of any kind — name, attributes, expiry are all fixed.
- **General cookie handling (UI state, preferences, tracking) — a permanent non-goal, not a
  deferral.** Every kind of state has exactly one home in Tesl's model, and none of them is a
  general cookie:
  - a credential → the session cookie (this item);
  - data the *server* must trust or persist per user → a DB entity keyed by the session subject
    (an unsigned cookie is client-editable, so it could never be trusted anyway);
  - client-only UI state → the client's own storage (`localStorage` etc.) in the generated
    TS/Elm app — it never needs to cross the wire, while a cookie rides *every* request and
    competes with the session for the ~4 KB header budget.
  The usual counter-examples dissolve into those rows: locale and feature flags are per-user
  data (DB) or response data (body); A/B bucketing is an edge/CDN concern, not the app server's;
  consent banners are client state. If a genuinely new case ever appears it is a new roadmap
  item carrying its own justification — the bar this file already sets for response headers.
- Key rotation / multi-`kid` verification — the format now supports it (`kid` stamped); the
  mechanism is a future item.
- A cookie-read capability — reading request data is not an effect.
- Server-side session revocation — stateful by nature; see "Horizontal scaling" for the trade
  and the existing revocable-credential answer.

## Verification bar

- A handler sets the cookie; an api-test (or the Racket harness if `HttpResponse.headers` wiring
  proves deeper than expected) asserts the full `Set-Cookie` line **from an ordinary handler that
  passed nothing** — `__Host-session`, `HttpOnly`, `Secure`, `SameSite=Lax`, `Path=/`,
  `Max-Age=3600`. Defaults are asserted, not just settable.
- Round trip: login sets the cookie, the value is fed back via the existing api-test `cookie`
  clause, `JWT.verify` inside `auth` mints `Authenticated`, the protected endpoint answers 200.
- A tampered cookie → 401; a cookie signed with a different key → 401; both through the existing
  constant-time path. Two tenants, two keys: A's session does not verify under B's key, and the
  minted token's `kid` equals `Crypto.keyFingerprint` of the signing key.
- `logout` emits `Max-Age=0`; a handler that sets a cookie and then `fail`s emits **no**
  `Set-Cookie`.
- `Http.setSessionCookie someString` is a type error; calling either function without
  `cookieCap` in scope is the usual capability error; calling them without the import is the
  usual unbound-name error (nothing ambient); `grep -r JwtSecret` over the tree finds nothing;
  the stdlib binding seam test and `test_secret_surface.ml` pass with the unified `Secret` and
  the three new `Tesl.Http` provides.
- A program can go `Env.requireSecret` → `JWT.sign`/`JWT.verify` with no `String` of key material
  at any point — the admin-task-api example after Phase 3 is the proof.
- Generated TS/Elm clients for a cookie-setting handler are byte-identical to before (the whole
  point of keeping the return type untouched).
- `./ci.sh` green; lesson76 byte-exact in the snapshot sweep.

## Related

- `roadmap/completed/tesl_crypto.md` — Phases 0–4 landed; this item is its Phase 5, rescoped.
  Its "no ambient keys" and "no options" rules are load-bearing here.
- `roadmap/discarded/security_hardening_audit.md` — **L2** closes with this item. **L1**
  (`establish` as the remaining trust escape) is untouched and stays open.
- `LANGUAGE-SPEC.md:2269` (`fail` minimalism), `§21.2` (JWT = session token), `:902`
  (api-test `HttpResponse`).
- `dsl/web.rkt:121,1255,1782,1817` — response struct, header append, dispatch, ambient-effect
  parameterization. `tesl/private/runtime.rkt:109` — the existing cookie read.
- `compiler/lib/type_system.ml:1553` (function→capability table),
  `validation_common.ml:1730` (capability provider rows), `tesl/time.rkt:40`
  (`define-capability` pattern), `Email.send` (capability-gated Unit function as the
  statement-position precedent).
