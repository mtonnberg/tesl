# `Tesl.Crypto` — Phases 1-4 (2026-07-29)

Implements `roadmap/completed/tesl_crypto.md` Phases 1-4. Phase 0 has its own write-up
(`crypto_phase0_security_lints.md`); Phase 5 was **extracted rather than dropped**, to
`roadmap/completed/response_metadata_and_cookies.md`, because it is blocked on a response-metadata
language feature and not on crypto.

Every decision, deviation and open question is argued in
`IMPLEMENTATION-LOG-crypto-and-onboarding.md` at the repo root. The user-facing surface is
documented in `LANGUAGE-SPEC.md` §21.7. This file is the "what changed and why it is trustworthy"
summary.

## The claim, and how it is checkable

> It is libsodium's `crypto_pwhash`, unmodified, with libsodium's recommended parameters.

A language asking people to trust a novel proof system cannot also ask them to trust novel crypto,
so the whole of `tesl/crypto.rkt` is FFI marshalling plus parameter selection. It implements no
cryptography. `tesl doc Crypto.<name>` names the primitive under every friendly name, so an
auditor who does not read Racket can confirm the claim in a minute.

Cost parameters are **read from the library at call time**
(`crypto_pwhash_opslimit_interactive` / `_memlimit_interactive`), never hardcoded. That is what
makes the upgrade story free: a libsodium bump strengthens every new hash, `needsRehash` starts
answering `True` for old ones, and correct application code stays correct.

## What the type system adds that a library cannot

1. **Storing the hash of the wrong password does not compile.** `hashPassword` returns
   `PasswordHash ::: HashFor plaintext`; a storing function demands the two agree. Verified in the
   change-password shape — two same-typed strings in scope — in both directions.
2. **Verification returns a proof, not a `Bool`.** A `Bool` can be ignored, inverted or compared
   with `==`; a fact cannot. `PasswordVerified` / `Authentic` are minted only by the two check
   functions, and are absent from `proof_discharge.ml`'s `stdlib_auto_preds`, so there is no
   grant-by-name path.
3. **`PasswordHash` has no constructor, no `.value`, no `Eq`.** A plaintext cannot be blessed as a
   hash (`T001`), and a hand comparison cannot route around `checkPassword`.
4. **A secret cannot become a `String`.** `secret X = T` is the newtype declaration minus `.value`,
   minus `Ord`, plus redaction at every rendering sink, plus rejection in a response/codec/client
   position — one-way at the network boundary.

## Defects the design had to handle, and how

| Defect | Handling |
|---|---|
| User enumeration via timing | `checkPassword` takes `Maybe PasswordHash` and hashes against a lazily-built dummy when there is no row, so a missing user and a wrong password cost the same **and return the same message**. Tested: both paths exceed 5 ms and are within a factor of 2 |
| No bound on password input | libsodium imposes none (`crypto_pwhash_passwd_max` = 2^32-1; a 100 KB password hashed fine). **1024 bytes of UTF-8**, enforced on `hashPassword` **and** `checkPassword` — a long *candidate* is the DoS vector, since an attacker never controls the stored value. Rejection with a 400, never truncation |
| `randomToken` must not take a length | It does not. 256 bits, base64url, no parameter |
| `PasswordVerified` narrows the auth gap, it does not close it | Stated in the spec, the docs and the lesson: reaching `Authenticated` still needs an `establish`. What the fact buys is that the unverified step becomes small and reviewable |

## Verification

`tests/crypto-runtime-tests.rkt` — 45 cases, registered in `ci.sh`'s `RKT_SUITES`.

The three that would be easiest to omit and hardest to do without:

- **The cost-parameter regression**, two independent ways. A build whose Argon2id work factor
  collapsed passes every known-answer test in the file, and that is a total security failure that
  looks like everything working. So: wall clock (best of three ≥ 15 ms) **and** the memory limit the
  library reports (≥ the OWASP 19 MiB floor). A fast machine can hide a parameter regression from
  the clock; neither check alone is enough.
- **An independent-implementation oracle.** RFC 4231 cases 3-7 use `0xaa`/`0xdd` key bytes, and
  `signWith` takes a Tesl `String`, so those bytes cross as *two* UTF-8 bytes each — the vectors are
  unreachable through this API and asserting them would assert a different computation. libsodium is
  therefore compared against **OpenSSL libcrypto** (already a dependency via `tesl/jwt.rkt`) across
  key lengths 0/1/31/32/63/64/65/100/131/200 — straddling the block boundary, which is what RFC 2104
  key handling is actually about — plus 50 random pairs.
- **The documented limits as ratchets.** A foreign Argon2id PHC with non-libsodium parameters
  verifies *and* is flagged by `needsRehash`; bcrypt and scrypt are asserted **not** verifiable. The
  roadmap claimed scrypt and PBKDF2 would verify; they do not, and the tests are what stop the
  claim drifting back.

Plus: `compiler/test/test_stdlib_runtime_binding.ml` (every name resolves to a real Racket provide,
checked by asking Racket via `module->exports`), `test_stdlib_docs.ml` +
`test_stdlib_signature_coverage.ml` (no untyped or undocumented export),
`test_capability_registry.ml` (the independent capability oracle),
`tests/cli-portability.sh` (libsodium resolves through the wrapper, resolution is **lazy**, and a
missing library produces an actionable hint), and `example/learn/lesson64-password-storage.tesl`
(5 test blocks, a real `Memory`-backed `PasswordHash` column round-trip).

## Capabilities: no new one

A capability marks an **effect**; sensitivity is carried by the types and the facts, which track the
*value* rather than the function. Only `hashPassword` (draws a salt) and `randomToken` are gated, on
the existing `random`. `fingerprint`, `keyFingerprint`, `signWith`, `checkSignature`,
`checkPassword` and `needsRehash` are pure and ungated — no more privileged than `String.length`.

`Tesl.JWT`'s `jwt` capability is inconsistent with that rule (`JWT.sign` is a pure HMAC and is
gated) and is retained as recorded debt rather than propagated: removing a capability would break
every `requires [jwt]` in the wild.

The DoS argument correctly loses its capability home. `hashPassword` is deliberately expensive and
an unauthenticated login endpoint is a free amplifier — that is a **cost** concern, not an
authority one. It is handled by the input-length bound, by documentation, and by rate limiting
(`roadmap/discarded/rate-limiting.md`, worth re-reading now that this has landed).

## Three bugs found on the way, all fixed

None are crypto bugs; all were found *by* writing the lesson, which is the argument for a real
lesson over a synthetic fixture. Full detail in the implementation log.

1. **Emitted code called bare Racket builtins a Tesl program can shadow** (issue-#12 class).
   `let hash = …` broke every emitted `(hash 'field val)`. Class-fixed with a non-shadowable
   `tesl-hash` — a Tesl identifier cannot contain a hyphen, the same reasoning as the `tesl-prop-*`
   helpers. 30 builtin names probed; `hash` was the only live instance.
2. **`Something x.field` parsed as `(Something x).field`**, and it **typechecked**, because the
   permissive dot fallback swallowed `.field` on a `Maybe`. `Something` was the only affected
   constructor. Zero corpus exposure.
3. **A stdlib function must `raw-value` its arguments before testing a predicate.** `checkPassword`
   did not; every direct call worked and the failure appeared only from real emitted code, deep
   inside FFI marshalling. Two regression tests at exactly that shape.

Also: **`tesl doc` was unreachable from an installed CLI** (no arm in `nix/tesl-cli-body.sh`), which
was quietly disabling the entire transparency contract for anyone who installed via the flake.

## Follow-ups this uncovered

- `.value` and arbitrary fields are **T_ANY on the other stdlib nominal types** (`Int32`, `Money`,
  `PosixMillis`, `ExchangeRate`) — they are absent from `checker.ml`'s `is_known_opaque`. A live
  fail-open class; worth its own small item.
- `Money n` typechecks as `String`, because `"Money"` is in `known_qualifier_modules`. `Crypto` is
  deliberately not, which is what makes `PasswordHash "x"` a clean `T001`.
- **W061 fires on a proof-only parameter** — `hash: PasswordHash ::: HashFor newPassword` is
  value-unused by design. Underscore-prefixing the parameter that makes the code safe reads badly in
  exactly the place the language is showing off.
- Foreign **scrypt** verification is a one-function follow-up if a real migration needs it
  (libsodium has `crypto_pwhash_scryptsalsa208sha256_str_verify`); PBKDF2 would need libcrypto.
