# SSO / third-party auth — document the proxy pattern, then one declarative clause over a function-supplied connection

Overarching goal: A user making their app in Tesl should get best-in-class (app) security for free without any friction. As always the developer experience should be fantastic, the compiler helpful and the underlaying runtime should be water tight.

**Status: PLANNED** (drafted 2026-07-30, expanded and re-scoped from the original ask; first security
review folded in 2026-07-30 — see **Phase −1**, which gates everything else; **second, adversarial
review folded in 2026-07-30** — see **Phase 2.5** (ID-token signature verification, now in scope),
**§Entra ID and the multi-tenant issuer trap**, **§What `onIdentity` does when it says no**, and the
honesty correction to **Item A**. **Third review folded in 2026-07-30**, taking the item *as a whole*
rather than the flow alone — its finding is that the flow reaches gold standard while the item's
claim does not, because the two account-takeover decisions were enforced by prose rather than by
types, mixed-mode password login was unconsidered, and four platform properties the claim rests on
were filed as someone else's problem. See **§Typed identity, not documented identity**, **§Login
methods and the mixed-mode bypass**, **§Session key rotation**, **§The platform baseline this claim
rests on**, **Phase −2**, and Risks 32–41. **Fourth review folded in 2026-07-30**, checking the
plan's claims against the tree rather than against the plan. Its findings: two compensating controls
named in this document cannot be implemented as specified (single-use `state` under cookie-only
storage; HSTS "on every https response" in a runtime with no trustworthy notion of "https"); the
header baseline as scoped would still miss the two response paths that skip *every* header today —
the SPA fallback and the static file responder, which are also the two that serve the app's own
HTML; SSRF containment was hostname-shaped where the threat is resolution-shaped; and the mixed-mode
bypass was contained by a warning this document itself predicts will be ignored. See **§Where the
flow's own state lives**, **§Login methods and the mixed-mode bypass** (now a checked declaration,
not a warning), **§The platform baseline this claim rests on**, **Phase −2**, and Risks 42–55.
**Fifth review folded in 2026-07-30**, checking the *new checks themselves* against the codebase's
own diagnosed root failure mode (decide-by-spelling, fail-open-by-enumeration). Its findings: the
`loginMethods` compile check was a password-call denylist that misses every hand-rolled or future
login path — now an allowlist over `auth` blocks, the enumerable minting sites; Item A's
binding-secret discharge had no semantic definition and was dischargeable by `secret == secret` —
now defined by dataflow, with the forged shapes as compile-time negatives; the session signing key
was about to be reused raw across two algorithms — now purpose-derived subkeys; `SsoSubjectKey`'s
derivation was never stated to be injective — now length-prefixed or hashed, collision-tested; and
two fail-closed rules would have broken real deployments into disabling them (`Host` validation vs.
health probes, `Sec-Fetch-Site` vs. non-browser clients) — both get stated, tested exceptions. See
**§Login methods** (re-shaped again), **§Item A**, **§Where the flow's own state lives**, **§Typed
identity**, **§The platform baseline**, Risks 56–62, and Open Question 18. **Sixth review folded in
2026-07-30**, checking the fifth review's own enforcement boundary against the tree. Its findings: the
`loginMethods` allowlist classified `auth` blocks, but `auth` blocks *verify* sessions — the
session-minting chokepoint in the tree is `Http.setSessionCookie` behind `cookieCap`, called from
plain handlers (lesson76's own login is one), so a magic-link handler — the fifth review's own listed
example — still compiled under `loginMethods [Sso]`; the allowlist now classifies the cookie-writing
sites, keeping the `auth`-block rule for per-request minting. Two gates were *recognisable* rather
than *unforgeable* — Item A's dataflow discharge and the `Bool`-returning password gate — and both
become runtime-minted witnesses on the `PasswordHash`/proof-kernel precedent, which deletes the
planned checker dataflow analysis instead of hardening it. And the frozen auth-event `client IP`
field records the proxy's socket address until a trusted-proxy declaration exists. See **§Login
methods** (re-shaped a third time), **§Item A**, Open Questions 15 and 18 (revised), Risks 63–65, and
the exit criteria, which now require an external pass over the new checker rules themselves. The
sixth review also moves **per-user session revocation** off the exclusion list: the request-path
store stays declined, but a fail-closed check consulted only when a session **renews** bounds
revocation latency to the renewable TTL with the verify path untouched — see **§Revocation at the
renewal boundary**, item 38, Risk 66, Open Question 19; the platform claim's named exclusions drop
to two (rate limiting, app-frontend XSS). Rate
limiting remains explicitly **DEFERRED** — see Risk 19 and **§How rate limiting slots in later** —
but its *scope* is corrected: it now covers the password endpoint, which is a worse thing to leave
unmetered than the two SSO routes.)

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
   Blocker 7, Phase −1.
1. **It does not work today.** Eight blockers, mapped below.
2. **Split the item.** Document the authenticating-proxy pattern first (Item A, no language change,
   the honest recommendation for most teams). Then build the in-app flow (Item B). **Item A enforces
   no property Tesl can check** — see the honesty note in Item A; that is an argument for Item B, not
   against it.
3. **Item B is a declarative clause, not a set of primitives.** A `sso` clause on the `server` block,
   with the runtime owning both endpoints. This *deletes* four of the six original blockers from the
   language surface rather than solving them — it is strictly **less** new Tesl surface than exposing
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
11. **ID-token signature verification is IN SCOPE (Phase 2.5), not deferred.** The earlier draft
    leaned entirely on OIDC Core §3.1.3.7 (TLS in place of a signature check). That argument is
    spec-legal but it is **not** gold standard, and it fails in exactly the enterprise networks this
    item blesses — see §The trust argument, honestly. Phase 2.5 lands RS256/ES256 *verify* + JWKS.
    Asymmetric **signing** stays out (that is what still blocks Apple).
12. **Rate limiting is DEFERRED, explicitly and in writing.** No rate-limiting subsystem exists
    anywhere in the tree; building one is not in this item's scope. The compensating controls that
    *are* in scope are named in Risk 19, and the residual exposure is stated in the spec rather than
    left implicit.
13. **Session lifetime becomes a closed `SessionPolicy` ADT, not a duration.** `StandardSession`
    (1h/12h, the default and today's behaviour) and `ShortSession` (15min/8h). Server-wide, not
    SSO-specific; the absolute cap is named per constructor rather than derived from the TTL. It is the
    only control over the IdP-revocation window, which is why it is in scope here. §Session policy.
14. **`SsoIdentity` is reshaped so the two takeover rules are types, not lesson text.** An unverified
    email is a different constructor from a verified one, the storable identity is an opaque
    `SsoSubjectKey` that contains no email, and `claims` loses its string-flattening. Risks 2, 3, 4
    and 18 were previously contained by "the template and the lesson teach this"; that is the same
    unenforceable-guarantee shape the honesty note rejects in Item A. §Typed identity, not documented
    identity, and Risk 32.
15. **Mixed-mode login is named, because SSO's whole value can be bypassed by the password form next
    to it.** Tesl already has `Crypto.hashPassword`/`checkPassword`, so an app that adds SSO usually
    keeps passwords, and a password account on an SSO-mandated address bypasses the IdP's MFA and
    conditional access with every control in this document intact. §Login methods, Risk 33.
16. **The session signing key becomes rotatable.** `kid` is already stamped
    (`tesl/jwt.rkt:244`) but verification takes a single key, so a leaked `SESSION_KEY` cannot be
    rotated without terminating every session — and with server-side revocation a standing non-goal
    there is then no kill switch at all. Verify against `[current, previous]`, sign with current.
    §Session key rotation, Risk 34.
17. **Four platform properties are named as blockers of the *claim*, not as SSO non-goals**: security
    response headers server-wide, the `SameSite`-only CSRF posture, session revocation, and rate
    limiting. Only rate limiting stays deferred, and it now has a stated slot-in shape so landing it
    later costs no redesign. §The platform baseline this claim rests on, §How rate limiting slots in
    later.
18. **`listenAddress` stops being "possibly".** Item A's pattern has exactly one safe deployment and
    it must be expressible — preferably checkable — in the program before the pattern is published.
    Phase −2, Risk 31 (revised).
19. **Exit requires one real IdP.** Every test in the earlier draft was `stubHttp`, which cannot
    falsify our own reading of the specs. One containerized IdP in CI, plus one OIDC conformance run
    before the phrase "gold standard" ships. Risk 37.
20. **Mixed-mode login becomes a checked `loginMethods` declaration, not a linter warning.**
    `loginMethods [Sso]` makes a password path a **compile error**; `loginMethods [Sso, Password via
    ssoRequired]` routes every password check and every password *set* through one runtime-mediated
    gate, so there is no second or third call site to forget. The mandate stays app data; *that the
    check happens* stops being the author's responsibility. §Login methods, Risk 46, Open Question 14
    (settled the other way).
21. **The flow's own in-flight state gets integrity rules, and one claim gets retracted.**
    `__Host-oauth` is authenticated under the session key (a client-writable blob decided this login's
    `nonce`, verifier and start time), and "single-use `state`" — which two other controls were leaning
    on — is honestly rescoped, because it is not implementable under cookie-only storage. §Where the
    flow's own state lives, Risks 42–43.
22. **"Is this request https" is answered by `publicOrigin`, never by the request.** There is no
    `X-Forwarded-*` handling anywhere in the tree and this document forbids adding trust in it, so an
    HSTS rule conditioned on the request would emit nothing in exactly the proxy-fronted deployments
    that need it. Risk 44.
23. **The header baseline covers the static file responder and the SPA fallback, and carries a CSP
    default for HTML that Tesl serves.** Those two paths pass `'()` headers today — not even
    `nosniff` — and Tesl, not the app, serves the app's `index.html`, so "the app writes its own CSP"
    was unachievable in-language. Without this, XSS in the served frontend defeats every session
    control in this document by calling the API with the victim's cookie. Risk 45.
24. **SSRF containment moves from hostnames to resolved addresses**, with connect-time pinning, and it
    applies to `jwks_uri` — the one URL that arrives from a document rather than from config.
    Risk 47.
25. **The CSRF posture is recorded as the trio the code already relies on**, not as "the cookie
    attribute is the defence": `SameSite=Lax` + 415-on-non-JSON (`dsl/web.rkt:1308`) + no CORS
    headers. Plus two cheap additions — `Sec-Fetch-Site: cross-site` refused on state-changing
    requests, and inbound `Host` validated against `publicOrigin`. Risks 49–50.
26. **Item A's compile-time discharge accepts a verified proxy-binding secret**, not only a loopback
    `listenAddress` — because a container or pod must bind `0.0.0.0` to be reachable, so a
    loopback-only rule would degrade to the acknowledgement escape in the target deployment. Risk 48.
27. **Domain restriction becomes runtime-enforced connection fields**, not a claim check the template
    demonstrates and the author must remember — and it is satisfiable only by `VerifiedEmail`.
    Risk 53.
28. **Exit adds one real browser.** Every listed test asserts server-side bytes, but `__Host-`
    acceptance, `SameSite` behaviour on the callback navigation and `HttpOnly` are browser behaviours
    whose failure mode is silent non-storage. Risk 55.
29. **`loginMethods` classifies every `auth` block, not just password calls.** The fourth review's
    check — find `Crypto.checkPassword`/`hashPassword` — was denylist-shaped and misses every login
    path not spelled with those names (magic links, API keys, hand-rolled compares, future WebAuthn).
    `auth` blocks are the enumerable sanctioned minting sites, so the allowlist form is checkable
    today: under a `loginMethods` declaration, an `auth` block not attributable to a declared method
    does not compile. The password-call rejection stays as a backstop one level down. §Login methods,
    Risk 56, Open Question 18. **Corrected in part by the sixth review (item 35, Risk 63): `auth`
    blocks verify sessions rather than create them, so the primary allowlist boundary is the
    cookie-writing sites; this rule is kept for the per-request minting it does govern.**
30. **Item A's binding-secret discharge is defined by dataflow, not by shape.** A discharge
    recognisable by spelling is dischargeable by `secret == secret`. It holds only when a
    config-originated `Secret` is compared against a value read from `request.headers` and the mint
    is control-dependent on that comparison succeeding — with the forged shapes as compile-time
    negatives. §Item A, Risk 57.
31. **One key is never used for two purposes.** The `__Host-oauth` MAC/AEAD key is derived from the
    session signing key with domain separation (libsodium `crypto_kdf`, distinct contexts), never
    the raw key that HMACs the session JWT; rotation carries through because subkeys rotate with
    their parent. §Where the flow's own state lives, Risk 58.
32. **`SsoSubjectKey` derivation is injective.** Naive concatenation lets `("https://a",
    "x|https://b")` collide across issuers; the derivation is length-prefixed or a domain-separated
    hash, and Phase 5 carries a cross-issuer collision test. §Typed identity, Risk 59.
33. **Two fail-closed rules get stated exceptions so they survive contact with production.** `Host`
    validation exempts a declared probe path (Kubernetes/LB health checks send `Host: <ip>`, and a
    restart-looping pod ends with the check disabled); the `Sec-Fetch-Site` refusal fires only on the
    literal `cross-site` value, an absent header allows (non-browser clients never send it). §The
    platform baseline, Risks 60–61.
34. **Rate limiting stays deferred, but the future item's landing spot is now named.** §Login
    methods' runtime-mediated password gate is exactly the dispatch-level chokepoint that item
    requires; its first work is gate-local — a per-identifier throttle plus a process-wide Argon2id
    concurrency cap. §How rate limiting slots in later.
35. **`loginMethods` classifies the cookie-writing sites; `auth` blocks were the wrong boundary.** The
    fifth review's allowlist was over `auth` blocks, but those *verify* sessions — lesson76's own login
    is a plain handler calling `JWT.sign` + `Http.setSessionCookie`
    (`example/learn/lesson76-sessions.tesl:256`), so a magic-link handler — the fifth review's own
    listed example — compiled under `loginMethods [Sso]`, caught by neither the allowlist nor the
    password-call backstop. The true chokepoint is unique and already capability-gated
    (`Http.setSessionCookie` behind `cookieCap` is the only cookie-writing function, by lesson76's own
    guarantee): under a `loginMethods` declaration every reachable call site of it must be attributable
    to a declared method. The `auth`-block rule stays for per-request minting. §Login methods, Risk 63.
36. **Discharges are runtime-minted witnesses, not recognised code shapes.** Item A's binding-secret
    discharge was a dataflow pattern for the checker to recognise, and the password gate returned a
    `Bool` a caller can discard and mint anyway. Both become runtime functions minting evidence only
    the kernel can mint (`Proxy.verifyBinding`; a witness-returning password gate) on the
    `PasswordHash`/fact precedent — the forged shapes become unrepresentable instead of detected, and
    the planned checker dataflow analysis is deleted rather than built. §Item A, §Login methods,
    Risk 64, Open Question 15.
37. **The auth event's client-address field is named for what it records.** Behind every real
    deployment the socket peer is the proxy, and the trusted-proxy declaration is deferred with rate
    limiting — so the field ships as `peerAddress` (or with socket-peer semantics documented on it),
    and `clientIP` appears only when a trusted-proxy declaration can make it true. Risk 65.
38. **Per-user revocation moves from standing gap to renewal-boundary check.** The non-goal's argument
    covers a store *on the request path*; a check at **renewal** costs one read per session per TTL,
    keeps verify stateless, and bounds revocation latency to the renewable window (≤1h
    `StandardSession`, ≤15min `ShortSession`) — the same semantics as the access/refresh-token
    architecture, where the refresh boundary is the control point. Optional fail-closed hook over the
    app's own schema; absent hook is today's behaviour. It does **not** shorten the
    IdP-deprovisioning window by itself — that is stated, not implied. §Revocation at the renewal
    boundary, Risk 66, Open Question 19.

## The answer to "it is not clear if it works": it does not

Mapped 2026-07-30. The intuition in the Notes is right, and the list is longer than "we need to
redirect". Ranked by how hard each blocks, with what the declarative model does to it. Blockers 7 and
8 were added by the first security review and are the only two that the declarative model does **not**
make cheaper — they must be built:

| # | Blocker | Evidence | Under the declarative model |
|---|---|---|---|
| 1 | No non-2xx-with-`Location` response is reachable from Tesl | `handler-result->response` `dsl/web.rkt:1777-1798` returns JSON or `error-response`. Runtime half already exists — `dsl-response` is `(status headers body)` :132, `json-response` takes `#:status`/`#:headers` :1221 | **Deleted from the surface.** Redirects happen inside runtime-owned routes, in Racket |
| 2 | `Set-Cookie` attaches on 2xx only — and the callback needs cookie **plus** 303 | `(and (>= status 200) (< status 300))` `dsl/web.rkt:1223`, a deliberate rule with a test behind it (lesson76: a handler that sets a cookie then `fail`s sends none) | **Internal.** Never becomes a language rule; lesson76's `fail`-path guarantee stays literally true |
| 3 | JWT is HS256 only; OIDC ID tokens are RS256/ES256 with JWKS + rotation | `{"alg":"HS256",…}` hardcoded `tesl/jwt.rkt:244`; primitive is HMAC-SHA256 `tesl/crypto.rkt:511`; the crypto backend is **libsodium**, which has no RSA and no P-256 at all (`tesl/crypto.rkt:84-140`) | **Must be built — Phase 2.5.** The §3.1.3.7 dodge is spec-legal but not sufficient (see below). Verify-only, via `openssl/libcrypto`, which `tesl/jwt.rkt:88` already requires. Asymmetric *signing* stays out, which is still why Apple stays out |
| 4 | No percent-encoding and no base64url on the Tesl surface, so neither the authorize URL nor PKCE `S256` is expressible | `base64url-encode` exists but is internal to `tesl/crypto.rkt:276`, absent from its `provide` (:60-76). `plain` PKCE is not an acceptable substitute | **Deleted.** Runtime builds the URL and the challenge |
| 5 | Exactly one cookie exists and its value type is `JwtToken`, so `state`/`nonce`/verifier have no browser-bound home | `session-cookie-name` fixed to `__Host-session` `tesl/http.rkt:58`; general cookie handling is a stated permanent non-goal (lesson76) | **Invisible.** Runtime owns `__Host-oauth`; "exactly one cookie" stays true *of the Tesl surface* |
| 6 | `JWT.decode : JwtToken -> Dict String String` but the runtime returns raw `string->jsexpr`; an ID token's `aud`/`amr` are often JSON **arrays** | `type_system.ml:871` vs `tesl/jwt.rkt:629` | **Off the critical path** — runtime parses claims in Racket and hands the user a typed record. Still a real defect; fix it in Phase 0, before anything reads provider claims |
| **7** | **`HttpClient` does not authenticate its TLS peer.** No certificate validation, no hostname check | `(http-conn-open host #:ssl? use-ssl? #:port port)` `tesl/http-client.rkt:395` and `:495`, where `use-ssl?` is the bare boolean `(equal? scheme "https")` :80. Racket's `#:ssl? #t` takes the default client context, which does not verify; `ssl-secure-client-context` occurs **zero** times in the tree | **Must be built, and first.** Not an SSO problem — a live defect for every existing `HttpClient` caller (webhooks, payment APIs). Phase −1 |
| **8** | **No configured public origin exists**, so `redirect_uri` has no trustworthy source | no `baseUrl`/`publicOrigin`/`PUBLIC_URL` concept in `tesl/http.rkt` or `dsl/web.rkt` | **Must be built.** Deriving it from `Host`/`X-Forwarded-Host` is redirect-URI poisoning. New required server-level setting, https-validated at compile time |

**What already works and needs nothing** (with blocker 7 fixed — read every "`HttpClient` handles this"
claim below as conditional on it)**:** `Env.requireSecret` → `Secret` (`tesl/env.rkt:26`);
`Secret` is a genuine constructor `String -> Secret` (`type_system.ml:923`), so a connection secret
can come from anywhere; arbitrary outbound headers/bodies for the token exchange and the userinfo
call (`HttpClient.post`/`HttpClient.get` `tesl/http-client.rkt:523-531`, CRLF-guarded :52); CSPRNG
tokens (`Crypto.randomToken`, 256-bit base64url, :500); constant-time comparison
(`crypto-constant-time-equal?` `tesl/crypto.rkt:252`); `request.queryParameters` for `?code=&state=`
(LANGUAGE-SPEC :638, `dsl/web.rkt:2325`); record update `{ base | field = val }` for the override
story (`compiler/lib/parser.ml:2324`); ADT variants with named field declarations
(LANGUAGE-SPEC:2993); `Cache-Control: no-store` already emitted on some responses (`dsl/web.rkt:1281`,
`:2295`); and a complete test story — `stubHttp` (`dsl/test-support.rkt:328`) fakes discovery, token
and userinfo endpoints from a `.tesl` api-test, which already carries cookies across requests and
takes inline query strings; and **password authentication already exists** (`Crypto.hashPassword` /
`Crypto.checkPassword`, libsodium Argon2id — `type_system.ml:925`, `stdlib_docs_entries.ml:690`), which
is what makes §Login methods a live concern rather than a hypothetical one, and whose `PasswordHash` is
the exact precedent for `SsoSubjectKey`'s opacity (no constructor, storable, redacted).

**Correction from the third review to the earlier claim "no new test infrastructure and no live
provider":** the stub-level suite needs neither, and that still holds — but stubs cannot falsify our own
reading of the specs, so exit now also requires one containerised IdP in CI and one OIDC conformance run
(Risk 37). That is new CI infrastructure, and it is small, but it is not nothing.

## Item A — the authenticating-proxy pattern (do first, no language change)

The overwhelmingly common production answer to "does your app support Entra ID?" is an
authenticating reverse proxy — oauth2-proxy, Cloudflare Access, Azure App Service Easy Auth, an ALB
OIDC listener. The proxy runs the whole flow and hands the app a verified identity header.

**This works with Tesl today, unchanged**: an `auth` block reads `request.headers` and produces
`::: Authenticated user`. It also delivers MFA, conditional access, SAML and IdP-initiated login for
free — exactly the "scope out MFA from Tesl" goal in the ask, with zero language work.

> **Honesty note — Item A enforces nothing that Tesl can check.** Its entire security rests on
> deployment topology the compiler and runtime cannot inspect: that the app is unreachable except
> through the proxy. A phrase like "a network path that provably cannot be bypassed" is a hope, not a
> property. So Item A is the right *recommendation* and the wrong thing to call a guarantee — and
> "Tesl users get a secure system for free" is achievable only for Item B, where the runtime owns the
> flow. Document Item A as a pattern with a checklist; do not let it read as a Tesl security feature.

It is written down nowhere, and documenting it is a **security** task, not a docs task:

> **An `auth` block that trusts a request header is a forgery machine if the app is ever reachable
> without the proxy in front of it.** Anyone who can reach the app directly sets the header and
> becomes any user. This must be stated with the force of the `__Host-` argument in lesson76,
> together with the mitigation: bind the app to the proxy — a shared `Secret` header compared with
> `Crypto.checkSignature` (or the constant-time `==`), or mTLS, or a network path that cannot be
> reached from outside — and fail closed when the binding is absent.

**Tesl currently binds to every interface, so the naive deployment of this pattern is exposed.**
`serve/servlet` is called with `#:listen-ip #f` (`dsl/web.rkt:2386`), which in Racket means *all*
interfaces, v4 and v6. A user who follows the proxy pattern on a host with any other reachable
interface — a cloud VM with a public IP, a container on a shared bridge network, a laptop on a café
network — is serving the header-trusting app directly to that interface. The Item A deliverable must
therefore name the concrete binding, not just the principle:

- **Bind to loopback (or a unix socket) whenever the identity-header pattern is used.** SETTLED by the
  third review: Tesl grows the setting, it lands *before* the pattern is documented (Phase −2), and
  the pattern is **compiler-checked** rather than merely described. An `auth` block whose only evidence
  is a request header may not compile unless the program either declares a loopback/unix-socket
  `listenAddress` or writes an explicit acknowledgement clause. Deployment instructions cannot be
  checked; a declaration can, and this is the single change that moves Item A from "a pattern we
  recommend" to "a property Tesl holds". The acknowledgement escape exists because a container network
  or systemd socket activation is a legitimate answer the compiler genuinely cannot see — but it must
  be *written in the program*, so the reviewer of that program sees the trust assumption instead of
  inferring it from a deploy script. See Risk 31 (revised) and Phase −2.
- **Revised by the fourth review: a verified binding secret discharges the rule too, and is the
  discharge most deployments will actually use.** A loopback-only rule sounds strongest but fails in the
  target deployment: an app in a container or a Kubernetes pod **must** bind `0.0.0.0` to be reachable
  by its sidecar or service, so `listenAddress Loopback` is unavailable and the acknowledgement escape
  becomes the normal path — at which point the compile-time check is ceremony in exactly the
  environments the pattern is written for. The control that *is* visible in the program regardless of
  topology is the binding itself: an `auth` block that compares a `Secret` against the proxy-supplied
  binding header with `Crypto.checkSignature` or the constant-time `==` is checkable, and it is also the
  stronger of the two controls, because it survives a host that has other reachable interfaces. So a
  header-trusting `auth` block compiles if **any** of three hold: a loopback/unix `listenAddress`, a
  verified binding-secret comparison in the block's own evidence, or the explicit written
  acknowledgement. The acknowledgement stays as the last resort (mTLS terminated at the proxy is a real
  answer the compiler cannot see), but it should no longer be the only reachable one.
- **Added by the fifth review: the binding-secret discharge is defined by dataflow, not recognised by
  shape.** "A verified binding-secret comparison in the block's own evidence" must not be a syntactic
  pattern — otherwise `secret == secret`, a constant-time compare of two header values, or a compare
  against a literal each discharge the rule, and the check joins the decide-by-spelling class the
  2026-07-05 forgery reviews reopened. The discharge holds only when all three facts are established
  on the dataflow: (1) one operand is a `Secret` originating in configuration (`requireSecret` or a
  connection value), (2) the other operand is read from `request.headers`, and (3) the fact-mint is
  control-dependent on the comparison succeeding — a false branch that still mints does not
  discharge. Phase −2 carries the forged shapes as compile-time negatives (Risk 57).
- **Revised by the sixth review: the discharge is a runtime-minted witness, and the dataflow analysis
  is deleted rather than built (Risk 64).** Risk 57's rule is right about what must hold and expensive
  about how: it puts a control-dependence analysis into the checker — the component the 2026-07-05
  reviews identified as this codebase's historically fail-open one — to *recognise* a pattern the
  runtime could simply *own*. Instead, one stdlib function performs the comparison and mints evidence
  only the kernel can mint: `Proxy.verifyBinding : Secret -> HttpRequest -> …`, producing a
  `ProxyBound`-style fact on success and failing closed otherwise, on the `PasswordHash`/fact
  precedent this document already leans on twice. The forged shapes (`secret == secret`,
  header-vs-header, a literal compare, a false branch that still mints) stop being negatives the
  checker must catch and become unrepresentable — none of them produces the witness, and the mint
  requires the witness. Control-dependence comes free: the witness does not exist unless the check
  succeeded. Phase −2 keeps the forged shapes as tests, now asserting unconstructibility rather than
  checker vigilance.
- Whichever it is, the lesson must state the interface question explicitly and show the check
  (`ss -ltnp`, or the equivalent) as part of the pattern, because "it works" and "it is bound only to
  the proxy" look identical from the browser.

Three further rules the pattern needs, all easy to miss:

- **The proxy must strip inbound copies of the identity header**, and the Tesl side must **reject a
  duplicated or variant-spelled instance** rather than picking one. Header smuggling — a second
  `X-Auth-User`, or an underscore/dash variant that the proxy normalises differently than the app
  does — defeats the binding without ever touching the shared secret.
- **A static shared-secret header is replayable** by anyone who reads a log line, a HAR file or a
  crash dump; it authenticates the *value*, not the request. Prefer mTLS. If a header is what ships,
  make it a timestamped HMAC with a replay window, or state the weakness explicitly — the naive
  version is not equivalent to mTLS and the lesson must not imply that it is.
- **Only the identity header is trusted, and only for identity.** A proxy that also forwards
  `X-Auth-Groups` / `X-Auth-Roles` is forwarding *its* view of authorization; the app must decide
  whether that is an input at all, and if so it inherits every duplicate-header and spelling-variant
  rule above. Default in the template: identity only, authorization from the app's own tables.

*Deliverable:* one lesson, a `manual/best-practices.md` section, one template `auth` block, api-tests
covering three negatives (no binding header, wrong binding secret, duplicated identity header — each
one 401), the binding-interface guidance, and the warnings above. ~1–2 days, **on top of Phase −2**,
which is now a prerequisite rather than an option — plus compile-time tests over all three discharges: a
header-trusting `auth` block must compile with a loopback `listenAddress`, with a verified binding-secret
comparison in its own evidence, or with the acknowledgement clause, and must **fail** to compile with
none of the three — and with each of Risk 57's forged discharge shapes, which look like the binding
check and are not.

**Item A and Item B may coexist in one program** (a proxy-fronted enterprise deployment that also
offers "log in with Google" to self-serve users), and nothing about that is special: both paths end at
the same `__Host-session` cookie under the same `SessionPolicy`, and the `auth` block and `onIdentity`
are two sanctioned minting sites for the same fact. The rule worth stating is the one from §Login
methods: two ways in means the *weaker* one sets the app's security level, so a program that mandates
SSO for a domain must enforce that on the header path too.

*Rationale for doing it first:* it is what actually closes "does Tesl work with SSO?" for real
deployments, and it is the better answer for most teams. Item B is for teams that will not run a
proxy — self-hosted single binary, air-gapped, or an app that wants "log in with Google" — and it is
the only one of the two where Tesl itself can hold the guarantee.

## Item B — one declarative clause

### The decision that makes it small

**Exchange the third-party identity once, at the callback, for Tesl's own session cookie. Never
verify a third-party token on a normal request.**

Consequences, all good: the entire existing session/proof surface is untouched, all SSO code is
confined to runtime-owned endpoints, and no request-path latency is added.

### The trust argument, honestly

The earlier draft of this item concluded that blocker 3 was **deleted** for the OIDC family: with a
confidential client running the authorization-code flow, the ID token arrives over a direct TLS POST
to the provider's own token endpoint, and OIDC Core §3.1.3.7 *permits* TLS server authentication in
place of verifying the token's signature. That reading of the spec is correct. **The conclusion was
still wrong, on three counts, and the second review reversed it.**

1. **Phase −1 authenticates the channel to whatever chain the host trusts, which is not the same as
   the channel to the IdP.** Enterprise egress TLS-inspection middleboxes install a trusted CA on the
   host. `ssl-secure-client-context` will then validate the middlebox's certificate happily and
   report success. Those middleboxes are routine in precisely the corporate networks where Entra ID
   lives — i.e. the deployment this item blesses as its reference enterprise path. On such a network,
   with signatures unverified, a middlebox (or anything that has compromised one) mints any ID token
   it likes and **nothing** stands in the way.
2. **Choosing not to verify signatures removes the only defence in depth.** The earlier draft made
   this argument itself, then treated Phase −1 as fully discharging it. It does not: Phase −1 makes
   TLS *correct*, not *sufficient*, and a design whose entire identity guarantee is one mechanism has
   no answer to that mechanism failing.
3. **It forecloses things we will want.** `private_key_jwt` client authentication (required by several
   enterprise IdPs and by every FAPI-style profile) needs asymmetric operations anyway; and "we do not
   verify ID token signatures" is a procurement and OIDC-certification failure even where it is
   spec-legal. The point of this item is that a Tesl user passes their customer's security review
   without doing extra work.

**So Phase 2.5 lands RS256/ES256 verification with JWKS.** Scope it honestly: the crypto backend is
libsodium, which has **no RSA and no P-256** (`tesl/crypto.rkt:84-140`), so this is not a new call
against an existing primitive — it is a second asymmetric-verify backend via `openssl/libcrypto`
(already required by `tesl/jwt.rkt:88`, bound lazily so a missing library does not break the
module-level seam test the way `tesl/crypto.rkt:84-88` warns about). Verify only — no signing, so
Apple stays out for the same reason as before.

**Phase 2.5 closes only half of Risk 11, and the spec must not read as though it closes both.** Risk 11
names two distinct losses from an unauthenticated peer: a forged ID token, *and* disclosure of
`client_secret` at the token exchange. Signature verification answers the first. It does nothing about
the second — a TLS-inspecting middlebox that the host trusts still reads the secret out of every
exchange, in either client-authentication method, because `client_secret_basic` and
`client_secret_post` both hand the secret to whatever terminated the TLS. The honest residual is
therefore: **on a network with an interception middlebox, the app's client secret is compromised, and
signature verification is what keeps that from also being an identity forgery.** The real answers are
`private_key_jwt` (asymmetric signing, out of scope — see Non-goals) and a documented secret-rotation
cadence, so the lesson must say to treat the client secret as rotatable and to rotate it on any
suspicion, rather than as a build-time constant.

**`at_hash` and `c_hash` are deliberately not checked, and that is correct here** — they bind an ID
token to an access token or code delivered through a *different* channel, which is a hybrid/implicit
concern. In a confidential-client code flow the ID token and the access token arrive in the same
direct token response, so there is no second channel to bind to. Stated because a reviewer who greps
for them and finds nothing will otherwise file it.

Until Phase 2.5 lands, the §3.1.3.7 path is the *interim* behaviour, and it is only acceptable
because Phase 2.5 is committed in the same item. **The spec text must carry both the §3.1.3.7
argument and its limits**, because "we don't check the signature" reads as a hole until the argument
is stated, and stating the argument without the middlebox caveat is the mistake this section exists to
correct.

Phase 2.5's own rules, each asserted rather than assumed:

- **`alg` is pinned from discovery**, out of `id_token_signing_alg_values_supported`, intersected with
  what we implement. A token whose header `alg` is not in the pinned set is rejected before any
  parsing of its payload. `alg: none` and any HMAC `alg` on an ID token are rejected unconditionally —
  the classic algorithm-confusion attack is "sign the token with the *public* key as an HMAC secret".
- **Key selection is by `kid`**, from the JWKS at the discovery-declared `jwks_uri`, fetched under the
  same rules as every other outbound leg (https only, no redirects, size cap, time cap). Cache with a
  bounded TTL; on an unknown `kid`, refetch **at most once**, rate-limited by a minimum interval, then
  fail — an unbounded refetch on unknown `kid` is a provider-facing amplification primitive.
- **A JWKS key with no usable `kid`, an unsupported `kty`, or an RSA modulus below 2048 bits is
  refused**, not coerced.
- **Key material in the token's own header is ignored, never fetched and never trusted.** `jwk`, `jku`,
  `x5u` and `x5c` are the classic key-injection route: a verifier that honours an embedded or
  linked key lets the token nominate the key that verifies it, which is a total bypass with a valid
  signature. Keys come only from the discovery-declared `jwks_uri` for *that* issuer. Risk 27 implies
  this; it is stated here because the implementation is where it is lost. Also refuse a token carrying
  `crit`, and refuse a five-segment (JWE) token outright rather than attempting to unwrap it.
- **Verification failure is a hard failure**, never a downgrade to the §3.1.3.7 path. Once Phase 2.5
  is in, there is no code path that accepts an unverified ID token.
- **If a userinfo call is ever made on an OIDC connection, its `sub` must equal the ID token's `sub`**
  (OIDC Core §5.3.2). v1 calls userinfo only for the plain-OAuth2 family, so this reads inapplicable —
  but the escape hatch reaches it today (a hand-written `OAuth2Endpoints` pointed at an OIDC provider),
  and Okta/Auth0 deployments routinely need claims the ID token does not carry, so it is the first
  extension anyone asks for. Without the check, one login's claims can be attached to another login's
  identity. Write the rule now; it costs a comparison.

Two claim checks remain mandatory and fail-closed regardless of signature verification — signature
tells you *who wrote* the token, not *what login it belongs to*:

- **`nonce`.** Together with the browser-bound `__Host-oauth` cookie it is what ties the token to this
  login attempt. Absent, unparseable, or mismatched ⇒ reject.
- **`iss` and `aud`.** `aud` must contain the connection's `clientId` and nothing unexpected (and
  `azp` must match it when the claim is present); `iss` must match the issuer that discovery itself
  declared — see Risk 13 and §Entra ID below, which is where "match" stops being a string equality.

Plus the boring ones, stated because omitting them is how real deployments drift:

- **`exp` is required** and checked with a small, fixed leeway (≤ 60s). No leeway is a support burden;
  unbounded leeway is a replay window.
- **`iat` is sanity-checked** — not in the future beyond the leeway, and not older than the in-flight
  login's own start time (which the `__Host-oauth` cookie dates). A token materially older than the
  flow is a replay, not a slow network.

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
                      scopes: List String, extraAuthorizeParams: Dict String String,
                      allowedTenants: List String,
                      allowedEmailDomains: List String,    # runtime-enforced, VerifiedEmail only
                      allowedHostedDomains: List String }  # the `hd` CLAIM, not the authorize param
  | OAuth2Endpoints { authorizeUrl: String, tokenUrl: String, userinfoUrl: String,
                      clientId: String, clientSecret: Secret, scopes: List String,
                      subjectField: String, emailField: Maybe String,
                      emailVerifiedField: Maybe String, nameField: Maybe String,
                      allowedEmailDomains: List String }   # runtime-enforced, VerifiedEmail only

Sso.defaults : SsoProvider -> String -> Secret -> SsoConnection
```

`Sso.defaults` returns the right constructor per provider — `OidcIssuer` for Google,
`OAuth2Endpoints` for GitHub and Discord — with that provider's endpoints, scopes and field mapping
pre-filled. **Blessed scope defaults are minimal** (`openid email profile`; `identify email`;
`user:email`) and widening them is the user's explicit act via record update — a defaults table is a
place where over-broad scope silently becomes every Tesl app's default, so minimality is a rule here,
not a preference.

`allowedTenants` exists only for the multi-tenant issuer problem and is empty in every single-tenant
configuration; see §Entra ID.

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
| Entra ID | `OidcIssuer`, hand-written | **read §Entra ID and the multi-tenant issuer trap before writing the template.** Single-tenant issuer, `tid` checked, no email linking (Entra emits no `email_verified`) |
| Okta / Auth0 / Keycloak / Cognito / … | `OidcIssuer`, hand-written | no table entry needed — the issuer *is* the config |
| GitHub | `OAuth2Endpoints` | `/user` returns only the **public** profile email (often null and unverified). The verified primary needs `user:email` scope and a **second** call to `/user/emails` — the descriptor must encode both calls |
| Discord | `OAuth2Endpoints` | `/users/@me` with `identify email` returns `id`, `email`, `verified`; API version is in the URL path, so it drifts |

**Domain restriction is a claim check, not a request parameter — and the runtime does it, not the
template.** Google's `hd` on the *authorize request* narrows the account picker; an attacker simply
omits it and nothing enforces anything. Real restriction means verifying the **`hd` claim on the
returned ID token**, or the domain of a **verified** email address. The same trap applies to any
"restrict to our tenant" parameter on any provider: only the returned assertion is evidence.

**Revised by the fourth review: this is enforced by the connection, not demonstrated by the
template.** The earlier draft made it "a claim check which happens in `onIdentity`", shown in the
lesson — the same prose-containment shape §Typed identity was written to eliminate, for a rule whose
omission authenticates everyone. A forgotten check compiles, passes every test, and looks right in
review. `allowedTenants` already sets the precedent that a restriction of exactly this kind belongs
on the connection value and is checked by the runtime; `allowedEmailDomains` and
`allowedHostedDomains` are the same rule for the non-Entra providers. Their semantics, all
fail-closed:

- **Empty list ⇒ no restriction** (every single-tenant, open-signup configuration), so nothing changes
  for a program that does not want one.
- **Non-empty `allowedHostedDomains` ⇒ the ID token's `hd` claim must be present and a member.**
  Absent claim is a refusal, not a pass.
- **Non-empty `allowedEmailDomains` ⇒ the identity's email must be a `VerifiedEmail` whose domain is a
  member.** `UnverifiedEmail` and `NoEmail` are refusals — restricting by the domain of an address the
  provider never verified is exactly Risk 2's takeover wearing a control's clothing, so the type that
  already distinguishes them is what the check reads. A consequence worth stating in the template:
  **`allowedEmailDomains` is unusable with Entra**, which emits no `email_verified`; Entra restricts by
  `allowedTenants`, which is the correct mechanism for it anyway.
- **Matching is normalised, on both sides (fifth review, Risk 62).** The comparison is case-insensitive
  over IDNA/punycode (A-label) normalised domains — config values normalised at compile/boot, the
  claim's domain at check time — so `ACME.COM` and `acme.com` are one domain, a Unicode spelling and
  its punycode form are one domain, and a homoglyph domain is a *different* domain rather than a fuzzy
  match. An unnormalised comparison is a restriction walked past with a capital letter.
- **The check runs before `onIdentity` is called at all**, so a refusal takes the denial path in §What
  `onIdentity` does when it says no and no app code ever sees the identity.
- **`onIdentity` may still add its own policy** (per-user provisioning, local disable). The connection
  fields are the floor, not a replacement — but the floor is now the runtime's, which is the part that
  cannot be forgotten.

**Not blessed, but expressible.** Facebook, X/Twitter and bespoke internal OAuth2 servers are reached
by hand-writing an `OAuth2Endpoints` value. No blessing from us, no language change.

**Apple stays genuinely out**: its `client_secret` is not a string but an **ES256-signed JWT the app
must mint and rotate at most every 6 months**. That needs asymmetric *signing*, which Phase 2.5 does
**not** add (it is verify-only, and libsodium offers no P-256 signing either). Revisit only if
asymmetric signing lands for another reason.

### Entra ID and the multi-tenant issuer trap

Entra ID is the reference enterprise path (largest share, most quirks), and it is also where the
issuer rule from Risk 13 — *the discovery document's own `issuer` must equal the configured issuer,
exactly* — **stops being true**. Getting this wrong is one of the most-exploited OIDC
misconfigurations in existence, so it is designed against here rather than discovered in Phase 5.

**What goes wrong.** Configure the tenant-agnostic authority
`https://login.microsoftonline.com/common/v2.0` (or `/organizations/v2.0`) and its discovery document
declares a **templated** issuer, `https://login.microsoftonline.com/{tenantid}/v2.0`. Exact matching
fails immediately, at which point the natural repair is to relax to a prefix or a wildcard — and
`common` accepts **any Microsoft tenant on earth, plus personal Microsoft accounts**. The app then
authenticates the entire internet, with a green checkmark on every other control in this document.

**Rules, all fail-closed:**

- **A discovery `issuer` containing a `{…}` template placeholder is refused** unless the connection
  supplies a non-empty `allowedTenants`. There is no wildcard, no prefix match, and no "trust the
  authority host" mode.
- **When `allowedTenants` is supplied**, the token's `tid` claim must be a member of it, and the
  token's `iss` must be exactly the templated issuer with `{tenantid}` replaced by that same `tid`.
  Both checks, not either.
- **`tid` therefore joins the authorization inputs.** This is the one exception to Risk 18's
  "`claims` is never an authorization input": `tid` is *not* read out of the loose `claims` dict; it
  is a typed, runtime-validated field like `issuer` and `subject`. See `SsoIdentity` below.
- **Single-tenant is the documented default.** The Entra template configures
  `https://login.microsoftonline.com/<tenant-guid>/v2.0` with `allowedTenants` empty, so the plain
  exact-match rule applies and the multi-tenant machinery is not reachable by accident.
- **Entra's `sub` is pairwise** — app-specific and unstable across app registrations — while `oid` is
  the stable per-tenant object id. The template must say which it keys on and why, because a team that
  keys on `sub` and later recreates the app registration orphans every account. The identity key is
  `(issuer, subject)` as everywhere else (§Typed identity), so what the Entra template must document is
  that Entra users who want survivable identities map `oid` into `subject` via the connection — the
  `subject` the runtime keys on is whichever claim the connection names.

**nOAuth, concretely.** An Entra tenant admin can set an **unverified** `email` on a user, and Entra
does **not** emit `email_verified`. Under §Typed identity that means the runtime can never construct
`VerifiedEmail` for Entra — `email` is at best `UnverifiedEmail`, always, which is correct. The danger
was never the value; it is the reasoning at the point of use: "this is an enterprise IdP, of course the
mail attribute is real." That is exactly the nOAuth takeover, and it is why the constructor is named
`UnverifiedEmail` rather than carried in a sibling boolean: the author who links on it has to write the
word. The Entra template still **refuses to link on email, visibly and with the reason in a comment** —
now as a demonstration of a rule the type already enforces, rather than as the only thing enforcing it.

### Why not "let the frontend do social login"

Worth killing explicitly, because it looks cheaper and is not. The frontend-only path is either the
implicit flow (deprecated; removed in OAuth 2.1) or a browser PKCE public client. The public client
leaves the SPA holding a token it must send to the Tesl backend — and the backend then has to verify
an assertion that arrived **through the browser**, where TLS-to-the-IdP is not even arguably the trust
basis, so full RS256 + JWKS + rotation is unavoidable *and* every §3.1.3.7-style shortcut is off the
table. The confidential-client server-side flow keeps the assertion on a channel we control.
**Pushing this to the frontend buys nothing and loses the one flow whose trust story is short.** (The
single escape is calling a provider's own `tokeninfo`-style endpoint per login — provider-specific,
rate-limited, and a hack.)

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

  ssoSessionKey  (requireSecret "SESSION_KEY")           # one session key for all of them
  ssoPreviousKey (requireSecret "SESSION_KEY_PREVIOUS")  # OPTIONAL — rotation overlap, §Session key rotation
  publicOrigin   "https://app.example.com"               # REQUIRED — the redirect_uri origin, see below
  afterLogin     "/"
  sessionPolicy  ShortSession                            # OPTIONAL, server-wide — see §Session policy
  listenAddress  Loopback                                # OPTIONAL here; a header-trust auth block needs
                                                         # this OR a verified binding secret OR the
                                                         # acknowledgement (Phase −2, §Item A)
  loginMethods   [Sso]                                   # REQUIRED alongside an sso clause — §Login methods.
                                                         # [Sso] ⇒ a password path will not compile;
                                                         # [Sso, Password via ssoRequired] ⇒ mixed mode
                                                         # through one runtime-enforced gate
}

fn githubConn(login: SsoConnectionRequest) -> Maybe SsoConnection requires [envRead] =
  Something (Sso.defaults GitHub (env "GITHUB_CLIENT_ID") (requireSecret "GITHUB_CLIENT_SECRET"))

fn corporateConn(login: SsoConnectionRequest) -> Maybe SsoConnection requires [envRead] =
  Something (OidcIssuer { issuer: env "OIDC_ISSUER", … })
```

**The hook's argument is the narrow, runtime-constructed `SsoConnectionRequest`** — the route segment
plus a runtime-extracted tenant hint — never the raw `HttpRequest`. Open Question 5 recommended this
and the fifth review settled it: the earlier version of this very example showed `HttpRequest` while
the question argued against it, and the example is what gets copied.

The literal segment mints `/auth/github/login` and `/auth/github/callback`. **The path cannot be
derived from the provider any more** — the provider is a runtime value now — and that is a net
improvement: the paths are explicit rather than magic, a user can pick their own, and the compiler
needs them literally anyway for route-collision checking and client-generation exclusion.

**`publicOrigin` is required and may not be inferred (blocker 8).** `redirect_uri` is
`publicOrigin ++ "/auth/" ++ segment ++ "/callback"`, and the *identical literal string* is sent at
the authorize step and again at the token exchange, as the specs require. It must come from
configuration, never from `Host` or `X-Forwarded-Host`: a request-derived `redirect_uri` lets an
attacker who can set one header point the provider's `code` delivery at their own host. Validate at
compile time — absolute, `https`, no query, no fragment — with a `http://localhost[:port]` carve-out
that is subject to the single dev-escape rule below. (Named `publicOrigin`, not `ssoBaseUrl`, per Open
Question 7: a verified public origin is wanted by more than SSO, and two spellings of "where this app
lives" would be worse than one.)

**One dev escape, one gate, one ratchet.** Three separate fail-open surfaces were accumulating — the
Phase −1 TLS opt-out (Open Question 8), `publicOrigin`'s localhost carve-out, and Risk 5's
loopback/literal-IP dev override. Collapse them into a **single** environment-level development gate,
with these properties, each tested:

- It is one named mechanism, checked in one place, reported in the startup banner when active.
- It refuses to activate unless every affected host is loopback, and it refuses to activate at all in
  a build produced by `tesl build` / a configured `[deploy].target`.
- A ratchet test asserts that no new independent opt-out appears (no bare `#:ssl? #t`, no second
  "allow http" flag, no per-call escape).

`SsoIdentity`, handed to `onIdentity` — see §Typed identity, not documented identity for why each
field has the type it has:

```
SsoIdentity = { key: SsoSubjectKey,       # the ONLY storable identity. Opaque. Contains no email
                issuer: String, provider: String, subject: String,
                tenant: Maybe String,     # `tid`, validated against allowedTenants
                email: EmailClaim,        # verified-ness is a constructor, not a sibling Bool
                name: Maybe String,
                claims: Dict String Json }
```

The runtime owns: discovery (OIDC, cached document) or the endpoints from the connection value, PKCE
S256, `state`/`nonce` generation and the `__Host-oauth` cookie that binds them to the browser, the
code exchange, ID-token signature verification and claim validation (Phase 2.5), the userinfo call
where required, calling `onIdentity`, signing the session JWT from what it returns, setting
`__Host-session`, and the 303 to `afterLogin`.

**The only user code is a config function and the identity → local user mapping.** The latter cannot
live in the runtime — it writes the app's own schema under the app's own proofs.

### Typed identity, not documented identity

The earlier draft's `SsoIdentity` was `{ email: Maybe String, emailVerified: Bool, …,
claims: Dict String String }`, and its containment for Risks 2, 3, 4 and 18 was "the shipped templates
and the lesson teach the rule". **That is the same shape as Item A's honesty note**: a security
property that the compiler and runtime cannot check, resting on the user reading the right page. It is
the wrong containment for the two decisions in this whole document most likely to end in account
takeover, and the fix is cheap because the values are the runtime's own construction.

Three changes, each turning a documented prohibition into an unreachable state:

**1. Unverified email is a different constructor, not a flag next to the value.**

```tesl
type EmailClaim
  = VerifiedEmail   String   # the provider asserted this address AND asserted it is verified
  | UnverifiedEmail String   # the provider gave an address and no proof; display only
  | NoEmail                  # no address, or one that failed to parse
```

`email: Maybe String` + `emailVerified: Bool` lets a correct-looking `upsert user where email ==
identity.email` compile and pass tests, and Risk 2's takeover is one forgotten `&&` away. With
`EmailClaim`, reading the address at all forces a `case`, the unverified branch is *named for what it
is* at the point of use, and "link on an unverified email" becomes a thing an author must write down
deliberately rather than something a reviewer must notice is missing. Risk 3's fail-closed rule
(absent/missing/non-boolean ⇒ not verified) is now the statement that the runtime **never constructs
`VerifiedEmail` without a positive verification signal** — for Entra, which emits no `email_verified`
at all, `VerifiedEmail` is therefore unreachable by construction, which is exactly the nOAuth
containment, expressed in the type instead of in a comment.

**2. The storable identity is opaque and contains no email.**

```tesl
SsoSubjectKey            # opaque: no constructor on the Tesl surface, no field access.
                         # Has ==, is storable in a column, renders redacted-by-default in logs.
Sso.keyText : SsoSubjectKey -> String     # for the DB column
```

The runtime derives it from `(issuer, subject)` and nothing else. Because there is no email inside it
and no constructor outside the runtime, "key the user table on the email address" is not merely
discouraged — the type the schema wants cannot be built from an email. That closes Risk 4 by
construction rather than by convention. `email`, `name` and `claims` remain available for display, and
an app that *wants* email-based linking while already authenticated (the legitimate "link my accounts"
flow in Risk 2) still writes it by hand, from an authenticated session, which is the case where it is
sound.

**Added by the fifth review: the derivation is injective, by construction.** `(issuer, subject)` is
two strings, and naive concatenation makes `("https://a", "x|https://b")` and `("https://a|x",
"https://b")` one key — a cross-issuer collision, which in a multi-provider program is the takeover
shape, and subjects are not always un-influenceable (self-hosted IdPs with username-as-`sub`
configurations exist). The derivation length-prefixes each component or hashes them with domain
separation; Phase 5 carries the collision test. The existing "one provider asserting another
provider's `subject`" test does not cover this — that is about claims, this is about encoding
(Risk 59).

**The key is `(issuer, subject)`, not `(provider, issuer, subject)`** — a correction to the earlier
draft. `provider` is now the route segment, a user-chosen deployment label: renaming `sso "github"` to
`sso "gh"` would silently orphan every account if the segment were part of the identity. `issuer`
already distinguishes providers, and for the plain-OAuth2 family — where there is no issuer claim —
the runtime synthesises one from the **scheme and host of `userinfoUrl`** (`https://api.github.com`,
`https://discord.com`), which is stable across a segment rename and across Discord's in-path API
version bump. That synthesis is part of the descriptor and must be tested, because it is what makes
plain-OAuth2 identities survivable. `provider` stays in `SsoIdentity` for display, logging and
"which button did they press"; it is not identity.

**3. `claims` is `Dict String Json`, not `Dict String String`.** The prohibition ("never an
authorization input") stays, but stating a prohibition while handing over a substring-matchable string
is what makes Risk 18 reachable: `"admin"` matches a flattened `"[superadmin, readonly]"`, and the code
that does it looks right. With a `Json` value, an array-valued `groups` is an array — a substring match
does not typecheck, and the naive version fails at compile time instead of authorising an attacker.
This depends on Phase 0's answer for blocker 6, and it is the same defect one level down, so the two
should be decided together: whatever `JWT.decode` ends up returning for an array-valued `aud` is what
`claims` should carry here.

The load-bearing, trusted fields are `key`, `issuer`, `provider`, `tenant` and the *constructor* of
`email`. `tenant` is a typed field precisely so the Entra rule is never expressed as a lookup into
`claims`. A `subject` that is absent, empty, or not a JSON string is a hard failure, not an empty
identity (Risk 9) — and now also not a constructible `SsoSubjectKey`.

**Cost, honestly:** `EmailClaim` is one baked ADT (tables-only rows, the `SsoProvider` pattern) and
`SsoSubjectKey` is one opaque type in the mould of `PasswordHash`, which already exists and has exactly
these properties — opaque, no constructor, storable, redacted (`stdlib_docs_entries.ml:696`). So this
is a table-shaped change to Phase 2, not new machinery, and `PasswordHash` is the precedent to copy
rather than a design to invent.

### Session policy — one closed ADT, not a duration

Because the provider is a login mechanism only, the session TTL is the **sole** control over the
revocation window in Non-goals: a user disabled at the IdP keeps access until their session expires.
Today that window is not adjustable at all — `jwt-ttl-seconds` is `3600` and `jwt-absolute-max-seconds`
is `(* 12 jwt-ttl-seconds)`, both hardcoded (`tesl/jwt.rkt:277,302`). An organisation whose policy
requires 15-minute reauthentication therefore cannot comply, and has no workaround.

The knob is a **baked ADT, not a duration**, for the same reason `TimeZone` and `SsoProvider` are:
every value is enumerable and every value is safe, so the setting cannot be turned the unsafe way.
A `Duration` field would let someone write 30 days; a closed ADT cannot express it, and a typo is an
unknown-constructor compile error with completion listing the alternatives.

```tesl
type SessionPolicy
  = StandardSession   # 1h renewable, 12h absolute — today's behaviour, and the default
  | ShortSession      # 15min renewable, 8h absolute
```

Four rules, each of which is where a naive version goes wrong:

- **Each constructor names both numbers. The absolute cap is not a multiple of the TTL.** Today's
  `(* 12 jwt-ttl-seconds)` formula, applied to a 15-minute TTL, would silently produce a **3-hour**
  absolute cap — forced reauthentication mid-workday, which no policy asked for and which reads as a
  bug. `ShortSession` pairs a 15-minute renewable window with an 8-hour absolute cap (a workday)
  deliberately: the short number is the idle/reauth interval that compliance regimes actually specify,
  the long one is unrelated to it.
- **It is a server-level setting, not an SSO setting.** Same argument as `publicOrigin` (Open
  Question 7): the session belongs to the app, not to the login mechanism, so password login,
  proxy-header login and SSO all inherit one policy. `sessionPolicy` is optional and defaults to
  `StandardSession`, so nothing changes for existing programs.
- **The cap is `iat`-anchored and evaluated at verify time** (`tesl/jwt.rkt:587,605`), so a token
  issued under one policy is judged under whatever policy the *verifying* process has. During a rolling
  deploy the two coexist, and **lowering the policy immediately shortens live sessions** rather than
  only future ones. That is the correct behaviour — it is what makes the setting usable as an incident
  response — but it is also a surprising support ticket if unwritten, so it goes in the spec, with the
  matching note that raising the policy does not extend a session already past the reading process's
  own `iat + cap`.
- **Adding a third point is one table row.** The ADT is closed and additive, so a future
  `RegulatedSession` (or whatever a real customer requirement turns out to be) costs a constructor and
  a row, with no migration for anyone. Do not pre-invent it.

Tests: the renewal clamp at `tesl/jwt.rkt:596-607` under both policies; a token issued under
`StandardSession` and verified under `ShortSession` (accepted only within the shorter window); and a
policy-independent assertion that no code path derives the absolute cap by multiplying the TTL.

### Session key rotation — the only kill switch, and today it does not exist

`SessionPolicy` bounds the *IdP-revocation* window. It does nothing for the other compromise this item
makes worth thinking about: the session signing key itself. Today `kid` is already stamped into every
header from a derived key fingerprint (`tesl/jwt.rkt:244`, with the reasoning at `:200-238`), but
**verification takes a single key**. Two consequences, both bad, neither previously written down:

- **A leaked `SESSION_KEY` cannot be rotated without terminating every live session.** So the operator
  facing a suspected leak chooses between "keep using the compromised key" and "log out every user with
  no warning", and under pressure people pick the first.
- **Combined with server-side revocation being a standing non-goal (LANGUAGE-SPEC §21.8), there is no
  kill switch at all.** Anyone holding the key mints sessions for any subject, valid until each
  token's own absolute cap, and nothing in the system can refuse them. "Do you verify ID token
  signatures?" is the question this document already answers; "can you terminate a session?" is the one
  an enterprise reviewer asks first, and the honest answer today is no.

The fix is small precisely because `kid` is already there:

```tesl
server AppServer for AppApi {
  ssoSessionKey     (requireSecret "SESSION_KEY")
  ssoPreviousKey    (requireSecret "SESSION_KEY_PREVIOUS")   # OPTIONAL — the rotation overlap slot
}
```

- **Sign with current, always.** Verify against current, then previous. `kid` picks the order and gives
  the operator "which key is this token on"; it stays **advisory**, exactly as `tesl/jwt.rkt:233-238`
  already argues, so a `kid` mismatch remains a non-error and no new failure mode is introduced.
- **Renewal re-signs under the current key**, so the previous key drains on its own: after one
  `SessionPolicy` absolute cap with no live token on it, the slot can be emptied. That gives a rotation
  procedure with no mass logout — set new current, move old to previous, wait one cap, unset previous.
- **Emptying the previous slot while rotating current *is* the global kill switch**, and the spec must
  name it as such: it is blunt (everyone is logged out) but it is the only incident response Tesl has,
  and an operator needs to know it exists before the incident rather than during it.
- **Both keys are `Secret`**, and the absent-previous case is the default, so nothing changes for
  existing programs.

**Superseded by the sixth review: per-user revocation is no longer a non-goal** — see §Revocation at
the renewal boundary, which lands it without touching the request path. The two blunt levers (rotate
the key, lower the policy) remain as the *zero-latency* incident responses; the renewal check is the
targeted one.

### Revocation at the renewal boundary

The non-goal this document inherited (LANGUAGE-SPEC §21.8) is a session **store on the request
path** — a per-request read is the stateless-scaling trade the language deliberately declined, and it
stays declined. But "no store on the request path" had been silently widened into "no per-user
revocation at all", and the two are not the same, because the session design already has a second,
rare, runtime-owned event: **renewal**. A token is verified on every request but *renewed* once per
TTL, and the renewal clamp already runs in one place (`tesl/jwt.rkt:596-607`). Consulting a
revocation check there — and only there — costs one read per session per renewable window and changes
nothing about verify:

```tesl
server AppServer for AppApi {
  sessionPolicy   ShortSession
  sessionRevoked  revoked          # OPTIONAL — the renewal-boundary check
}

fn revoked(subject: String, issuedAt: PosixMillis) -> Bool requires [dbRead] =
  -- the app's own schema: a disabled flag, or a per-user
  -- "revoke every session issued before T" timestamp
  ...
```

Rules, each where the naive version goes wrong:

- **Consulted at renewal only, never at verify.** The request path stays byte-identical stateless; a
  test asserts no read happens on ordinary verify with the hook declared. This keeps the original
  non-goal's *reason* intact while deleting its overreach.
- **Latency is the remaining renewable window, and the spec says the number.** A revoked user's live
  token stays valid until its own `exp`: ≤1 hour under `StandardSession`, ≤15 minutes under
  `ShortSession`. That is the bound the access/refresh-token architecture already ships everywhere —
  access tokens are not revocable mid-lifetime either; the refresh boundary is the control point, and
  Entra's own default access-token lifetime is longer than `ShortSession`'s window. "Per-user
  revocation with latency bounded by the renewable TTL" is the sentence an enterprise reviewer
  accepts; "instant revocation" is the overclaim Risk 66 exists to prevent.
- **Fail-closed.** The hook raising, or its `dbRead` failing, denies the renewal — the user
  re-authenticates. For an SSO user that is one silent redirect (the IdP session persists), and it
  re-applies the IdP's own policy at that moment, which is a feature.
- **The signature carries `issuedAt`** so "log this user out everywhere" is expressible as app data:
  write a per-user timestamp, deny renewal of anything issued before it. Subject alone cannot express
  that.
- **A denied renewal is an expired session** — 401, cookie cleared, re-login — the path that already
  exists; no new failure mode.
- **Absent hook = today's behaviour**, and the store is the app's own schema, so Tesl still owns no
  session store and nothing changes for existing programs.
- **What this does *not* do, stated:** it does not shorten the IdP-deprovisioning window by itself —
  the hook reads the app's table, not the IdP, so a user disabled *only* at the IdP still renews
  until the absolute cap unless the app mirrors deprovisioning into its own data (SCIM stays a
  non-goal). And it is not instant: the two blunt levers remain the zero-latency responses.

With this, §The platform baseline's item 3 comes off the exclusion list the same way mixed-mode login
did — by becoming a runtime-owned mechanism rather than prose — and the platform claim's named
exclusions drop to **two**: rate limiting and app-frontend XSS.

Tests: renewal of a revoked subject denied with the cookie cleared; a revoke-before-`issuedAt`
timestamp denying an older token while a newer one renews; the hook raising ⇒ denial; ordinary verify
performing **no** read with the hook declared; absent hook ⇒ byte-identical behaviour to today.

### Where the flow's own state lives

Open Question 4 settled cookie-only in-flight state: `state`, `nonce`, the PKCE verifier and the
flow's start time live in `__Host-oauth` and nowhere on the server. That remains the right call — a
table plus a cleanup job, bought to survive a deploy that otherwise costs one retried redirect, is a
bad trade. But the fourth review found two things the earlier draft asserted its way past.

**1. "Single-use `state`" is not implementable statelessly, and two other controls were leaning on
it.** Phase 1 says `state` is "consumed once, and a second presentation fails", and single-use `state`
is then named as a compensating control for deferred rate limiting (Risk 19) *and* for the
authorization `code` reaching browser history and reverse-proxy logs (Risk 24). With no server-side
record, "consumption" means deleting a cookie the client holds — and a client that declines to delete
it can present the pair again. Two fixes, and this item takes both:

- **Fix the claim.** What actually stops a replayed callback is the provider's own single-use `code`
  plus the PKCE verifier binding. Both are real; neither is ours. The spec says that, rather than
  crediting Tesl with a property it does not hold.
- **Add the half that is real.** A bounded, TTL'd in-process set of spent `state` values — TTL = the
  `__Host-oauth` `Max-Age`, so it stays small and empties itself, and bounded so it cannot become a
  memory-amplification primitive. That makes single-use true *within a process*, which is where a
  replay flood lands anyway. It is explicitly **not** claimed across processes: a multi-process
  deployment gets the provider's `code` single-use and nothing more, and the spec states that instead
  of implying a cluster-wide guarantee.

**2. The cookie payload must be integrity-protected.** The attribute list was pinned (`HttpOnly`,
`Secure`, `Path=/`, `SameSite=Lax`, short `Max-Age`); the *contents* were not. A cookie value is
client-writable — `HttpOnly` stops JavaScript **reading** it, not a client **choosing** it — so an
unauthenticated blob means the browser, not the server, decides what this login attempt's `nonce`,
verifier and start time were. Phase 2.5's `iat` sanity check ("not older than the in-flight login's own
start time, which the `__Host-oauth` cookie dates") is worth nothing if the client picks that date.
Rules:

- **The payload is authenticated under a purpose-derived subkey of the session signing key** (MAC or
  AEAD — Open Question 16), never the raw key: one key must not serve two algorithms (the JWT HMAC
  and the cookie MAC/AEAD), so the cookie key is derived with domain separation — libsodium
  `crypto_kdf` with a distinct context — and verification runs against subkeys derived from
  `[current, previous]` exactly as §Session key rotation does, so a key rotation still does not break
  logins that are in flight (Risk 58).
- **It carries the route segment**, so a cookie minted at one `sso` clause cannot be presented at
  another's callback.
- **A failed MAC is a failed flow** — the fixed error page from §What `onIdentity` does when it says no,
  never a fallthrough to a state-optional path, and never treated as a fresh login.
- **Nothing in the payload is trusted before the MAC verifies**, including its own timestamp.

Both points are asserted in Phase 1 and attacked in Phase 5.

### Login methods and the mixed-mode bypass

**Every control in this document can be bypassed by the password form next to it, and the earlier draft
did not mention passwords once.** Tesl has had password authentication since crypto landed —
`Crypto.hashPassword` / `Crypto.checkPassword` over libsodium Argon2id (`type_system.ml:925`,
`stdlib_docs_entries.ml:690`) — and an app that adds SSO almost always keeps it, for the admin account,
for the customers not on the IdP, or just because it already worked.

The attack needs no cleverness. A customer mandates Entra ID with MFA and conditional access. The
attacker (or an insider who finds MFA annoying) uses the password form with an address in that domain.
Every rule in this item holds — signature verified, `tid` checked, `hd` checked, no email linking — and
the IdP's entire contribution has been skipped. **Password reset is the same hole through a second
door:** a reset flow that will set a password on an SSO-mandated account re-creates the bypass even if
password *login* was disabled for it.

**The fix is a checked declaration and one gate — revised by the fourth review.** The third review's
containment was a template function the author calls from three places (the password `auth` block, the
reset flow, the Item A header path) plus a *linter warning* where an `sso` clause and
`Crypto.checkPassword` coexist. That containment cannot detect the failure the same paragraph
predicts: the warning fires on **coexistence**, which is the legitimate and common shape, so it fires
on nearly every program that adds SSO, says nothing about whether all three sites were wired, and is
acknowledged once and never again. This is the highest-severity finding in the document contained by
the weakest available mechanism — the exact shape §Typed identity and the Item A honesty note exist to
reject.

A program with both mechanisms declares so, and the declaration is what the compiler and the runtime
enforce:

```tesl
server AppServer for AppApi {
  loginMethods [Sso]                            # SSO only — a password path will not compile
  # ── or ──
  loginMethods [Sso, Password via ssoRequired]  # mixed — one policy function, named once
}

fn ssoRequired(identifier: String) -> Bool requires [dbRead] = ...
```

- **`loginMethods [Sso]` is checked, not documented.** A program declaring SSO-only that contains a
  `Crypto.checkPassword` **or** `Crypto.hashPassword` call **does not compile**. This is the either/or
  branch, and it closes the bypass completely with no app data involved — there is no password path to
  bypass through. It is also the branch an enterprise questionnaire is actually asking about, and it
  becomes answerable by pointing at one line of the program.
- **Mixed mode requires the policy function, and the runtime calls it — the author does not.** With
  `Password` declared, password verification goes through the runtime-mediated form (candidate spelling
  `Auth.passwordLogin : String -> String -> PasswordHash -> Bool`, Open Question 15), which consults
  `ssoRequired` on the login identifier **before** it can return a positive result. The
  password-*setting* paths — reset, signup, admin set-password — consult it too, because a reset that
  will set a password on a mandated account re-creates the bypass even where password login was
  refused.
- **Bare `Crypto.checkPassword` / `hashPassword` are rejected at compile time in any program containing
  an `sso` clause.** They stay legal exactly as today in programs with no `sso` clause, so no existing
  program breaks. This is what removes the second and third call sites: there is one gate, it lives in
  the runtime, and the un-gated function will not compile next to SSO.
- **The Item A header path is covered by the same declaration**, for the same reason: two paths that
  each check separately is how one of them stops checking.
- **The mandate itself stays app data.** *Which* identifiers or domains are SSO-mandated is a table the
  app owns — it changes without a deploy and it is per-customer — so `ssoRequired` is an ordinary
  function over the app's own schema. The declaration fixes **that the check happens**; the function
  decides **for whom**. Only the first of those is Tesl's problem, and it is the one that was
  unenforced.
- **`ssoRequired` fails closed.** Raising, or a failing `dbRead`, denies the password login; it does not
  fall through to "not mandated".

**Re-shaped by the fifth review: an allowlist over minting sites, not a search for password calls
(Risk 56).** The rule as written above — reject `Crypto.checkPassword`/`hashPassword` — is
denylist-shaped, and it misses every login path that is not spelled with those two names: a generic
hash compared with `==`, a magic-link flow, an `auth` block reading an API key, a future WebAuthn
handler. Each mints a session; none contains a "password call"; so the program reads
`loginMethods [Sso]` while a fourth door stands open. That is decide-by-spelling — the failure mode
this codebase has already diagnosed as the root generator of its soundness bugs — inside the very
check built to end prose containment. The checkable invariant sits one level up, and the checker
already has the facts: **`auth` blocks are the enumerable sanctioned session-minting sites, so
`loginMethods` classifies all of them.**

- **Under a `loginMethods` declaration, every `auth` block must be attributable to exactly one
  declared method.** The `sso` clause's `onIdentity` is `Sso` by construction; a header-trusting
  block discharged under Phase −2 is `Proxy` — which must then appear in the list; a block wired
  through the runtime-mediated password path is `Password`. A block the checker cannot attribute —
  whatever evidence it reads — is a **compile error**. Unattributable is refused, never defaulted.
- **The password-call rejection stays, as a backstop one level down** — it catches misuse *inside* a
  classified block — but it is no longer the enforcement boundary.
- **The attribution's spelling is Open Question 18** (an annotation on the `auth` declaration, or a
  named list entry); the fail-closed rule does not depend on the answer: no attribution, no compile.
- Consequence worth stating: `loginMethods [Sso]` now means what an enterprise reviewer reads it to
  mean — *this program has no session-minting site other than the SSO callback* — rather than "this
  program does not call two particular functions".

**Re-shaped a third time by the sixth review: the allowlist must cover the sites that *create*
sessions, and `auth` blocks are not those sites (Risk 63).** The fifth review's premise — "`auth`
blocks are the enumerable sanctioned session-minting sites" — is not what the tree says. An `auth`
block mints the per-request `Authenticated` fact from evidence it reads; the *session* is created
elsewhere, by an ordinary handler: lesson76's own login is a plain POST handler calling `JWT.sign`
then `Http.setSessionCookie` (`example/learn/lesson76-sessions.tesl:256`), and its `auth` block
(`sessionOwner`, `:280`) verifies whatever session exists, method-blind. So under
`loginMethods [Sso]` the magic-link flow — the fifth review's own listed example — still compiled: a
handler validates the emailed token against the DB and sets the cookie; it contains no password call
(the backstop misses it) and no `auth` block (the allowlist misses it). The fourth door was still
open, one level below the fix built to close it. The correct chokepoint already exists, is unique,
and is already capability-gated — lesson76's own guarantee is "no way to set an unsigned cookie, and
no second cookie-writing function":

- **Under a `loginMethods` declaration, every reachable `Http.setSessionCookie` call site must be
  attributable to exactly one declared method.** The runtime's SSO callback is `Sso` by construction;
  a site gated by the password witness (below) is `Password`; any other site — a magic-link handler,
  a signup auto-login, anything holding `cookieCap` — carries the Open Question 18 attribution or
  does not compile. Enumeration rides the existing capability system (`cookieCap` already names every
  holder) rather than a parallel registry.
- **The `auth`-block classification stays**, for the minting it does govern: per-request fact-minting
  with no session (API keys, the Item A header path). Both classifications are fail-closed;
  unattributable is refused in each.
- **The password gate returns a witness, not a `Bool` (Risk 64).** `Auth.passwordLogin : … -> Bool`
  is forgeable by discarding the result — call it, ignore the `Bool`, set the cookie anyway — and an
  attribution meaning "wired through the gate" would bless exactly that bypass. The gate returns
  kernel-minted evidence (spelling with Open Question 15), and a `Password`-attributed cookie site
  requires it: the same construction-not-analysis move as §Item A's `Proxy.verifyBinding`, for the
  same reason — the witness cannot exist unless the check succeeded, so control-dependence needs no
  checker analysis.
- Consequence, corrected: `loginMethods [Sso]` now delivers the sentence the fifth review only
  promised — *no code path in this program can produce a session cookie except the SSO callback* —
  because the rule sits on the one function that produces session cookies.

**Cost, honestly.** More than the warning the third review budgeted: a `loginMethods` server clause
(thin — a list plus one optional function reference, the same AST shape as `sso` itself), one checker
rule keyed on the declaration, and a runtime-mediated password path. It is worth it because the
alternative is leaving this document's highest-severity finding contained by prose, in an item whose
whole claim is that dangerous states are unrepresentable. Lands in Phase 3 with the `sso` clause, since
it is the same parser work. See Risk 33 (revised), Risk 46 for the residual, and Open Question 14,
which the fourth review settles the other way.

Phase 5 tests the bypass in every direction: password login and password reset against an SSO-mandated
address, the same on the Item A header path, a bare `Crypto.checkPassword` beside an `sso` clause
(must not compile), and a `loginMethods [Sso]` program containing a password call (must not compile) —
plus the fifth review's allowlist negatives: an API-key `auth` block and a hand-rolled password compare
(generic hash + `==`) under `loginMethods [Sso]`, each refused as an unattributable minting site rather
than by the password-call backstop.

### The platform baseline this claim rests on

The flow reaches gold standard under Phases −1 through 5. **"Tesl users get a secure system for free"
is a claim about the platform, not the flow**, and four platform properties carry it. They are named
here so they are blockers of the *claim* rather than SSO's non-goals — three are in scope, one stays
deferred.

**1. Response security headers — IN SCOPE, server-wide.** The tree emits exactly one:
`X-Content-Type-Options: nosniff` (`dsl/web.rkt:1292`, `:2372`). There is no `Strict-Transport-Security`,
no `Referrer-Policy`, no frame denial anywhere. That matters directly here: the session cookie is
`Secure` and `__Host-`-prefixed, but **without HSTS the first navigation to the app can still be
plaintext**, and an SSO login *is* a top-level navigation. The earlier draft put
`Referrer-Policy: no-referrer` on the callback only — the right control at too narrow a scope, since
session-bearing pages leak referrers too. So:

- `Strict-Transport-Security` — and the fifth review states the values instead of promising them:
  `max-age=31536000` (one year); **no `includeSubDomains` by default** — Tesl cannot see the subdomain
  topology, and a wrong guess bricks a sibling site for a year; **no `preload` by default, ever** — it
  is effectively irreversible and must be the operator's explicit act. **Emitted on the basis of
  `publicOrigin`'s scheme, never the request's** — see the fourth review's correction below.
  Suppressed when `publicOrigin` is the loopback dev value.
- `Referrer-Policy: no-referrer` as the **default for every response**, not just the callback.
- Frame denial on runtime-owned responses.
- A conservative CSP on the pages the *runtime* owns (the callback error page, the default error
  responder) **and a CSP default on HTML the runtime serves from the static directory** — see the
  fourth review's correction below.
- These are defaults changes in `dsl/web.rkt`'s response construction, with a byte-identical-output
  test in the style of `compiler/test/test_session_cookie.ml` and a ratchet test so a response path
  cannot be added that skips them.

**Correction 1 (fourth review) — "on every https response" has no source of truth, so as written it
emits nothing where it matters.** Tesl's server speaks plain HTTP; TLS is terminated by whatever sits
in front of it, which is the deployment Item A blesses. The scheme normally arrives as
`X-Forwarded-Proto`, and there is **no `X-Forwarded-*` handling anywhere in the tree** — nor may there
be, because blocker 8's whole argument is that a request header is not a trustworthy statement about the
deployment. A rule conditioned on the request therefore evaluates false behind every real proxy, and the
header silently never ships. **`publicOrigin` is the answer, and it already exists for exactly this
reason**: it is configured, compile-time validated, and not forgeable. `publicOrigin` is `https` ⇒ emit
HSTS on every response, unconditionally; `publicOrigin` is the `http://localhost` dev value ⇒ that *is*
the dev case, suppress. The same rule decides the dev suppression of every other header. Write it down,
or someone implements the request-derived version and Phase −2(b) becomes a no-op in production.

**Correction 2 (fourth review) — two response paths skip every header today, and they are the two that
serve the app's own HTML.** The earlier scoping said "a CSP for the app's own HTML is the app's to write
and is not in scope; a runtime-rendered page with no CSP is ours." That line does not survive contact
with the tree:

- `dsl/web.rkt:2348` — the **SPA fallback** reads `index.html` off disk and answers
  `response/full … '()`: an empty header list. Not even `X-Content-Type-Options`.
- `try-serve-static` (`dsl/web.rkt:2286`) — every **static asset**, also `'()`.

So Tesl, not the app, serves the app's HTML and JavaScript, and **a Tesl program has no mechanism to
attach a header to a file the runtime reads and returns**. "The app writes its own CSP" describes
something the app cannot do. This matters more than a missing hardening header: the session cookie is
`HttpOnly`, but script running on the app's origin does not need to *read* the cookie — the browser
attaches it automatically, so injected script simply calls the API as the victim. `__Host-`, `HttpOnly`,
`SameSite`, PKCE and signature verification are all intact and all bypassed. Therefore, in scope:

- The server-wide header set applies to **both** of those call sites, and the Phase −2 ratchet test
  names them specifically, because they are the two that skip everything today.
- **A CSP default on served HTML**, overridable — a real SPA has to declare its own script/style/connect
  sources, so an unconfigurable policy would either break apps or be set so loose it means nothing. Shape
  is Open Question 17.
- Even with a CSP default, XSS in the app's own frontend is *reduced, not eliminated*. It is therefore a
  **named exclusion** of the platform claim, alongside per-user revocation and rate limiting, rather than
  an unstated precondition of it.

**2. The CSRF posture is three mechanisms, not one, and the earlier draft was about to write it down
wrong.** The third review's text said "the cookie attribute *is* the CSRF defence". `tesl/http.rkt:61-65`
already argues something stronger and more accurate: **`SameSite=Lax`, plus the 415 on non-JSON request
bodies (`dsl/web.rkt:1308`), plus the absence of CORS headers on JSON routes.** That trio is what blocks
cross-site state change — a cross-origin `application/json` `fetch` needs a preflight that never
succeeds, and an HTML form cannot produce a JSON content type at all. `SameSite` alone would *not* be
enough, because `SameSite` is site-level rather than origin-level: a sibling subdomain (a marketing site,
a status page, a customer CNAME) is same-site and its requests carry the cookie. Recording the weaker
single-mechanism story in LANGUAGE-SPEC would invite a future reviewer to relax the 415 rule believing the
cookie carries the property. In scope:

- **State all three as load-bearing**, with the subdomain caveat that explains why the cookie attribute
  alone is not the argument.
- **The no-mutating-GET linter rule** — flag a write capability (`dbWrite`, `dbDelete`, queue enqueue)
  inside a GET route. Both facts are already visible to the checker.
- **Refuse a state-changing request whose `Sec-Fetch-Site` is `cross-site`.** Zero occurrences in the
  tree today; every current browser sends it. It is belt over the existing braces, and unlike the 415
  argument it covers the routes that are *not* JSON — SSE, static, and whatever ships next. **The
  refusal fires only on the literal `cross-site`; an absent header allows** (fifth review, Risk 61) —
  non-browser clients (curl, SDKs, server-to-server callers) never send the header and also carry no
  ambient cookie to protect, so fail-closed here would break every API client while defending
  nothing. The braces (`SameSite` + 415 + no-CORS) carry the property; this header is the belt.

**3. Per-user session revocation — IN SCOPE via the renewal boundary (sixth review).** The earlier
framing — "it needs a store on the request path" — was the non-goal's reason widened past its
argument: renewal, not verify, is where the check belongs, and renewal already runs in one place.
§Revocation at the renewal boundary lands an optional fail-closed hook consulted only there, with
revocation latency bounded by the renewable TTL and the verify path untouched. The two blunt levers
(§Session key rotation) remain the zero-latency incident responses; "log this one user out now" gets
the targeted answer an enterprise reviewer asks for. Off the exclusion list, the way mixed-mode login
came off it — with its own overclaims named (Risk 66).

**4. Rate limiting stays deferred** — see below, and Risk 19, whose *scope* the fourth review corrects:
it is not only the two SSO routes.

**5. Inbound `Host` validation — IN SCOPE, and nearly free.** `publicOrigin` is a configured statement of
where the app lives, so a request whose `Host` disagrees with it can be refused outright. That closes
cache-poisoning and absolute-URL-confusion classes, and it removes the temptation to ever answer "which
origin am I?" from a header. Same setting, same phase, one comparison. **One exception, added by the
fifth review (Risk 60): a declared probe path.** Kubernetes liveness/readiness probes and load-balancer
target checks hit the app by IP with `Host: <ip>`; a bare refusal restart-loops the pod until someone
disables the whole check, and a disabled control is worse than an absent one. The comparison exempts
exactly one declared health path (shape decided in Phase −2 with the rest of the header work) and
nothing else; the dev-gate loopback value is exempt as everywhere else.

**6. Cross-site scripting in the app's own frontend — NAMED EXCLUSION.** Established by Correction 2
above: Tesl serves the app's HTML and JS from the static directory, so the CSP default is in scope, but
CSP reduces rather than eliminates XSS, and script on the app's origin defeats the session design by
using the cookie rather than reading it. This is the third thing the platform claim does not cover, and it
was previously an unstated precondition of it.

With 1, 2, 3, 5 and Phases −1…5 in, the honest platform claim is: **gold standard except rate limiting
and cross-site scripting in the app's own frontend — both named in the spec with their
deployment-level answers.** That sentence, and not "gold standard", is what may ship until those land.
Note that mixed-mode login and per-user revocation are **no longer** on this list: §Login methods
moved the first from a documented trap to a checked declaration, and §Revocation at the renewal
boundary moved the second to a runtime-owned check — which is what the remaining two would each need
to come off it.

### How rate limiting slots in later

Deferred by decision (Risk 19), revisited as its own item *after* this one. What this item owes that
future item is a shape it can drop into without reopening SSO. Four requirements:

- **It must land at the router / dispatch boundary, not as a per-handler decorator.** SSO's two routes
  are minted by the runtime and have no user-written handler, so anything shaped as "annotate your
  handler" covers every route except the unauthenticated ones that most need it — and reopening this
  item would be the only fix. A dispatch-level limiter covers minted routes by construction, including
  whatever future feature mints routes next.
- **The auth event log is the signal source, so its fields are frozen now.** Risk 21's event already
  carries provider, segment, issuer, subject, tenant, outcome class, timestamp and client IP; a limiter
  keys on those. Keeping them stable means the limiter needs no new emit site and no second definition
  of "a failed login".
- **Client-IP determination must reuse Phase −2's proxy declaration, not invent a second one.** A
  limiter keyed on `X-Forwarded-For` without a trusted-proxy declaration is both bypassable (spoof the
  header) and a denial-of-service primitive (spoof someone else's address to get them limited) — the
  same class as blocker 8. `listenAddress`/the acknowledgement clause is already the program's statement
  of what sits in front of it, and it is the right and only input. **This is the main reason the two
  items must stay aligned**, and the reason Phase −2 is worth landing even before it is strictly
  needed.
- **The in-scope compensating controls stay in scope regardless**, so the limiter is defence in depth
  rather than the first line: every outbound leg size- and time-capped, bounded discovery and negative
  caches, a minimum-interval-limited JWKS refetch on unknown `kid`, single-use `state`.
- **Added by the fifth review: the Phase 3 password gate is the chokepoint, and the future item must
  land *at* it.** §Login methods routes every password verify and every password set through one
  runtime-mediated call; that is precisely the dispatch-level position the first bullet demands, and
  it will already exist. The rate-limiting item's first work is therefore gate-local: a per-identifier
  throttle at the mediated password path, and a process-wide Argon2id concurrency cap (one semaphore) —
  the KDF is expensive by design, so unmetered parallelism is the resource-exhaustion primitive Risk 54
  names. Named here so that item lands at the gate instead of re-plumbing beside it.

Until it lands, the deployment-level answer (a rate limiter in front of the app) is what the spec says,
and the residual exposure is stated rather than implied.

### `onIdentity` is a fact-minting trust boundary

It turns provider-asserted data into `::: Authenticated user`. A plain `fn` minting a fact is the
confirmed `fn→Fact` forgery class, and only sanctioned boundaries may mint. **Declare it as an
`auth`-kind declaration**, reusing the existing sanctioned minting site rather than inventing a
second one:

```tesl
auth linkUser(identity: SsoIdentity) -> user: String ::: Authenticated user
  requires [dbWrite] =
  -- upsert on identity.key, which IS (issuer, subject) and contains no email.
  -- `Sso.keyText identity.key` is the column value; see §Typed identity and Risks 2, 3, 4
  ...
```

Note the parameter type: every existing `auth` declaration takes `HttpRequest`
(`example/learn/lesson76-sessions.tesl:280`), so `SsoIdentity` is a new shape for the sanctioned
minting site. Phase 3 must confirm that the proof-kernel wiring keys on the declaration *kind* and
not on the parameter type, and a fail-closed characterization test must cover the new shape.

### What `onIdentity` does when it says no

Denial is not an edge case here — it is the **designed** control path for three things this document
requires: domain restriction (Risk 17, an `hd`/`tenant` claim check), refusing to link an unverified
email (Risk 2), and refusing a user who is not provisioned or is disabled locally. `auth` blocks
already have the channel — `fail 401 "no session"`
(`example/learn/lesson76-sessions.tesl:283`) — but the callback's behaviour on that `fail` was
unspecified, which is how a designed denial turns into an accidental login. Pin all of it:

- **No session cookie is minted.** lesson76's guarantee (a handler that sets a cookie then `fail`s
  sends none) must hold literally for the callback path, asserted by test.
- **Any pre-existing `__Host-session` is cleared**, not left alone. A failed re-login that leaves the
  previous session intact is how "log in as someone else, get denied, still be the old user" happens;
  worse, it makes a denial look like a success to the app's own UI.
- **`__Host-oauth` is deleted**, exactly as on the success path — the verifier and `state` are spent
  either way.
- **The response is a fixed error page with a fixed status** (403 for a policy denial, 401 only where
  the flow itself failed), never a redirect carrying an error, and never a JSON body from the router's
  default responder — the callback is a browser navigation, so its failure mode must be a page.
- **The `fail` message is the app author's own text, so it may be shown.** This is the one exception to
  Risk 15's never-reflect rule, and stating it matters: without the distinction, either provider text
  leaks (Risk 15) or authors get no way to say "your account is not provisioned". Provider-supplied
  strings are still never reflected, at any sink.
- **A denial is logged as an auth event** (see Risk 21), with the reason class, and never with the
  token.
- **`connection` returning `Nothing` follows the same path**: fixed page, fixed status, nothing about
  which segment or provider is misconfigured, and a loud server-side log — a misconfigured connection
  is an operator error, not information for the requester.

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

Listed in **execution order**, which the names no longer follow — the negative numbers accumulated as
reviews found prerequisites underneath earlier ones. Phases −2, −1.5, −1, 0 and the runtime halves of
`SessionPolicy` and `ssoPreviousKey` are all **independent of SSO** and each ships on its own merits;
everything from Phase 1 on is the feature.

- **Phase −2 — the deployment surface Item A needs, and the response-header baseline. GATES PHASE A.**
  Two things, both platform-level and both useful with or without SSO:
  (a) a `listenAddress` server setting (loopback / unix socket / explicit interface) **plus the
  compile-time rule** that an `auth` block whose only evidence is a request header requires either a
  loopback/unix `listenAddress` or an explicit acknowledgement clause — this is what turns Item A from a
  recommended pattern into a checked property, and it is also the declaration a future rate limiter needs
  in order to trust `X-Forwarded-For` (§How rate limiting slots in later);
  (b) the server-wide response security headers in §The platform baseline — HSTS,
  `Referrer-Policy: no-referrer`, frame denial, a CSP on runtime-owned pages — as defaults in
  `dsl/web.rkt`, suppressed for loopback under the single development gate.
  Added by the fourth review, same phase:
  (a′) the header-trust discharge accepts a **verified binding secret** as well as a loopback
  `listenAddress` or the acknowledgement, because a container must bind `0.0.0.0` and would otherwise
  always take the escape (§Item A, Risk 48);
  (b′) **HSTS and the dev suppression are decided from `publicOrigin`'s scheme, never from the
  request** — there is no `X-Forwarded-*` handling in the tree and there must not be, so a
  request-conditioned rule emits nothing behind a proxy (Risk 44). `publicOrigin` therefore lands here
  rather than in Phase 3;
  (b″) the header set covers **`try-serve-static` (`dsl/web.rkt:2286`) and the SPA fallback
  (`dsl/web.rkt:2348`)**, which pass `'()` headers today, plus an overridable **CSP default on served
  HTML** — Tesl serves the app's HTML, so the app cannot do this itself (Risk 45, Open Question 17);
  (c) **inbound `Host` validated against `publicOrigin`** (§The platform baseline item 5).
  Added by the fifth review, same phase:
  (a″) the binding-secret discharge is recognised by **dataflow, not shape** (§Item A, Risk 57): a
  config-originated `Secret` compared against a `request.headers` value, with the mint
  control-dependent on success — and the forged shapes (`secret == secret`, header-vs-header, a
  compare against a literal, a false branch that still mints) are compile-time negatives;
  (c′) `Host` validation exempts exactly one declared probe path (Risk 60), whose spelling is decided
  here;
  (d) the `Sec-Fetch-Site` refusal fires only on the literal `cross-site` — an absent header allows
  (Risk 61).
  Added by the sixth review, same phase:
  (a⁗) the binding-secret discharge is a **runtime-minted witness** — `Proxy.verifyBinding`, §Item A,
  Risk 64 — superseding (a″)'s dataflow analysis; the forged shapes stay as tests, now asserting that
  none of them can construct the witness rather than that the checker recognises each.
  Tests: the compile-time negative for a header-trusting `auth` block, in all three discharge shapes; a
  byte-identical-output header test; a ratchet test that no response path skips the header set, **naming
  the static and SPA-fallback paths explicitly** since those are the two that skip it today; HSTS present
  under an `https` `publicOrigin` behind a plain-HTTP request, and absent under the loopback dev value.
  Ship independently of SSO.
- **Phase −1.5 — the CSRF posture, linter-only.** The no-mutating-GET rule that makes the
  `SameSite=Lax` + 415 + no-CORS trio load-bearing (§The platform baseline item 2). Facts the checker
  already has; no runtime work. Can land in parallel with anything. **The mixed-mode item moved out of
  this phase**: the fourth review replaced the warning with the checked `loginMethods` declaration, which
  needs parser work and therefore lands in Phase 3 (§Login methods). The `Sec-Fetch-Site` refusal is
  runtime and lands in Phase −2.
- **Phase A — the proxy pattern documented** (Item A above). No compiler change of its own; **requires
  Phase −2**, whose `listenAddress` + compile-time rule is the pattern's only enforceable form.
- **Phase −1 — close blocker 7: authenticate the TLS peer. GATES EVERYTHING BELOW.** Replace the bare
  `#:ssl? #t` at `tesl/http-client.rkt:395` and `:495` with a verifying client context
  (`ssl-secure-client-context`, which validates the chain *and* the hostname), with the single dev
  escape described above — loud, environment-level, loopback-only, impossible to enable in a deployed
  build. Ship it **independently of SSO and before it**, because it is a live defect for every current
  `HttpClient` caller — webhooks, payment APIs, agent HTTP tools — not just a prerequisite here.
  Tests: a self-signed / wrong-hostname endpoint must be refused, and a ratchet test asserting no
  `#:ssl? #t` literal reappears in the tree. Write into the spec that this makes TLS *correct*, not
  *sufficient* — the middlebox argument, so the reasoning survives the next reviewer.
- **Phase 0 — close blocker 6.** Pin what `JWT.decode` does with an array-valued `aud`, then either
  type it honestly or coerce under a stated rule, with a regression test. Independent of SSO; do it
  before anything reads provider claims.
- **Phase 1 — `Tesl.Sso` runtime, OIDC family.** `dsl/sso.rkt`: discovery + cached document, PKCE
  S256, `state`/`nonce` + the `__Host-oauth` cookie (short `Max-Age`, `SameSite=Lax` — **not
  `Strict`**: the callback is a top-level cross-site GET and `Strict` would drop the cookie), code
  exchange over `HttpClient.post`, claim validation, one-time `state` consumption. All internal; no
  Tesl surface yet. Tests are pure-Racket plus `stubHttp`. The hygiene rules that belong here, each
  one asserted rather than assumed:
    - `__Host-oauth` carries `HttpOnly` (it holds the PKCE verifier), `Secure`, `Path=/`,
      `SameSite=Lax`, short `Max-Age`; it is **deleted on the success path and on every failure path**.
    - `state` is compared with `crypto-constant-time-equal?` (`tesl/crypto.rkt:252` — it already
      exists). **Single-use is per-process and honestly scoped** (§Where the flow's own state lives): a
      bounded, TTL'd spent-`state` set makes a second presentation fail within a process; across
      processes the guarantee is the provider's single-use `code` plus PKCE binding, and the spec says
      so rather than claiming a cluster-wide property that cookie-only storage cannot provide.
    - **The `__Host-oauth` payload is authenticated under a purpose-derived subkey of the session key**
      (MAC/AEAD over a `crypto_kdf`-derived key with a distinct context — never the raw key that HMACs
      the session JWT, Risk 58 — verified against subkeys derived from `[current, previous]`) and
      carries the route segment; nothing inside it — including its own
      timestamp — is trusted before the MAC verifies, and a failed MAC is a failed flow, not a fresh
      login (§Where the flow's own state lives, Risk 43).
    - **PKCE is `S256` and never `plain`, and a provider that does not advertise `S256` in
      `code_challenge_methods_supported` is refused.** The real-world failure here is silent: we send
      a challenge, the IdP ignores it, everything works, and there is no protection. Absence of the
      metadata field is treated as absence of support.
    - **Token-endpoint client authentication is chosen from
      `token_endpoint_auth_methods_supported`**, preferring `client_secret_basic`, falling back to
      `client_secret_post`, and refusing a provider that advertises neither (`private_key_jwt` is a
      Phase-2.5-or-later possibility, not v1). The secret never appears in a URL, in either method.
      This is as much a "painless setup" requirement as a security one: guessing the method is how
      teams end up sending the secret twice, or in a query string.
    - **The token endpoint used at exchange time is derived from the callback path's own connection,
      never from anything in the authorization response.** This is the invariant that makes
      per-provider callback paths a real mix-up defence (equivalent in effect to RFC 9207's `iss`)
      rather than an accident of the design. Additionally, **if the authorization response carries an
      `iss` parameter it is checked and a mismatch is rejected** — cheap, and it is the standardised
      control.
    - The session cookie minted at the callback **replaces** any pre-existing one (session fixation),
      and the pre-login `__Host-oauth` value never becomes a session.
    - Discovery validation: the document is fetched over `https` only, follows no off-origin redirect,
      and its own `issuer` field must equal the configured issuer exactly — or, for a templated
      issuer, must satisfy the `allowedTenants` + `tid` rule in §Entra ID and nothing looser
      (Risk 13). Cached with a bounded TTL and a bounded negative cache.
    - Every outbound leg (discovery, JWKS, token, userinfo) has a body-size cap and a time cap, and
      follows no redirects at all.
    - **SSRF containment is by resolved address, not by hostname** (Risk 47): resolve, refuse if **any**
      returned address is loopback, link-local (`169.254.0.0/16`, `fe80::/10`), unique-local
      (`fc00::/7`), RFC1918, CGNAT (`100.64.0.0/10`), `0.0.0.0/8` or an IPv4-mapped form of any of
      those, then **connect to the address that was checked** so re-resolution cannot rebind. Re-run per
      leg, including `jwks_uri` — the one URL that arrives from a document rather than from
      configuration. A name check alone is bypassed by a hostname that resolves to `169.254.169.254`,
      whose payoff is cloud instance credentials.
    - The access token travels in the `Authorization` header, never in a query string.
    - Provider-supplied `error` / `error_description` strings are **never reflected** into a response
      body, a redirect target, or a log line (Risk 15). The app author's own `fail` text may be shown
      (see §What `onIdentity` does when it says no) — the two are different and the code must not
      conflate them.
    - `redirect_uri` is built from `publicOrigin` and is byte-identical at authorize and at exchange.
    - **The callback response carries `Cache-Control: no-store` and `Referrer-Policy: no-referrer`.**
      The authorization `code` unavoidably arrives in the query string, so it is already in the
      browser's history and in any reverse proxy's access log; `no-referrer` stops it leaking onward
      through a subresource request on the landing page, and the immediate 303 gets it out of the
      address bar. Say in the spec that the compensating controls for the logged `code` are
      single-use consumption + PKCE binding, rather than leaving the exposure unmentioned.
    - `code`, `state`, the PKCE verifier, the access token and the ID token are redacted at the point
      of construction so they cannot reach OTel spans, error messages, or the debugger's value-lens
      surfaces, which render live runtime values (Risk 12). The sweep includes the **request line /
      proxy access log** shape, not only Tesl-internal sinks.
    - **A second concurrent login in the same browser fails closed.** One `__Host-oauth` cookie means
      the second `/login` overwrites the first tab's state; the first tab's callback must then be
      *rejected* with a retry page, never fall through to a state-less or state-optional path.
- **Phase 2 — plain-OAuth2 path + the types.** The userinfo call and its field mapping, GitHub's
  second `/user/emails` call, `SsoProvider`/`SsoConnection`/`SsoIdentity` and `Sso.defaults` as
  tables-only stdlib rows. Same runtime, same `SsoIdentity`. **The §Typed identity types land here
  too** — `EmailClaim` as a baked ADT and `SsoSubjectKey` as an opaque type in the mould of
  `PasswordHash`, plus `Sso.keyText` and the plain-OAuth2 synthesised issuer (scheme+host of
  `userinfoUrl`). **The `SsoSubjectKey` derivation is injective** — length-prefixed components or a
  domain-separated hash of `(issuer, subject)`, never naive concatenation (Risk 59). **Fail-closed rule lands here:** an absent, missing or non-boolean
  `emailVerifiedField` yields `UnverifiedEmail`, never `VerifiedEmail` — i.e. the runtime has exactly
  one code path that constructs `VerifiedEmail`, and it requires a positive verification signal.
  Tests: each blessed descriptor's verified/unverified outcome; a hand-written descriptor with a
  misspelled `emailVerifiedField`; a `userinfoUrl` whose path changes but whose host does not,
  asserting the identity key is unchanged; and an encoding-collision pair — two distinct
  `(issuer, subject)` pairs that concatenate identically — asserting distinct keys.
- **Phase 2.5 — ID-token signature verification (RS256/ES256 + JWKS). Required for the gold-standard
  claim; see §The trust argument, honestly.** A verify-only asymmetric path in `tesl/jwt.rkt` over
  `openssl/libcrypto` (already required at `:88`; bind lazily so a missing library does not break the
  module-level seam test the way `tesl/crypto.rkt:84-88` warns about) — libsodium cannot do this, it
  has neither RSA nor P-256. JWKS fetch/cache/`kid` selection under Phase 1's outbound rules, with a
  single rate-limited refetch on unknown `kid`. `alg` pinned from
  `id_token_signing_alg_values_supported` ∩ implemented; `alg: none` and HMAC algs on an ID token
  rejected unconditionally (algorithm confusion); RSA moduli below 2048 bits refused; verification
  failure is terminal with **no** downgrade path to §3.1.3.7. Added by the fourth review: **the token's
  own header may not nominate its key** — `jwk`, `jku`, `x5u` and `x5c` are ignored and never fetched,
  `crit` is refused, and a five-segment (JWE) token is refused rather than unwrapped (Risk 51); and **a
  userinfo call on an OIDC connection must check `sub` against the ID token's** (OIDC Core §5.3.2,
  Risk 52). Tests: a valid token from a stubbed JWKS accepted; wrong-key, wrong-`kid`, `alg: none`,
  HS256-signed-with-the-public-key, expired, future-`iat`, unknown-`kid`-flood, embedded-`jwk`,
  `jku`-pointing-at-an-attacker-JWKS, and `crit`-carrying cases each refused. Once this lands, the spec's §3.1.3.7
  passage becomes history-and-rationale, not operative behaviour.
- **Phase 3 — the `sso` clause.** Parser/AST/validation/emit; route minting from the literal segment;
  route-collision checking; client-generation exclusion; `onIdentity` as an `auth`-kind declaration
  with the proof-kernel wiring reviewed explicitly **and a fail-closed characterization test for the
  new `SsoIdentity` parameter shape**. Compile-time validation lands here too: `afterLogin`
  relative-or-same-origin, and the `extraAuthorizeParams` reserved-name rejection. (`publicOrigin`'s own
  absolute/`https`/no-query validation moved to Phase −2, where HSTS now depends on it.)
  **`loginMethods` lands here too** (§Login methods, Risk 46): the clause, the compile error for a
  password call under `loginMethods [Sso]` or for a bare `Crypto.checkPassword`/`hashPassword` in any
  program with an `sso` clause, and the runtime-mediated password path that consults the declared policy
  function on both verify and set. Re-shaped by the fifth review (Risk 56): the enforcement is the
  **allowlist over `auth` blocks** — under a `loginMethods` declaration every `auth` block must be
  attributable to a declared method, and an unattributable block does not compile — with the
  password-call rejection kept as the backstop one level down. Re-shaped a third time by the sixth
  review (Risk 63): the allowlist additionally — and primarily — classifies every reachable
  `Http.setSessionCookie` call site (enumerable via `cookieCap`), since sessions are created by
  handlers rather than by `auth` blocks; and the runtime-mediated password path returns a
  kernel-minted witness rather than `Bool` (Risk 64, Open Question 15). **The runtime-enforced `allowedEmailDomains` / `allowedHostedDomains`
  checks land with it** — before `onIdentity` is called, and satisfiable only by `VerifiedEmail`
  (§Domain restriction, Risk 53). The denial semantics in §What `onIdentity` does when
  it says no are asserted here. **`SessionPolicy` lands here too** — the `sessionPolicy` server setting
  and the `SessionPolicy` ADT as tables-only rows; its runtime half (parameterising
  `jwt-ttl-seconds`/`jwt-absolute-max-seconds` and decoupling the cap from the TTL multiplier,
  `tesl/jwt.rkt:277,302`) is independent of SSO and may land earlier with the tests named in §Session
  policy. **`ssoPreviousKey` lands here too** (§Session key rotation): the optional second verify slot,
  sign-with-current, renewal re-signing under the current key, `kid` staying advisory as
  `tesl/jwt.rkt:233-238` already argues. Its runtime half is likewise independent of SSO and may land
  earlier, with the tests named in that section. **The `sessionRevoked` renewal-boundary hook lands
  here too** (§Revocation at the renewal boundary): the optional server clause and the consult wired
  into the renewal clamp (`tesl/jwt.rkt:596-607`), fail-closed, verify path untouched; its runtime
  half is likewise independent of SSO, with the tests named in that section.
- **Phase 4 — surface polish.** Template with a working three-button login,
  `example/learn/lessonXX-sso.tesl`, LANGUAGE-SPEC section carrying **both** trust arguments
  (signature verification + validated claims for OIDC; PKCE + `state` + single-use code + server-side
  userinfo for plain OAuth2 — they are different arguments and must be written separately), the
  account-linking rule, and Entra ID as the tested enterprise reference path — single-tenant issuer,
  `tid` checked, and **no email linking, with the nOAuth reason in the template's own comment**. The
  spec text must also carry: the §3.1.3.7 history and why TLS alone was not accepted (the middlebox
  argument), the multi-tenant issuer rule, that `hd`-style authorize params are hints and domain
  restriction is a *claim* check, that `claims` is not an authorization input while `tenant` is, the
  revocation window the app is accepting together with `SessionPolicy` as its only control (Risk 22,
  §Session policy — including the rolling-deploy semantics), and the deferred rate limiting (Risk 19).
  Added by the third review, all spec text rather than code: the **mixed-mode bypass rule** and the
  one-enforcement-function pattern (§Login methods); **key rotation as the only kill switch**, with the
  procedure and its bluntness (§Session key rotation); **per-user revocation at the renewal boundary — its latency bound
  and its two overclaims (Risk 66)** — next to the revocation-window paragraph; the **`client_secret` half of Risk 11 that Phase 2.5 does not
  close**, with rotation as the answer; why **`at_hash`/`c_hash` are correctly absent**; and the
  identity-key rule (`(issuer, subject)`, synthesised issuer for plain OAuth2, segment is not identity).
  Added by the fourth review, also spec text: **what single-use `state` does and does not guarantee**
  (per-process, with the provider's `code` and PKCE carrying the rest — §Where the flow's own state
  lives); **the CSRF trio and why the cookie attribute alone is not the argument**, with the same-site
  subdomain caveat; **HSTS deriving from `publicOrigin`, never from a request header**, and the standing
  rule that no `X-Forwarded-*` trust may be introduced; **XSS in the app's own frontend as the third named
  exclusion**, with the CSP default described as reduction rather than elimination; **`loginMethods` as the
  answer to "how do I prove to my customer that only SSO can log in"**, which is the form the question
  actually arrives in; and **`allowedEmailDomains` being unusable with Entra** (no `email_verified`), with
  `allowedTenants` as Entra's correct mechanism.
- **Phase 5 — adversarial review pass, mandatory**, matching
  `roadmap/completed/session_cookie_security_followups.md`. Minimum attack list: `state` replay and
  cross-user `state` swap; PKCE verifier reuse; `nonce` omitted or unchecked (OIDC) and the absence of
  a `nonce` equivalent (plain OAuth2); `iss`/`aud` confusion; a `code` replayed twice; a provider
  returning 200 with an error body; **SSRF via any user-supplied issuer/token/authorize/userinfo/JWKS
  host**; a discovery document served over plain HTTP or redirecting off-origin; **account takeover by
  linking on an unverified email**; an `emailVerifiedField` pointing at a missing or non-boolean field;
  one provider asserting another provider's `subject`; `Set-Cookie` leaking through a `fail` path; and
  an `afterLogin` value pointing off-origin. Added by the first 2026-07-30 review:
    - **A MITM presenting a valid-shaped but wrongly-signed ID token over an unverified TLS channel** —
      the Phase −1 regression.
    - **`redirect_uri` poisoning** via `Host` / `X-Forwarded-Host` / `X-Forwarded-Proto`.
    - **Mix-up:** a `code` obtained from provider A delivered to provider B's callback — and the
      stronger form, an authorization response whose `iss` names a different provider than the
      callback path.
    - **`extraAuthorizeParams` overriding `redirect_uri`** (and each other reserved name), and a value
      containing `&`/`=`/`#` or a percent-encoded variant attempting parameter smuggling.
    - **Discovery `issuer` mismatch:** a document whose own `issuer` differs from the configured one.
    - **A provider-supplied `error_description` carrying HTML, a newline, or a URL**, checked at every
      sink: response body, redirect target, log line, OTel span.
    - **Secret leakage sweep:** `code`, `state`, verifier, access token and ID token must appear in no
      span, no log, no error message, and no debugger value-lens rendering.
    - **`__Host-oauth` readable from JavaScript** (missing `HttpOnly`), surviving the callback, or
      accepted a second time.
    - **Session fixation:** a pre-existing session cookie surviving a fresh SSO login.
    - **`hd`-as-restriction:** an out-of-domain Google account completing login when `hd` was passed on
      the authorize request but the `hd` claim was never checked.
    - **Authorization on a flattened `claims` value:** `"admin"` matching a `groups` value of
      `"[superadmin, readonly]"`.
    - **A `subject` that is absent, empty, `null`, or a JSON number** rather than a string.
    - **Unbounded or slow provider responses** (multi-megabyte userinfo, a token endpoint that never
      closes), and a discovery endpoint that redirects off-origin.
  Added by the second 2026-07-30 review:
    - **Algorithm confusion:** an ID token with `alg: none`; one signed HS256 using the provider's
      **public key** as the HMAC secret; one whose `alg` is outside the pinned set.
    - **Key confusion:** an unknown `kid`; a `kid` naming a key from a *different* issuer's JWKS; a
      JWKS with an under-2048-bit RSA modulus; an unknown-`kid` flood that must not become an
      unbounded JWKS refetch.
    - **Multi-tenant issuer:** a `common`-authority discovery document with a templated issuer and
      empty `allowedTenants` (must refuse); a `tid` outside `allowedTenants`; a token whose `iss`
      tenant segment disagrees with its own `tid`.
    - **PKCE downgrade:** a provider advertising only `plain`, and one advertising nothing (both must
      refuse); a token exchange that succeeds *without* the verifier being required.
    - **Client-auth confusion:** a provider that accepts only Basic; the secret appearing in a URL in
      either method.
    - **Denial path:** an `onIdentity` that `fail`s must leave no session cookie, must **clear** a
      pre-existing one, must delete `__Host-oauth`, and must render a page rather than a JSON
      responder body. Same for `connection` returning `Nothing`.
    - **`code`/`Referer` leakage:** the callback response missing `Referrer-Policy: no-referrer` or
      `Cache-Control: no-store`; a `code` visible in a captured request line after redaction is
      claimed.
    - **Concurrent-login clobber:** two tabs starting a login, the first tab's callback must be
      rejected, not accepted state-lessly.
    - **Clock:** an ID token with `exp` in the past, `iat` in the future beyond leeway, and an `iat`
      older than the `__Host-oauth` cookie's own issuance.
    - **Dev-gate escape:** the single development gate activating for a non-loopback host, and
      activating in a `tesl build` artifact — both must refuse.
    - **Entra `sub` instability** documented rather than tested: assert the template keys on
      `identity.key` and that the `oid` guidance is present.
  Added by the fourth 2026-07-30 review:
    - **`__Host-oauth` forgery:** a hand-built cookie with a chosen `nonce`, a chosen verifier and a
      chosen start time must be refused at the MAC check, before any field of it is read; a cookie minted
      at one `sso` segment must be refused at another segment's callback; a cookie MAC'd under the
      previous session key must still verify (rotation overlap), and one under neither key must not.
    - **`state` replay across processes:** assert what is actually claimed — refused within a process,
      and the spec statement that the cross-process guarantee is the provider's single-use `code` plus
      PKCE. A test asserting cluster-wide single-use must not exist, because the design does not provide
      it.
    - **SSRF by resolution:** a hostname resolving to `169.254.169.254`, to `127.0.0.1`, to an RFC1918
      address and to an IPv4-mapped loopback must each be refused — for `issuer`, `tokenUrl`,
      `userinfoUrl` **and** a `jwks_uri` taken from a discovery document; and a name that resolves
      differently on the second lookup must not reach an unchecked address (connect-time pinning).
    - **Key nomination via the token header:** embedded `jwk`, a `jku` pointing at an attacker-controlled
      JWKS, an `x5c` chain, and a `crit` header — each refused, and in the `jku` case with no outbound
      request made at all.
    - **Response headers on the paths that skip them today:** a static asset and an SPA-fallback
      `index.html` must each carry the server-wide set and the CSP default; HSTS must be present when
      `publicOrigin` is `https` even though the inbound request was plain HTTP, and absent under the
      loopback dev value.
    - **`Host` mismatch** against `publicOrigin` refused; **`Sec-Fetch-Site: cross-site`** on a
      state-changing request refused.
    - **Mixed-mode, compile-time:** a bare `Crypto.checkPassword` beside an `sso` clause must not
      compile; a password call under `loginMethods [Sso]` must not compile; and under
      `loginMethods [Sso, Password via ssoRequired]`, a password verify **and** a password set against a
      mandated identifier must both be refused, with `ssoRequired` raising also producing a refusal.
    - **Domain restriction, runtime:** an out-of-domain account with a non-empty `allowedEmailDomains`
      refused before `onIdentity` runs; an in-domain but `UnverifiedEmail` account also refused; an
      Entra-shaped token (no `email_verified`) with `allowedEmailDomains` set refused rather than
      silently passing; `allowedHostedDomains` non-empty with the `hd` claim absent refused.
    - **Item A discharge:** a header-trusting `auth` block compiles with a verified binding secret and a
      non-loopback `listenAddress`, and does **not** compile with neither that, nor loopback, nor the
      acknowledgement.
  Added by the third 2026-07-30 review:
    - **Identity-key stability:** a segment rename (`sso "github"` → `sso "gh"`) must leave every
      `SsoSubjectKey` unchanged; a `userinfoUrl` path/API-version change must too; a *host* change must
      change it (that is a different provider, and the failure must be visible, not silent).
    - **`VerifiedEmail` reachability:** an Entra-shaped token (no `email_verified`) must never yield
      `VerifiedEmail`; a descriptor with a misspelled `emailVerifiedField` must not either; a
      `emailVerifiedField` naming a string `"true"` rather than a boolean must not either.
    - **Mixed-mode bypass:** with SSO mandated for a domain, a password login and a password *reset* on
      an address in that domain must both be refused; and the same rule must apply on the Item A
      identity-header path (§Login methods).
    - **Session key rotation:** a token signed under the previous key verifies; one signed under a
      key that is in neither slot does not; a renewal of a previous-key token is re-signed under the
      current key; removing the previous key invalidates it (§Session key rotation).
    - **Callback with no `__Host-oauth` cookie at all** must be rejected as a failed flow, never
      treated as a fresh one (login-CSRF hygiene, Risk 38).
    - **Response headers:** the callback, the post-login landing response and an ordinary
      session-bearing response must each carry the server-wide header set (§The platform baseline).
    - **`listenAddress` enforcement:** a header-trusting `auth` block must fail to compile without
      either a loopback/unix `listenAddress` or the explicit acknowledgement clause (Phase −2).
  Added by the fifth 2026-07-30 review:
    - **Minting-site allowlist:** an `auth` block reading an API key (no password call anywhere in the
      program) under `loginMethods [Sso]` must not compile; a hand-rolled password compare (generic
      hash + `==` inside an `auth` block) must not compile either — both refused as unattributable
      minting sites, not caught by the password-call backstop.
    - **Forged Item A discharges:** `secret == secret`, a constant-time compare of two header values,
      a compare against a literal, and a comparison whose false branch still mints — each must fail
      Phase −2's discharge rule.
    - **Key separation:** an `__Host-oauth` payload authenticated under the *raw* session key must not
      verify (the subkey is not its parent); a payload under the previous key's subkey must still
      verify during rotation overlap.
    - **`SsoSubjectKey` collision:** two distinct `(issuer, subject)` pairs constructed to concatenate
      identically must produce distinct keys.
    - **Domain normalisation:** `ACME.COM` and `acme.com` accepted as one `allowedEmailDomains` entry;
      a Unicode label and its punycode form as one; a homoglyph domain refused as a different domain.
    - **Operational exceptions, both directions:** a probe-path request with `Host: <ip>` accepted
      while any other path with a mismatched `Host` is refused; a state-changing request with **no**
      `Sec-Fetch-Site` header accepted while `cross-site` is refused.
  Added by the sixth 2026-07-30 review:
    - **Cookie-writing allowlist:** a magic-link flow — a plain handler that validates an emailed
      token and calls `JWT.sign` + `Http.setSessionCookie`, with no password call and no `auth`
      block — must not compile under `loginMethods [Sso]`; the same handler carrying an Open
      Question 18 attribution to a declared method must.
    - **Witness forgery:** a `Password`-attributed cookie site that calls the password gate and
      discards its result must not compile (the witness is required, not the call); each of Risk 57's
      forged shapes must be unable to construct a `ProxyBound` witness; and a hand-built value of
      either witness type must be impossible on the Tesl surface (no constructor), in the mould of
      the existing fail-closed characterization tests.
    - **Event-log field:** the auth event emitted behind a proxy carries the socket peer under the
      corrected name; no field named `clientIP` ships while it would carry the proxy's address
      (Risk 65).

*Exit for the whole item:* two end-to-end api-tests — one OIDC (stubbed discovery → JWKS → token →
callback) and one plain OAuth2 (stubbed token → userinfo → callback) — each driving login → session
cookie → protected endpoint with no live provider; `dune test` and `./compile-examples.sh` green; the
stdlib binding-existence seam test covering every new name; the Phase −1 TLS tests (wrong-hostname and
self-signed peers refused, no bare `#:ssl? #t` in the tree) green; and the Phase 2.5 signature tests
green. Without Phase −1 **and** Phase 2.5, no exit is claimable and the item may not be described as a
gold-standard integration.

**Added by the third review — one real IdP, because every test above is our own stub.** `stubHttp`
tests assert that the implementation matches *our reading* of the specs; they cannot falsify that
reading, and the failure modes this document spends the most words on are exactly the ones a stub is
least able to reproduce: a real discovery document, real JWKS rotation and `kid` churn, a real
`id_token_signing_alg_values_supported` set, Entra's templated issuer, GitHub's two-call verified-email
dance. So exit additionally requires:

- **One containerised IdP in CI** (Keycloak or dex — self-hostable, standards-clean, no account
  needed), running the OIDC path end to end against real discovery, real JWKS and a real signed ID
  token, including one key rotation mid-suite.
- **One OIDC conformance run** (the certification suite's basic RP profile) performed once against the
  implementation before the phrase "gold standard" appears in any user-facing text. Not wired into CI —
  a recorded, dated result, re-run when the flow changes.
- **The plain-OAuth2 family stays stub-only** and that is accepted: GitHub and Discord have no
  conformance suite and no self-hostable double, so its trust argument is carried by review plus the
  synthesised-issuer and verified-email tests named in Phase 2.

**Added by the fourth review — one real browser, because every test above asserts server-side bytes.**
`__Host-` acceptance, `SameSite=Lax` surviving the callback's top-level navigation, `HttpOnly`, and the
CSP default not breaking the SPA are all *browser* behaviours, and their failure mode is silent: the
cookie is simply not stored, or the policy simply blocks the app's own script, and every server-side
assertion still passes. One headless-browser run through login → session → protected endpoint → logout,
against the containerised IdP, catches that class. Nothing else on this list can (Risk 55).

**Added by the sixth review — an external pass over the new checker rules themselves.** Five
successive reviews each found real holes in the previous round's fixes, and the sixth found one in the
fifth's (Risk 63). Every guarantee this item adds rides on new compile-time rules in the component the
2026-07-05 reviews identified as this codebase's historically fail-open one, so "gold standard"
additionally waits on one independent review scoped to exactly those rules — the `loginMethods`
attributions (cookie-writing sites and `auth` blocks), the two witness requirements, and the Phase −2
discharges — held to the same adversarial standard Phase 5 applies to the flow.

And the claim itself: **until §The platform baseline items 1, 2 and 5 land, the item may be described as a
gold-standard SSO *flow*, not as a gold-standard *platform*** — the two sentences are different, and the
second is the one the original ask is about. Its named, spec-stated exclusions are **two**: rate
limiting (at the scope corrected below — including the password endpoint) and cross-site scripting in
the app's own frontend. Mixed-mode login and per-user revocation were the third and fourth until
§Login methods made the one a checked declaration and §Revocation at the renewal boundary made the
other a runtime-owned check; that is the standard the remaining two are measured against.

## Non-goals

- **Rate limiting on the two minted routes — DEFERRED, by decision, 2026-07-30.** No rate-limiting
  subsystem exists anywhere in the tree, so this is a new subsystem rather than a line item, and it is
  out of scope here. What *is* in scope: every outbound leg is size- and time-capped, the discovery
  negative cache is bounded, the unknown-`kid` JWKS refetch is rate-limited by a minimum interval, and
  `state` is single-use *within a process* (§Where the flow's own state lives). The residual exposure —
  an unauthenticated `/login` that mints a cookie and an unauthenticated `/callback` that can trigger up
  to four outbound provider calls — is stated in the spec and in Risk 19, with "put a rate limiter in
  front of it" as the deployment-level answer until Tesl has one. Revisit when a general rate-limiting
  item lands.
  **Scope correction, fourth review: the deferral is not SSO-route-shaped, because §Login methods brought
  password authentication into this item.** An unauthenticated password endpoint with no limiter has no
  brute-force or credential-stuffing control **and** is a resource-exhaustion primitive by design:
  Argon2id is deliberately CPU- and memory-expensive, so each unauthenticated attempt costs the server
  real work and a handful of requests per second degrades it. That is a worse exposure than four outbound
  provider calls, and no compensating control in this item touches it. The deferral still stands — the
  subsystem is out of scope here — but the spec must state the exposure at *this* scope, so a team sizing
  their front-door limiter for the SSO routes does not leave the expensive endpoint open. Carried into the
  rate-limiting item as its first motivating case.
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
  tenant from `state` and returns that tenant's row, over one shared callback.
  **The broker is itself a trust concentration and the docs must say so**: one OIDC connection to a
  broker means the broker can assert *any* user of *any* customer, so compromise there is total, and the
  app's remaining defences are the ordinary ones — `iss` and `aud` pinned to the broker connection,
  signature verified under Phase 2.5, no email linking. That is a sound trade (it is the same trade as
  trusting Entra, with one more party) but it is a decision the user should make knowingly rather than
  inherit from a roadmap recommendation.
  If it is ever built,
  three requirements are non-negotiable and are the most commonly missed parts of DIY multi-tenant SSO:
  identity must key on `(tenant, issuer, subject)` and never on email — otherwise tenant B configures
  an IdP, asserts `alice@acme.com`, and takes over tenant A's user; a tenant's IdP must not be allowed
  to authenticate a domain until that tenant has proven control of it (DNS TXT or equivalent); and the
  `allowedTenants`/`tid` rule from §Entra ID applies per tenant row, not once globally.
- **Persisting the provider access token.** It is used once, for the userinfo call, and discarded. The
  moment it is stored we are an OAuth client library for calling third-party APIs on a user's behalf —
  different feature, different threat model.
- **Asymmetric *signing*.** Phase 2.5 is verify-only. This is what keeps Apple out (its
  `client_secret` is an ES256 JWT the app mints and rotates) and what keeps `private_key_jwt` client
  authentication out.
- **Blessed defaults for Apple, Facebook or X/Twitter.** Apple is blocked (ES256 signing); the other
  two are reachable by hand-written `OAuth2Endpoints` and do not earn a table row.
- SAML, WS-Fed, LDAP.
- MFA, conditional access, password policy — the explicit point of delegating to a provider.
- Refresh tokens / offline access. Tesl's session is its own 1h JWT under a 12h absolute cap;
  re-login is a redirect.
- Token introspection, back-channel or front-channel logout notifications, SCIM/user provisioning,
  group/role sync. **State the residual risk instead of leaving it implicit:** because the provider is
  a login mechanism only, a user disabled or deprovisioned at the IdP keeps access to the app until
  their session JWT expires — up to 1 hour, and up to the 12-hour absolute cap if it renews, under the
  default `StandardSession` policy; `ShortSession` narrows that to 15 minutes / 8 hours, and choosing
  the policy is the **only** control over this window (§Session policy). **The renewal-boundary hook
  does not change this window by itself** — it consults the app's own data, not the IdP, so an
  IdP-only disable runs to the absolute cap unless the app mirrors deprovisioning into its data
  (SCIM stays out; §Revocation at the renewal boundary, Risk 66). Logging
  out of the app clears only the app's cookie; the provider's session persists, so on a shared machine
  "log out, log in" is an instant silent re-login. Both are acceptable for v1 and both are the first
  questions an enterprise security reviewer asks about an SSO integration, so they belong in the
  LANGUAGE-SPEC section and the lesson, not in an unwritten assumption. (RP-initiated logout would need
  `Http.redirect` — the separate item.)
- IdP-initiated login; implicit and hybrid flows.
- `Http.redirect` and any general redirect surface — **separate item**.
- **Per-user revocation on the *request path*** (LANGUAGE-SPEC §21.8) — narrowed by the sixth review
  to what its argument actually covers. A per-request store stays out; per-user revocation itself is
  **in scope** at the renewal boundary (§Revocation at the renewal boundary), with latency bounded by
  the renewable TTL, the two blunt levers (§Session key rotation) as the zero-latency responses, and
  the overclaims named in Risk 66.
- **Forced reauthentication and step-up:** `max_age`, `prompt=login`, `prompt=consent` and the
  `auth_time` claim are not passed and not checked, so an app cannot demand a fresh authentication for a
  sensitive action, and cannot tell how long ago the IdP actually authenticated the user. `ShortSession`
  is the blunt substitute. Stated as a non-goal so it is not later filed as a defect; `max_age` +
  `auth_time` is the natural first extension if a real requirement appears, and both are reachable
  through `extraAuthorizeParams` and `claims` in the meantime (without validation, which is the point of
  leaving them out).
- Hot-reloading provider configuration. The `connection` hook runs per login, so credentials can come
  from anywhere; the clause itself is fixed at server construction.

## Risks & containment

1. **`onIdentity` mints `Authenticated` from third-party assertions.** Contain: it is an `auth`-kind
   declaration, so minting stays at an existing sanctioned boundary and inside the proof kernel's
   remit — no second minting site, no `fn→Fact` reopening. Reviewed explicitly in Phase 3, with a
   fail-closed characterization test for the new `SsoIdentity` parameter shape.
2. **Account linking is an account-takeover vector, and social login makes it unavoidable.** Three
   login buttons mean one human arrives as three identities; keyed on `(provider, issuer, subject)`
   that is three accounts. Linking them **by email address is a takeover vulnerability unless that
   provider provably verified the address**: an attacker signs up at a provider permitting an
   unverified address, claims `victim@gmail.com`, and inherits the victim's account. GitHub makes this
   concrete — `/user`'s email is the *public profile* field and unverified, so the verified primary
   requires the second `/user/emails` call. **Entra makes it concrete in the other direction** — it
   emits no `email_verified` at all and a tenant admin can set an arbitrary `email` (this is nOAuth),
   so "enterprise IdP, the mail attribute must be real" is the exact wrong inference. Contain:
   **verified-ness is a constructor, not a field** — `EmailClaim = VerifiedEmail | UnverifiedEmail |
   NoEmail` (§Typed identity), so reading the address forces a `case` and the unverified branch is named
   for what it is at the point of use; the runtime has exactly one code path that builds `VerifiedEmail`
   and it requires a positive verification signal; the shipped templates **refuse to link on an
   unverified email** — with the nOAuth reason written into the Entra template itself, not only in the
   lesson — and offer explicit "link account" while already authenticated. **Revised by the third
   review:** the earlier containment was "the templates and the lesson teach the rule", which is the
   unenforceable-guarantee shape this document rejects in Item A.
3. **Email verification is user-configurable, so a config typo can forge it.** `emailVerifiedField`
   comes from a value the user may hand-write. Contain: **absent, missing at runtime, or
   non-boolean ⇒ `UnverifiedEmail`, never `VerifiedEmail`** — fail closed, asserted by test, and now
   expressed as "one constructor site, one positive signal required" rather than as a boolean default.
   Without this rule, Risk 2 becomes reachable through a misspelled field name.
4. **Identity keyed on the wrong claim.** Even single-provider, matching a user by `email` rather than
   by the provider's subject is wrong: `email` is mutable at most providers and reassignable at
   some, so a reassigned address silently inherits the previous holder's account. Contain: **the
   storable identity is an opaque `SsoSubjectKey` derived from `(issuer, subject)` that contains no
   email and has no constructor on the Tesl surface** (§Typed identity), so the type the user table
   wants cannot be built out of an email address — closed by construction, not by template. `email` is
   display data. **Note the correction:** the key is `(issuer, subject)`, *not*
   `(provider, issuer, subject)` — `provider` is the user-chosen route segment, so including it would
   make a segment rename silently orphan every account (Risk 36). Provider-specific
   note that belongs in the Entra template: Entra's `sub` is **pairwise** — app-specific and unstable
   across app registrations — while `oid` is the stable per-tenant object id, so a team that keys on
   `sub` and later recreates its app registration orphans every account; document mapping `oid` into
   `subject` for survivable identities.
5. **SSRF via configuration — now wider, because every endpoint can be user-supplied.** `issuer`,
   `authorizeUrl`, `tokenUrl`, `userinfoUrl` and the discovery-declared `jwks_uri` all drive outbound
   requests. Contain: require `https`, refuse redirects off the origin, and — **revised by the fourth
   review from hostnames to resolved addresses (Risk 47)** — resolve first, refuse if any returned
   address is loopback, link-local, unique-local, RFC1918, CGNAT, `0.0.0.0/8` or an IPv4-mapped form
   of those, and connect to the address that was checked so re-resolution cannot rebind. A name check
   alone is bypassed by a hostname resolving to `169.254.169.254`. Applies identically to blessed
   defaults and hand-written values, and per leg — including `jwks_uri`, which comes from a document.
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
    runtime and the tables-only types (Phases 1–2.5) behind tests before touching the frontend, so a
    stalled Phase 3 still leaves working, tested machinery.

Added by the first 2026-07-30 security review:

11. **The unverified TLS peer (blocker 7).** Two distinct losses, not one: a network attacker forges an
    ID token that nothing else would catch, *and* the token exchange discloses `client_secret` to that
    attacker. Contain: **Phase −1, shipped before any SSO code**, plus a ratchet test so a bare
    `#:ssl? #t` cannot come back. **Note the correction from the second review:** Phase −1 makes TLS
    correct, not sufficient — see Risk 23. **And from the third review: Phase 2.5 closes only the first
    loss.** A trusted-CA interception middlebox still reads `client_secret` out of every token exchange,
    in both `client_secret_basic` and `client_secret_post`. Residual contained only by treating the
    client secret as rotatable (documented cadence, rotate on suspicion) and, later, by `private_key_jwt`
    — which needs asymmetric signing and is a stated non-goal. §The trust argument, honestly.
12. **Secrets and tokens leaking into observability.** `Secret` redacts the client secret and nothing
    else. `code`, `state`, the PKCE verifier, the access token and the ID token are ordinary strings
    flowing through a runtime that has OTel spans, structured errors, and a debugger that renders live
    values on three surfaces. A traced token is a replayable token. Contain: redact at construction,
    not at each sink; add the sweep to Phase 5; keep the access token out of URLs so it cannot land in
    a proxy access log either — and see Risk 24 for the `code`, which cannot be kept out of a URL.
13. **Discovery-document trust is not the same as issuer trust.** Fetching
    `<issuer>/.well-known/openid-configuration` and believing its endpoints is only sound if the
    document's own `issuer` field matches the configured issuer — otherwise a compromised or
    misconfigured discovery response relocates the token endpoint (and, now, the `jwks_uri`). Contain:
    exact `issuer` match, or the `allowedTenants` + `tid` rule for a templated issuer and nothing
    looser; `https` only; no off-origin redirects; bounded cache TTL; bounded negative cache.
14. **`extraAuthorizeParams` can rewrite the flow.** A `Dict String String` merged into the authorize
    URL is account takeover by config if it reaches `redirect_uri`. Contain: reserved-name hard error
    plus percent-encoding of key and value (see "the provider is a value" section); tested in Phase 5.
15. **Reflecting provider-supplied error text.** The callback is the one route reachable
    unauthenticated, and `error_description` is attacker-influenceable at some providers. Reflected
    into a body it is XSS; into a redirect it is an open redirect; into a log it is log injection.
    Contain: never reflect — log a fixed code, show the user a fixed page. The app author's own `fail`
    message is a different thing and *is* showable (§What `onIdentity` does when it says no); the
    implementation must not conflate the two sources.
16. **Cookie hygiene at the callback.** `__Host-oauth` holds the PKCE verifier, so a missing `HttpOnly`
    hands it to any XSS; surviving the callback makes it replayable; and a pre-existing session cookie
    that outlives a fresh login is session fixation. Contain: the explicit attribute list and the
    delete-on-every-path rule in Phase 1, each asserted. Known accepted limitation: one cookie means
    two concurrent logins in two tabs clobber each other — and the losing tab must **fail closed** with
    a retry page, asserted in Phase 5, never fall through to a state-optional path.
17. **`hd`-style authorize parameters look like access controls.** They are account-picker hints.
    Contain — **revised by the fourth review from documentation to enforcement (Risk 53)**: domain
    restriction is `allowedHostedDomains` / `allowedEmailDomains` on the connection, checked by the
    runtime before `onIdentity` runs and satisfiable only by `VerifiedEmail`; the `onIdentity` claim
    check remains available for app-specific policy but is no longer the only thing standing between a
    forgotten line and an unrestricted login. Phase 5 tests the out-of-domain login, the in-domain
    unverified address, and the absent-`hd` case.
18. **Authorizing on `claims`.** A `Dict String String` flattens arrays, so a `groups` claim becomes a
    string a naive substring check will happily match — `"admin"` matches `"[superadmin, readonly]"`.
    Contain: **`claims` is `Dict String Json`, not `Dict String String`** (§Typed identity), so the
    naive substring match does not typecheck and the mistake is a compile error rather than an
    authorisation decision; the prohibition ("display and debug only") stays in the spec, but it is no
    longer the only thing standing between a user and the bug. The authorization inputs are `key`,
    `issuer`, `provider`, `tenant` and the *constructor* of `email` — all typed, and `tenant` is a
    typed field *precisely* so the Entra rule (Risk 25) is never expressed as a lookup into the
    untrusted dict. Revisit by giving typed claims a typed home if role sync ever stops being a
    non-goal. **Depends on Phase 0's blocker-6 decision** — this is the same defect one level down, so
    the two answers must agree.
19. **Abuse of the two unauthenticated routes — rate limiting DEFERRED.** `/login` starts a flow and
    mints a cookie; `/callback` can trigger up to four outbound provider calls (discovery, JWKS,
    token, userinfo) per request. Tesl has no rate limiter and this item does not build one. Contain,
    within scope: cap and bound every outbound leg, bound the discovery negative cache, rate-limit the
    unknown-`kid` JWKS refetch by a minimum interval, keep discovery and JWKS cached so the steady-state
    per-request cost is two legs, and make `state` single-use **within a process** (Risk 42 — the
    cross-process version is not implementable under cookie-only storage and is no longer claimed). Out of
    scope and **stated in the spec**: per-IP request limits, so the deployment-level answer is a rate
    limiter in front of the app. **Scope corrected by the fourth review (Risk 54): the unmetered surface
    includes the password endpoint**, where the absence is both a brute-force gap and — because Argon2id is
    expensive by design — a resource-exhaustion primitive worse than four outbound provider calls.
    Revisit when a general rate-limiting item lands — and see **§How rate limiting slots in later**,
    added by the third review, which fixes the four properties that item must have (dispatch-level, not
    per-handler; keyed off the Risk 21 auth event; client IP from Phase −2's proxy declaration and not
    from a bare `X-Forwarded-For`) so landing it later costs no redesign of anything here.
20. **`afterLogin` will be asked to take a runtime `?next=` target within a week of shipping.**
    Compile-time validation of a literal is correct now, but decide the runtime rule before it is
    demanded rather than under pressure: relative paths only, from an allowlist, rejecting `//host`,
    backslashes, control characters and encoded variants of each. Contain: write the rule into the spec
    now, even though v1 only accepts a literal.

Added by the second 2026-07-30 adversarial review:

21. **No auth event log.** Redaction rules were specified with no positive requirement to emit an
    auditable record, and "who logged in, from where, when, and who was refused" is the first artefact
    an enterprise security review asks for — and the only way an operator detects the abuse that
    deferred rate limiting leaves open (Risk 19). Contain: emit a structured login event on success and
    on every denial — provider, segment, issuer, subject, tenant, outcome class, timestamp, client IP —
    carrying **no** token, `code`, `state` or verifier. OTel is already in the runtime, so this is
    wiring, not a subsystem.
22. **Session lifetime is not configurable — fix it with a closed ADT, not a number.**
    `jwt-ttl-seconds` is `3600` and `jwt-absolute-max-seconds` is `(* 12 jwt-ttl-seconds)`, both
    hardcoded (`tesl/jwt.rkt:277,302`). 1h/12h is a defensible default, but an organisation whose
    policy requires 15-minute reauth cannot comply, and the revocation window in Non-goals has no knob
    — the *only* mitigation for "deprovisioned at the IdP, still in the app" is a shorter session, and
    there is no way to shorten it. Contain: **a baked `SessionPolicy` ADT** (§Session policy) — closed,
    every value safe, both numbers named per constructor so the absolute cap is never derived by
    multiplying the TTL — plus the limit and the rolling-deploy semantics stated in the spec next to the
    revocation-window paragraph.
23. **"Authenticated TLS channel" is weaker than it reads, so §3.1.3.7 alone is not gold standard.**
    Phase −1 authenticates the peer against the host's trust store; an enterprise TLS-inspection
    middlebox is *in* that trust store by design, and those middleboxes are routine in the corporate
    networks where Entra ID lives. With signatures unverified there is no second control. Contain:
    **Phase 2.5 ships signature verification in this item**, the §3.1.3.7 reasoning is written into the
    spec together with this limitation, and there is no runtime path that downgrades from verified to
    unverified once Phase 2.5 lands.
24. **The authorization `code` is in a URL and cannot be moved.** Unlike the access token, `code`
    arrives as `?code=` and therefore reaches browser history and every reverse-proxy access log on the
    path. Contain: **the provider's own single-use `code`** plus PKCE binding are the compensating
    controls and must be named as such in the spec — corrected by the fourth review from "our single-use
    `state`", which cookie-only storage cannot deliver across processes (Risk 42);
    `Cache-Control: no-store` and `Referrer-Policy: no-referrer` on the
    callback response stop onward leakage; the immediate 303 clears the address bar; and Risk 12's
    redaction sweep explicitly covers the request-line shape, not only Tesl-internal sinks.
25. **The multi-tenant issuer trap.** A tenant-agnostic authority (`common`, `organizations`) returns a
    *templated* discovery `issuer`, exact matching fails, and the natural repair — prefix or wildcard
    matching — authenticates every Microsoft tenant and every personal Microsoft account on earth.
    Contain: templated issuers refused unless `allowedTenants` is non-empty; `tid` ∈ `allowedTenants`
    **and** `iss` equal to the template with `{tenantid}` := that `tid`; single-tenant issuer as the
    documented default in the Entra template; Phase 5 tests all three failure shapes. See §Entra ID.
26. **PKCE that is not actually enforced.** Sending `code_challenge` to a provider that ignores it
    looks identical to protection. Contain: require `S256` in `code_challenge_methods_supported` and
    refuse the provider otherwise, treating an absent field as absent support; Phase 5 asserts that an
    exchange without the verifier fails.
27. **Algorithm and key confusion in Phase 2.5.** Adding asymmetric verification adds its own classic
    holes: `alg: none`, an HMAC `alg` verified against the provider's public key as the secret, a
    `kid` naming a key from another issuer, an undersized RSA modulus, and an unknown-`kid` flood
    turned into unbounded JWKS refetching. Contain: `alg` pinned from discovery ∩ implemented, HMAC
    and `none` refused unconditionally on an ID token, keys taken only from the discovery-declared
    `jwks_uri` for *that* issuer, ≥2048-bit RSA, one rate-limited refetch on unknown `kid`; each one a
    Phase 5 test.
28. **The token-endpoint client-authentication method was unspecified.** Guessing between
    `client_secret_basic` and `client_secret_post` is how a secret ends up sent twice or in a query
    string, and it breaks setup against IdPs that accept only one. Contain: choose from
    `token_endpoint_auth_methods_supported`, prefer Basic, refuse a provider advertising neither,
    never place the secret in a URL.
29. **Mix-up defence rested on an unstated invariant.** Per-provider callback paths only prevent
    cross-provider code injection while the token endpoint at exchange time comes from the callback
    path's connection and from nothing in the authorization response. Contain: state the invariant,
    also check a present `iss` response parameter, and test the stronger form in Phase 5.
30. **Three independent development escapes were accumulating.** A TLS opt-out, a `publicOrigin`
    localhost carve-out and an SSRF loopback override are three chances to ship a fail-open build.
    Contain: one named environment-level gate, one enforcement point, refused for any non-loopback host
    and refused entirely in a `tesl build` artifact, announced in the startup banner, with a ratchet
    test against a fourth escape appearing.
31. **Item A's guarantee is unenforceable, and Tesl binds to every interface.** The proxy pattern's
    security is deployment topology the compiler cannot see, and `serve/servlet` runs with
    `#:listen-ip #f` (`dsl/web.rkt:2386`) — all interfaces. A user following the documented pattern on
    a host with any other reachable interface serves the header-trusting app directly. Contain —
    **revised by the third review from "prefer the setting" to "the setting, and checked"**:
    **Phase −2** adds `listenAddress` *and* the compile-time rule that a header-trusting `auth` block
    requires either a loopback/unix binding or an explicit written acknowledgement, and Phase −2 gates
    Phase A so the pattern is never published without its enforceable form. The lesson still shows the
    verification step (`ss -ltnp`), and Item A is still described as a pattern — but the part Tesl can
    check is now checked, which is the only version of "secure for free" that means anything.

Added by the third 2026-07-30 review, which read the item as a whole rather than the flow alone:

32. **The two takeover-prone decisions were enforced by prose.** `email: Maybe String` +
    `emailVerified: Bool` and `claims: Dict String String` let the wrong code compile, pass tests, and
    look right in review; the containment for Risks 2, 3, 4 and 18 was the template and the lesson. In a
    language whose pitch is that dangerous states are unrepresentable, that is the weakest available
    answer, and it is structurally identical to the Item A honesty note. Contain: §Typed identity — an
    `EmailClaim` ADT, an opaque `SsoSubjectKey` with no email in it and no surface constructor, and
    `claims: Dict String Json`. Cost is table rows plus one opaque type modelled on `PasswordHash`,
    which already has exactly these properties, so this is not new machinery.
33. **Mixed-mode bypass: the password form next to the SSO button defeats the whole item.** Tesl has
    Argon2id password auth (`type_system.ml:925`), most apps keep it when they add SSO, and a password
    login — or a password *reset* — on an SSO-mandated address skips the IdP's MFA and conditional
    access with every control in this document intact and green. Unmentioned in the earlier draft.
    Contain — **revised by the fourth review (Risk 46) from a warning to a checked declaration**:
    §Login methods — `loginMethods [Sso]` makes a password path a compile error; mixed mode declares one
    policy function which the *runtime* consults on every password verify and every password set;
    bare `Crypto.checkPassword`/`hashPassword` do not compile beside an `sso` clause, so the second and
    third call sites cannot be forgotten. The mandate is still app data, not configuration. Phase 5 tests
    all three entry points plus both compile-time negatives.
34. **The session signing key cannot be rotated, so there is no kill switch of any kind.** `kid` is
    stamped (`tesl/jwt.rkt:244`) but verification takes one key, so a suspected leak forces a choice
    between keeping a compromised key and logging out every user unannounced — and with per-user
    revocation a standing non-goal, anyone holding the key mints any session until each token's absolute
    cap, with nothing able to refuse it. Contain: §Session key rotation — an optional `ssoPreviousKey`
    verify slot, sign-with-current, renewal re-signing under current so the old key drains in one cap,
    `kid` staying advisory so no new failure mode appears. Emptying the previous slot while rotating
    current *is* the global kill switch and must be documented as the incident-response lever it is.
35. **The response-header baseline does not exist, and the cookie rules depend on it.** The tree emits
    only `X-Content-Type-Options` (`dsl/web.rkt:1292`, `:2372`): no HSTS, so a `Secure`/`__Host-` cookie
    scheme still permits a plaintext first navigation — and an SSO login is a top-level navigation; no
    `Referrer-Policy` default, which the earlier draft added at the callback only; no frame denial; no
    CSP even on the pages the runtime itself renders. Contain: Phase −2(b), server-wide defaults with a
    byte-identical-output test and a ratchet against a response path that skips them.
36. **The identity key contained a user-chosen deployment label.** `(provider, issuer, subject)` where
    `provider` is the `sso "github"` segment means renaming the segment silently orphans every account,
    and there is no error — the next login just creates a new user. Contain: key on `(issuer, subject)`;
    for plain OAuth2, where no issuer claim exists, synthesise it from the scheme+host of `userinfoUrl`
    (stable across Discord's in-path API version bump); `provider` stays for display and logging only;
    Phase 5 asserts key stability across a segment rename and a userinfo path change.
37. **Every planned test was our own stub, so none of them can falsify our reading of the specs.**
    `stubHttp` cannot reproduce real discovery, real JWKS rotation, a real advertised `alg` set, Entra's
    templated issuer, or GitHub's two-call verified-email dance — the exact cases this document treats as
    most dangerous. Contain: one containerised IdP (Keycloak or dex) in CI including a mid-suite key
    rotation, plus one dated OIDC conformance run before the phrase "gold standard" is used anywhere
    user-facing. The plain-OAuth2 family stays stub-only, stated as accepted.
38. **Login CSRF was not named, and the no-cookie callback case was unspecified.** `__Host-` plus a
    cookie-bound `state` closes the interesting version (an attacker cannot set a cookie on the app's
    origin), so this is a small residual — but "closed by a prefix we happen to use" should be written
    down, and the callback's behaviour when there is **no** `__Host-oauth` cookie at all must be pinned:
    rejected as a failed flow with the fixed error page, never treated as a fresh one. Related to but
    distinct from the concurrent-tab rule in Risk 16. Contain: state the argument, assert the case.
39. **`SameSite=Lax` is the entire CSRF story and nothing enforces its precondition.**
    `tesl/http.rkt:65` is sound exactly while no state-changing route is reachable by GET. Contain: say
    in the spec that the cookie attribute *is* the CSRF defence, and add the Phase −1.5 linter rule
    flagging a write capability inside a GET route — the checker already has both facts.
40. **`publicOrigin` as a compile-time literal forces one artifact per environment**, and the first team
    that wants one build for staging and production will reach for an environment variable — which is
    blocker 8 arriving through the side door with everyone's approval. Contain: decide the answer *now*
    (Open Question 11) rather than under that pressure; whichever it is, the value must never be
    derivable from a request header, and the compile-time shape validation must survive.
41. **The claim itself is the risk.** "Gold standard, for free" is a sentence a user will quote to their
    customer's security reviewer, so the item must not be able to ship it while per-user revocation and
    rate limiting are absent. Contain: the two-sentence rule in the exit criteria — a gold-standard
    *flow* is claimable after Phase 5; a gold-standard *platform* is not until §The platform baseline
    items 1, 2 and 5 land, and even then with its **three** exclusions named in the spec (revocation,
    rate limiting, app-frontend XSS). Anything stronger is the same overclaim the Item A honesty note
    exists to prevent.

Added by the fourth 2026-07-30 review, which checked the plan's claims against the tree rather than
against the plan:

42. **"Single-use `state`" cannot be implemented under cookie-only storage, and two other controls were
    leaning on it.** Open Question 4 settles cookie-only; Phase 1 then asserts consumption, and Risks 19
    and 24 both cite single-use `state` as a compensating control. With no server-side record,
    "consumption" is deleting a cookie the client holds. Contain: §Where the flow's own state lives — a
    bounded TTL'd spent-`state` set makes it true per-process, the cross-process guarantee is restated as
    the provider's single-use `code` plus PKCE binding, and Risks 19 and 24 are re-worded to cite what
    exists. A test asserting cluster-wide single-use must not be written.
43. **The `__Host-oauth` payload was unauthenticated, so the browser decided the login's own facts.**
    Attributes were pinned; contents were not. `HttpOnly` stops JavaScript reading a cookie, not a client
    choosing one — so `nonce`, the PKCE verifier and the flow start time were all client-supplied, which
    makes Phase 2.5's `iat`-versus-cookie-age check vacuous. Contain: MAC/AEAD under the session key
    against `[current, previous]`, route segment inside the payload, nothing read before the MAC
    verifies, failed MAC ⇒ failed flow. §Where the flow's own state lives, Open Question 16.
44. **HSTS as scoped would never ship.** Phase −2(b) said "emitted on every https response", but Tesl
    serves plain HTTP behind a TLS-terminating proxy, there is **no** `X-Forwarded-*` handling in the tree,
    and blocker 8 forbids trusting one. So the condition is false in every proxy-fronted deployment and the
    header silently never appears — in the one deployment Item A blesses. Contain: decide from
    `publicOrigin`'s scheme, which is configured, validated and unforgeable; `publicOrigin` moves to
    Phase −2 for that reason. §The platform baseline, Correction 1.
45. **Two response paths skip every header today, and they are the two that serve the app's own HTML.**
    `try-serve-static` (`dsl/web.rkt:2286`) and the SPA fallback (`dsl/web.rkt:2348`) both answer with
    `'()` headers — no CSP, no `Referrer-Policy`, not even the `nosniff` the tree is credited with. And
    since Tesl reads and returns those files, a Tesl program has no way to attach a header to them, so
    "the app writes its own CSP" was unachievable in-language. The consequence is not a missing hardening
    header: script on the app's origin does not need to read a `HttpOnly` cookie, it calls the API with
    it, defeating `__Host-`, `SameSite`, PKCE and signature verification at once. Contain: Phase −2(b″)
    covers both call sites, an overridable CSP default on served HTML, the ratchet naming those paths, and
    XSS as the third named exclusion of the platform claim. §The platform baseline, Correction 2.
46. **The mixed-mode bypass was contained by a warning that fires on the legitimate shape.** Risk 33
    correctly predicts "a rule enforced in two of three entry points"; the third review's containment —
    a template function called from three sites plus a coexistence warning — cannot detect that. The
    warning triggers on nearly every SSO-adopting program, says nothing about whether the sites were
    wired, and is acknowledged once. Contain: **`loginMethods`** (§Login methods) — `[Sso]` makes a
    password path a compile error; mixed mode routes verify **and** set through one runtime-mediated gate
    consulting one declared policy function; bare `Crypto.checkPassword`/`hashPassword` do not compile
    beside an `sso` clause. Residual, stated: mixed mode still trusts the app's own `ssoRequired` table
    to name the right users — but *that the check runs* is no longer the author's responsibility, which
    is the half that was failing.
47. **SSRF containment was hostname-shaped where the threat is resolution-shaped.** Risk 5's "refuse
    literal-IP and loopback/link-local hosts" passes any hostname that *resolves* to
    `169.254.169.254` — cloud instance credentials — or to an internal RFC1918 service. `jwks_uri` makes
    it sharper: it is the one URL taken from a document rather than from configuration. Contain: check
    every resolved address against the full deny set, connect to the checked address (pinning, so
    re-resolution cannot rebind), re-run per leg and per refused redirect. Phase 1.
48. **Item A's compile-time discharge is unavailable in the deployments it targets.** A container or pod
    must bind `0.0.0.0` to be reachable by its sidecar, so `listenAddress Loopback` is out and the
    acknowledgement escape becomes the normal path — leaving the check as ceremony exactly where the
    pattern is used. Contain: accept a **verified binding-secret comparison** in the `auth` block's own
    evidence as a third discharge; it is topology-independent, visible in the program, and the stronger
    control anyway. §Item A.
49. **The CSRF story was about to be written down weaker than the code's own.** `tesl/http.rkt:61-65`
    relies on `SameSite=Lax` **plus** 415-on-non-JSON (`dsl/web.rkt:1308`) **plus** absent CORS headers;
    the draft's "the cookie attribute *is* the CSRF defence" is both less accurate and less safe, since
    `SameSite` is site-level and a sibling subdomain is same-site. Recording the weak version invites a
    future reviewer to relax the 415 rule. Contain: state all three, with the subdomain caveat, and add a
    `Sec-Fetch-Site: cross-site` refusal on state-changing requests — which also covers the non-JSON
    routes the 415 argument does not reach.
50. **No inbound `Host` validation.** `publicOrigin` is a configured statement of where the app lives, so
    a mismatched `Host` can be refused for the cost of one comparison, closing cache-poisoning and
    absolute-URL-confusion classes and removing any future temptation to answer "which origin am I?" from
    a header. Contain: Phase −2(c).
51. **The ID token's own header could nominate its verification key.** `alg` pinning, `kid` selection and
    modulus floors were specified, but `jwk`, `jku`, `x5u` and `x5c` were not — and a verifier that
    honours an embedded or linked key accepts any token with a valid signature over an attacker's key.
    Contain: those four ignored and never fetched, `crit` refused, JWE refused rather than unwrapped;
    Phase 2.5 tests each, asserting for `jku` that **no outbound request is made at all**.
52. **No userinfo-`sub` match rule.** v1 calls userinfo only for plain OAuth2, so it reads inapplicable —
    but a hand-written `OAuth2Endpoints` against an OIDC provider reaches it today, and Okta/Auth0
    deployments needing claims absent from the ID token are the first requested extension. Without OIDC
    Core §5.3.2's check, one login's claims attach to another login's identity. Contain: state and test
    the rule now.
53. **Domain restriction was still prose after §Typed identity removed the rest.** "Verify the `hd` claim
    in `onIdentity`, as the template shows" is the same unenforceable shape, for a rule whose omission
    authenticates the whole internet — and `allowedTenants` already proved this class of restriction
    belongs on the connection. Contain: runtime-enforced `allowedEmailDomains` / `allowedHostedDomains`,
    checked before `onIdentity` runs, empty ⇒ unrestricted, and **satisfiable only by `VerifiedEmail`** —
    restricting on the domain of an address no provider verified is Risk 2 dressed as a control. Follows
    that `allowedEmailDomains` is unusable with Entra, which is correct and must be in the template.
54. **The rate-limiting deferral was scoped before passwords entered the item.** Risk 19 frames the
    residual as two SSO routes; §Login methods brought Argon2id password auth into scope, and an unmetered
    password endpoint has no brute-force control **and** is a CPU/memory exhaustion primitive precisely
    because the KDF is expensive on purpose. Contain: the deferral stands, its stated scope is corrected in
    Non-goals and in the spec, and it is carried into the rate-limiting item as that item's first
    motivating case.
55. **Every planned test asserts server-side bytes, so the browser half is untested.** `__Host-`
    acceptance, `SameSite=Lax` on the callback navigation, `HttpOnly`, and a CSP default that does not
    break the SPA are browser behaviours whose failure is silent — the cookie is simply not stored and
    every server-side assertion still passes. Contain: one headless-browser run through
    login → session → protected endpoint → logout against the containerised IdP, added to the exit
    criteria beside the conformance run.

Added by the fifth 2026-07-30 review, which checked the new checks themselves against the codebase's
own root-cause diagnosis (decide-by-spelling; fail-open by enumeration):

56. **`loginMethods` enforcement was denylist-shaped.** "Find `Crypto.checkPassword`/`hashPassword`"
    misses every minting path not spelled with those names — a generic hash compared with `==`, a
    magic-link flow, an API-key `auth` block, a future WebAuthn handler — so a program could read
    `loginMethods [Sso]` with a fourth door open. That is the decide-by-spelling failure mode inside
    the very check built to end prose containment. Contain: the allowlist over `auth` blocks — the
    checker already enumerates the sanctioned minting sites, so under a `loginMethods` declaration an
    `auth` block not attributable to a declared method does not compile; the password-call rejection
    stays as a backstop. §Login methods, Open Question 18.
57. **Item A's binding-secret discharge had no semantic definition.** A discharge recognised by shape
    is dischargeable by `secret == secret`, by a compare of two header values, or by a comparison
    whose false branch still mints — accidental forgeries, in the same class the 2026-07-05 reviews
    reopened. Contain: the discharge is established on the dataflow — a config-originated `Secret`
    compared against a `request.headers` read, with the mint control-dependent on success — and
    Phase −2 carries the forged shapes as compile-time negatives. §Item A.
58. **The session signing key was about to serve two algorithms raw.** The `__Host-oauth` MAC/AEAD
    "under the session signing key" reuses the key that HMACs the session JWT; two algorithms over
    one raw key is not gold standard — an oracle or flaw in one use reaches the other. Contain:
    purpose-derived subkeys (libsodium `crypto_kdf`, distinct contexts), rotation carried through by
    deriving from `[current, previous]`. One line in Phase 1. §Where the flow's own state lives,
    Open Question 16.
59. **`SsoSubjectKey`'s derivation was not stated to be injective.** Naive concatenation makes
    `("https://a", "x|https://b")` and `("https://a|x", "https://b")` one key — a cross-issuer
    collision, the takeover shape in a multi-provider program, and `sub` is not always
    un-influenceable (self-hosted IdPs with username-as-`sub` exist). The Phase 5 "one provider
    asserting another provider's subject" test is about claims and does not cover encoding. Contain:
    length-prefixed components or a domain-separated hash, plus the collision test. §Typed identity.
60. **`Host` validation as scoped would be disabled in the field.** Kubernetes/LB health probes hit
    the app by IP with `Host: <ip>`; a bare refusal restart-loops the pod, and the operator's fix is
    to turn the check off — a disabled control is worse than an absent one. Contain: exactly one
    declared probe path is exempt, nothing else; its spelling decided in Phase −2 with the rest of
    the header work. §The platform baseline item 5.
61. **`Sec-Fetch-Site` fail-closed would break every non-browser client.** curl, SDKs and
    server-to-server callers never send the header — and carry no ambient cookie to protect — so
    refusing on absence defends nothing and breaks all of them; the reflexive fail-closed instinct is
    wrong here and must be written down as wrong. Contain: refuse only the literal `cross-site`;
    absent allows; the `SameSite` + 415 + no-CORS trio remains the load-bearing defence. §The
    platform baseline item 2.
62. **`allowedEmailDomains` matching was unnormalised.** A case-sensitive or non-IDNA compare is
    walked past with `ACME.COM` or a Unicode spelling of the same label — a restriction bypassed by a
    capital letter — while a homoglyph domain must stay a *different* domain. Contain: normalise both
    sides (case-insensitive over A-labels), config at compile/boot, claims at check time, tested in
    Phase 5. §Domain restriction.

Added by the sixth 2026-07-30 review, which checked the fifth review's enforcement boundary against
the tree:

63. **The `loginMethods` allowlist guarded the verifiers, not the minting sites.** "`auth` blocks are
    the enumerable sanctioned session-minting sites" is false in the tree: an `auth` block mints the
    per-request `Authenticated` fact; the *session* is created by whatever handler calls `JWT.sign` +
    `Http.setSessionCookie` — lesson76's login is a plain POST handler doing exactly that
    (`example/learn/lesson76-sessions.tesl:256`), and its `auth` block verifies sessions method-blind.
    A magic-link handler therefore compiled under `loginMethods [Sso]` — no password call for the
    backstop, no `auth` block for the allowlist — one level below the fix built to close it. Contain:
    the allowlist classifies every reachable `Http.setSessionCookie` site, enumerable via `cookieCap`
    (the existing gate; lesson76 already guarantees there is no second cookie-writing function), with
    the `auth`-block classification retained for per-request minting. Phase 5 carries the magic-link
    negative. §Login methods.
64. **Two gates were recognisable rather than unforgeable.** Item A's discharge asked the checker —
    the component the 2026-07-05 reviews identified as historically fail-open — to run a
    control-dependence analysis recognising a comparison pattern, and the password gate returned a
    `Bool` whose caller can ignore it and mint anyway (the exact false-branch shape Risk 57 lists, one
    gate over). Contain: both become runtime functions minting kernel evidence —
    `Proxy.verifyBinding` producing a `ProxyBound`-style fact, a witness-returning password gate — so
    the forged shapes are unrepresentable by construction and control-dependence is free (no witness
    unless the check succeeded). The proof kernel is the mechanism this codebase already trusts for
    exactly this job. §Item A, §Login methods, Open Questions 15 and 18.
65. **The frozen auth-event field `client IP` records the proxy.** Risk 21 froze the event's fields so
    the future rate limiter needs no second emit site — but client-IP determination explicitly waits
    for the trusted-proxy declaration deferred with rate limiting, so until then the value is the
    socket peer: the proxy's address, behind every deployment Item A blesses. An operator reading it,
    or a limiter later keying on it, gets the wrong answer with a right-sounding name. Contain: ship
    the field as `peerAddress` (or document socket-peer semantics on the field itself); introduce
    `clientIP` only when the trusted-proxy declaration lands and can make it true. Risk 21, §How rate
    limiting slots in later.
66. **Revocation-at-renewal invites two overclaims, and has one regression to guard.** "Per-user
    revocation" reads as instant, and as covering the IdP: neither is true — a revoked user's live
    token stays valid until its own `exp` (the renewable window), and the hook reads the app's data,
    so an IdP-only disable still runs to the absolute cap unless the app mirrors it. The regression:
    the check must never migrate to the verify path, or the stateless-scaling trade has been silently
    re-traded under a feature's name. Contain: both bounds stated in the spec next to the
    revocation-window paragraph; the two blunt levers documented as the zero-latency responses; and a
    test asserting ordinary verify performs no read with the hook declared. §Revocation at the
    renewal boundary.

## Open questions

1. **Is `sso` a clause on `server`, or a top-level declaration referenced by name from the server?**
   The latter is likely cheaper to parse, composes with the two-API pattern more obviously, and reads
   better when three providers are configured. RECOMMENDATION: prototype both against
   `emit_racket.ml`'s statement lists before committing.
2. **Where do the shared settings live** (`ssoSessionKey`, `publicOrigin`, `afterLogin`) when several
   `sso` clauses coexist — repeated per clause, or once per server? RECOMMENDATION: once per server; a
   per-provider session key or landing page has no use case and multiplies the config surface.
   `publicOrigin` is necessarily once per server — one deployment, one public origin.
3. **Who signs the session JWT — the runtime (from the shared session key) or `onIdentity` (returning
   a token)?** Runtime-signs is tighter and keeps the flow closed; user-signs preserves the existing
   `JWT.sign` idiom and lets the app add claims. RECOMMENDATION: runtime signs, and `onIdentity`'s
   returned subject is the only input — extra claims are a follow-up if anyone asks.
4. **Does `state` need to survive a server restart?** Cookie-only means an in-flight login fails after
   a deploy (acceptable: retry is one redirect). A DB row survives but adds a table and a cleanup job.
   RECOMMENDATION: cookie-only.
5. **Does the `connection` hook take an argument, and how wide?** `() -> Maybe SsoConnection` is enough
   for v1, but the multi-tenant extension wants the tenant resolved from `state`/the request, and
   widening later is a breaking change to every user's hook. The earlier recommendation was
   `HttpRequest -> Maybe SsoConnection`; the second review flags that as **re-opening blocker 8's
   class** — it hands the user the raw request in the one hook that chooses the issuer and can
   therefore build a trust decision out of `Host`/`X-Forwarded-*` again. REVISED RECOMMENDATION: take
   a narrow, runtime-constructed argument instead — a typed `SsoConnectionRequest` carrying the route
   segment and a runtime-extracted tenant hint (from `state`, not from headers) — so the signature is
   future-proof without the header surface. If `HttpRequest` is chosen anyway for shape reasons, the
   spec must state that nothing trust-bearing may be derived from it, and the linter should flag
   `Host`/`X-Forwarded-*` reads inside a `connection` hook. **SETTLED by the fifth review: the narrow
   `SsoConnectionRequest`.** §Shape's example showed `HttpRequest` while this question recommended
   against it, and the example is what gets copied; the example now shows the narrow type.
6. **Should `Sso.defaults` be capability-free?** It only builds a record — but the `env`/`requireSecret`
   calls the user feeds it already carry `envRead`, so the function itself needs nothing.
   RECOMMENDATION: pure, no capability row.
7. **Does the public origin belong to the `sso` feature or to the server generally?** SETTLED: name it
   generally (`publicOrigin`) and let SSO *require* it, rather than minting an SSO-only setting — a
   verified public origin is wanted by more than SSO (absolute links in emails, canonical redirects,
   CSP report URIs), and two spellings of "where this app lives" would be worse than one. Still to
   confirm during Phase 3: that nothing in `dsl/web.rkt` already infers an origin from headers, because
   that inference would then be the bug rather than the fix.
8. **How loud is the development gate, and does the TLS opt-out need to exist at all?** SETTLED in
   part: one gate for all three escapes (TLS verification, `publicOrigin` localhost, SSRF loopback),
   loopback-only, refused in a `tesl build` artifact, banner-announced, ratchet-tested. Remaining
   question: whether a self-signed internal IdP justifies *any* escape, or whether "add your CA to the
   trust store" is the answer. RECOMMENDATION: no per-call opt-out ever; the environment gate only, and
   prefer the trust-store answer in the docs. Adding a narrower escape later is easy; retracting a
   broad one is not.
9. **Two `SessionPolicy` points or three?** SETTLED that the knob is a closed ADT rather than a
   duration, that each constructor names both numbers, and that it is server-wide (§Session policy).
   Residual: `StandardSession` + `ShortSession` covers "today" and "15-minute reauth policy", which are
   the two demands we can name. RECOMMENDATION: ship exactly those two and add a third only against a
   real requirement — the ADT is closed and additive, so a later row costs nobody a migration, whereas
   an invented middle point becomes a documented promise immediately. Also settle the names against
   `SameSite`: do **not** call them `Lax`/`Strict`, which already mean something specific and adjacent
   in this codebase (`tesl/http.rkt:65`).
10. **Does `listenAddress` become a Tesl setting** (Risk 31), or does Item A rely on deployment
   instructions? **SETTLED by the third review: a setting, in Phase −2, and compile-time enforced for
   header-trusting `auth` blocks** — with an explicit written acknowledgement as the escape for
   container-network and socket-activation deployments the compiler cannot see. A pattern whose security
   cannot be expressed in the program is one Tesl cannot help the user get right, which is the whole
   point of this item. Residual: the exact spelling of the acknowledgement clause, and whether it belongs
   on the `server` block or on the `auth` declaration that trusts the header (the latter is more local
   and reads better in review).

Added by the third 2026-07-30 review:

11. **Is `publicOrigin` a compile-time literal, or an environment value with compile-time shape
   validation?** (Risk 40.) A literal is the safest thing that works and forces one artifact per
   environment; an env value keeps one build for staging and production, which is what teams will
   actually want, at the cost of moving validation to boot. RECOMMENDATION: accept **either a literal or
   `requireSecret`-style env read, validated identically and at boot when it is the latter, and fail to
   start on a value that is not absolute-https-no-query** — because the alternative is not "teams accept
   one artifact per environment", it is "teams derive it from a header". The invariant that must hold
   under both is: never from a request.
   Decision: Support both inline or read from env (the origin is not a secret I think)
12. **Does `claims` ship in v1 at all?** Risk 18 is contained by `Dict String Json`, but the field's only
   purpose is display and debugging, and Tesl has a debugger that renders live runtime values on three
   surfaces. Dropping it removes the last authorisation-by-accident surface in `SsoIdentity` entirely.
   RECOMMENDATION: ship it — `name`-style display fields and provider-specific quirks (`hd`, `oid`) have
   to be reachable or the escape-hatch story breaks — but decide this together with Phase 0's blocker-6
   answer, and revisit if the typed `Json` shape turns out to be awkward enough that people ask for the
   string version back.
13. **Should the session settings be renamed off the `sso` prefix?** `ssoSessionKey` and (new)
   `ssoPreviousKey` name a *session* mechanism, and Open Question 7 already settled that the session
   belongs to the app rather than to the login mechanism — which is why `sessionPolicy` has no prefix.
   RECOMMENDATION: `sessionKey` / `sessionPreviousKey`, with SSO *requiring* them, exactly as
   `publicOrigin` was resolved. Do it before Phase 3 ships the spelling, because renaming a server
   setting afterwards is a breaking change for every user.
   Descsion: Sounds good, better to fix it now rather than later.
14. **Is the mixed-mode coexistence check a warning or a checked declaration?** (Risk 33.) A warning is
   cheap and both facts are visible to the linter; a declaration (`loginMethods [sso, password]` or
   similar) would let the compiler *verify* that a program claiming SSO-only contains no
   `Crypto.checkPassword` path. Earlier recommendation was the warning, on the grounds that the
   enforcement rule lives in app data so a clause can only check the coarse case, and that the syntax
   budget was spent on `sso`.
   **SETTLED the other way by the fourth review: the declaration, `loginMethods`, in this item** — see
   §Login methods and Risk 46. The warning fires on *coexistence*, which is the legitimate and common
   shape, so it fires on nearly every SSO-adopting program, is acknowledged once, and never tells anyone
   whether all three enforcement sites were wired — i.e. it cannot detect the failure Risk 33 itself
   predicts. The "app data" objection was also only half right: **which** users are mandated is app data,
   but **that the check runs** is not, and that is the half that was unenforced. The declaration splits
   them: `[Sso]` is fully checkable with no app data at all, and mixed mode makes the check unforgettable
   by routing it through the runtime. Budget objection accepted and paid — the clause is a list plus one
   optional function reference, the same AST shape as `sso`.

Added by the fourth 2026-07-30 review:

15. **What is the spelling of the runtime-mediated password path?** (§Login methods.) The gate has to see
   the login identifier, which today's `Crypto.checkPassword` does not take. Candidates: a new
   `Auth.passwordLogin : String -> String -> PasswordHash -> Bool` (identifier, password, hash) with bare
   `checkPassword` rejected beside an `sso` clause; or widening `checkPassword` itself, which breaks every
   existing password program. RECOMMENDATION: the new name. Existing programs have no `sso` clause and keep
   compiling untouched, the gated path is the one with the better name, and "the un-gated function does not
   compile next to SSO" is a clearer rule than "the function behaves differently depending on a clause
   elsewhere". Also decide the set-side spelling (reset/signup/admin-set) at the same time, since it must be
   gated identically. **Revised by the sixth review (Risk 64): whatever the spelling, the gate returns
   kernel-minted evidence rather than `Bool` — a `Bool` is forgeable by discarding it — and the
   set-side functions are witness-gated identically. The `Password` attribution then means "this
   cookie site requires the witness", not "this site calls the function".**
16. **Is the `__Host-oauth` payload MAC'd or AEAD'd?** (Risk 43.) A MAC over a readable payload keeps the
   value debuggable in a browser dev-tools session; AEAD hides `nonce` and the verifier from anything that
   captures the cookie without the key. RECOMMENDATION: AEAD — the payload is a bearer secret in its own
   right (the PKCE verifier is in there), nobody needs to read it, and libsodium already provides the
   primitive. Both variants must verify against `[current, previous]` so key rotation does not kill
   in-flight logins. Added by the fifth review (Risk 58): whichever is chosen, the key is a
   purpose-derived subkey (`crypto_kdf`, distinct context), never the raw session key — and
   verification runs against subkeys derived from `[current, previous]`.
17. **What shape is the CSP default on served HTML?** (Risk 45.) Tesl serves the app's `index.html` and
   assets, so a policy has to exist, but a real SPA declares its own script/style/connect sources — an
   unconfigurable default either breaks apps or is set so loose it means nothing. Options: a
   `contentSecurityPolicy` server setting taking a literal; a small typed allowlist (script/style/connect
   sources) the runtime renders into a header; or a strict default plus an explicit opt-out.
   RECOMMENDATION: the typed allowlist, defaulting to `default-src 'self'`, with the opt-out written in the
   program rather than achieved by omission — the Item A acknowledgement is the precedent for "the escape
   exists but is visible in review". Decide before Phase −2 ships the spelling; it is a server setting and
   renaming one later is breaking.

Added by the fifth 2026-07-30 review:

18. **What is the spelling of the `auth`-block method attribution?** (Risk 56, §Login methods.) The
   allowlist rule needs every `auth` block attributable to a declared login method. Structural
   attribution covers the built-ins (`onIdentity` is `Sso`; a Phase −2 header-trust discharge is
   `Proxy`; the runtime-mediated password path is `Password`); a hand-rolled method needs a written
   attribution — an annotation on the `auth` declaration, or a named entry in `loginMethods` that the
   block references. RECOMMENDATION: the annotation on the block — it is local, it reads in review at
   the site that mints, and it matches the Item A acknowledgement precedent ("the escape exists but is
   visible in the program"). The fail-closed rule is independent of the spelling: no attribution, no
   compile. **Extended by the sixth review (Risk 63): the same attribution spelling covers
   `Http.setSessionCookie` call sites, which are the primary boundary — one mechanism for both site
   kinds, and a handler-level cookie site with no attribution does not compile under a `loginMethods`
   declaration.**
19. **What is the spelling and signature of the renewal-boundary hook?** (§Revocation at the renewal
   boundary.) Candidates: `sessionRevoked(subject, issuedAt) -> Bool` (deny renewal on `True`, deny
   on error) or the positive `sessionActive`. RECOMMENDATION: `sessionRevoked`, with `issuedAt` in
   the signature — the negative name makes the fail-closed direction read naturally ("an error means
   assume revoked"), and `issuedAt` is what makes "log this user out everywhere" expressible as one
   app-data timestamp. Decide together with Open Question 13's renames so the session-setting
   spellings ship once. Also settle and write down: a `Bool` is acceptable *here*, unlike Risk 64's
   gates — the runtime is both caller and consumer, so there is no app-side mint for a discarded
   result to forge; state that distinction so a future review does not "fix" it into a witness
   nobody needs.
