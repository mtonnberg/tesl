# `Tesl.Crypto` — hashing, HMAC, password storage, signed sessions

> **Status:** Next · **Effort:** L (design-heavy; native dependency + proof design + an open
> audit gap ride on it). Plan before writing code.

Carved out of `roadmap/next/primitive_gaps_and_outbound_hardening.md` (2026-07-29) because it
is materially bigger than the other items there: it needs a native dependency decision, a
proof-predicate design, and it is the unlock for a **documented audit gap** (L2). It is also
the single most likely reason an application cannot be written in Tesl at all, and therefore
the real answer to most "give me FFI" requests (see
`roadmap/discarded/using_queues_for_ffi.md`).

## Overall goal

Tesl should provide an easy and simple way of working with crypto and other security related relevant things. It should be easy to do the right(secure) thing. It should not require security knowledge to use the crypto/hashing features but it should be transparent for experts.

## Current state

App code can reach exactly one cryptographic operation: `JWT.sign` / `JWT.verify` (HS256),
gated by the `jwt` capability. Under the hood `tesl/jwt.rkt:19-66` already reaches OpenSSL
libcrypto through `ffi/unsafe` + `openssl/libcrypto` for HMAC-SHA256 — so the *mechanism* and
the trust pattern (native call wrapped as capability-gated stdlib functions, never exposed as
FFI) are established and proven in-tree.

Not reachable at all: any hash, any HMAC outside JWT, CSPRNG bytes, hex/base64,
constant-time comparison, password hashing.

## Why this is large

Four independent design problems, any of which can sink a naive implementation:

### 1. Password hashing needs a native dependency decision

Argon2id is the correct default and is **not in libcrypto**. Options:

| Option | Cost |
|---|---|
| argon2 (libargon2 / libsodium) via `ffi/unsafe` | new native dep → nix flake input, docker base image (`racket/racket:9.2-full` + the .so), `raco distribute`/`--exe` bundling, multi-arch |
| bcrypt via libcrypto | no new dep, but weaker, 72-byte truncation, no memory-hardness |
| PBKDF2-HMAC-SHA256 via libcrypto | no new dep, FIPS-blessed, weakest of the three against GPU attack |
| pure-Racket implementation | unacceptable — timing and performance both wrong |

This decision drives the packaging work, which is most of the effort. Note the deploy story
is currently "just an image" (`manual/deploy.md`) and `tesl build` stages only the runtime
collections plus `app.rkt` — a new .so touches that path, `compile-examples.sh`, and the nix
flake together.

### 2. The proof design is the actually-Tesl part

A hashing function is a library. The interesting question is what the type system enforces:

- **Can a plaintext password reach an entity field?** A `PasswordHash` newtype plus a
  predicate (`IsHashed`?) that only `Crypto.hashPassword` can mint would make "we stored a
  plaintext password" a compile error. That is worth more than the hash function itself, and
  it is exactly the kind of thing the proof system exists for.
- **Constant-time comparison must be the only way to verify.** If `==` works on a
  `PasswordHash`, the primitive ships with a timing leak. Either the newtype has no `Eq`, or
  verification is the only exposed operation. Decide deliberately — the
  `eq_ord_generic_soundness` work is the relevant precedent.
- **Secret material should not be loggable.** Telemetry is the one ambient, always-on egress
  sink (audit L4) with no redaction. A `JwtSecret`-style newtype that telemetry refuses to
  serialize would close part of L4 for the highest-value case.

### 3. Capability granularity

`hash` needs no secret; `hmac` and password verification do; `randomBytes` is already covered
conceptually by the existing `random` capability (`tesl/random.rkt:19`). One `crypto`
capability flattens a real risk distinction. Candidate split: reuse `random` for CSPRNG bytes,
a plain (ungated?) `hash` for non-secret digests, and a distinct capability for
secret-consuming operations. Needs a decision consistent with `capability_completeness.md`
and the existing `cap_map` single-source work.

### 4. It unlocks audit L2 — and that is the real prize

`roadmap/discarded/security_hardening_audit.md` L2 records: *"`auth` is a crypto-free trust
root; insecure session pattern … No built-in signed-session / secure-cookie primitive"*, and
notes the examples model a plaintext, guessable session cookie
(`cookies "user" == "admin"`). That gap **cannot** be closed without HMAC — so a signed
session/cookie primitive is the natural second phase of this item, and arguably its main
justification:

- `Session.sign` / `Session.verify` over a `JwtSecret`-style key, with expiry
- an `auth` pattern in the examples that is not a guessable plaintext cookie
- guidance + a lesson replacing the current insecure demo pattern

That turns L2 from "missing primitive + guidance" into a closed item, and fixes the
copy-paste-from-the-examples problem, which is the more dangerous half.

## Surface sketch (not settled)

- `Crypto.sha256` / `sha512` → hex or base64 `String`
- `Crypto.hmacSha256 key message`
- `Crypto.randomBytes n` (CSPRNG, `random` capability)
- `Crypto.hashPassword` → `PasswordHash`; `Crypto.verifyPassword` → `Bool` (constant-time)
- `Crypto.hexEncode` / `hexDecode` / `base64Encode` / `base64Decode`
- *(phase 2)* `Session.sign` / `Session.verify`

**Return `String` or `Bytes`?** `Bytes` is currently an inert type — it maps to `BYTEA`
(`LANGUAGE-SPEC.md:1782`) and can be declared as an entity field, but nothing in the stdlib
constructs or consumes one. Returning hex/base64 `String` avoids that dependency entirely and
is probably right for v1; if real binary is ever needed, the `Bytes` companion surface is
tracked in `primitive_gaps_and_outbound_hardening.md`.

## Verification bar

- **Known-answer tests** against published vectors for every digest and HMAC (not
  round-trip-only tests — a broken implementation round-trips fine).
- Argon2/bcrypt: verify against hashes produced by the reference implementation, and verify a
  *foreign-produced* hash (people migrate existing user tables into Tesl — this is a real
  requirement, not a nicety).
- A constant-time-comparison test, and a test that the plaintext-to-entity-field path is a
  **compile error** if the proof design lands.
- `test_stdlib_runtime_binding.ml` green — every new stdlib name must resolve to a real Racket
  provide (the seam test that catches typechecks-but-unbound).
- `tesl doc` catalog + `test_stdlib_signature_coverage.ml` coverage held.
- `./compile-examples.sh` green with the new lesson(s), byte-exact in the integration
  snapshot.
- Native dep: builds in the nix dev shell **and** in the `tesl build` docker image, on the
  architectures we claim.

## Open questions

1. Argon2id with a new native dependency, or bcrypt/PBKDF2 to stay inside libcrypto? This is
   the fork in the road — everything else is downstream of it.
2. Is the plaintext-password-to-database compile error in scope for v1, or does v1 ship the
   functions and phase 2 adds the proofs? (Shipping functions first risks the insecure
   pattern spreading before the guard exists — the L2 lesson.)
3. Does the signed-session work belong here or in its own item? It is the strongest
   justification but also doubles the scope.
4. Key management: where does the signing key come from? `Tesl.Env` today. Is there a rotation
   story, or is that explicitly out of scope?

## Related

- `roadmap/next/primitive_gaps_and_outbound_hardening.md` — the smaller siblings this was split from
- `roadmap/discarded/security_hardening_audit.md` — L2 (crypto-free auth root), L4 (telemetry egress)
- `roadmap/discarded/using_queues_for_ffi.md` — why this item, not FFI, is the answer to "Tesl can't do X"
- `tesl/jwt.rkt` — the pattern to follow (libcrypto behind a capability-gated surface)
