# Response metadata — headers, cookies, and the signed-session primitive they unblock

> **Status:** Next · **Effort:** M for the language feature, S for the crypto on top of it.
> Carved out of `roadmap/next/tesl_crypto.md` (2026-07-29) when its Phase 5 turned out to be
> blocked on something that is **not crypto**.

## Why this exists

`roadmap/next/tesl_crypto.md` Phase 5 was "signed sessions and secure cookies". Phases 0-4 of that
item have landed; Phase 5 has not, and the reason is worth stating precisely because it is easy to
misfile as a crypto gap.

**Verified 2026-07-29 (re-verified after Tesl.Crypto landed): there is no way to set a response
cookie — or any response header — from a Tesl handler.** The response surface is a serialized
return value plus `fail STATUS "message"`, and `LANGUAGE-SPEC.md:2269` documents that minimalism as
intentional:

> **`fail` shape is intentionally minimal.** `fail STATUS "message"` takes exactly an HTTP status
> code and a plain message. Tesl deliberately does **not** accept a structured JSON payload here.

`grep -c Set-Cookie dsl/web.rkt` → **0**. There is no `Set-Cookie` machinery anywhere in the
runtime.

So `HttpOnly` / `Secure` / `SameSite` cookies need a **response-metadata language feature that does
not exist**, and the crypto half is nearly free once it does: with `Tesl.Crypto` shipped,
`Session.sign` is `Crypto.signWith` with a session payload and `Session.verify` is
`check Crypto.checkSignature`, both of which exist and are tested today. **The genuinely new
capability is the cookie transport, not the signing.**

This is also what stands between the codebase and closing audit **L2** completely
(`roadmap/discarded/security_hardening_audit.md:160`): *"`auth` is a crypto-free trust root;
insecure session pattern … No built-in signed-session / secure-cookie primitive"*. The
crypto-free-trust-root half is now closed — `auth` bodies can reach a real verification, and the
examples do. The **secure-cookie** half needs this item.

---

## What is actually missing

| Need | Today |
|---|---|
| Set a response header | ✗ nothing |
| Set a response cookie with `HttpOnly` / `Secure` / `SameSite` / `Max-Age` / `Path` | ✗ nothing |
| Set a status other than 200 on success | ✗ (only `fail` sets a non-2xx) |
| Read a request cookie | ✓ `Dict.lookup "k" request.cookies` |
| Read a request header | ✓ `Dict.lookup "k" request.headers` |

The asymmetry is the whole problem: Tesl can read the request side of both, and can write neither.

---

## Design constraints inherited from elsewhere — read these before designing

**1. The response surface's minimalism is deliberate, and this item must not casually undo it.**
`fail STATUS "message"` refuses a structured payload on purpose. A response-metadata feature that
turns every handler return into an envelope would be a large, permanent change to the most-written
shape in the language. Prefer a design where the common case — return a value, get a 200 and a JSON
body — is **unchanged**, and metadata is opt-in and additive.

**2. A crypto function never reads its key from ambient config.** From
`roadmap/next/tesl_crypto.md`:

> **A crypto function never reads its key from ambient config. The key is always an explicit
> parameter.**

`Crypto.signWith key payload` already obeys it, which is what makes per-tenant keys a non-problem.
**Where it would break is exactly here**: a `Session.sign` that read its key from `Env` would
reintroduce the ambient-key assumption and make multi-tenant and bring-your-own-key impossible
without a redesign. Design `Session.*` with the key as a parameter from day one.

**3. Put a key id in the signed format from day one.** Rotation is out of scope for v1, but a
format without a key id cannot rotate without a flag day — Tink's lesson. With per-tenant keys you
must also be able to answer *which* key verified a token. This costs nothing now and is expensive
to retrofit.

**4. Rule 1 still applies: no options.** Correct cookie defaults (`HttpOnly`, `Secure`,
`SameSite=Lax`), chosen by the library. A caller who can pass `SameSite=None` will.

**5. `secret` already exists and should carry the key.** The session key is a `Secret`
(`Tesl.Crypto`), so it is redacted at every rendering sink and cannot become a `String`. It can
come from `Env.requireSecret`, from a `secret` column on a tenant entity, or from a KMS over HTTP
with the existing cache — no new primitives.

---

## Sketch, not a decision

Two shapes worth costing. **Do not pick one from this document — cost them both against real
handlers first.**

**(a) A response-metadata return wrapper.** A handler that needs metadata returns
`Response { body: T, cookies: [...], headers: [...] }` instead of `T`. Plain handlers are
untouched. Cost: a new type in the response position, and every emitter (`emit_ts`, `emit_elm`, the
codec layer, the api-test harness) has to know that a `Response T` client-side means `T`.

**(b) An effect form, like `telemetry`.** `setCookie "session" value` as a statement inside the
handler body, lowered the way `telemetry` and `enqueue` already are. Cost: response construction
becomes order-dependent and the effect has to be threaded to the response builder; but the return
type — and therefore every generated client — is completely unchanged. `telemetry` is the existing
precedent for a fixed-shape effect form in a handler body (`desugar.ml` lowers `ETelemetry` to a
runtime call), which makes this the cheaper of the two to reach.

**Then, and only then:** `Session.sign` / `Session.verify` with a **key id** in the format, no
options, correct cookie defaults, and a replacement `auth` lesson. That closes L2.

---

## Verification bar

- A handler sets a cookie; an api-test asserts the `Set-Cookie` header including `HttpOnly`,
  `Secure` and `SameSite`.
- The **default** cookie attributes are asserted, not just settable — a test that passes because the
  test set them explicitly proves nothing about what an ordinary handler gets.
- A round-trip: sign a session, hand it back as a request cookie, verify it, reach `Authenticated`
  through **one** `establish` beside a real verification.
- **A tampered cookie is rejected**, and a cookie signed with a *different* key is rejected — both
  as 401, both constant-time (they go through `Crypto.checkSignature`, which is already tested for
  this).
- **Two tenants, two keys**: a session minted for tenant A does not verify for tenant B, and the
  key id in the format identifies which key verified.
- A generated TS/Elm client is **unchanged** for a handler that sets a cookie (shape (b)), or
  correctly unwraps `Response T` (shape (a)). Whichever shape wins, this test is what proves the
  choice did not leak into every client.
- `./ci.sh` green; the new lesson byte-exact in the snapshot sweep.

---

## Related

- `roadmap/next/tesl_crypto.md` — Phases 0-4 landed; this item is its Phase 5, extracted. Read its
  "Capabilities are effects", "Upgrades, rolling deploys, and multi-tenant keys" and `secret`
  sections before designing
- `roadmap/discarded/security_hardening_audit.md` — **L2** (the crypto-free auth root; its
  secure-cookie half is what this item closes), **L1** (`establish` as the remaining trust escape)
- `LANGUAGE-SPEC.md:2269` — why the response surface is minimal today
- `dsl/web.rkt` — `handler-result->response` / `prepare-response-value` / `json-response` are where
  a response is built, and where cookie support has to land
- `compiler/lib/desugar.ml` — how `telemetry` is lowered, the precedent for shape (b)
