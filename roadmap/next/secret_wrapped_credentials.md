# Secret-wrapped credentials — should `Secret` carry a payload type (and a proof)?

> **Status:** Next · **Effort:** M, and it is a MODEL decision before it is code. Do not build the
> generic type without settling the "one key type vs. a hide-box" question below.

## The prompt

`Secret` today is `define-secret-newtype Secret String` (`tesl/crypto.rkt`): a nominal newtype over
`String`, redacted at every rendering sink (telemetry, the three debugger surfaces, structured
logging), with no readable `.value`. It is **the one key-material type in the language** — what
`Env.requireSecret` returns, what `JWT.sign`/`JWT.verify` and `Crypto.signWith`/`checkSignature`
take, and what the SEC003 hardcoded-credential lint keys off (`secret_accepting_params` in
`type_system.ml`).

The question raised (2026-07-30): should it be parameterized — `Secret a` — so that a plaintext
credential in transit can be modelled as, e.g.

```tesl
record Credentials {
  user: String
  password: Secret (String ::: LengthLongerThan 8)
}
```

The appeal: the password would be **redacted everywhere** and **un-inspectable in Tesl code** (which
is what we want for a plaintext credential), while a codec still validates it at the boundary.

## Why this is not a quick win, and what the real design space is

Three observations that reshape the item:

1. **The proof half is already available, without `Secret`.** A codec attaches a proof at the HTTP
   boundary today: `password <- "password" with_codec stringCodec via requireLongEnough` yields
   `String ::: LengthLongerThan 8`. So the `::: P` in the proposal needs no new type.

2. **A proof inside an un-inspectable box is nearly inert.** Proofs are consumed by functions that
   take the *value*. If `Secret` hides the value, the only thing you can pass a `Secret (String :::
   P)` to is a privileged sink (`Crypto.checkPassword`), so `::: P` buys boundary validation
   (codec → 400 on a short password) and nothing downstream — and boundary validation is the codec's
   job, reachable without `Secret`. So the generic *proof* parameter delivers little over a codec.

3. **The real prize is redaction, and that is a smaller change than `Secret a`.** Making a password
   redacted + un-inspectable needs at most `password: Secret String` plus teaching
   `Crypto.checkPassword` to consume a `Secret` instead of a bare `String` — which is strictly *more*
   protective (the plaintext never becomes an inspectable String at all). The generic type parameter
   is not required for that.

## The decision that gates everything

**Is `Secret` "the key-material type" or "a generic hide-box"?**

- Today it means *long-lived key material the SERVER holds* (signing keys, API keys). SEC003 and the
  redaction registry lean on that single, narrow meaning.
- A password is a *transient credential in transit* that must be hashed and immediately discarded —
  a different lifecycle and threat model.
- `Secret a` (or even letting passwords be `Secret String`) collapses the two. That might be the
  right call — redaction is valuable for both — but it dilutes the "this value is a cryptographic
  key" signal that a reader and the lints currently get for free. Decide it deliberately; do not let
  it happen as a side effect of a lesson edit.

## Options, in increasing size

- **A — do nothing.** Passwords stay plain `String` through `Crypto.hashPassword`/`checkPassword`
  (lesson64), validated by a codec. The status quo. Cost: a plaintext password is an inspectable,
  loggable String until it is hashed.
- **B — passwords are `Secret String` (no generic parameter).** `Crypto.checkPassword` and
  `Crypto.hashPassword` accept `Secret String`; a codec produces it. Gets the redaction, keeps
  `Secret` non-generic, but blurs key-vs-credential and touches the Crypto signatures + SEC003 table.
- **C — generic `Secret a`.** The full proposal. Needs: the parameterized nominal type, proof
  threading through the wrapper, codec support for producing a wrapped proof-carrying value, every
  `Secret`-consuming stdlib signature revisited, and a re-think of what SEC003 flags (a `Secret Int`?
  a `Secret MyRecord`?). Largest surface, most expressive, most conflation risk.

**Recommendation:** if the goal is "redact the password," B is the honest minimum and C is
over-built for it. Reach for C only if a concrete second use-case for a generic secret appears that a
codec + `Secret String` cannot serve. Either way, `lesson76-sessions.tesl` is the WRONG place to
introduce it — that lesson is about sessions; passwords belong to lesson64.

## Verification bar (whichever option)

- A password value renders as `[redacted]` in telemetry, the debugger, and logs — a test, not a
  claim.
- `Crypto.checkPassword` still works end to end (lesson64 green).
- SEC003 still fires on a hardcoded key and does NOT regress on the new shape.
- No `String` holds the plaintext at any point the design says it should not (the property the JWT
  key-unification already established for keys, extended to credentials).

## Related

- `roadmap/completed/tesl_crypto.md`, `tesl/crypto.rkt` (`define-secret-newtype`), the redaction
  registry in `dsl/types.rkt`.
- `type_system.ml` `secret_accepting_params` + `secret_param_expected_base` (the one place a user's
  `secret MyKey = String` is already special-cased — the seam any generic work extends).
- `roadmap/completed/response_metadata_and_cookies.md` (the key unification, the precedent for "no
  String ever holds key material").
