# SSO / third-party auth — split the item: document the proxy pattern now, then one blessed OIDC code flow

**Status: PLANNED (drafted 2026-07-30, expanded from the original ask)**

## Original ask

> We have added crypto and session cookies. A lot of real apps use Single-sign-on (SSO), both to
> avoid handling the critical sign in logic themselves but also because that is a common demand from
> customers. Also that allows us to scope out mfa etc from Tesl. It is not clear right now if Tesl
> would work out of the box with a standard SSO solution/3rd party Auth service (Azure AD, Auth0 or
> similar). It should be painless and easy to setup … It should map nicely into our
> proofs/auth-handlers. I guess some of it is possible to do inside an auth-handler with the help of
> http-calls but for SSO we need to redirect.

## The answer to "is it not clear if it works": it does not work today

Mapped 2026-07-30. The intuition in the Notes is right, and the blocker list is longer than "we need
to redirect". Ranked by how hard it blocks:

1. **No non-2xx-with-`Location` response exists on the Tesl surface.** A handler returns a typed
   value (JSON-encoded) or `fail`s into `error-response` — `handler-result->response`
   `dsl/web.rkt:1777-1798`. The runtime half is nearly free (`dsl-response` carries
   `(status headers body)` `web.rkt:132`, `json-response` already takes `#:status`/`#:headers`
   :1221), but **no Tesl construct can reach it**. Both hops of the authorization-code flow are
   redirects.
2. **`Set-Cookie` is attached on 2xx only** — `(and (>= status 200) (< status 300))`
   `dsl/web.rkt:1223`, a deliberate rule with a test behind it (lesson76: "a handler that sets a
   cookie and then `fail`s sends NO Set-Cookie"). The OIDC callback wants to do *exactly* the thing
   this forbids: mint the session cookie **and** redirect (303) to the app. Any redirect design must
   answer this explicitly; it is not an oversight to route around.
3. **JWT is HS256 only.** `tesl/jwt.rkt:244` hardcodes `{"alg":"HS256",…}`; the signing primitive is
   `Crypto.signWith` = HMAC-SHA256 (`tesl/crypto.rkt:511`). IdP ID tokens are RS256/ES256 with JWKS
   and key rotation. There is no asymmetric verify, no JWKS fetch/cache, no `kid` lookup.
4. **No percent-encoding and no base64url on the Tesl surface.** Building
   `…/authorize?client_id=…&redirect_uri=…&scope=…&state=…` needs URL encoding; PKCE `S256` needs
   `base64url(sha256(verifier))`. `base64url-encode` exists but is internal to
   `tesl/crypto.rkt:276` and is **not** in its `provide` (:60-76). So neither the authorize URL nor
   an S256 challenge is expressible in Tesl today. `plain` PKCE is not an acceptable substitute.
5. **There is exactly one cookie and its value type is `JwtToken`.** `session-cookie-name` is fixed
   to `__Host-session` (`tesl/http.rkt:58`) and general cookie handling is a stated permanent
   non-goal (lesson76). So the `state`/`nonce`/PKCE-verifier round trip has no browser-bound place
   to live.
6. **`JWT.decode : JwtToken -> Dict String String`** (`type_system.ml:871`) but the runtime returns
   whatever `string->jsexpr` produced (`tesl/jwt.rkt:629`). An ID token's `aud` and `amr` are
   frequently JSON **arrays**, so a decoded claim can be a list sitting in a `Dict String String`.
   **Verify current behavior before designing on top of it** — this is either a soundness hole
   already or a documented coercion, and SSO is the first feature that hits it in the wild.

What *is* already in place and needs nothing: `Env.requireSecret` → `Secret` for the client secret
(`tesl/env.rkt:26`); arbitrary outbound headers and bodies for the token exchange
(`HttpClient.post url headers body`, `tesl/http-client.rkt:529`, CRLF-guarded :52); CSPRNG tokens
(`Crypto.randomToken`, 256-bit base64url, :500); `request.queryParameters` for `?code=&state=`
(LANGUAGE-SPEC :638, `dsl/web.rkt:2325`); and a working test story — `stubHttp`
(`dsl/test-support.rkt:328`) fakes the IdP token endpoint from a `.tesl` api-test, and api-tests
already assert `set-cookie` and take inline query strings, so a full SSO flow is testable with no
new test infrastructure and no live IdP.

## Criticism of the item as written

**"It should be painless" hides two different features with very different costs, and the cheap one
is missing from the plan entirely.**

The overwhelmingly common production answer to "does your app support Azure AD?" is an
**authenticating reverse proxy** — oauth2-proxy, Cloudflare Access, Azure App Service Easy Auth, an
ALB OIDC listener. The proxy performs the whole flow and hands the app a verified identity header.
That path **works with Tesl today, unchanged**: an `auth` block reads `request.headers` and produces
`::: Authenticated user`. It also gets MFA, conditional access, SAML and IdP-initiated login for
free — precisely the "scope out MFA from Tesl" goal in the ask, achieved without any language work.

It is not written down anywhere, and it has one sharp edge that makes documenting it a *security*
task rather than a docs task: **an `auth` block that trusts a request header is a forgery machine if
the app is ever reachable without the proxy in front of it.** That must be stated with the same
force as the `__Host-` argument in lesson76, together with the mitigation (bind the app to the proxy
— shared `Secret` header compared with `Crypto.checkSignature`/constant-time `==`, or mTLS, or a
network path that cannot be bypassed).

So: **split the item.**

- **Item A (do first, ~1-2 days, zero language change): document the proxy pattern.** A lesson + a
  best-practices section + one template `auth` block + an api-test. This is what actually closes
  "does Tesl work with SSO?" for real deployments, and it is the honest recommendation for most
  teams.
- **Item B (the language work below): one blessed in-app OIDC authorization-code flow**, for teams
  that will not run a proxy (self-hosted single binary, "log in with Google" on a consumer product).

Item B is worth doing — a language that ships crypto, sessions and JWT but cannot complete a Google
login is visibly incomplete — but it should be scoped by one decision that makes it small (below),
and it should not start before Item A ships.

## The decision that makes Item B small

**Exchange the IdP identity once, at the callback, for Tesl's own session cookie. Never verify an
IdP token on a normal request.**

Consequences, all good: every `auth` block, `JWT.verify`, `JWT.renew`, the 12-hour absolute cap, the
stateless/horizontal-scaling story and the whole proof surface stay **completely unchanged**; all
SSO code is confined to two endpoints; and no request-path latency is added. The IdP is a login
mechanism, not a session mechanism.

**And it deletes blocker 3.** With a confidential client doing the code flow, the ID token arrives
over a direct TLS-protected POST to the IdP's own token endpoint, which OIDC Core §3.1.3.7 permits
as the basis for trusting it *without* signature verification. So v1 needs **no RS256, no JWKS, no
key rotation, no `kid` lookup** — `JWT.decode` (subject to blocker 6) plus `iss`/`aud`/`nonce`/`exp`
claim checks is sufficient. Asymmetric verify is only required for flows we should refuse to support
(implicit/hybrid, front-channel-only trust, IdP-initiated). Write that reasoning down where a
reviewer will find it, because "we don't check the signature" reads as a hole until the argument is
stated.

## Design sketch (Item B)

Two generated-in-the-template endpoints, plus the smallest possible new surface:

```tesl
GET  /auth/login     -> redirect to <idp>/authorize?…&state=…&code_challenge=…
GET  /auth/callback  -> POST <idp>/token, decode+check claims, upsert user,
                        Http.setSessionCookie (JWT.sign …), redirect to "/"
```

New surface, in the order it is needed:

1. **A redirect response form.** The architectural collision to resolve first: handler return types
   are what the Elm/TS client generators emit from, and a redirect has no typed body. Options —
   (a) `Http.redirect : String -> Unit` + `redirectCap`, recorded in a request-scoped accumulator
   exactly like `dsl/response-cookies.rkt` does for `Set-Cookie`, read by
   `handler-result->response`; the route's declared response type stays for the client generators and
   is simply not sent. (b) A new `redirect` route kind, excluded from client generation. **(a) is
   recommended** — it reuses a proven, already-reviewed mechanism, keeps the blast radius to
   `web.rkt`'s response builder plus a stdlib name, and makes the effect capability-gated like
   `cookieCap`. Both options must additionally decide blocker 2: recommendation is to attach
   `Set-Cookie` on a **303 emitted through this accumulator only**, not to widen the 2xx rule — the
   `fail`-path guarantee stays literally true.
   Open-redirect is the classic vulnerability here: the target must be same-origin/relative, or from
   a startup-declared allowlist, enforced at the call, not in docs.
2. **`Http.urlEncode : String -> String`** (or, better, a helper that builds the whole authorize URL
   from typed parts so nobody hand-concatenates query strings).
3. **PKCE**: `Crypto.pkceVerifier() -> Secret` + `Crypto.pkceChallenge : Secret -> String`
   (S256, base64url). Preferable to exporting raw `base64url` — one correct pair beats three
   primitives users can miscombine, matching the `Crypto.randomToken` precedent.
4. **The `state`/`nonce`/verifier round trip.** Needs a decision:
   - *DB row* keyed by the random `state`, one-time consumption, short expiry — works today with
     `dbWrite`, no new surface, but is **not bound to the browser**, so login-CSRF binding is weaker
     than the spec intends.
   - *A second blessed cookie* `__Host-oauth` — short `Max-Age`, `SameSite=Lax` (**not `Strict`**:
     the callback is a top-level cross-site GET and `Strict` would drop it), fixed attributes, value
     a `JwtToken` carrying `state`/`nonce`/verifier, cleared at the callback. **Recommended** — it is
     the only browser binding available, and the "one cookie, no options" rule in lesson76 was about
     refusing *general* cookie handling, not about refusing a second *fixed, blessed* one. It also
     needs no schema and no cleanup job.
5. **Config**: issuer/client-id/redirect-uri/scopes as ordinary `env` reads; client secret via
   `Env.requireSecret`. No discovery-document fetching in v1 (endpoints are config, not runtime
   lookup) — that keeps startup offline and testable.

## Phases

- **Phase A — proxy-header SSO documented** (Item A above). Lesson + best-practices + template
  `auth` block + api-test + the bypass warning and its mitigation. No compiler or runtime change.
- **Phase 0 — verify blocker 6**, then close it: pin what `JWT.decode` does with an array-valued
  `aud`, and either type it honestly or coerce with a stated rule + regression test. Nothing else
  should be built on `Dict String String` until this is settled.
- **Phase 1 — redirect.** `Http.redirect` + `redirectCap` + the accumulator + the same-origin/allowlist
  guard + the 303-cookie interaction, with the `fail`-path no-cookie guarantee re-asserted by test.
  Independently useful beyond SSO (RP-initiated logout, post-form redirects, short links).
- **Phase 2 — URL encoding + PKCE helpers.**
- **Phase 3 — the flow**: `__Host-oauth` cookie (or the DB alternative), the two endpoints as a
  template + lesson, claim checks (`iss`, `aud`, `nonce`, `exp`, `email_verified` where relevant),
  the identity→local-user upsert, and the "IdP is login, Tesl JWT is session" argument written into
  the spec.
- **Phase 4 — an adversarial review pass**, mandatory, matching
  `roadmap/completed/session_cookie_security_followups.md`. Minimum attack list: open redirect via
  the `Location` value, `state` replay and cross-user `state` swap, PKCE verifier reuse, `nonce`
  omission, `iss`/`aud` confusion between two configured IdPs, a `code` replayed twice, an IdP
  returning a 200 with an error body, a hostile IdP host (SSRF via a config-supplied token endpoint),
  and `Set-Cookie` on the 303 leaking through a `fail` path.

*Exit for the whole item:* one end-to-end api-test that drives login → stubbed IdP token endpoint
(`stubHttp`) → callback → session cookie → protected endpoint, with no live IdP; `dune test` +
`./compile-examples.sh` green; the stdlib binding-existence seam test covering every new name.

## Non-goals

- SAML, WS-Fed, LDAP.
- MFA, conditional access, password policy — the explicit point of delegating to an IdP.
- Refresh tokens / offline access / long-lived IdP sessions. Tesl's session is its own 1h JWT with a
  12h absolute cap; re-login is a redirect.
- Token introspection, back-channel logout, front-channel logout notifications, SCIM/user
  provisioning, group/role sync.
- Multi-tenant IdP discovery (email-domain → IdP routing), IdP-initiated login.
- A generic OAuth *client* library for calling third-party APIs on a user's behalf — different
  feature, different threat model.
- Server-side session revocation (unchanged non-goal, LANGUAGE-SPEC §21.8).
- Asymmetric JWT / JWKS — explicitly out of v1 by the §3.1.3.7 argument above; revisit only if a
  flow we intend to support actually needs it.

## Open questions

1. **Redirect via accumulator (recommended) or a new route kind?** The answer determines whether the
   client generators change at all.
2. **`Set-Cookie` on a 303**: widen the response rule, or attach only for redirects minted through
   `Http.redirect`? RECOMMENDATION: the latter.
3. **`__Host-oauth` second cookie vs DB-stored `state`?** RECOMMENDATION: the cookie, for browser
   binding — but it directly touches the "exactly one cookie" invariant and needs an explicit sign-off.
4. **How much of the flow is a template vs stdlib?** A template is inspectable and adaptable; a
   stdlib `Sso.beginLogin` / `Sso.completeLogin` pair is harder to get wrong. RECOMMENDATION: stdlib
   helpers for the crypto-shaped steps (PKCE, claim checks), template for the two endpoints, so the
   flow stays readable and per-IdP quirks stay editable.
5. **Which IdP is the reference?** Pick one (Auth0 or Entra ID) and make its exact `scope`/claim
   spelling the tested path; note the other's deltas rather than abstracting over both.
