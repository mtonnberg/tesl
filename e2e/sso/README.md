# SSO end-to-end test (real browser -> Tesl backend -> real dex IdP)

Proves the SSO flow works for real: a headless Chromium logs in through a local
**dex** OpenID Connect IdP, the Tesl backend (`backend.tesl`, using the generic
`Sso.oidc` connection) runs the full OAuth2/OIDC dance + token-signature check,
sets the `__Host-session` cookie, and the protected `/me` returns the subject.
Everything is provisioned through Nix (`dex-oidc`, `openssl`, `playwright`).

## Run

```bash
nix develop --command bash e2e/sso/run.sh                 # full headless browser e2e (VERIFIED)
SSO_E2E_HEADED=1 nix develop --command bash e2e/sso/run.sh # same, but a real window (WSLg), slow-mo
SSO_E2E_SMOKE=1  nix develop --command bash e2e/sso/run.sh # protocol smoke (no browser)
bash e2e/sso/serve.sh                                      # bring the stack UP and leave it running for a MANUAL browser session
```

`serve.sh` starts dex + the backend and waits: open http://localhost:8080, click
"Log in with dex", sign in as `alice@example.com` / `password` (the browser shows
a one-time cert warning on the dex page — self-signed loopback cert, click
through). `Ctrl-C` to stop.

`run.sh` re-execs itself inside a `nix shell` that adds dex / openssl / mkpasswd
(+ node + playwright + the browser bundle for the full run); `racket` and the
linked `tesl` collections come from the surrounding `nix develop`. Both the full
browser run and the smoke pass on a WSL2 Nix sandbox.

## Pieces
- `backend.tesl` — the Tesl app: `Sso.oidc(requireEnv "DEX_ISSUER") …`, an `auth`
  block that rebuilds a `User` from the verified session, a protected `/me`, and
  `loginMethods [Sso]`. Serves `public/` as its static dir.
- `public/index.html` — the sandbox page with the "Log in with dex" button.
- `sso.spec.ts` / `playwright.config.ts` — the headless-browser assertions
  (happy path sets `__Host-session`; unauthenticated `/me` is 401).
- `run.sh` — boots dex over loopback HTTPS (self-signed), compiles+boots the
  backend with the loopback TLS dev escape, drives the login, tears down.

## Notes / constraints (why it's shaped this way)
- The SSO runtime is **https-only** for discovery/token/userinfo, so dex serves a
  loopback self-signed cert and the backend runs with `TESL_HTTP_TLS_INSECURE_DEV=1`
  (the loud loopback-only dev escape); Playwright uses `ignoreHTTPSErrors`.
- The backend stays plain `http://localhost:8080`: `publicOrigin` is loopback (so
  HSTS is suppressed) and Chromium accepts the `Secure` `__Host-session` cookie on
  `localhost` (a secure context).
- Opt-in only — not part of `dune test` / `ci.sh` fast path (needs dex + a browser).
