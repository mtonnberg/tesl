# SSO / third-party auth — document the proxy pattern, then one declarative clause over a function-supplied connection

**Status: PLANNED** (drafted 2026-07-30, expanded and re-scoped from the original ask; security review folded
in 2026-07-30 — see **Phase −1**, which now gates everything else)

## Original ask

> We have added crypto and session cookies. A lot of real apps use Single-sign-on (SSO), both to
> avoid handling the critical sign in logic themselves but also because that is a common demand from
> customers. Also that allows us to scope out mfa etc from Tesl. It is not clear right now if Tesl
> would work out of the box with a standard SSO solution/3rd party Auth service (Azure AD, Auth0 or
> similar). It should be painless and easy to setup … It should map nicely into our
> proofs/auth-handlers. I guess some of it is possible to do inside an auth-handler with the help of
> http-calls but for SSO we need to redirect.

## Summary of the decisions in this item

0. **`HttpClient` does not authenticate its TLS peer, and that must be fixed before any of this is
   built.** `http-conn-open`'s `#:ssl? #t` uses Racket's default client context, which verifies
   neither the certificate nor the hostname; `ssl-secure-client-context` appears nowhere in the tree.
   Every trust argument below rests on an authenticated channel. Blocker 7, Phase −1.
1. **It does not work today.** Eight blockers, mapped below.
2. **Split the item.** Document the authenticating-proxy pattern first (Item A, no language change,
   the honest recommendation for most teams). Then build the in-app flow (Item B).
3. **Item B is a declarative clause, not a set of primitives.** A `sso` clause on the `server` block,
   with the runtime owning both endpoints. This *deletes* four of the six blockers from the language
   surface rather than solving them — it is strictly **less** new Tesl surface than exposing
   `Http.redirect` + URL encoding + PKCE helpers + a second cookie.
4. **The clause declares only the flow; the provider and its credentials arrive from an ordinary
   function.** `Sso.defaults GitHub clientId clientSecret -> SsoConnection`, over a baked
   `SsoProvider` ADT — the `TimeZone`/`Currency` pattern, tables-only, no provider keyword and no
   clause-level enum. Both provider families (OIDC and plain OAuth2) are constructors of one
   `SsoConnection` ADT, so there is no separate `social_auth` feature.
5. **That keeps an escape hatch.** A hand-written `OAuth2Endpoints` value reaches an unblessed
   provider with no language change and no `Http.redirect`.
6. **`Http.redirect` is NOT part of this item.** It becomes a separate, independently justified item.
7. **The provider is a login mechanism, not a session mechanism.** Exchange the third-party identity
   once, at the callback, for Tesl's own session cookie. Every `auth` block, `JWT.verify`,
   `JWT.renew`, the 12-hour cap and the stateless-scaling story stay unchanged.
8. **Blessed defaults: Google, GitHub, Discord**, plus the generic OIDC issuer path for every
   enterprise IdP.
9. **In-app multi-tenant per-org SSO is a non-goal.** Route through an SSO broker; see Non-goals.
10. **The app's public origin becomes explicit configuration.** `redirect_uri` may never be derived
    from a request header. Blocker 8.

## The answer to "it is not clear if it works": it does not

Mapped 2026-07-30. The intuition in the Notes is right, and the list is longer than "we need to
redirect". Ranked by how hard each blocks, with what the declarative model does to it. Blockers 7 and
8 were added by the security review and are the only two that the declarative model does **not** make
cheaper — they must be built:

| # | Blocker | Evidence | Under the declarative model |
|---|---|---|---|
| 1 | No non-2xx-with-`Location` response is reachable from Tesl | `handler-result->response` `dsl/web.rkt:1777-1798` returns JSON or `error-response`. Runtime half already exists — `dsl-response` is `(status headers body)` :132, `json-response` takes `#:status`/`#:headers` :1221 | **Deleted from the surface.** Redirects happen inside runtime-owned routes, in Racket |
| 2 | `Set-Cookie` attaches on 2xx only — and the callback needs cookie **plus** 303 | `(and (>= status 200) (< status 300))` `dsl/web.rkt:1223`, a deliberate rule with a test behind it (lesson76: a handler that sets a cookie then `fail`s sends none) | **Internal.** Never becomes a language rule; lesson76's `fail`-path guarantee stays literally true |
| 3 | JWT is HS256 only; OIDC ID tokens are RS256/ES256 with JWKS + rotation | `{"alg":"HS256",…}` hardcoded `tesl/jwt.rkt:244`; primitive is HMAC-SHA256 `tesl/crypto.rkt:511` | **Not needed — but only once blocker 7 is fixed.** See the §3.1.3.7 argument below, which is *conditional on an authenticated TLS channel*. Also why Apple stays out |
| 4 | No percent-encoding and no base64url on the Tesl surface, so neither the authorize URL nor PKCE `S256` is expressible | `base64url-encode` exists but is internal to `tesl/crypto.rkt:276`, absent from its `provide` (:60-76). `plain` PKCE is not an acceptable substitute | **Deleted.** Runtime builds the URL and the challenge |
| 5 | Exactly one cookie exists and its value type is `JwtToken`, so `state`/`nonce`/verifier have no browser-bound home | `session-cookie-name` fixed to `__Host-session` `tesl/http.rkt:58`; general cookie handling is a stated permanent non-goal (lesson76) | **Invisible.** Runtime owns `__Host-oauth`; "exactly one cookie" stays true *of the Tesl surface* |
| 6 | `JWT.decode : JwtToken -> Dict String String` but the runtime returns raw `string->jsexpr`; an ID token's `aud`/`amr` are often JSON **arrays** | `type_system.ml:871` vs `tesl/jwt.rkt:629` | **Off the critical path** — runtime parses claims in Racket and hands the user a typed record. Still a real defect; fix it, but it no longer gates SSO |
| **7** | **`HttpClient` does not authenticate its TLS peer.** No certificate validation, no hostname check | `(http-conn-open host #:ssl? use-ssl? #:port port)` `tesl/http-client.rkt:395` and `:495`, where `use-ssl?` is the bare boolean `(equal? scheme "https")` :80. Racket's `#:ssl? #t` takes the default client context, which does not verify; `ssl-secure-client-context` occurs **zero** times in the tree | **Must be built, and first.** Not an SSO problem — a live defect for every existing `HttpClient` caller (webhooks, payment APIs). It is listed here because SSO's central design decision (skip ID-token signature verification) is *unsound without it*, and because the token exchange would post `client_secret` to an unauthenticated peer |
| **8** | **No configured public origin exists**, so `redirect_uri` has no trustworthy source | no `baseUrl`/`publicOrigin`/`PUBLIC_URL` concept in `tesl/http.rkt` or `dsl/web.rkt` | **Must be built.** Deriving it from `Host`/`X-Forwarded-Host` is redirect-URI poisoning. New required server-level setting, https-validated at compile time |

**What already works and needs nothing** (with blocker 7 fixed — read every "`HttpClient` handles this"
claim below as conditional on it)**:** `Env.requireSecret` → `Secret` (`tesl/env.rkt:26`);
`Secret` is a genuine constructor `String -> Secret` (`type_system.ml:923`), so a connection secret
can come from anywhere; arbitrary outbound headers/bodies for the token exchange and the userinfo
call (`HttpClient.post`/`HttpClient.get` `tesl/http-client.rkt:523-531`, CRLF-guarded :52); CSPRNG
tokens (`Crypto.randomToken`, 256-bit base64url, :500); `request.queryParameters` for `?code=&state=`
(LANGUAGE-SPEC :638, `dsl/web.rkt:2325`); record update `{ base | field = val }` for the override
story (`compiler/lib/parser.ml:2324`); ADT variants with named field declarations
(LANGUAGE-SPEC:2993); and a complete test story — `stubHttp` (`dsl/test-support.rkt:328`) fakes
discovery, token and userinfo endpoints from a `.tesl` api-test, which already carries cookies across
requests and takes inline query strings. **No new test infrastructure and no live provider.**

## Item A — the authenticating-proxy pattern (do first, no language change)

The overwhelmingly common production answer to "does your app support Entra ID?" is an
authenticating reverse proxy — oauth2-proxy, Cloudflare Access, Azure App Service Easy Auth, an ALB
OIDC listener. The proxy runs the whole flow and hands the app a verified identity header.

**This works with Tesl today, unchanged**: an `auth` block reads `request.headers` and produces
`::: Authenticated user`. It also delivers MFA, conditional access, SAML and IdP-initiated login for
free — exactly the "scope out MFA from Tesl" goal in the ask, with zero language work.

It is written down nowhere, and documenting it is a **security** task, not a docs task:

> **An `auth` block that trusts a request header is a forgery machine if the app is ever reachable
> without the proxy in front of it.** Anyone who can reach the app directly sets the header and
> becomes any user. This must be stated with the force of the `__Host-` argument in lesson76,
> together with the mitigation: bind the app to the proxy — a shared `Secret` header compared with
> `Crypto.checkSignature` (or the constant-time `==`), or mTLS, or a network path that provably
> cannot be bypassed — and fail closed when the binding is absent.

Two further rules the pattern needs, both easy to miss:

- **The proxy must strip inbound copies of the identity header**, and the Tesl side must **reject a
  duplicated or variant-spelled instance** rather than picking one. Header smuggling — a second
  `X-Auth-User`, or an underscore/dash variant that the proxy normalises differently than the app
  does — defeats the binding without ever touching the shared secret.
- **A static shared-secret header is replayable** by anyone who reads a log line, a HAR file or a
  crash dump; it authenticates the *value*, not the request. Prefer mTLS. If a header is what ships,
  make it a timestamped HMAC with a replay window, or state the weakness explicitly — the naive
  version is not equivalent to mTLS and the lesson must not imply that it is.

*Deliverable:* one lesson, a `manual/best-practices.md` section, one template `auth` block, api-tests
covering three negatives (no binding header, wrong binding secret, duplicated identity header — each
one 401), and the warnings above. ~1–2 days.

*Rationale for doing it first:* it is what actually closes "does Tesl work with SSO?" for real
deployments, and it is the better answer for most teams. Item B is for teams that will not run a
proxy — self-hosted single binary, air-gapped, or an app that wants "log in with Google".

## Item B — one declarative clause

### The decision that makes it small

**Exchange the third-party identity once, at the callback, for Tesl's own session cookie. Never
verify a third-party token on a normal request.**

Consequences, all good: the entire existing session/proof surface is untouched, all SSO code is
confined to runtime-owned endpoints, and no request-path latency is added.

**And it deletes blocker 3 for the OIDC family — conditionally.** With a confidential client running
the authorization-code flow, the ID token arrives over a direct TLS-protected POST to the provider's
own token endpoint, which OIDC Core §3.1.3.7 permits as the basis for trusting it *without* verifying
its signature. So v1 needs **no RS256, no JWKS, no key rotation, no `kid` lookup** — validated
`iss`/`aud`/`nonce`/`exp` claims are sufficient. Asymmetric verify is required only for flows we
should refuse to support (implicit, hybrid, front-channel-only trust, IdP-initiated). **Write this
reasoning into the spec**, because "we don't check the signature" reads as a hole until the argument
is stated.

> **The condition is load-bearing and is currently false.** §3.1.3.7's basis is a TLS channel *whose
> server was authenticated*. Blocker 7 says ours is not: `#:ssl? #t` verifies neither certificate nor
> hostname. On an unverified channel a network attacker mints any ID token it likes and there is no
> signature check standing in the way — and the same exchange hands that attacker the `client_secret`.
> Skipping signature verification also means there is **no defence in depth** if TLS is ever
> misconfigured again. So blocker 7 is not a nice-to-have prerequisite; it *is* the security of this
> design, and it ships in Phase −1 before any SSO code exists.

Two claim checks are therefore mandatory, not best-effort, and must fail closed:

- **`nonce`.** With the signature unverified, `nonce` plus the browser-bound `__Host-oauth` cookie are
  the *only* things tying the token to this login attempt. Absent, unparseable, or mismatched ⇒ reject.
- **`iss` and `aud`.** `aud` must equal the connection's `clientId` (and `azp` must match it when the
  claim is present); `iss` must equal the issuer that discovery itself declared — see Risk 13.

### Two provider families, one flow, one extra step

Both families do the same thing: redirect to authorize → callback with `code` → POST the code to a
token endpoint. The only difference:

- **OIDC** (Google, Entra ID, Okta, Auth0, Keycloak, Cognito, GitLab, Ping): identity comes back
  *inside* the token response as a signed ID token. Endpoints are discoverable at
  `/.well-known/openid-configuration`.
- **Plain OAuth2** (GitHub, Discord): the token response carries only an access token. Identity needs
  **one extra authenticated GET** to a provider-specific userinfo endpoint with a provider-specific
  JSON shape. No discovery, no ID token, no `nonce`.

So social login is **one extra step plus a defaults table**, not a second feature. A separate
`social_auth` construct would duplicate route minting, `state`/PKCE, the cookie and the identity hook
for a one-step difference — **rejected**.

### The provider is a value, not syntax

`SsoConnection` is an ADT with one constructor per family, and a stdlib function fills in the blessed
defaults:

```tesl
type SsoProvider
  = Google | GitHub | Discord              # baked ADT — the TimeZone / Currency pattern

type SsoConnection
  = OidcIssuer      { issuer: String, clientId: String, clientSecret: Secret,
                      scopes: List String, extraAuthorizeParams: Dict String String }
  | OAuth2Endpoints { authorizeUrl: String, tokenUrl: String, userinfoUrl: String,
                      clientId: String, clientSecret: Secret, scopes: List String,
                      subjectField: String, emailField: Maybe String,
                      emailVerifiedField: Maybe String, nameField: Maybe String }

Sso.defaults : SsoProvider -> String -> Secret -> SsoConnection
```

`Sso.defaults` returns the right constructor per provider — `OidcIssuer` for Google,
`OAuth2Endpoints` for GitHub and Discord — with that provider's endpoints, scopes and field mapping
pre-filled.

**Why this replaced a `provider Google` keyword.** `TimeZone` (489 baked IANA constructors) and
`Money`'s `Currency` (155 ISO codes) are already baked ADTs *passed as values to functions*, and the
spec advertises the diagnostic that buys: a typo'd zone is an unknown-constructor compile error and
completion lists every zone. That is the entire benefit a clause-level enum would have delivered,
available with **tables-only** work (`type_system.ml` rows) and no parser change. It also collapses
two mechanisms into one: the `connection` hook was already a function returning `SsoConnection`, so a
provider keyword sitting beside it was redundant.

`Sso.defaults GitHub …` is preferred over three separate `githubDefaults`/`googleDefaults` functions:
one name to learn, and adding a provider is one constructor plus one table row.

**Overrides are record update, not clause syntax.** The "defaults are defaults" rule — needed because
provider endpoints and field names drift (Discord's API version sits in its URL path, GitHub renames
scopes) — is expressed in the language:

```tesl
{ Sso.defaults GitHub id sec | scopes = ["user:email", "read:org"] }
```

So a drifted provider is fixable by the user without waiting for a Tesl release, and we did not have
to invent per-field override syntax.

**`extraAuthorizeParams` is an injection surface and needs a rule.** It is a free-form
`Dict String String` merged into the authorize URL, so without constraints a config value can rewrite
the flow's own parameters — `redirect_uri` first among them, which is full account takeover *through
configuration*, the same class as Risk 3. Two non-negotiable rules, asserted by test:

1. **Reserved names are a hard error, not a silent drop:** `client_id`, `redirect_uri`, `response_type`,
   `scope`, `state`, `nonce`, `code_challenge`, `code_challenge_method`, `code_verifier`,
   `client_secret`, `grant_type`, `code`.
2. **Both key and value are percent-encoded** by the runtime, so no value can smuggle an `&` or `=`
   and append a parameter of its own.

**Blessed defaults and their quirks:**

| Provider | Constructor | Notes |
|---|---|---|
| Google | `OidcIssuer` | discovery; `hd` may be passed via `extraAuthorizeParams` but it is **only an account-picker hint — never a restriction**; see below |
| Entra ID / Okta / Auth0 / Keycloak / Cognito / … | `OidcIssuer`, hand-written | no table entry needed — the issuer *is* the config |
| GitHub | `OAuth2Endpoints` | `/user` returns only the **public** profile email (often null and unverified). The verified primary needs `user:email` scope and a **second** call to `/user/emails` — the descriptor must encode both calls |
| Discord | `OAuth2Endpoints` | `/users/@me` with `identify email` returns `id`, `email`, `verified`; API version is in the URL path, so it drifts |

**Domain restriction is a claim check, not a request parameter.** Google's `hd` on the *authorize
request* narrows the account picker; an attacker simply omits it and nothing enforces anything. Real
restriction means verifying the **`hd` claim on the returned ID token** (together with
`email_verified`), which happens in `onIdentity`. The lesson and template must show the claim check,
because the request-parameter version reads like a control and is not one. The same trap applies to
any "restrict to our tenant" parameter on any provider: only the returned assertion is evidence.

**Not blessed, but expressible.** Facebook, X/Twitter and bespoke internal OAuth2 servers are reached
by hand-writing an `OAuth2Endpoints` value. No blessing from us, no language change.

**Apple stays genuinely out**: its `client_secret` is not a string but an **ES256-signed JWT the app
must mint and rotate at most every 6 months**. That needs asymmetric *signing*, which we do not have
(HS256 only, `tesl/jwt.rkt:244`) — blocker 3 in reverse. Revisit only if asymmetric signing lands for
another reason.

### Why not "let the frontend do social login"

Worth killing explicitly, because it looks cheaper and is not. The frontend-only path is either the
implicit flow (deprecated; removed in OAuth 2.1) or a browser PKCE public client. The public client
leaves the SPA holding a token it must send to the Tesl backend — and the backend then has to verify
an assertion that arrived **through the browser**, which is exactly the case where blocker 3 bites:
RS256 + JWKS + rotation, unavoidable. The confidential-client server-side flow is the one path that
avoids asymmetric verify entirely. **Pushing this to the frontend imports the expensive blocker
instead of dodging it.** (The single escape is calling a provider's own `tokeninfo`-style endpoint per
login — provider-specific, rate-limited, and a hack.)

### Shape

A repeatable clause on the `server` block. Each clause names its route segment and points at two
functions — one for config, one for identity:

```tesl
server AppServer for AppApi {
  whoami = whoami
  logout = logout

  sso "github"    connection githubConn    onIdentity linkUser
  sso "google"    connection googleConn    onIdentity linkUser
  sso "corporate" connection corporateConn onIdentity linkUser

  ssoSessionKey (requireSecret "SESSION_KEY")   # one session key for all of them
  afterLogin    "/"
}

fn githubConn() -> Maybe SsoConnection requires [envRead] =
  Something (Sso.defaults GitHub (env "GITHUB_CLIENT_ID") (requireSecret "GITHUB_CLIENT_SECRET"))

fn corporateConn() -> Maybe SsoConnection requires [envRead] =
  Something (OidcIssuer { issuer: env "OIDC_ISSUER", … })
```

The literal segment mints `/auth/github/login` and `/auth/github/callback`. **The path cannot be
derived from the provider any more** — the provider is a runtime value now — and that is a net
improvement: the paths are explicit rather than magic, a user can pick their own, and the compiler
needs them literally anyway for route-collision checking and client-generation exclusion.

`SsoIdentity`, handed to `onIdentity`:

```
SsoIdentity = { provider: String, issuer: String, subject: String,
                email: Maybe String, emailVerified: Bool,
                name: Maybe String, claims: Dict String String }
```

The runtime owns: discovery (OIDC, cached document) or the endpoints from the connection value, PKCE
S256, `state`/`nonce` generation and the `__Host-oauth` cookie that binds them to the browser, the
code exchange, the userinfo call where required, claim validation, calling `onIdentity`, signing the
session JWT from what it returns, setting `__Host-session`, and the 303 to `afterLogin`.

**The only user code is a config function and the identity → local user mapping.** The latter cannot
live in the runtime — it writes the app's own schema under the app's own proofs.

### `onIdentity` is a fact-minting trust boundary

It turns provider-asserted data into `::: Authenticated user`. A plain `fn` minting a fact is the
confirmed `fn→Fact` forgery class, and only sanctioned boundaries may mint. **Declare it as an
`auth`-kind declaration**, reusing the existing sanctioned minting site rather than inventing a
second one:

```tesl
auth linkUser(identity: SsoIdentity) -> user: String ::: Authenticated user
  requires [dbWrite] =
  -- upsert on (provider, subject) — never on email; see Risks 2 and 3
  ...
```

### Why a clause at all, when the metrics item rejected new syntax

`roadmap/completed/opentelemetry_metrics.md` rejected a `metric` statement form because plain stdlib
functions were tables-only and the syntax bought nothing. That argument now covers **everything except
the clause itself**: `SsoProvider`, `SsoConnection`, `Sso.defaults` and both hooks are tables-only.
What remains needs syntax because it must **mint routes**, **produce an `Authenticated` fact**,
**bind at server construction**, and **be excluded from client generation** — none of which is
function-shaped; there is no function that adds two endpoints to a server. `serverTools` is the
precedent for the opposite call: it stayed a plain function (`serverTools MyServer user : List Tool`)
precisely because it could.

Cost is real: a new clause means token/AST/parser/desugar plus the ~15 exhaustive matches the metrics
item enumerated (`validation_proof.ml`, `validation_capabilities.ml`, `ast_visitor.ml`, `linter.ml`,
`mutate.ml`, `proof_checker.ml`, several `emit_racket.ml` statement lists). But it is now a *thin*
clause — a string and two function references — rather than a config block, so the AST node and its
matches stay small.

**Placement rationale — server, not `main`:** routes belong to a server; the two-API pattern
(`tests/two-api-server-tools-tests.tesl`) means SSO belongs to the browser-facing API and not the
machine one; and `main` is the wrong altitude and historically the least-checked construct in the
language.

### `Http.redirect` is still a separate item

With the escape hatch now provided by hand-written `OAuth2Endpoints`, `Http.redirect` is no longer
needed as SSO's fallback at all. It becomes a separate roadmap item justified on its own non-SSO
merits (RP-initiated logout, post-form redirect, short links), so SSO's design does not pay for
redirect's generality, its open-redirect surface, or the `Set-Cookie`-on-303 question.

## Phases

- **Phase A — the proxy pattern documented** (Item A above). No compiler or runtime change.
- **Phase 0 — close blocker 6.** Pin what `JWT.decode` does with an array-valued `aud`, then either
  type it honestly or coerce under a stated rule, with a regression test. Independent of SSO; do it
  before anything reads provider claims.
- **Phase 1 — `Tesl.Sso` runtime, OIDC family.** `dsl/sso.rkt`: discovery + cached document, PKCE
  S256, `state`/`nonce` + the `__Host-oauth` cookie (short `Max-Age`, `SameSite=Lax` — **not
  `Strict`**: the callback is a top-level cross-site GET and `Strict` would drop the cookie), code
  exchange over `HttpClient.post`, claim validation, one-time `state` consumption. All internal; no
  Tesl surface yet. Tests are pure-Racket plus `stubHttp`.
- **Phase 2 — plain-OAuth2 path + the types.** The userinfo call and its field mapping, GitHub's
  second `/user/emails` call, `SsoProvider`/`SsoConnection`/`SsoIdentity` and `Sso.defaults` as
  tables-only stdlib rows. Same runtime, same `SsoIdentity`. **Fail-closed rule lands here:** an
  absent or unparseable `emailVerifiedField` yields `emailVerified = False`, never `True`.
- **Phase 3 — the `sso` clause.** Parser/AST/validation/emit; route minting from the literal segment;
  route-collision checking; client-generation exclusion; `onIdentity` as an `auth`-kind declaration
  with the proof-kernel wiring reviewed explicitly.
- **Phase 4 — surface polish.** Template with a working three-button login,
  `example/learn/lessonXX-sso.tesl`, LANGUAGE-SPEC section carrying **both** trust arguments (§3.1.3.7
  for OIDC; PKCE + `state` + single-use code + server-side userinfo for plain OAuth2 — they are
  different arguments and must be written separately), the account-linking rule, and one reference IdP
  made the tested enterprise path (Entra ID recommended — largest share, most quirks).
- **Phase 5 — adversarial review pass, mandatory**, matching
  `roadmap/completed/session_cookie_security_followups.md`. Minimum attack list: `state` replay and
  cross-user `state` swap; PKCE verifier reuse; `nonce` omitted or unchecked (OIDC) and the absence of
  a `nonce` equivalent (plain OAuth2); `iss`/`aud` confusion; a `code` replayed twice; a provider
  returning 200 with an error body; **SSRF via any user-supplied issuer/token/authorize/userinfo
  host**; a discovery document served over plain HTTP or redirecting off-origin; **account takeover by
  linking on an unverified email**; an `emailVerifiedField` pointing at a missing or non-boolean field;
  one provider asserting another provider's `subject`; `Set-Cookie` leaking through a `fail` path; and
  an `afterLogin` value pointing off-origin.

*Exit for the whole item:* two end-to-end api-tests — one OIDC (stubbed discovery → token → callback)
and one plain OAuth2 (stubbed token → userinfo → callback) — each driving login → session cookie →
protected endpoint with no live provider; `dune test` and `./compile-examples.sh` green; the stdlib
binding-existence seam test covering every new name.

## Non-goals

- **In-app multi-tenant per-org SSO** (each customer org bringing its own IdP). **Route through an SSO
  broker instead** — WorkOS, Auth0 Organizations, Stytch, Descope exist to be exactly this layer: the
  app integrates **one** OIDC connection to the broker, and the broker fans out per customer to
  Entra/Okta/Google/**SAML**, and ships domain verification and the org-admin self-service UI with it.
  So the single-connection clause above **already is** the answer to multi-tenant SSO, and it gets
  SAML — which we will never ship — as a side effect. The residual case (won't pay a broker, or
  air-gapped) is real but narrow, and most of what it needs is not Tesl's: tenant-resolution UX
  (subdomain vs. email-domain interstitial vs. explicit), per-tenant client secrets encrypted at rest
  (`Secret` redacts rendering sinks; it says nothing about storage), an org-admin config +
  test-connection UI, and domain verification. **The `connection` hook is deliberately a function so
  this stays reachable later without redesigning the clause** — a multi-tenant implementation takes the
  tenant from `state` and returns that tenant's row, over one shared callback. If it is ever built, two
  requirements are non-negotiable and are the most commonly missed parts of DIY multi-tenant SSO:
  identity must key on `(tenant, issuer, subject)` and never on email — otherwise tenant B configures
  an IdP, asserts `alice@acme.com`, and takes over tenant A's user — and a tenant's IdP must not be
  allowed to authenticate a domain until that tenant has proven control of it (DNS TXT or equivalent).
- **Persisting the provider access token.** It is used once, for the userinfo call, and discarded. The
  moment it is stored we are an OAuth client library for calling third-party APIs on a user's behalf —
  different feature, different threat model.
- **Blessed defaults for Apple, Facebook or X/Twitter.** Apple is blocked (ES256 signing); the other
  two are reachable by hand-written `OAuth2Endpoints` and do not earn a table row.
- SAML, WS-Fed, LDAP.
- MFA, conditional access, password policy — the explicit point of delegating to a provider.
- Refresh tokens / offline access. Tesl's session is its own 1h JWT under a 12h absolute cap;
  re-login is a redirect.
- Token introspection, back-channel or front-channel logout notifications, SCIM/user provisioning,
  group/role sync.
- IdP-initiated login; implicit and hybrid flows.
- `Http.redirect` and any general redirect surface — **separate item**.
- Server-side session revocation (unchanged non-goal, LANGUAGE-SPEC §21.8).
- Hot-reloading provider configuration. The `connection` hook runs per login, so credentials can come
  from anywhere; the clause itself is fixed at server construction.

## Risks & containment

1. **`onIdentity` mints `Authenticated` from third-party assertions.** Contain: it is an `auth`-kind
   declaration, so minting stays at an existing sanctioned boundary and inside the proof kernel's
   remit — no second minting site, no `fn→Fact` reopening. Reviewed explicitly in Phase 3.
2. **Account linking is an account-takeover vector, and social login makes it unavoidable.** Three
   login buttons mean one human arrives as three identities; keyed on `(provider, subject)` that is
   three accounts. Linking them **by email address is a takeover vulnerability unless that provider
   provably verified the address**: an attacker signs up at a provider permitting an unverified
   address, claims `victim@gmail.com`, and inherits the victim's account. GitHub makes this concrete —
   `/user`'s email is the *public profile* field and unverified, so the verified primary requires the
   second `/user/emails` call. Contain: `SsoIdentity.emailVerified` is load-bearing and the blessed
   descriptors populate it honestly; the shipped template **refuses to link on an unverified email**
   and offers explicit "link account" while already authenticated; the lesson teaches this as a rule,
   not advice.
3. **`emailVerified` is now user-configurable, so a config typo can forge it.** `emailVerifiedField`
   comes from a value the user may hand-write. Contain: **absent, missing at runtime, or
   non-boolean ⇒ `False`, never `True`** — fail closed, asserted by test. Without this rule, Risk 2
   becomes reachable through a misspelled field name.
4. **Identity keyed on the wrong claim.** Even single-provider, matching a user by `email` rather than
   `(provider, subject)` is wrong: `email` is mutable at most providers and reassignable at some, so a
   reassigned address silently inherits the previous holder's account. Contain: the lesson and template
   upsert on `(provider, subject)`; `email` is display data.
5. **SSRF via configuration — now wider, because every endpoint can be user-supplied.** `issuer`,
   `authorizeUrl`, `tokenUrl` and `userinfoUrl` all drive outbound requests. Contain: require `https`,
   refuse redirects off the origin, refuse literal-IP and loopback/link-local hosts outside an explicit
   dev override. Applies identically to blessed defaults and hand-written values.
6. **Open redirect via `afterLogin`.** Contain: relative or same-origin only, validated where the
   clause is compiled, not at runtime.
7. **Discovery is a network call.** Fail-closed stops the app booting during a provider outage;
   fail-open boots without SSO. Neither is obviously right, and both break offline dev and hermetic
   tests. Contain: fetch lazily at first login, cache the document, and let a hand-written
   `OAuth2Endpoints`/explicit-endpoint value bypass discovery entirely — which is also what `stubHttp`
   api-tests use.
8. **Runtime-minted routes leaking into generated clients.** A typed Elm/TS client that `fetch`es
   `/auth/github/login` receives a 303 it cannot act on. Contain: explicit non-emission, asserted by a
   byte-identical-output test in the style of `compiler/test/test_session_cookie.ml`.
9. **`OAuth2Endpoints` is a wide surface a user can get wrong.** Contain: nobody types it in the common
   case (they call `Sso.defaults`); the fail-closed rule in Risk 3; the SSRF rules in Risk 5; and a
   clear error when a userinfo response lacks `subjectField` rather than a silent empty subject.
10. **Parser blast radius** — the `server` block has no non-route clause today. Contain: land the
    runtime and the tables-only types (Phases 1–2) behind tests before touching the frontend, so a
    stalled Phase 3 still leaves working, tested machinery.

## Open questions

1. **Is `sso` a clause on `server`, or a top-level declaration referenced by name from the server?**
   The latter is likely cheaper to parse, composes with the two-API pattern more obviously, and reads
   better when three providers are configured. RECOMMENDATION: prototype both against
   `emit_racket.ml`'s statement lists before committing.
2. **Where do the shared settings live** (`ssoSessionKey`, `afterLogin`) when several `sso` clauses
   coexist — repeated per clause, or once per server? RECOMMENDATION: once per server; a per-provider
   session key or landing page has no use case and multiplies the config surface.
3. **Who signs the session JWT — the runtime (from the shared session key) or `onIdentity` (returning
   a token)?** Runtime-signs is tighter and keeps the flow closed; user-signs preserves the existing
   `JWT.sign` idiom and lets the app add claims. RECOMMENDATION: runtime signs, and `onIdentity`'s
   returned subject is the only input — extra claims are a follow-up if anyone asks.
4. **Does `state` need to survive a server restart?** Cookie-only means an in-flight login fails after
   a deploy (acceptable: retry is one redirect). A DB row survives but adds a table and a cleanup job.
   RECOMMENDATION: cookie-only.
5. **Does the `connection` hook take an argument?** `() -> Maybe SsoConnection` is enough for v1, but
   the multi-tenant extension wants the tenant resolved from `state`/the request. Settle the signature
   now even though nothing uses the argument yet — widening it later is a breaking change to every
   user's hook. RECOMMENDATION: `HttpRequest -> Maybe SsoConnection`.
6. **Should `Sso.defaults` be capability-free?** It only builds a record — but the `env`/`requireSecret`
   calls the user feeds it already carry `envRead`, so the function itself needs nothing.
   RECOMMENDATION: pure, no capability row.
