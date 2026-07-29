# `Tesl.Crypto` — hashing, message authentication, password storage, secrets

> **Status:** Phases 0-4 LANDED 2026-07-29 · Phase 5 extracted to
> `roadmap/next/response_metadata_and_cookies.md` (blocked, and not on crypto).
> **Effort:** a six-phase ladder, each phase independently shippable.
>
> **What landed, and where to read about it:**
> * the shipped surface, types, facts and limits — `LANGUAGE-SPEC.md` §21.7
> * every decision, deviation and open question — `IMPLEMENTATION-LOG-crypto-and-onboarding.md`
>   at the repo root
> * the lesson — `example/learn/lesson64-password-storage.tesl` (which also closed the
>   long-standing missing-`lesson64` gap, so the renumber that
>   `roadmap/next/revised_onboarding.md` planned for it is no longer needed)
> * the security suite — `tests/crypto-runtime-tests.rkt`
>
> **Corrections to this document, found while implementing it.** Each is argued in the
> implementation log; they are listed here so nobody re-derives them from the text below:
> 1. libsodium verifies foreign **Argon2i/Argon2id only** — NOT scrypt, and it has no PBKDF2 at
>    all (§"libsodium and the stored format" claims otherwise). Both limits are now pinned by
>    tests.
> 2. `error_codes.ml` has **eight** categories, not the six quoted in §"Security lints".
> 3. The `cookies "user" == "admin"` grep matches **nothing**; the real spelling appears in
>    **26 files**, not six — including both `tesl init` scaffolds.
> 4. Only **one** api-test in the whole corpus posts a cookie.
> 5. There is **no mechanism to promote a diagnostic category to errors** (no `--strict`, no env
>    var, no config key), so §"Security lints"'s "CI can promote the category" is not available.
> 6. `Signature` needs hex transport in **both** directions, or the webhook-verification use case
>    that justifies Phase 2 cannot be written at all.
> 7. Open questions 1, 3 and 5 are answered — see the log.

Carved out of `roadmap/next/primitive_gaps_and_outbound_hardening.md` (2026-07-29). It is the
single most likely reason an application cannot be written in Tesl at all, and therefore the real
answer to most "give me FFI" requests (`roadmap/discarded/using_queues_for_ffi.md`).

---

## The end state

When every phase has landed, Tesl should be a language where **an ordinary developer cannot get
application security wrong in the ways that matter**, without knowing any cryptography:

- Storing a password is one call, uses Argon2id with current parameters, and **storing the hash
  of the wrong value does not compile**.
- Verifying a password is one call, is constant-time, is immune to user-enumeration timing, and
  **produces a proof** that downstream authorization can demand.
- A secret — a password in a request body, an API key, a signing key — **cannot become a `String`
  in Tesl code**, so it cannot be interpolated, logged, exported in telemetry, shown in the
  debugger, or serialized to a client.
- Upgrading Tesl silently strengthens every newly written password hash, and old hashes upgrade
  on next login, across a rolling deploy, with no application change.
- The compiler *teaches* this: every security mistake it can detect has a stable code, an
  explanation, and where possible a machine-applicable fix.
- Every primitive is **libsodium**, unmodified. Tesl's contribution is the type system around
  the primitives, never the primitives.

That is the bar. The phases below are how to get there without paying for all of it at once.

### The four design rules

**1. No mechanism reaches the application author.** No algorithm choice, no work factor, no
nonce, no salt, no encoding, no length. Every knob is a place where a non-expert makes a wrong
call and gets a plausible-looking result. The surface exposes *intents*. Experts get transparency
through documentation and the algorithm tag inside every stored artifact — not through parameters.
`insert` does not take a SQL dialect flag; `hashPassword` does not take a work factor.

**2. Names describe the job, not the primitive.** Someone who has never heard of HMAC must pick
the right function from the name. Algorithm names exist as *expert aliases* and are never required
to write correct code.

**3. Verification returns a proof, not a `Bool`.** A `Bool` can be ignored, inverted or compared
with `==`. A fact cannot. Making the result of checking the only route to the downstream
capability turns "someone forgot to verify" from a review problem into a compile error. This is
the whole reason to build it in Tesl rather than link a library.

**4. We use an established library, and say so loudly.** Nobody should have to audit Tesl to
decide whether Tesl's password hashing is sound. The answer must be *"it is libsodium's
`crypto_pwhash`, unmodified, with libsodium's recommended parameters"* — checkable in a minute by
someone who does not read Racket. A language asking people to trust a novel proof system cannot
also ask them to trust novel crypto.

### Role models

| Project | What to take |
|---|---|
| **libsodium / NaCl** | The primary model *and* the implementation. One algorithm per job, no cipher suites, no caller-visible nonce, `crypto_pwhash_str` returns a self-describing string |
| **Google Tink** | Key management as a first-class concept — the source of "put a key id in the format from day one" |
| **age** | Radical simplicity as a security property. No config, no negotiation, no options |
| **Inferno** (.NET) | Same thesis: correct defaults chosen by the library |
| **Rust `secrecy`** | `Secret<T>` refuses `Debug`/`Display` — the model for `secret` |
| **Rails `MessageVerifier`, Django `signing`** | Friendly naming for "signed value the client cannot tamper with" |
| **PHC string format**, **OWASP Password Storage Cheat Sheet** | The stored-hash interop contract and the parameter recommendations |
| **Django `PASSWORD_HASHERS`** | Upgrade-on-login for an existing user table |

---

## What we will not build

The bar is **not** "too big" — scope is handled by phasing. The bar is **bad for the language**.
Tesl is a language for web APIs, not a general-purpose language, and each of these fails on that:

| Refused | Why |
|---|---|
| General `encrypt` / `decrypt`, raw AES/ChaCha, cipher modes | The largest misuse surface in cryptography — nonce reuse, AEAD vs raw, key derivation. Violates rule 1 permanently, and no web-API use case demands it |
| Any parameter knob (work factor, iterations, key length, token length) | Rule 1. A caller who can pass `4` will |
| MD5, SHA-1 | `file/sha1` exists in the Racket distribution; do not surface it. If a foreign protocol ever needs SHA-1, expose it under a name that says so |
| **Key custody: envelope encryption, KMS integration, key rotation infrastructure** | This is platform infrastructure, not language surface. It needs symmetric encryption (refused above) and it belongs to whatever runs the app. Tesl's job is to accept a key as a value; where the key is kept is the operator's |
| Entropy scanning of string literals | A noisy security lint is *worse than none* — it trains people to ignore the whole category. The known-answer hash vectors this item adds would light it up permanently |
| A `reveal` / unwrap escape on `secret` | It would turn a flat guarantee into a hedged one. Kept as a specified contingency (below), not as a v1 feature |
| An external `tesl_jobs` consumer, user-facing FFI | Already settled in `roadmap/completed/interop_policy_and_docs.md` |

---

## Current state

App code can reach exactly one cryptographic operation: `JWT.sign` / `JWT.verify` (HS256), gated
by the `jwt` capability. `tesl/jwt.rkt:19-66` already reaches OpenSSL libcrypto through
`ffi/unsafe` for HMAC-SHA256, so the mechanism and the trust pattern — a native call wrapped as a
stdlib surface, never exposed as FFI — are established and proven in-tree.

Not reachable at all: any hash, any message authentication outside JWT, CSPRNG, constant-time
comparison, password hashing.

**Already in the Racket base distribution, verified 2026-07-29 — no FFI, no new dependency:**

| Need | Available |
|---|---|
| CSPRNG bytes | `racket/random` → `crypto-random-bytes` ✅ |
| base64 | `net/base64` ✅ (used by `tesl/jwt.rkt`) |
| hex | `openssl/sha1`'s `bytes->hex-string` ✅ (used by `tesl/jwt.rkt`) |
| SHA-256/512, HMAC | libcrypto FFI — the `tesl/jwt.rkt` pattern ✅ |
| Argon2id, constant-time compare | ❌ nothing — this is what libsodium is for |

The Racket `crypto` package is **not** installed in the dev shell (`(require crypto)` fails);
adding it would be a Racket-package dependency that drags in its own FFI bindings anyway — a worse
trade than the native library.

---

## The phase ladder

Ordered by **value per unit of permanent language surface**. Each phase is independently
shippable and independently justifiable.

| # | Phase | New language surface | Effort |
|---|---|---|---|
| **0** | Stop the bleeding — fix the insecure examples, the auth lint, redact `JwtSecret` | **none** | S |
| **1** | Password storage | opaque stdlib types; two facts (existing machinery) | M–L |
| **2** | Message authentication + digests | **none** — one more fact | S–M |
| **3** | `secret`, outbound half | the `secret` keyword | M |
| **4** | `secret`, inbound half + the naming lint | lint suppression | M |
| **5** | Signed sessions + secure cookies | *(depends on a response-metadata item)* | M |

### Phase 0 — Stop the bleeding (no crypto, no language surface)

`roadmap/discarded/security_hardening_audit.md:160` (**L2**) records: *"`auth` is a crypto-free
trust root; insecure session pattern … No built-in signed-session / secure-cookie primitive"*, and
notes the examples model a plaintext, guessable session cookie (`cookies "user" == "admin"`).

**The dangerous half of L2 needs no crypto at all.** The audit's own wording is *"missing
primitive **+ guidance**"*, and the guidance half is the more dangerous one because it has already
propagated into a corpus people copy from. JWT ships today and covers the token case end to end
(`example/learn/lesson57-jwt.tesl`).

- Replace the guessable-cookie pattern at: `example/learn/lesson06-proof-check-proof-auth.tesl:86`,
  `example/learn/lesson55-testing-auth-and-capabilities.tesl:25`, `example/todo-api.tesl:115`,
  `example/admin-task-api.tesl:52,55`, `example/ai-conversation-service.tesl:85,98`.
- State plainly, in the lesson and the spec, that a bare `cookies "user"` check is not
  authentication.
- Ship the **`Security` diagnostic category** and the **Tier-1 lints** (see
  [Security lints](#security-lints)) — pure linter work, and it makes the six files
  self-reporting while they are fixed.
- Redact `JwtSecret` in telemetry and the three debugger surfaces. Three stdlib types, fixed at
  the sink, no language change.

Budget honestly: these are gate fixtures with byte-exact `.rkt` snapshots and api-tests posting
`cookie {"session":"alice"}`. A careful day, not an afternoon — but a day that depends on nothing.

**Do this first and separately.** Largest security improvement per hour in the whole item, and
every week it waits is another week the pattern gets copied.

### Phase 1 — Password storage (the blocker)

The reason the item exists: an application that needs login cannot be written in Tesl today.

- **libsodium**, Argon2id, PHC string format (see [Implementation](#libsodium-and-the-stored-format)).
- `hashPassword` / `checkPassword` / `needsRehash` / `randomToken`.
- Both facts: **`HashFor`** on the mint side, **`PasswordVerified`** on the verify side (see
  [The proof design](#the-proof-design)).
- `PasswordHash` opaque — no caller-callable constructor, no `.value`, no `Eq`.
- The four correctness requirements in [Defects the design must handle](#defects-the-design-must-handle):
  timing-equalized verification, a bounded input length, no length knob, and honest framing of
  what `PasswordVerified` proves.
- The **change-password lesson**, which is where `HashFor` earns its place.
- Scheme-deprecation policy (see [Upgrades](#upgrades-rolling-deploys-and-multi-tenant-keys)).

### Phase 2 — Message authentication and digests

Justified by a concrete need JWT does not cover: **verifying an inbound webhook signature**
(Stripe, GitHub) and signing outbound payloads.

- `signWith` / `checkSignature` with the **`Authentic`** fact.
- `fingerprint` (content digest — etags, cache keys, dedup, idempotency) and `keyFingerprint`.
- **Retrofit `Authentic` onto `JWT.verify`.** It returns a claims `Dict` today, so a consumer
  cannot demand that verification happened. Adding the fact to the existing surface is strictly
  better than shipping a parallel MAC surface, and it reduces total surface rather than growing it.

### Phase 3 — `secret`, outbound half

The keyword, and everything that keeps a secret from *leaving*. See [`secret`](#secret).

### Phase 4 — `secret`, inbound half

Decoding a request body or job payload straight into a `secret`-typed field, so the submitted
plaintext password is never a Tesl `String`; direction-aware TS/Elm emit; the Tier-2 naming lint
and the lint-suppression mechanism it requires.

### Phase 5 — Signed sessions and secure cookies

**Blocked, and not on crypto.** Verified 2026-07-29: there is no way to set a response cookie —
or any response header — from a Tesl handler. The response surface is a serialized return value
plus `fail STATUS "message"` (`LANGUAGE-SPEC.md:2236` documents that as intentionally minimal),
and no `Set-Cookie` machinery exists in `dsl/web.rkt`.

So `HttpOnly` / `Secure` / `SameSite` cookies need a **response-metadata language feature that
does not exist**. File it as its own item. Note also that without cookies, `Session.sign` is
`JWT.sign` with a different payload — the genuinely new capability is the cookie transport.

When it lands: `Session.sign` / `verify` with a **key id** in the format, no options (rule 1),
correct cookie defaults, and a replacement `auth` lesson. That closes L2 completely.

---

## Design decisions that span phases

### libsodium and the stored format

**Decision: libsodium**, per rule 4.

| Option | Gets you | Packaging |
|---|---|---|
| **libsodium** | Argon2id (`crypto_pwhash_str`, PHC-formatted), constant-time compare (`sodium_memcmp`), HMAC, CSPRNG — and the API philosophy | nixpkgs `libsodium`, Debian/Alpine packages for `racket/racket:9.2-full`, `tesl build` staging, multi-arch |
| scrypt via libcrypto (`EVP_PBE_scrypt`) | memory-hard, OWASP-acceptable second choice | **zero** new dependency — the contingency if the spike fails |
| bcrypt | — | not in libcrypto either; 72-byte truncation; no memory-hardness |
| PBKDF2-HMAC-SHA256 | FIPS-blessed | zero new dep, weakest of the three against GPU attack |
| pure Racket | — | unacceptable: timing and performance both wrong, and it forfeits rule 4 |

The packaging cost is smaller than it looks. `libsodium` is in nixpkgs, is stable and widely
packaged with no transitive dependencies, and **Tesl already has an undeclared native
dependency** — `tesl/jwt.rkt` resolves libcrypto at runtime via `ffi-lib` and nothing in
`flake.nix` or the Docker templates declares it. Declaring libsodium explicitly makes the
situation more honest, not less.

**Blocking spike (≈half a day, before Phase 1):** confirm `(ffi-lib "libsodium")` resolves in
(a) the nix dev shell, (b) the `tesl-cli` wrapper's runtime environment — it sets
`PLTCOLLECTS`/`PATH` but nothing for shared-library lookup, so this may need `LD_LIBRARY_PATH` or
a `makeWrapper` change (`flake.nix:213-222`), (c) the `racket/racket:9.2-full` app-only image
(`templates/docker/Dockerfile.app-only.tmpl`), and (d) macOS. If any of those is ugly, fall back
to scrypt and record why.

**Store a PHC string** (`$argon2id$v=19$m=…,t=…,p=…$salt$hash`). This makes the algorithm choice
**reversible**: algorithm and parameters live in the stored value, so switching later is a
`verify` dispatch plus upgrade-on-login rather than a migration crisis. It is also what makes
foreign hashes verifiable.

**Foreign-hash migration — state the limit.** libsodium verifies Argon2i/Argon2id; libcrypto gives
scrypt and PBKDF2. **bcrypt (`$2a$`/`$2b$`) is in neither.** v1 verifies foreign
Argon2/scrypt/PBKDF2 and cannot verify foreign bcrypt. Document it rather than let someone
discover it mid-migration.

### Naming: friendly first, expert-aliased

`Crypto.hmacSha256 key message` fails rule 2 — a newcomer cannot tell whether it is what they
need, and a wrong guess produces a plausible wrong result.

| I want to… | Primary | Expert alias |
|---|---|---|
| store a password safely | `Crypto.hashPassword` | — |
| check a submitted password | `Crypto.checkPassword` | — |
| know whether a stored hash is outdated | `Crypto.needsRehash` | — |
| stop a client tampering with a value I hand them | `Crypto.signWith` | `Crypto.hmacSha256` |
| confirm a value I handed out came back unchanged | `Crypto.checkSignature` | — |
| a stable fingerprint of content | `Crypto.fingerprint` | `Crypto.sha256`, `Crypto.sha512` |
| tell whether I loaded the right key | `Crypto.keyFingerprint` | — |
| an unguessable token | `Crypto.randomToken` | — |

**Deliberately not `sign`/`verify` plainly.** `signWith` takes a shared secret — symmetric
authentication. If asymmetric signing (Ed25519, also in libsodium) is ever added it needs `sign`,
and having the symmetric one squatting there is a genuine misuse hazard: *"I signed it, so anyone
can verify it"* is exactly the confusion to avoid. Reserve the bare name.

**Argument order.** `x |> f` is `f x` and chains left-associatively (`LANGUAGE-SPEC.md:2500`), so
the piped value is the **last** argument. Configuration first, subject last:
`payload |> Crypto.signWith key` reads correctly and `Crypto.signWith key` partially applies into
a reusable signer.

**Documentation obligation.** Every friendly name's `tesl doc` entry states the primitive
underneath ("libsodium `crypto_pwhash` / Argon2id, `INTERACTIVE` parameters"). Friendly names hide
the *choice*, never the *fact*.

### The proof design

This is where the module earns its place in the language rather than being a wrapper.

#### `HashFor` — the mint side

```
Crypto.hashPassword : (plaintext: String) -> PasswordHash ::: HashFor plaintext
```

The bug this prevents is **hashing the wrong one of several same-typed strings in scope
together**, and there are exactly two handlers where that is the normal situation:
**change-password** (`oldPassword` and `newPassword` side by side) and **password-reset**
(`resetToken`, `newPassword`, `confirmPassword`). Those are the handlers with sibling variables of
identical type, and the ones exercised least. The type system cannot help — every candidate is a
`String`.

The constraint bites at a signature one layer up, as an ordinary cross-parameter proof
(`lesson10-cross-parameter-proofs.tesl`, `lesson44-multi-param-proofs.tesl`):

```
fn storeNewPassword(user: User,
                    newPassword: String,
                    hash: PasswordHash ::: HashFor newPassword) -> … = …

let np = body.newPassword
storeNewPassword user np (Crypto.hashPassword np)                # ✅
storeNewPassword user np (Crypto.hashPassword body.oldPassword)  # ❌ compile error
```

*"In Tesl, storing the wrong password hash does not compile"* is the single best demonstration the
proof system has, and password storage is the most security-critical thing most applications do.
Declining to apply the proof engine there would be an own goal for the language's central claim.

*Residual:* the fact is inert unless someone writes the constraining signature — true of every
fact in the language, and answered in practice by the Tier-1 lint below.

*To verify during implementation:* whether subject identity holds across a repeated field access,
or whether the pattern needs the `let`-binding shown above. Not a blocker either way.

#### `PasswordVerified` and `Authentic` — the verify side

```
Crypto.checkPassword  : (stored: Maybe PasswordHash) -> (candidate: String)
                      -> ok stored ::: PasswordVerified stored | fail 401

Crypto.checkSignature : (key: Secret) -> (sig: Signature) -> (payload: String)
                      -> ok payload ::: Authentic payload | fail 401
```

Check-shaped, exactly like `String.requireNonEmpty` and the `auth` idiom. An `auth` function then
reaches `Authenticated user` only by way of `PasswordVerified`, which only the trusted body can
mint. A function consuming session data can `require` an `Authentic` payload, so "forgot to check
the signature before trusting the cookie" stops compiling.

**Stated precisely:** this does not fully close L2. Going from `PasswordVerified user.passwordHash`
to `Authenticated user.id` still requires an `establish`, which is audit **L1**'s unrestricted
trust escape hatch. What the fact buys is that the unverified step becomes *small, explicit and
reviewable* — one `establish` beside a real verification — instead of an auth body that never
verified anything. A genuine improvement; not a proof of correct authentication.

**Surface this deletes:** with verification as the only comparison path, `constantTimeEquals` is
unnecessary — the constant-time compare moves inside `checkPassword`/`checkSignature` where it
cannot be got wrong.

#### Opacity, and why `secret` mostly provides it

Tesl newtypes are declared `type UserId = String`, and **`.value` unwraps any newtype**
(`lesson04-newtypes.tesl:42,46`). `tesl/jwt.rkt` shows the consequence:
`example/learn/lesson57-jwt.tesl` writes `JwtToken (String.dropPrefix "Bearer " raw)` — the
constructor is callable from application code, and `.value` gets the string back out.

So a `PasswordHash` needs two things withheld:

| Withheld | Provided by |
|---|---|
| the **eliminator** (`.value`) | `secret` — that is most of what the keyword *is* |
| the **constructor** (`PasswordHash "hunter2"`) | a stdlib export question: can a stdlib module export a type without its constructor? |

Only the second is an open unknown, and Phase 1 needs it. Local modules already distinguish
`exposing [Type]` from `exposing [Type(..)]`; the question is whether stdlib module rows can
express the same and whether the checker enforces it for stdlib types. **If the answer is no**,
the fallback is a `:::`-annotated field so `coerce-record-field-value` fails closed on decode
(`dsl/types.rkt:1394`, `:974`) — weaker, because it covers decode but not in-process
construction, so prefer fixing the export path.

**Write the negative test first:** assigning a plaintext `String` to a `PasswordHash` entity field
must be a compile error with a stable code, as a ratchet.

#### Comparison

`==` on a `secret` lowers to a constant-time compare, so the familiar operator stays and the
timing leak does not. No `Ord`.

But `PasswordHash` and `Signature` get **no `Eq` at all** — not for timing, but because a hand
comparison would route around `PasswordVerified` / `Authentic` and quietly defeat the whole design.
Their only legitimate comparison *is* a verification. `eq_ord_generic_soundness` is the precedent.

### `secret`

```
type   UserId   = String     # ordinary newtype: nominal, `.value` unwraps
secret Password = String     # same, minus `.value`, plus redaction
```

**Definition, in one line:** `secret X = T` is `type X = T` **minus `.value`, plus redaction at
every rendering sink.** A keyword parallel to one that already exists, defined by subtraction. The
whole concept a user must learn is that sentence.

#### An earlier objection to this feature, withdrawn

A previous revision argued against the keyword: audit **L3** spans many sinks (HTML, URLs, email
headers, logs), so the general problem is taint tracking, and a bespoke `secret` might foreclose a
general label mechanism. **That reasoning was wrong, on three counts:**

1. **`secret` is not taint tracking.** Taint is *provenance propagating through arbitrary
   computation*. This is a nominal type with a restricted eliminator: `String.length aSecret` does
   not produce a "tainted length", it does not compile. That is a far simpler and more predictable
   mechanism, and it is the one that works in practice (Rust's `secrecy`, Haskell newtype
   wrappers).
2. **The general mechanism I was preserving optionality for is a known failure.** Ruby removed
   `$SAFE` in 3.0; Perl's taint mode is deprecated. Protecting the option to build general taint
   is protecting an option that should not be exercised.
3. **L3's other cases want a different mechanism anyway.** HTML escaping and URL encoding want the
   value to reach the sink *transformed*; `secret` says it never reaches the sink at all. The right
   fix for escaping is a sink that takes structured input, not a label on a string. They do not
   unify.

`secret` is a complete, self-contained idea, not a down-payment on a larger one. It ships.

#### Semantics

- **Every rendering sink redacts** — interpolation, telemetry attributes, structured logs, the
  three debugger surfaces. `"${apiKey}"` yields `[redacted]`, never the value.
- **Serialization out is a compile error, not a silent redaction.** A `secret` in a response body,
  codec or generated client is rejected. Shipping `"[redacted]"` to a client expecting a value is a
  bug that looks like a feature.
- **Storage is not rendering.** A `secret` column writes and reads its real value — the SQL layer
  already handles newtype columns (`lesson67-newtype-columns.tesl`, issue #28).
- **No `.value`.** See below.

#### No unwrap: secret-accepting sinks

Every legitimate un-wrapping is a boundary crossing *into trusted code*, so expose sinks that
accept a secret rather than an unwrap:

| Where a secret goes | How |
|---|---|
| a crypto function | `Crypto.signWith k p` — the trusted body unwraps internally |
| a database column | the SQL layer takes the newtype |
| read from the environment | `Env.requireSecret` mints it directly |
| comparison | constant-time `==` |
| an outbound HTTP header | `HttpClient.bearer k`, `Http.secretHeader name k` |
| **in** from a request body or job payload | the decoder mints it — Phase 4 |

**One checker rule subsumes that table:** *a `secret T` may be passed where a parameter explicitly
marked secret-accepting expects a `T`. Nowhere else.* Opt-in is **per parameter, not per module** —
`String.concat` is stdlib and must never accept a secret. App authors never write the marking;
they only read it in docs, so the learnable surface stays one sentence.

**"How do I tell whether I loaded the right key?"** — `Crypto.keyFingerprint`, a short
non-reversible digest. SSH has identified keys this way for thirty years.

**The risk, named.** A design with no escape hatch fails when someone needs an unanticipated sink,
and the realistic outcome is not a filed issue — it is that they **stop declaring the type
`secret`** and lose the protection entirely. Ship without the escape, treat a missing sink as a bug
to fix rather than a wall, and if evidence demands one, its shape is *not* a method on the type: it
is something loud and declaration-level that shows up in `tesl doc` and agent-context, in the
spirit of `establish` as the app's explicit audit boundary.

#### The inbound half is the valuable half (Phase 4)

```
record LoginBody { email: String, password: String }     # today
record LoginBody { email: String, password: Password }   # Phase 4
```

**The plaintext password in a request body is the highest-value secret in the system and today has
no protection at all.** Mechanically this is small: bodies and job payloads decode through
`jsexpr->typed-value` / `coerce-record-field-value` and newtype decoding already exists.

**The asymmetry is the rule:** *a secret is one-way at the network boundary — it can come in, it
cannot go back out.* The apparent limitation is a nudge toward the correct design: if you must hand
a client a value once (fresh API key, reset token), that is not a secret you hold, it is a token
you mint — `randomToken`, send it, store only its hash. Never storing a retrievable credential is
right anyway.

**Composites, not just record fields.** A secret must be allowed anywhere in a decoded type — a
tuple slot, `List Password`, `Maybe Password`, an ADT payload. Two consequences, both of which a
shallow implementation gets wrong while appearing to work:

- **Redaction is structural** — the check goes at *every node of a renderer's walk*.
  `value-tree.rkt` recurses; `telemetry-value->jsexpr` recurses over lists, vectors and hashes
  (`dsl/otel.rkt:54-69`).
- **The serialization error is transitive** — a record containing a record containing a `secret` is
  equally rejected in a response position.

**Generated clients are direction-dependent.** A `secret` in a *request* type emits as `string` in
TS/Elm; in a *response* type it fails the build. Verify `emit_ts`/`emit_elm` can distinguish the
two positions; if they cannot today, that is part of Phase 4.

**api-tests keep working.** A test posts JSON, so a secret field decodes normally. Asserting on the
value is impossible — correctly. Tests assert on behaviour.

**One cost, stated rather than softened.** A developer debugging a failing login sees
`password: [redacted]` and cannot tell whether the client sent what they think. Do **not** soften
it with `[redacted, 12 chars]` — password length is a real leak, and partial disclosure in a
debugger is exactly the convenience that erodes the guarantee.

#### The guarantee, exactly

> **In Tesl code, a secret cannot become a `String`.** No interpolation, no concatenation, no
> `.value`, no escape hatch. It can only be handed to a trusted function that knows what to do
> with it.

What it does **not** claim: nothing outside Tesl is covered — the value is plaintext in the
environment variable it came from, in the column it is stored in, on the wire once a trusted sink
sends it, and in a core dump. And the trusted sinks are trusted: a bug in `HttpClient.bearer` leaks.
That risk moves from every application into one reviewable place, which is the point, but it does
not vanish. Overselling either is the false-confidence failure mode audit L3 warns about.

### Capabilities are effects

**A capability marks an effect. Sensitivity is handled by types and proofs.**

| Surface | Capability |
|---|---|
| `fingerprint`, `keyFingerprint`, `sha256`, `sha512` | **none** — pure, no more privileged than `String.length` |
| `signWith`, `checkSignature`, `checkPassword`, `needsRehash` | **none** — pure. They consume key material, and that sensitivity is carried by `secret` and by the facts, which track the *value* rather than the function |
| `randomToken`, `hashPassword` | `random` (existing) — genuinely non-deterministic; `hashPassword` draws a salt |

**No new capability, no new `cap_map` row.** Two consequences:

1. **`jwt` is inconsistent with this rule** — `JWT.sign` is a pure HMAC and is gated. Do not churn
   it (removing a capability breaks every `requires [jwt]` in the wild); record it as known debt in
   `capability_completeness.md` and do not propagate the mistake.
2. **The DoS argument loses its capability home, correctly.** `hashPassword` is deliberately
   expensive, and an unauthenticated login endpoint is a free amplifier (audit **L6**). That is a
   *cost* concern, not an authority concern: it belongs in documentation and rate limiting, plus the
   input-length bound below. Re-read `roadmap/discarded/rate-limiting.md` when Phase 1 lands.

### Security lints

The types and proofs stop mistakes expressible as type errors. They cannot stop **declaring
`password: String` in the first place** — a modelling error, and the realistic way the feature gets
bypassed. A lint is the right tool, and it serves the stated goal: the compiler should teach secure
behaviour, not merely permit it.

**Governing rule, because a wrong security lint is worse than none:**

> A security lint ships only if it is **actionable** (one obvious fix, ideally machine-applicable),
> **precise** (a clean codebase is completely silent), and **about something Tesl can enforce**.
> Anything failing those belongs in documentation.

**Give them their own category.** `error_codes.ml` has a `category` field
(`Syntax | Type | Proof | Structure | Naming | Lint`); add **`Security`** with its own prefix rather
than extending `W001–W091`, so `tesl help codes` groups them and CI can promote the category to
errors without promoting style lints.

**The payoff:** every diagnostic already has a stable code, a `tesl explain` explanation, a manual
deep-link and often a machine-applicable fix surfaced to the LSP and `agent-context`. That makes
**the linter the security curriculum**, delivered at the exact line at the moment it is relevant.

**Tier 1 — structural, Phase 0.** No name guessing; the compiler knows from dataflow or shape.

| Check | Why precise |
|---|---|
| An `auth` body that mints an authz fact from request data compared against a literal — the `cookies "user" == "admin"` shape | Audit L2's root, stated exactly. Fires on six real files today. The most valuable single lint here |
| A string literal passed to a secret-accepting parameter — a hardcoded key | Structural, not entropy guessing |
| An `Env` read into a plain `String` flowing into a secret-accepting parameter | It is a key; it should have come from `Env.requireSecret` |
| A `hashPassword` result reaching `insert` without passing a `HashFor`-constrained parameter | Closes `HashFor`'s residual gap. Dataflow only |

**Tier 2 — name-based, Phase 4.** Fire on a **record field, entity field or function parameter**
whose name's final camelCase segment is in a short curated list (`password`, `passwd`, `pwd`,
`secret`, `apiKey`, `clientSecret`, `privateKey`, `accessToken`, `refreshToken`, `sessionToken`,
`otp`, `pin`, `credential`) **and** whose type is a bare `String`.

Do **not** fire on: locals (transient names, bad signal); anything containing `hash`/`digest`/
`fingerprint`; substring matches (`passwordResetUrl`, `tokenizer` must be silent — match the last
camelCase segment); or bare `token` (a CSRF token is a secret, a `pageToken` is not). **When in
doubt, omit the word** — too short is recoverable, too noisy kills the feature. Warning severity,
**with a machine-applicable fix**; a security lint that only scolds gets suppressed.

**Prerequisite: there is no lint suppression mechanism.** Verified 2026-07-29 — nothing in
`linter.ml` or `error_codes.ml` implements per-site suppression. It must exist before Tier 2 ships,
or the only way to silence a false positive is to disable the linter. It must be **narrow and
greppable** — a specific code at a specific site, with a reason — never a file- or project-wide off
switch. A security suppression is an assertion that the author considered it, and should read like
one.

### Upgrades, rolling deploys, and multi-tenant keys

**Password hashes cannot be eagerly upgraded — arithmetic, not policy.** A hash is one-way; there
is no function from a stored hash to a stronger one without the plaintext, which exists for exactly
one moment: the next successful login. Upgrade-on-login is not the weaker option, it is the only
mechanism. That is what `needsRehash` is for. *(Hash wrapping — `argon2(bcrypt(pw))` — is the one
way to upgrade eagerly, and it adds a scheme-composition dimension every future verifier carries
forever. Recommended against; recorded so it is not rediscovered as a clever idea.)*

**What is automatic, and it is most of what anyone wants.** Because parameters are chosen by the
library and never by the application (rule 1), a Tesl upgrade that bumps libsodium's recommended
cost parameters means **every new hash is automatically stronger**, `needsRehash` starts returning
`True` for old ones, and application code that was correct stays correct unmodified. Safe precisely
because it never touches stored data without the plaintext. The lesson should say so — it is the
payoff for rule 1. Tesl must **not** perform the rehash itself: a crypto function writing to the
database is a hidden effect and couples the module to the data model. One explicit line.

**The rolling-update rule:** *verification accepts every scheme ever shipped; minting uses the
current one.* The PHC string gives this for free — algorithm and parameters live inside each stored
value, so old and new instances read the same rows. No flag day, no dual-write window.

Two consequences:

1. **Never auto-migrate stored data at startup.** Tesl already runs DDL at boot
   (`ensure-database-ready!`, audit **L7**), so the precedent exists and must not extend to data. A
   bulk rewrite during a rolling deploy risks startup timeouts, lock contention, partial completion
   and — worst — a format the still-running old instances cannot read.
2. **A scheme-deprecation policy**, or "accept everything forever" becomes unbounded. Drop old
   schemes only at a major version, with a release note and a documented `needsRehash` count query
   so an operator can tell whether it is safe.

**Multi-tenant and bring-your-own keys.** One rule keeps this a non-problem:

> **A crypto function never reads its key from ambient config. The key is always an explicit
> parameter.**

`Crypto.signWith key payload` already obeys it, so a per-tenant key is just a different value.
Nothing assumes one key; password hashing is unaffected entirely (per-hash salt, no key). The rule
also makes keys testable and rotation expressible. Where it *would* break is Phase 5's `Session.*`
if it read the key from `Env` — another reason that phase belongs in the response-metadata item,
designed with this rule in hand. It also makes the **key id** load-bearing rather than
nice-to-have: with per-tenant keys you must know *which* key verified a token.

Per-tenant keys can come from a `secret` column on the tenant entity, from per-tenant env vars, or
from a KMS over HTTP with the existing cache — no new primitives. **Key custody itself is refused**
(see [What we will not build](#what-we-will-not-build)): storing keys well is platform
infrastructure, not language surface.

**Certificates are out of scope.** X.509 and mTLS are transport, and Tesl does not terminate TLS
(`manual/deploy.md`). "Customer certificate" meaning a customer-supplied *signing* key is the BYOK
case above.

---

## Surface

Eight functions, three types, three facts. **No unwrap.**

```
Crypto.hashPassword    : (plaintext: String) -> PasswordHash ::: HashFor plaintext
                                                                       requires [random]
                         # rejects input over a documented maximum length — an
                         # unbounded memory-hard hash is a free DoS (L6)
Crypto.checkPassword   : (stored: Maybe PasswordHash) -> (candidate: String)
                       -> ok stored ::: PasswordVerified stored | fail 401
                         # takes `Maybe` deliberately: hashes against a dummy when
                         # there is no row, so a missing user and a wrong password
                         # cost the same
Crypto.needsRehash     : (stored: PasswordHash) -> Bool

Crypto.signWith        : (key: Secret) -> (payload: String) -> Signature
Crypto.checkSignature  : (key: Secret) -> (sig: Signature) -> (payload: String)
                       -> ok payload ::: Authentic payload | fail 401

Crypto.fingerprint     : (content: String) -> String
Crypto.keyFingerprint  : (key: Secret) -> String
Crypto.randomToken     : () -> String                                  requires [random]
                         # no length parameter — rule 1
```

**Types.** `PasswordHash` and `Signature` are `secret` *and* opaque — no `.value`, no
caller-callable constructor, no `Eq`. `Secret` is `secret` — constant-time `==`, redacts everywhere.
**Facts:** `HashFor`, `PasswordVerified`, `Authentic`.
**Expert aliases:** `hmacSha256` → `signWith`; `sha256`/`sha512` → the digests behind `fingerprint`.
**Phase 5:** `Session.sign` / `Session.verify`.

Plus the secret-accepting sinks in other modules: `Env.requireSecret`, `HttpClient.bearer` /
`Http.secretHeader`, the SQL layer, and the decode boundary.

**`Bytes` stays inert — decision made.** `primitive_gaps_and_outbound_hardening.md` §5 defers to
this item. Returning hex/`String` avoids the dependency and nothing above needs real binary.

**Key management.** Two forward-compatibility moves that cost nothing now and are expensive to
retrofit: read secrets through `Env.requireSecret` so redaction applies at the source, and put a
**key id** in the signed-session format from day one — rotation is out of scope for v1, but a
format without a key id cannot rotate without a flag day (Tink's lesson).

---

## Defects the design must handle

Four correctness problems that a straightforward implementation gets wrong. All are Phase 1.

1. **User enumeration via timing.** `checkPassword` is only reached when a user row exists — a
   missing user returns in microseconds, an existing one costs ~100 ms of deliberate work, so the
   login endpoint leaks which emails are registered. The goal is that users *never need to worry*,
   so the surface handles it: `checkPassword` takes `Maybe PasswordHash` and hashes against a dummy
   when there is no row.
2. **No bound on password input length.** libsodium has no bcrypt-style truncation, which is good —
   but it means a 10 MB "password" gets memory-hard-hashed, a free DoS on an unauthenticated
   endpoint (L6). A documented maximum, enforced inside `hashPassword`.
3. **`randomToken` must not take a length.** Rule 1: a caller who can pass `4` will.
4. **`PasswordVerified` narrows the auth gap; it does not close it.** Reaching `Authenticated`
   still needs an `establish` (audit L1). Say what it delivers and no more.

---

## Verification bar

- **Known-answer tests** against published vectors for every digest and MAC — not round-trip-only;
  a broken implementation round-trips fine.
- **Cross-implementation:** verify a *foreign-produced* Argon2id PHC string, plus a test asserting
  the documented limit that foreign **bcrypt** is not verifiable.
- **A cost-parameter regression test.** `hashPassword` must take at least *N* ms and allocate at
  least *M* MB on the CI machine. Known-answer tests pass fine against a build whose work factor
  silently collapsed, and that is a total security failure that looks like everything working. The
  test most likely to be skipped and most likely to matter.
- **A timing-equalization test:** verification against `Nothing` and against a real hash take
  indistinguishable time.
- **Proof tests, all three facts:** none can be minted outside the trusted bodies (an `establish`
  attempt is rejected), and an `auth` function that skips `checkPassword` cannot reach
  `Authenticated`.
- **The `HashFor` cross-parameter ratchet**, in the **change-password** shape — two same-typed
  strings in scope — not the registration shape. `Crypto.hashPassword oldPassword` is a compile
  error; `newPassword` compiles. Both directions.
- **Compile-error ratchets** with stable codes: plaintext `String` → `PasswordHash` entity field;
  `hashA == hashB`; a secret in an interpolation hole; a `secret` field in a response/codec/client.
- **Opacity:** `PasswordHash "anything"` from application code does not compile.
- **No-unwrap by enumeration:** no exported way turns a `secret` into a `String`, asserted over the
  module's exported surface so a future accidental accessor fails the build.
- **Sink coverage:** every secret-accepting sink accepts the type with no intermediate `String`,
  and `String.concat` **rejects** one. This proves the design is *usable*, not just safe.
- **Structural redaction:** a secret nested in a record, tuple, `List`, `Maybe` and ADT payload is
  redacted while siblings render — in telemetry and all three debugger surfaces. A shallow
  implementation passes the flat test and fails this one.
- **Transitive response rejection**, and the same type **accepted** in a request position.
- **Generated clients:** `secret` request field emits as `string`; response field fails the build.
- **Mixed-version verification:** hashes minted under current and previous parameters both verify
  and `needsRehash` distinguishes them. This is the rolling-update guarantee; untested it is an
  intention.
- **Security lints both ways:** a positive fixture per check, **and a negative corpus that stays
  completely silent** — `passwordHash`, `passwordResetUrl`, `pageToken`, a local named `password`,
  and this item's own known-answer vectors. The silence test is the one that matters. After Phase 0,
  the whole example corpus is silent under `Security`.
- `test_stdlib_runtime_binding.ml` green — every new stdlib name resolves to a real Racket provide.
- `tesl doc` catalog + `test_stdlib_signature_coverage.ml` held, **including expert aliases** and
  the "which primitive is underneath" line.
- `./ci.sh` green with the new lessons, byte-exact in the integration snapshot.
- Native dep resolves in the nix dev shell, through the `tesl-cli` wrapper, in both `tesl build`
  images, and on macOS. Add it to the CLI-portability ratchet (`tests/cli-portability.sh`).

---

## Open questions

1. **Can a stdlib module export a type without its constructor?** Phase 1 needs it; if no, use the
   `:::` fallback rather than adding an opacity mechanism to the language. *Answer first.*
2. **libsodium packaging** — settled by the half-day spike, not by argument. PHC makes the fallback
   survivable.
3. **Does string interpolation unwrap newtypes, or only proof-carrying values?**
   (`LANGUAGE-SPEC.md:2430`, `:2693`.) Decides whether `"${secret}"` needs a checker rule.
4. **Does subject identity hold across a repeated field access**, or does `HashFor` need the
   `let`-binding? Affects only how the lesson is written.
5. **Is `secret` a keyword or a modifier?** `secret Password = String` parallels the existing
   `type Password = String` exactly, which is the cheapest possible framing. Confirm no parser
   ambiguity.
6. **Can `emit_ts` / `emit_elm` distinguish request from response positions?** If not, that is
   unbudgeted Phase 4 work.
7. **Who owns the response-metadata / cookie item?** Phase 5 is blocked on it and it is not crypto
   work.
8. **Is there a test-only construction path for a `secret`**, and does it reopen the hole? Fixtures
   need to build one somehow.

---

## Related

- `roadmap/next/primitive_gaps_and_outbound_hardening.md` — the siblings this was split from; its
  §5 `Bytes` question is answered here (deferred)
- `roadmap/discarded/security_hardening_audit.md` — **L1** (`establish` trust escape),
  **L2** (crypto-free auth root), **L3** (no output escaping), **L4** (telemetry egress),
  **L6** (resource exhaustion), **L7** (startup DDL)
- `roadmap/discarded/rate-limiting.md` — re-read when Phase 1 lands
- `roadmap/completed/interop_policy_and_docs.md` — why this item, not FFI, answers "Tesl can't do X"
- `roadmap/completed/capability_completeness.md` — where the capabilities-are-effects ruling and the
  `jwt` misclassification debt belong
- `roadmap/completed/eq_ord_generic_soundness.md` — the precedent for withholding `Eq`
- `tesl/jwt.rkt` — the pattern to follow, the callable-constructor hole, and the existing undeclared
  native dependency
