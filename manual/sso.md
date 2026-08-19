# Single sign-on (SSO) and third-party auth

Add "Log in with GitHub / Google / Entra ID" as a **server clause**, not a
library your code drives. You declare a connection and say what a verified
identity means; the runtime owns the OAuth2/OIDC flow, PKCE, `state`, the
token-signature check, and the session cookie. See the compiling example
`example/learn/lesson78-sso.tesl` (`tesl help manual examples`) and the full
normative reference in `tesl help manual language-spec` (§23).

## The shape

```tesl
import Tesl.Sso exposing [SsoConnection, SsoIdentity, Github, Sso.defaults, Sso.subject]

fn githubConn() -> SsoConnection requires [envRead] =
  Sso.defaults Github (requireEnv "GH_CLIENT_ID") (requireSecret "GH_CLIENT_SECRET")

fn linkUser(identity: SsoIdentity) -> String =
  Sso.subject identity        # the durable (issuer, subject) key → the session JWT `sub`

server AppServer for AppApi {
  sso "github" connection githubConn onIdentity linkUser
  publicOrigin "https://app.example.com"
  sessionKey "SESSION_KEY"
  loginMethods [Sso]
}
```

Each `sso "<seg>" connection <fn> onIdentity <fn>` mints two runtime-owned
routes: `/auth/<seg>/login` (303 to the provider) and `/auth/<seg>/callback`
(exchange the code, verify, run `onIdentity`, set the `__Host-session` cookie,
303 to `afterLogin`).

## The provider is an ADT (or a generic OIDC issuer)

`Sso.defaults`' first argument is the closed `SsoProvider` ADT
(`Github` | `Google`), not a string — a typo is a compile error and completion
lists every provider. For any other OpenID Connect issuer — a self-hosted
Keycloak/dex, Okta, Auth0, or single-tenant Entra — use
`Sso.oidc "<issuer-url>" clientId secret`, which discovers the endpoints from
the issuer and applies the same signature+claims trust argument.

## The identity is opaque; the subject is a computed key

`SsoIdentity` has no fields: you cannot read `identity.email` and key a user on
it (the nOAuth account-takeover). `Sso.subject` returns the injective
`(issuer, subject)` key — the raw provider `sub` is unique only *within* one
issuer, so the accessor does the issuer-namespacing that makes it safe to store.

## Reading the session back

There is nothing SSO-specific about reading a logged-in user. The callback mints
an ordinary signed session cookie; an `auth` block reads it exactly like a
password session (`tesl help manual language-spec` §20-adjacent, lesson 76):
verify the cookie with the **same key** `sessionKey` names, read the `sub`
claim, and build your own principal record from it.

```tesl
auth sessionOwner(request: HttpRequest) -> user: User ::: Authenticated user requires [sessions] =
  case Http.sessionToken request of
    Nothing -> fail 401 "no session"
    Something token ->
      let claims = check JWT.verify token (sessionKey())
      ok (User { id: subjectOf claims }) ::: Authenticated user
```

## Capabilities are explicit and flow to `main`

The functions a `server` references run under the server's granted capabilities,
so their `requires` must be covered by `main`'s grant — the compiler rejects the
program otherwise rather than 500-ing at runtime. A connection reading env needs
`envRead`; a `sessionRevoked` hook hitting the DB needs `dbRead`; and the SSO
flow's own network calls mean an `sso` server forces `main` to grant
`httpClient`.

## The server clauses

- `sso "<seg>" connection <fn> onIdentity <fn>` — a login provider (repeatable).
- `publicOrigin "https://…"` — the verified redirect_uri base and HSTS origin
  (never from a request header).  Accepts an inline literal or, for 12-factor
  deploys, `publicOrigin fromEnv "PUBLIC_ORIGIN"` — the named env var is read
  and validated ONCE at boot (same rule as the literal), never per request.
- `sessionKey "ENV"` — the session-signing key's env var.
- `sessionPreviousKey "ENV"` — the previous key (rotation overlap; the only kill
  switch is emptying it).
- `afterLogin "/path"` — where a fresh session lands (relative).
- `sessionPolicy StandardSession | ShortSession` — renewable TTL + absolute cap.
- `sessionRevoked <fn>` — per-user revocation at the renewal boundary
  (fail-closed).
- `listenAddress Loopback | AllInterfaces` — bind 127.0.0.1 (behind a proxy) or
  all interfaces.
- `trustedProxies [ "10.0.0.1", ... ]` — declare the reverse proxy addresses in
  front of the app.  Enables `request.clientAddress`: with no declaration it is
  the unspoofable socket peer; with one it is the rightmost untrusted
  `X-Forwarded-For` hop (a spoofed, prepended entry is never reached), and a
  chain that disagrees with the declaration is refused rather than guessed.
  **Racket backend only.**  The Go backend has no `request.clientAddress`, so it
  refuses the clause rather than accepting a security declaration that would
  configure nothing.
- `healthProbePath "/healthz"` — when `publicOrigin` is set, the request `Host`
  must name that origin (a Host-header attack otherwise mints links/cookies for
  another origin); this ONE path is exempt so a host-blind load-balancer probe
  still succeeds.
- `contentSecurityPolicy "default-src 'self'; frame-ancestors 'none'"` — the
  server default CSP for HTML responses (the SPA fallback + static HTML). Typed
  in the program (a reviewer sees it), takes precedence over the `TESL_CSP` env,
  and a handler that sets its own `Content-Security-Policy` header still wins per
  response — that is the per-route form (e.g. an extension bundle route framable
  by its host).
- `loginMethods [Sso] | [Sso, Password via <fn>] | [Sso, Machine]` — the **checked** promise that
  no code path mints a session cookie except the SSO callback.

## `loginMethods` — proving only SSO can log in

Under `loginMethods [Sso]` (no `Password`), the compiler refuses any application
call to `Http.setSessionCookie` (and any `Crypto.checkPassword` /
`Crypto.hashPassword`), because the only sanctioned session-minting site is the
runtime-owned SSO callback. That is the sentence an enterprise reviewer wants:
*no code path in this program can produce a session cookie except the SSO
callback.*

`Password via <fn>` and `Machine` each license the application to mint sessions:
`Password` for human password login (the `<fn>` is the policy predicate), and
`Machine` for a per-installation MACHINE credential — a bearer token the app
verifies against stored material (a hashed token, `Crypto.checkSignature`, or
`Crypto.checkPassword`). A machine credential is neither SSO nor a human
password nor a proxy assertion, so it is its own member; declaring it keeps the
"only these methods mint a session" promise honest for a service-to-service API.

## Behind a reverse proxy (the authenticating-proxy pattern)

The reference deployment runs the app behind a reverse proxy (nginx). Tesl gives
you the pieces to make that edge a *declared*, checkable assumption rather than a
convention:

- `listenAddress Loopback` binds `127.0.0.1` only, so the app is never directly
  reachable — every request provably arrives through the proxy. This is the
  topology half of trusting the edge, and it is enforced at boot.
- `trustedProxies [ "<proxy-ip>", … ]` makes `request.clientAddress` the
  rightmost *untrusted* `X-Forwarded-For` hop; with no declaration it is the
  socket peer. A spoofed, prepended `X-Forwarded-For` entry is never reached, so
  the client address an app records (audit, abuse detection) is trustworthy.
- `publicOrigin` + `Host` validation (with one `healthProbePath` exempt) refuse a
  request whose `Host` does not name the app's origin, closing the Host-header
  class of attack.

### Trusting a header for identity

Two very different things look the same as "an `auth` block reads a request
header":

- **The header IS the assertion** — e.g. a proxy sets `X-Auth-User: alice` and
  the app believes it. This is sound ONLY because the network topology
  guarantees nobody but the proxy can set it, so it REQUIRES a topology claim:
  bind `listenAddress Loopback` behind the trusted proxy. Anyone who can reach
  the app directly could otherwise forge the header.
- **The header is VERIFIED against stored material** — e.g. an `Authorization:
  Bearer <token>` compared in constant time (`Crypto.checkSignature` /
  `Crypto.checkPassword`, or a hashed-token lookup) against a per-installation
  secret. This is the same posture as a session cookie and needs NO topology
  claim — the value is unforgeable without the secret. Declare it with
  `loginMethods [Sso, Machine]`.

Prefer the second form: a verified bearer secret is safe on any interface, so an
API that authenticates machines should compare a token against stored material
rather than trust a bare identity header.

`Tesl.Proxy.verifyBinding` turns the first case into the second: have the proxy
send a binding header equal to a shared secret, then
`check Proxy.verifyBinding proxySecret request.headers` mints a `ProxyBound` fact
ONLY on a constant-time match. Because `ProxyBound` can be obtained no other way
(no hand-written function may declare it), a handler that demands `ProxyBound`
reaches its trust decision by a real verification against stored material — the
proxy binding is now unforgeable rather than topology-assumed.
