# Implementation log — `Tesl.Crypto` + revised onboarding

Working log for `roadmap/completed/tesl_crypto.md` and `roadmap/completed/revised_onboarding.md`,
started 2026-07-29. Every decision taken without asking, every question left open, and
every place I deviated from the roadmap is recorded here for review.

Legend: **D** = decision taken · **Q** = question for the maintainer · **Δ** = deviation
from the written roadmap · **✓** = verified empirically.

---

## Part A — `Tesl.Crypto`

### A0. The blocking libsodium spike — **PASSED**

Run in the current dev shell against `/nix/store/…-libsodium-1.0.20/lib` with
`LD_LIBRARY_PATH` set. Raw results:

| Probe | Result |
|---|---|
| `(ffi-lib "libsodium" '("26" "23" #f))` | ✓ resolves (`libsodium.so.26` → 1.0.20) |
| `sodium_init` | ✓ returns 0 |
| `crypto_pwhash_str` (Argon2id, INTERACTIVE) | ✓ `$argon2id$v=19$m=65536,t=2,p=1$…`, **82 ms**, 64 MiB |
| `crypto_pwhash_str_verify` | ✓ good `#t`, wrong password `#f` |
| `crypto_pwhash_str_needs_rehash` | ✓ `0` for same params, `1` against MODERATE |
| `crypto_auth_hmacsha256` | ✓ matches RFC 4231 test case 2 byte for byte |
| `crypto_hash_sha256 "abc"` | ✓ `ba7816bf…0015ad` (NIST vector) |
| `crypto_hash_sha512 "abc"` | ✓ `ddaf35a1…54ca49f` (NIST vector) |
| `sodium_memcmp` | ✓ `0` / `-1` |
| `crypto-random-bytes` (racket/random) | ✓ no FFI needed for the CSPRNG |

**D-A0.1 — libsodium it is.** Rule 4 of the roadmap is satisfied without a fallback: the
scrypt/libcrypto contingency is *not* needed. Argon2id at libsodium's own INTERACTIVE
parameters (m=64 MiB, t=2, p=1) exceeds the OWASP floor (m=19 MiB, t=2) with margin.

**✓ Foreign-hash migration, measured — and the roadmap's claim is wrong.**

| Foreign stored hash | libsodium `crypto_pwhash_str_verify` |
|---|---|
| Argon2id PHC with *non-libsodium* params (`m=19456,t=2,p=1`), hand-assembled | ✓ **verifies** |
| bcrypt `$2b$12$…` | ✗ rejected |
| scrypt PHC `$7$…` | ✗ **rejected** |
| PBKDF2 | not tested — libsodium exports no PBKDF2 verifier at all (by symbol inspection) |

**Δ-A0.2** — `tesl_crypto.md` says *"v1 verifies foreign Argon2/scrypt/PBKDF2 and cannot
verify foreign bcrypt"*. Only the Argon2 half is true. libsodium's `crypto_pwhash_str_verify`
parses `$argon2i$` / `$argon2id$` and nothing else; scrypt lives behind a separate
`crypto_pwhash_scryptsalsa208sha256_str_verify` with its own `$7$` format, and PBKDF2 is not
in libsodium at all. **Decision: v1 verifies foreign Argon2i/Argon2id only**, documented as
such, with a test asserting bcrypt/scrypt/PBKDF2 are *not* verifiable so the limit is a
ratchet rather than folklore. Adding scrypt is a one-function follow-up if a real migration
needs it (the `$7$` verifier is in the same library); PBKDF2 would need libcrypto.

**✓ There is no libsodium-side length bound.** `crypto_pwhash_passwd_max` reports
`4294967295`, and a 100 000-byte password hashed successfully (rc=0). Defect 2 in the roadmap
is real and entirely ours to fix.

**D-A0.3 — the input bound is 1024 bytes of UTF-8.** Rationale: OWASP asks for at least 64
characters to be *accepted*; Django caps at 4096 bytes; 1024 bytes admits every real
passphrase (including CJK, where one character is 3 bytes) while capping the memory-hard
work at one hash. Enforced inside `hashPassword` **and** `checkPassword` (a long *candidate*
is the DoS vector, not a long stored password). Over the bound is a diagnostic, not a
truncation — silent truncation is the bcrypt-72-byte bug.

### A0b. Packaging — landed

| Surface | How libsodium is reached |
|---|---|
| nix dev shell | `libsodium` in `devShells.default.packages` + `TESL_LIBSODIUM` exported by the shellHook (`flake.nix`) |
| `nix profile install` wrapper | `TESL_LIBSODIUM` in `runtimePreamble` — the **absolute store path**, so it is a GC-rooted runtime dependency |
| dev wrapper (`tesl-cli-dev`) | same export |
| `tesl build` Docker images | `libsodium-dev` in both templates |
| macOS | `pkgs.stdenv.hostPlatform.extensions.sharedLibrary` resolves to `.dylib`; one expression covers both |

**D-A0.4 — bake the absolute path, do not use `LD_LIBRARY_PATH`.** A `nix profile install` user has no libsodium on any ambient search path, and on macOS `DYLD_LIBRARY_PATH` is unreliable. `tesl/crypto.rkt` therefore prefers `$TESL_LIBSODIUM` and falls back to a plain `ffi-lib "libsodium"` lookup for non-Nix installs (Docker, distro packages). This is strictly better than the status quo for libcrypto, which `tesl/jwt.rkt` resolves from the ambient path with no declaration anywhere — an undeclared native dependency the roadmap already flags.

**D-A0.5 — resolution must be lazy.** `compiler/test/test_stdlib_runtime_binding.ml` does `dynamic-require <module> (void)` over *every* stdlib `.rkt` to enumerate its real provides. A top-level `(ffi-lib "libsodium")` that fails would abort that dump and fail the seam test for **all** modules, not just Crypto. So the library handle and `sodium_init` live behind a `delay`, and every FFI binding is a memoised thunk. `tesl/jwt.rkt` gets this wrong today (`openssl/libcrypto` resolves at module instantiation); Crypto does not copy that.

### A1. Corrections to the roadmap discovered during recon

**Δ-A1.1 — `error_codes.ml` has 8 categories, not 6.** The roadmap quotes
`Syntax | Type | Proof | Structure | Naming | Lint`; the real type also has `Capability` and
`Codec` (both declared, neither used by any row). Adding `Security` is 2 compiler-forced edits
plus **one silent coupling**: the `cats` list in `index ()`. Omit it and `tesl explain SEC001`
works while `tesl help codes` never mentions the category and no test fails. Noted so the next
category-adder does not lose an hour.

**Δ-A1.2 — the `cookies "user" == "admin"` grep in the roadmap matches nothing.** The real
spelling is `Dict.lookup "user" request.cookies`, and it appears in **26 files**, not six —
including both `tesl init` scaffolds (`templates/minimal/app.tesl`, `templates/api/app.tesl`)
and the review test corpus. See D-B0.2 for what that does to the Tier-1 lint.

**Δ-A1.3 — only ONE api-test in the whole corpus posts a cookie**
(`lesson55-testing-auth-and-capabilities.tesl:75`, the `cookie { "session": "alice" }` dict
form). The roadmap budgets Phase 0 for several. The other five named files have no api-tests at
all. Phase 0 is cheaper than budgeted on that axis and more expensive on Δ-A1.2's.

**Δ-A1.4 — `W`-prefix does not mean warning and `E`-prefix does not mean error** in this
codebase (`W040` emits `severity = "error"`; `E030`–`E032` emit warnings). Severity is chosen
per emit site and is entirely decoupled from the code and the category. There is **no**
mechanism to promote a category to errors — no `--strict`, no `-W`, no env var, no config key.
So the roadmap's *"CI can promote the category to errors without promoting style lints"* is not
available; see D-B0.3.

**✓ Roadmap open question 1 answered: YES**, a stdlib module can export a type without its
constructor, and the mechanism is subtractive rather than a marker — a type is constructor-less
iff it has no `"Name", mono (t_fun [base] t_name)` row in `stdlib_env` **and** its name is not in
`Checker.known_qualifier_modules`. Verified empirically: `Int32 n` gives
`error[T001]: unknown constructor: Int32`. So the `:::` fallback is not needed.
**Consequence:** `PasswordHash`/`Signature`/`Secret` must NOT be added to
`known_qualifier_modules`. (`Money` is, which is why `fn bad(n: Int) -> String = Money n`
compiles to `T_ANY` today — a pre-existing hole, recorded, not touched here.)

**✓ Roadmap open question 3 answered: interpolation already rejects a newtype.**
`checker.ml:2044-2053` admits only `TCon ("String"|"Int"|"Bool"|"Float")` and `TVar _`; a
`TCon "Password"` falls to the error arm. So `"${apiKey}"` needs no new checker rule — only a
better *message* when the type is secret.

**✓ Roadmap open question 5 answered: `secret` must be a CONTEXTUAL keyword, not a lexer
keyword.** `secret` is already used as an ordinary identifier in the corpus
(`tests/jwt-tests.tesl:58,61,95,…` — `fn signClaims(claims: String, secret: JwtSecret)`, five
files). Adding it to `lexer.mll`'s keyword table would break them. It is recognised in
`parse_top_decl` only when the next token is a `UIDENT`, which is unambiguous against both the
bare-const arm (`IDENT` followed by `EQ`) and any expression.

**✓ `unify` is strictly nominal** (`type_system.ml:189`) and `ctx.type_aliases` is consulted only
by `ty_is_ord`/`ty_is_eq`. So `String.length aSecret` **already** fails to typecheck. Withholding
`.value` is therefore most of the containment, and the residual channels are exactly four:
`.value`, interpolation (already closed), stdlib functions typed with a bare `TVar`, and the
untyped effect forms `ETelemetry` / `EEnqueue` / `EPublish`.

---

## Part A2 — Phase 1 (password storage): LANDED

### The headline ratchet works

```
fn storeNewPassword(newPassword: String, hash: PasswordHash ::: HashFor newPassword) -> …

let h = Crypto.hashPassword newPassword
storeNewPassword newPassword h          # ✅ compiles

let h = Crypto.hashPassword oldPassword
storeNewPassword newPassword h          # ❌
```
> `error[V001]: call to storeNewPassword argument hash does not statically satisfy declared proof HashFor newPassword`
> `Hint: validate h with a check function that establishes HashFor newPassword (h is derived from oldPassword — same GDP subject)`

*In Tesl, storing the hash of the wrong password does not compile.* That is the single best
demonstration the proof system has, and it needed no new proof machinery — `HashFor` is an
ordinary cross-parameter fact minted by one `RetAttached` row.

### Surface as shipped

```
Crypto.hashPassword     : String -> PasswordHash ::: HashFor plaintext     requires [random]
Crypto.checkPassword    : Maybe PasswordHash -> String
                        -> ok stored ::: PasswordVerified stored | fail 401
Crypto.needsRehash      : PasswordHash -> Bool
Crypto.signWith         : Secret -> String -> Signature
Crypto.checkSignature   : Secret -> Signature -> String
                        -> ok payload ::: Authentic payload | fail 401
Crypto.signatureHex     : Signature -> String
Crypto.signatureFromHex : String -> Signature
Crypto.fingerprint      : String -> String
Crypto.keyFingerprint   : Secret -> String
Crypto.randomToken      : () -> String                                     requires [random]
Crypto.hmacSha256 / Crypto.sha256 / Crypto.sha512                          (expert aliases)
```

### Deviations from the roadmap's stated surface, with reasons

**Δ-A2.1 — `Signature` gained `signatureHex` / `signatureFromHex`, and this is a real hole in
the roadmap.** The roadmap gives `checkSignature : (key) -> (sig: Signature) -> (payload)` and
declares `Signature` opaque with no constructor. But the motivating use case is *verifying an
inbound webhook signature* (Stripe, GitHub) — and an inbound tag arrives as a hex `String` in a
header. With no constructor there is no way to get it into a `Signature`, so the feature as
specified cannot be used for the thing it was justified by. Symmetrically, signing an outbound
payload needs the tag *out* as a header value.

So both directions exist, and they are safe for different reasons: a MAC tag is **public data**
(publishing it is the entire point), and `Signature` keeps its real protection — **no `Eq`**, so
two `Signature`s still cannot be compared, and `.value` is still withheld.

The residual risk is named rather than hidden: `Crypto.signatureHex a == Crypto.signatureHex b`
is expressible and is a timing-unsafe MAC comparison. That is what the **SEC004** lint is for.

**Δ-A2.2 — `Secret` HAS a constructor; `PasswordHash` and `Signature` do not.** Something must
be able to mint a `Secret` from a config read, and `Secret "…"` only asserts "this string is key
material", which is strictly *more* protective than leaving it a bare `String`. A hardcoded key
is caught precisely by the SEC003 lint (a string **literal** reaching a secret-accepting
parameter) rather than by making the type unusable. `PasswordHash "hunter2"`, by contrast, would
bless a plaintext as a hash — a catastrophic type lie — so it has no row and is a `T001`.

**Δ-A2.3 — `Crypto.randomToken` is typed as a VALUE (`mono t_string`), not `Unit -> String`.**
That is how `nowMillis`, `UUID.v4` and `randomFloat` are typed; `Emit_racket.stdlib_zero_arg_names`
is what lowers the `()`. Typing it as a function produced
`error[T001]: cannot unify Unit with List a`.

### `.value` withheld — and a pre-existing hole closed on the way

`checker.ml`'s `is_known_opaque` list is the switch that decides whether an unresolved stdlib
type gets a fixed field set or the permissive `fresh ()` fallback — and the fallback types **any**
field access as *anything*. Verified before touching it: `m.value` (Money), `t.value` (JwtToken),
`x.value` **and `x.nonsense`** (Int32) all typecheck as T_ANY today.

`PasswordHash` / `Signature` / `Secret` are now in that list with a field set of **exactly
nothing**, and each gets a tailored diagnostic that says what to do instead. This is the whole
guarantee: there is no runtime representation difference between a secret and an ordinary
newtype, so **the checker is the sole enforcement** — consistent with the house precedent for
record proofs.

**Q-A2.1 — should the other stdlib nominal types get the same treatment?** `Int32`, `Money`,
`PosixMillis`, `ExchangeRate` are absent from `is_known_opaque`, so `.nonsense` on any of them is
T_ANY. Not touched here (out of scope, and each needs its own field-set decision), but it is a
live fail-open class and worth its own small item.

**Q-A2.2 — `Money n` typechecks as `String`.** `"Money"` is in `known_qualifier_modules`, which
makes the bare constructor resolve to `fresh ()`. Pre-existing; `Crypto` is deliberately NOT added
to that list, which is what makes `PasswordHash "x"` a clean `T001`.

### Eq and Ord

| Type | `==` | `<` `>` | Why |
|---|---|---|---|
| `Secret` | **yes**, constant-time | no | The familiar operator stays and the timing leak does not. An *ordered* comparison against a secret is a binary-search oracle for its value, so `Ord` is denied — checked BEFORE the alias chase, or `secret Code = Int` would silently inherit `Int`'s ordering |
| `PasswordHash` | **no** | no | Not for timing — because a hand comparison would route around `checkPassword` and quietly defeat the design. Its only legitimate comparison IS a verification |
| `Signature` | **no** | no | Same reason |

### Test evidence

`tests/crypto-runtime-tests.rkt` — **43 test cases, all passing.** The parts worth knowing about:

- **Known-answer, not round-trip.** SHA-256 and SHA-512 against NIST vectors; HMAC-SHA256 against
  RFC 4231 cases 1 and 2.
- **An independent-implementation oracle.** RFC 4231 cases 3-7 use `0xaa`/`0xdd` key bytes, and
  `signWith` takes a Tesl `String`, so the key crosses as UTF-8 where those bytes are *two* bytes
  each — those vectors are unreachable through this API, and asserting them would be asserting a
  different computation. Instead libsodium is compared against **OpenSSL libcrypto** (already a
  dependency via `tesl/jwt.rkt`) over key lengths 0/1/31/32/63/64/65/100/131/200 — straddling the
  64-byte block boundary, which is the RFC's actual concern — plus 50 random pairs. A bug would
  have to exist identically in both libraries to slip through.
- **The cost-parameter regression test**, two independent ways: wall clock (best of three ≥ 15 ms;
  the dev box measures ~82 ms, so the floor is far below observed while still orders of magnitude
  above a collapsed work factor) **and** the memory limit libsodium reports (≥ the OWASP 19 MiB
  floor; libsodium's INTERACTIVE is 64 MiB). Either alone is defeatable — a fast machine hides a
  parameter regression from the clock.
- **The timing-equalisation test.** Median of five, both paths must exceed 5 ms (so neither
  skipped the hash) and be within a factor of 2 of each other. A tight absolute bound would be
  flaky on shared CI; a factor-of-2 bound still fails loudly on the only regression that matters.
- **The 401 message is asserted IDENTICAL** for a wrong password and a missing user — the message
  is part of the enumeration surface, not just the timing.
- **Foreign-hash ratchets**: a hand-assembled Argon2id PHC with non-libsodium parameters verifies
  *and* is flagged by `needsRehash`; bcrypt and scrypt are asserted **not** verifiable.
- **The length bound**, four ways: over-length rejected with 400, exactly-at-bound accepted, the
  bound counts BYTES not characters (400 CJK characters = 1200 bytes), and it guards
  `checkPassword` too — a long *candidate* against a short stored hash is the actual DoS vector,
  since an attacker never controls the stored value.
- **Malformed inbound signatures** (`""`, `"zz"`, `"not-hex"`, …) each produce a clean 401, never
  an exception escaping the handler — a webhook sender can put anything in that header.

`compiler/test/test_stdlib_runtime_binding.ml` green: every `Tesl.Crypto` name resolves to a real
Racket provide, checked by asking Racket itself via `module->exports`.

---

## Part A3 — three real bugs the crypto work uncovered, all fixed

None of these are crypto bugs. All three were found *by* writing the password-storage
lesson, which is the argument for writing a real lesson rather than a synthetic fixture.

### Bug 1 — emitted code calls bare Racket builtins a Tesl program can shadow (issue-#12 class)

```tesl
let hash = Crypto.hashPassword newPassword       # Tesl
```
```racket
(let ([hash …]) (insert-one! Account (hash 'id id …)))   ; emitted
                                       ^^^^ the user's binding, applied
```
> `application: not a procedure; given: 'hash2860`

`hash` is not an exotic variable name — it is **the** natural name in password code, so the
crypto feature was unusable with the most obvious spelling. The emitter constructs record
literals, entity rows, `insert`/`update`/`upsert` field maps, codec encoders and property-test
rows with a bare `(hash …)`.

**Class fix, matching the existing precedent.** `dsl/types.rkt` now exports `tesl-hash` (a plain
alias for `hash`) and all 14 emission sites use it. A Tesl identifier cannot contain a hyphen, so
`tesl-hash` is **non-shadowable by construction** — the same reasoning behind the `tesl-prop-*`
helpers in `dsl/test-support.rkt`, which closed the `format`/`map`/`random` instances of this
identical class for generated property tests.

**Measured blast radius.** I probed 30 builtin names (`hash list cons format map void values error
apply length sort filter member reverse append min max abs string vector bytes set first rest last
take drop range count number char symbol boolean`) as let-bindings and parameters across record
literals, entity inserts, `update … set`, `case` and test blocks. **`hash` was the only one that
broke.** So this is now an instance-complete fix, not a partial one.

**Cost: 76 of 190 committed `.rkt` snapshots change.** Mechanical, and there is house precedent for
a regeneration sweep (`roadmap/completed/rkt_snapshot_regen_sweep.md` did 98). Regenerated in one
scripted pass.

### Bug 2 — `Something x.field` parsed as `(Something x).field`, and it typechecked

```tesl
fn double(x: Int) -> Int = x * 2
fn viaFn(b: Box)   -> Int       = double b.n        # ✅ (double (b.n))
fn viaCtor(b: Box) -> Maybe Int = Something b.n     # ❌ ((Something b).n)
```

`.` binds tighter than **function** application but did not bind tighter than the `Something`
constructor. `parse_atom`'s `SOMETHING` arm parsed its argument with `parse_atom` instead of
`parse_postfix`, so the argument stopped at `b` and the caller then wrapped the whole
constructor.

**`Something` was the only constructor affected** — it is the only one that parses its own
argument there; every other constructor (user ADTs, `Ok`, `Err`) is applied through `parse_app`,
whose argument parser is already `parse_postfix`.

**This was a SILENT wrong answer, not a compile error**, because two holes composed: the
precedence bug produced `.field` on a `Maybe`, and `.field` on an unresolved type falls through
the checker's permissive `fresh ()` fallback (the same T_ANY hole recorded as Q-A2.1). So it
typechecked, emitted, and trapped at runtime with a message pointing nowhere near the cause.

Fixed (`parse_atom` → `parse_postfix`, one token plus a comment explaining why).
**Zero corpus exposure**: no `.tesl` file in `example/`, `tests/` or `templates/` applies an ADT
constructor to a bare dotted argument — every apparent hit (`statusOk resp.status`) is a plain
function, which always parsed correctly.

### Bug 3 — mine: a stdlib function must `raw-value` its arguments BEFORE testing a predicate

`Crypto.checkPassword` tested `Something?` on its raw parameter. A Tesl stdlib function does not
necessarily receive its argument as the value: the GDP machinery may hand over the **subject
name** — a bare symbol like `'stored2859` — which `raw-value` resolves through
`current-evidence-env`, and the argument may also arrive wrapped in a `named-value` or a
`check-ok`.

Every direct call worked. Every unit test passed. The failure appeared only from real emitted Tesl
code, as a type-contract violation deep inside the FFI marshalling. **That is the worst possible
failure signature for a security primitive**, so it now has two regression tests at exactly that
shape (a subject name resolving to `Something h`, and one resolving to `Nothing`, so the
timing-equalisation path is covered through the same indirection too).

`tesl/string.rkt`'s `raw-str`-on-the-first-line is the house idiom; this is a note for the next
person adding a stdlib function that branches on its argument's shape.

### Two smaller findings

**`tesl doc` was unreachable from an installed CLI.** `nix/tesl-cli-body.sh` had no arm for `doc` /
`--doc-json` / `explain`, so the `*)` branch printed `unknown command` while `main.exe doc` worked
fine. It therefore failed for *everyone who installed via the flake* and worked only for people
running the compiler out of a checkout. That matters disproportionately here: `tesl doc` is the
entire delivery mechanism for rule 4 (every friendly name states the primitive underneath). Fixed;
`tesl doc Tesl.Crypto` now renders all 17 entries. **Note the delivery channel** — the dev shell's
`tesl` is a store-built wrapper, so this fix only reaches a user after a flake rebuild.

**W061 fires on a proof-only parameter.** `hash: PasswordHash ::: HashFor newPassword` is
value-unused by design — its *proof* is the whole point — and the linter calls it an unused
parameter. In the lesson I made the parameter genuinely used (it is inserted into a column), which
is better teaching anyway, so this is recorded rather than worked around. It would bite anyone
writing a pure proof-carrying signature, and `_`-prefixing the parameter that makes the code safe
reads badly in exactly the place the language is showing off.

### Δ-A3.1 — `lesson64` was a HOLE; the new lesson fills it

`roadmap/completed/revised_onboarding.md` decided to *renumber the tail* to close the missing-`lesson64`
gap. The new password-storage lesson is `lesson64-password-storage.tesl` instead, which closes the
gap for **zero** renames, zero module-name edits, zero snapshot churn in other files and zero
reference updates — against ~12 renames plus snapshots plus references for the renumber, which
delivers nothing else. If lesson ordering later moves into metadata (D5), neither choice matters.
Recommend dropping the renumber from the plan.

The lesson is the roadmap's requested **change-password shape**, not the registration shape: two
same-typed strings in scope, both directions tested. It has a real `Memory`-backed database so the
`PasswordHash` column round-trip is exercised end to end, and 5 test blocks in the gate.

---

## Part B — revised onboarding

### B1. Phase 1 — "stop the contradictions" — LANDED

| Defect (roadmap numbering) | Resolution |
|---|---|
| 1. README has two contradicting quick starts | `## Try the language today` deleted. README rewritten as a **119-line router** with a real, reproduced proof-error sample above the fold |
| 2. GETTING-STARTED never mentions `tesl init` | Rewritten around `tesl init` (485 → 190 lines). The `mkdir`/`touch` and "copy from a repository checkout" paths are gone |
| 3. Three different recommended first paths | README and `MANUAL.md` now name ONE. `TESL.md` folded in and deleted |
| 4. Counts have drifted three ways | All hand-typed counts removed; `manual/lessons.md` is now **generated** (see B2) |
| 9. No maintainer onboarding, and the nearest thing is wrong | `dev-docs/README.md` quick start rewritten: nix dev shell → `dune build` → `TESL_REPO_ROOT` (with the direnv/worktree trap) → PostgreSQL → **`./ci.sh` is the gate** |
| 10. The authoritative gate is not named anywhere | Named in `dev-docs/README.md` and `CONTRIBUTING.md`, with the two `exec` shims explained once |
| 12. Maintainer docs have their own hand-typed drift | "657+ Racket tests" removed from both sites |

**The doc-integrity check landed as its own script in the gate**, and it immediately earned its
place: **it caught a live regression in an in-flight rewrite.** The README rewrite had deleted two
headings that `LANGUAGE-SPEC.md:54,74` and `manual/FAQ.md:513` cite as anchors
(`#what-tesl-is-trying-to-achieve`, `#editor-and-language-server`); the check failed, the headings
were restored. Neither was in the roadmap's list of machinery to respect.

Final numbers from the first full scan: **278 relative links, 0 dead. 55 cited anchors, 3 dead
(all three the regression above, now green).**

**The biggest single gap it closed was not a check at all.** `manual/tests/test_embedded_docs.ml`
— 496 lines, 194 assertions, the best doc test in the repo — **was not wired into the gate at
all** and could not be reached by the root `dune test` either (it has its own `dune-project`). It
now runs as its own `ci.sh` phase. It needed `--force`: dune caches the alias against the `.ml`
file, but every assertion reads markdown, so a docs-only edit would otherwise not re-run it.

**Δ-B1.1 — `manual/anchors.md` had a SIXTH copy of the section list.** The section→file map was
duplicated in `main.ml` (four sites), `MANUAL.md` and `anchors.md`, and all six disagreed. The
`anchors.md` copy is deleted and now points at `MANUAL.md#manual-sections`, with
`tests/doc-integrity.sh` named as the enforcer that round-trips MANUAL.md ↔ the CLI in both
directions. `MANUAL.md` also gained the `intro`, `ai-testing` and `agent-handoffs` rows it was
missing — the CLI advertised sections the table did not list.

**Q-B1.1 — README headings are now de-facto contracted anchors.** Two of them have inbound
citations from `LANGUAGE-SPEC.md` and `FAQ.md`. They should be added to `manual/anchors.md`'s
stability table, or the citations retargeted. Left as a question because `LANGUAGE-SPEC.md` was
outside the rewriting worker's scope and preserving the headings was the safe call.

**A gotcha worth recording:** `tesl help manual language-spec` outputs 236 kB, and capturing that
into a shell variable makes the *next* `fork` fail with `E2BIG`, which surfaced as a phantom
`rc=126` on whatever ran next. The doc-integrity script redirects to a file, never a variable.

### B2. Lesson metadata and the generated catalog

**D5's decision implemented as specified: header comment, not a sidecar.** Two lines per lesson:

```
# lesson: track=<track> order=<int> needs=<slug,slug|none>
# summary: <one line>
```

`scripts/gen-lesson-index.sh` harvests them, validates, and generates `manual/lessons.md`; a
`--check` mode runs in the gate. This is the `scripts/gen-stdlib-rkt.sh` pattern the repo already
uses, so drift fails CI rather than accumulating.

Validation, all of which are real ambiguities rather than nits: `order` unique corpus-wide; every
prerequisite exists; no self-requirement; **a prerequisite must have a lower `order`** (or the
sequence tells a reader to go read something they have not reached); every featured lesson's
prerequisites are themselves featured.

**Δ-B2.1 — `order` is sparse (10, 20, 30…) and decoupled from the filename.** This is the
substance of D5's *"decouple order from the filename"* recommendation, but achieved **without the
75-file rename**. The roadmap costed that rename at ~75 renames + 75 module-name edits + 75
snapshot regenerations + ~110 reference updates + cross-lesson import fixes + embedded-doc key
churn — and concluded it should be paid once so that future reorders are "a metadata edit". Putting
the order in metadata delivers exactly that outcome; renaming the files as well delivers nothing
further, because once ordering lives in metadata the filename numbers are inert. So the filenames
stay, `lesson42-mutation-testing.tesl` keeps working with `ci.sh`'s hardcoded path,
`lesson07-consumer` keeps importing `Lesson07Home`, all ~110 `lessonNN` references keep resolving,
and the "I'm on lesson 12" affordance is retained rather than mitigated. **Recommend striking the
rename from the plan.**

**Δ-B2.2 — the featured set is EIGHT, not seven.** `lesson64-password-storage` is added.
`roadmap/completed/tesl_crypto.md` argues that *"in Tesl, storing the wrong password hash does not
compile"* is "the single best demonstration the proof system has"; leaving it out of a why-Tesl
showcase while including compile-time units would be hard to defend.

**Δ-B2.3 — "the featured seven declare no prerequisites" is implemented as "a featured lesson's
prerequisites are themselves featured".** The literal rule would have forced FALSE metadata into
the one place that is supposed to be the source of truth: `lesson12-records-with-proofs` genuinely
does build on `lesson05-intro-to-proofs`. Since lesson05 is itself featured, the restated invariant
delivers the same guarantee — the showcase is enterable cold and self-contained — while keeping the
metadata true.

**Δ-B2.4 — generated cold-entry blocks are delivered as the `needs=` line itself, not as a
generated region inside each source file.** The roadmap settled on generating a short "if you
jumped straight here" block into every lesson. A generated region inside 76 source files needs
marker delimiters, a regeneration story, and a way to stop someone hand-editing it — and it would
shift line numbers on every regeneration, invalidating 76 snapshots each time. The `needs=` line is
already human-readable in the file, and the generated index expands each prerequisite with that
lesson's own one-liner. Zero duplication, nothing to keep in sync, and it works for every lesson
rather than only the featured ones — which was the stated goal.

### B3. Phase 5 of the crypto item was extracted, not dropped

`roadmap/next/response_metadata_and_cookies.md` — re-verified after Crypto landed: there is still
no way to set a response header or cookie from a Tesl handler (`grep -c Set-Cookie dsl/web.rkt` →
0), and `LANGUAGE-SPEC.md:2269` documents the minimal response surface as intentional. With Crypto
shipped, `Session.sign` is `Crypto.signWith` and `Session.verify` is `check
Crypto.checkSignature` — both exist and are tested. **The genuinely new capability is the cookie
transport.** The item carries the two constraints that would otherwise be rediscovered too late:
the key must be an explicit parameter (never ambient `Env`), and the format needs a key id from day
one.

---

## CLOSED — the composability gap (was the one blocker)

### The `secret` keyword and `Tesl.Crypto` did not compose — now they do

Both features work in isolation. Together they do not, and the failing case is **the exact story
Phase 4 exists to deliver**:

```tesl
secret Password = String
record LoginBody { email: String, password: Password }

fn hashIt(body: LoginBody) requires [minting] -> PasswordHash =
  Crypto.hashPassword body.password
```
> `error[T001]: cannot unify Password with String`

```tesl
secret ApiKey = String
fn fpIt(k: ApiKey) -> String = Crypto.keyFingerprint k
```
> `error[T001]: cannot unify ApiKey with Secret`

So *"the plaintext password in a request body is the highest-value secret in the system"* can be
declared `secret` — and then nothing can be done with it. An app author's only options are to use
the stdlib `Secret` everywhere (which cannot be a request-body field of a domain-named type) or to
stop declaring their types `secret`, which is precisely the failure mode the roadmap names:

> The realistic outcome is not a filed issue — it is that they **stop declaring the type `secret`**
> and lose the protection entirely.

**The cause is that the roadmap's own subsuming rule was not implemented.** It says:

> **One checker rule subsumes that table:** *a `secret T` may be passed where a parameter explicitly
> marked secret-accepting expects a `T`. Nowhere else.* Opt-in is **per parameter, not per module** —
> `String.concat` is stdlib and must never accept a secret.

What was built instead is nominal-only: `Env.requireSecret : String -> Secret` and
`HttpClient.bearer : Secret -> …`, with `Secret` a single concrete stdlib type. That is a defensible
v1 for *key material* — `Secret` genuinely is the type for a signing key — but it leaves the
`secret` keyword with no route into any function, which is most of its value.

**Required fix**, and it is small and fail-closed:

1. A per-parameter table in `type_system.ml`: function name → the argument indices that accept a
   secret. Concretely `Crypto.hashPassword` [0], `Crypto.checkPassword` [1] (the *candidate*),
   `Crypto.signWith` [0], `Crypto.checkSignature` [0], `Crypto.keyFingerprint` [0],
   `HttpClient.bearer` [0], `HttpClient.secretHeader` [1].
2. One call-site rule: if a parameter is marked secret-accepting and the argument's type is a
   `secret X = T`, unify against `T` (with the stdlib `Secret`'s base being `String`) instead of
   against the declared parameter type. **Nowhere else** — `String.concat` must keep rejecting a
   secret, which is the test that proves the rule is a marking and not a hole.
3. Tests both ways: every secret-accepting sink accepts a user-declared secret with no intermediate
   `String`, and `String.concat` **rejects** one. The roadmap calls this "sink coverage" and says it
   is what proves the design is *usable*, not just safe.

Until this lands, `secret` is sound but nearly inert, and the honest description of the feature is
"declare it, store it, compare it, log it safely — but do not expect to hash it".

### B4. Phase 2 — the spine — LANDED

Three new documents, all wired into `MANUAL.md`, the four `main.ml` section-map sites, and
`dev-docs/README.md`:

- **`manual/first-change.md`** — the S3 document the roadmap calls "the single highest-value new
  document in the plan". Every diagnostic in it was **reproduced against the real binary**, not
  paraphrased.
- **`CONTRIBUTING.md`** — a router, as decided. Names `./ci.sh` as authoritative and explains the
  two `exec` shims once; states the trunk-based workflow and that there is no CODEOWNERS or review
  requirement, neither of which a newcomer can infer.
- **`dev-docs/12-your-first-compiler-change.md`** — the `W020` lap, starting at defect #2 (the
  missing machine-applicable fix).

**Δ-B4.1 — `first-change.md` builds something unvalidated and then opts into the proof**, rather
than deleting a `via` from the scaffold. `GETTING-STARTED.md` already uses the delete-a-`via` beat,
so repeating it would teach the same mechanic twice. The two-beat version makes the takeaway
*"unproven is allowed; falsely proven is not"* instead.

**Δ-B4.2 — the W020 improvement is DOCUMENTED, not shipped.** `linter.ml` / `error_codes.ml` /
`diag_fix.ml` were held by the concurrent security-lint work. The change was implemented and
gate-checked in a throwaway tree first, so the guide describes a verified sequence rather than a
guess, and it is written so that a reader who finds the fix already landed is told to pick another
defect from the same table.

**Three of my own briefing claims turned out to be wrong**, and the corrections are better material
than the originals:

1. *"Any fix-shipping code must be added to `Diag_fix.titled_codes` or `test_fix_titles.ml` fails"*
   — **false as stated.** That test discovers fix-shipping codes by compiling a **fixed 7-source
   corpus**, and none of those sources has a bad module name. Adding a W020 fix leaves the suite
   green; you must add a corpus entry *first*, and only then does it fail. This is now the guide's
   headline lesson — *check whether the test that guards this kind of thing can actually see your
   change* — which is a sharper instance of "single-source machinery punishes skipped steps" than
   the one I supplied.
2. **The fix-title standard has an undocumented fourth rule**: an *allowlist* of imperative verbs.
   `"Rename the module to …"` fails; `"Change the module name to …"` passes.
3. `error_codes.ml`'s W020 entry is at line 300, not 242.

**A real bug found in passing, and fixed:** `Compile.agent_diag_json` called `fix_to_json` **without
`~code`**, while `diag_to_json` passes it correctly. So every quick-fix an **AI agent** saw through
`agent-context` had a generic, edit-derived title (`Replace with \`TodoApi\``) while the identical
fix shown to the LSP had the real intent-bearing one (`Change the module name to \`TodoApi\``). For
a language positioned around its agent surface, that is the wrong half to degrade. One-line fix.

**Also found, not fixed:** a naive first-character-only W020 fix is **unsound as a fix** — it emits
`Todo_api`, which silences the warning without producing an UpperCamelCase name. Defects #2 and #3
in the W020 table are therefore coupled, which the guide now says explicitly.

### B5. Phase 4 — the browser-checking spike — FEASIBLE, and shipped

The roadmap's D7 thesis held. `tesl_compiler_lib` builds under `js_of_ocaml` and
`teslCheck(source) → JSON` is the browser equivalent of `tesl --check-json`, reusing the *same*
`Compile.check_source` + `Linter.lint_file` pair and the *same* `diag_to_json` serializer — so the
diagnostics array is byte-identical to the CLI's, and there is no second implementation to drift.

Measured: **5–10 ms warm for a 20-line snippet, 50–65 ms for a 500-line lesson.** Interactive.

**The `embedded_docs.ml` size fear was unfounded**, and the measurement is the useful part: the
2.3 MB manual is dropped entirely by dead-code elimination because the driver never references it.
Wiring up an in-page `tesl help` would cost **+6.2 MB raw / +1.55 MB gzipped** — so if that is ever
wanted, fetch the manual as a lazily-loaded JSON file rather than linking it into the bundle.

**The target is excluded from the default dune alias**, so plain `dune build`, `dune test`, `./ci.sh`
and the nix derivation never touch it and a machine without `js_of_ocaml` still builds the compiler
normally. Output is two static files with relative paths only — publishing is "copy `dist/` to any
static host", which honours the roadmap's host-agnostic constraint ahead of the planned forge move.

**Δ-B5.1 — the base artifact size is NOT written into the README.** `build.sh` reports it on every
build. A hand-copied size in a README is precisely the figure that drifts, which is the same defect
the generated lesson counts exist to kill; the *delta* above is the decision-relevant number and is
stable.

**Phase 3 (the static site) is deliberately not built.** It is the lowest-value remaining item — the
roadmap itself keeps the README canonical and says the site is "a nicer way to read the same
content" — and the honest cheap path is not obvious: a hand-rolled markdown renderer is a
maintenance liability that would need its own tests, and there is no dependency-free renderer in the
tree. Phase 4's page is a better nucleus for a site than a markdown pipeline would be, and it now
exists. Recommend re-scoping Phase 3 around it rather than building a parallel doc renderer.

**RESOLVED.** `Type_system.secret_accepting_params` is now a single exported table of
(function, argument index) pairs, and `Checker.secret_relaxed_param` is a decide-by-resolution rule
that fails closed on **four independent facts**: the name is in the table, *and* the index is
marked, *and* the argument resolves to a known secret type, *and* that secret's base type is the one
the parameter wants.

Verified both directions:

```tesl
secret Password = String
record LoginBody { email: String, password: Password }
fn hashIt(body: LoginBody) -> PasswordHash = Crypto.hashPassword body.password   # ✅ compiles
secret ApiKey = String
fn fpIt(k: ApiKey) -> String = Crypto.keyFingerprint k                            # ✅ compiles
```
```tesl
fn leak1(k: ApiKey) -> String = String.concat k "suffix"      # ❌ cannot unify ApiKey with String
fn leak2(k: ApiKey) -> String = Crypto.fingerprint k          # ❌ cannot unify ApiKey with String
```

`Crypto.fingerprint` rejecting a secret is the interesting one: it is in the same module, takes a
`String`, and is deliberately **not** marked — a content digest is not a secret sink, and a fast
digest of key material is not what you want. Also verified rejected: `checkPassword`'s slot 0 (the
stored hash, not the candidate), and `secret Code = Int` against `signWith` (right marking, wrong
base type). So the relaxation is a per-parameter marking, not a hole.

**One special case was needed and is the only one:** the stdlib `Secret` is declared in
`tesl/crypto.rkt` and therefore has no `ctx.type_aliases` row, so its base must be known to be
`String` for a user's `secret ApiKey = String` to satisfy `Crypto.signWith`.

### Three security judgements in the `secret` implementation worth recording

**1. `HttpClient.bearer` returns an opaque runtime value, not a plaintext string.** The signature is
`Secret -> Tuple2 String String`, which leaves all four HTTP verbs and the whole corpus untouched —
but the value half is an opaque `secret-header-value` struct with a custom writer that prints
`[redacted]`. The naive version leaks two ways: a plaintext string escapes via `Tuple2.second`, and
a bare `newtype-value` escapes via `~a`'s transparent struct print. Both are closed.

**2. `Env.requireSecret` mints through crypto.rkt's real `Secret` constructor** via
`dynamic-require`, not a hand-built `(newtype-value 'Secret …)`. The hand-built version carries a
bare symbol instead of the module-owned `type-ref` token, so it would satisfy neither the runtime
type predicate nor `secret-value?` — it would typecheck and then **silently fail to redact**, which
is the worst possible failure mode for this feature.

**3. Structural redaction is one opt-in parameter on one walker, not six re-implemented walks.**
`runtime-value->jsexpr` gained `current-redact-secrets?`, default **off** so persistence is
unaffected (asserted in both directions), and each sink switches it on with a single
`parameterize`. That also fixed a latent bug: record/ADT/newtype values previously fell through
telemetry's `[else value]` and emitted a raw struct rather than a jsexpr.

**Δ — the roadmap's "do not emit an encoder for a secret" is wrong.** Dropping the Elm decoder makes
the generated module fail to compile, because a request record's own decoder references it. The
encoder *is* the legitimate direction (a secret goes in), the client is outside the guarantee
boundary anyway, and enforcement is the checker's response-position rejection. TS drops the brand
instead, since a client cannot mint one.

**Roadmap open question 6 is moot**, not answered: because the checker rejects a secret in a
response position, the generators are never handed one, so no request-vs-response reachability walk
in `emit_ts`/`emit_elm` was needed at all.

### A4. Phase 0 — the `Security` category and the Tier-1 lints — LANDED

Three lints shipped, **three specified checks deliberately refused**, and the refusals are the more
interesting half — they are the governing rule actually being applied rather than quoted:

> A security lint ships only if it is **actionable**, **precise** (a clean codebase is COMPLETELY
> silent), and **about something Tesl can enforce**.

That rule bites much harder here than it looks, because **Tesl has no suppression mechanism of any
kind** — no per-site pragma, no `--strict`, no config key. A false positive cannot be silenced at
all; the only remedy is turning the whole linter off. So "slightly noisy" is not a tolerable state.

**Shipped:**

- **SEC001** — inside an `auth` body, request-derived data compared with a **string literal**. Audit
  L2's root stated exactly. Taint is structural over `.cookies`/`.headers`/`.queryParameters`,
  propagated through `let` bindings and `case` arm binders to a fixpoint — and **cleared by
  verification** (`Crypto.checkSignature`, `Crypto.checkPassword`, `JWT.verify`, any `check`/`auth`).
  That last part matters: without it the lint fires on its own recommended fix, since comparing an
  *already-verified* role against `"admin"` is correct authorization. `.body` and `.path` are
  deliberately not tainted — an `auth` comparing `.path` to a literal is route logic.
- **SEC003** — a string **literal** as key material (in `Secret`'s value position, or the key
  argument of `signWith` / `checkSignature` / `keyFingerprint` / `hmacSha256`). This is what stops
  `Secret`'s deliberate constructor (Δ-A2.2) from becoming a place to type a key.
- **SEC004** — comparing a `Crypto.signatureHex` result with `==`. This exists *because*
  `signatureHex` had to be added for transport (Δ-A2.1): `Signature` still has no `==`, and SEC004
  covers the hex escape hatch. `==` on `String` short-circuits at the first differing byte, so the
  comparison leaks how much of the tag the caller guessed.

**Refused, with reasons worth keeping:**

- **"an `auth` body mints a fact from an unverified request value"** — measured blast radius **21
  files** including both `tesl init` scaffolds and the review corpus. Refused because *every honest
  `auth` reads request data — that is what an `auth` is for.* The read is not the signal; the
  literal comparison is, which is what SEC001 keys on.
- **SEC002 (client-supplied role)** — a real privilege escalation in `admin-task-api.tesl`, and
  **not precisely detectable by `linter.ml`**: the chain crosses a function boundary through a record
  field, needing cross-function dataflow *and* type information, and the linter has neither. Closed
  the other two ways instead: the file is fixed (the role is now a claim inside a signed token, so
  the client cannot promote itself) and it is documented in `manual/best-practices.md` § Security
  under *"Never let the client declare its own privileges"* — which says plainly that Tesl cannot
  check this one for you. **Saying so is better than a check that half-works.**
- **SEC005 (`hashPassword` → `insert` without a `HashFor` parameter)** — implementable but not
  precise. The bug `HashFor` prevents only exists where several same-typed plaintexts are in scope;
  in an ordinary signup handler there is exactly one, so
  `insert User { passwordHash: Crypto.hashPassword body.password }` is clean code and a lint firing
  there is noise on a correct program.

**Eight files corrected** — the six the roadmap named **plus both `tesl init` scaffolds**, which
matter more than any lesson because they are what every new user starts from. `JwtSecret` is now
`define-secret-newtype`, so it redacts through all six sinks.

**Δ-A4.1 — the `Security` category is the NINTH, and its one silent coupling is now pinned.** The
`cats` list in `index ()` is not compiler-enforced: omit it and `tesl explain SEC001` works while
`tesl help codes` never mentions the category, and no test fails. There is now a test case for
exactly that.

---

## Part C — integration: what only showed up when everything was together

### C1. The playground broke gate phase 1, and the intended exclusion never worked

The js_of_ocaml target was excluded from the build with an empty
`(alias (name default))` override in `compiler/playground/dune`. **That does not work.**
`Library "js_of_ocaml" not found` is raised while dune *resolves* the rule, before any alias gets
to decide whether to build it — so plain `dune build`, and therefore **ci.sh phase 1**, failed on
every machine without js_of_ocaml. Which is exactly what the exclusion existed to prevent.

Worth recording because the failure mode is deceptive: the target *looks* opt-in, the README says
it is opt-in, and a developer who happens to have js_of_ocaml installed never sees the problem.

`%{env:…}` is the direct way to express "opt in" but needs `(lang dune 3.15)`; this project is on
3.0, and bumping the language version to gate one optional target would change defaults across the
whole build. So the gate is `(enabled_if (= %{profile} release))`, which needs no version bump:
everything that must keep working without js_of_ocaml uses the **dev** profile — plain `dune build`,
`dune test`, `./ci.sh`, and flake.nix's `dune build bin/main.exe` — while `playground/build.sh`
already passes `--profile release`. Cost, stated rather than hidden: `dune build --profile release`
now requires js_of_ocaml, and nothing in the repo does that.

### C2. The snapshot sweep, and one thing it caught

`scripts/regen-rkt-snapshots.sh` now exists, because the regeneration command was only ever
documented in prose and got retyped from scratch each time. **153 snapshots regenerated** — the
`hash` → `tesl-hash` emitter fix plus the line-number shifts from adding two metadata lines to every
lesson.

Two properties the scripted version has that the prose one did not:

- **write-only-on-success.** A compile failure must not truncate the committed snapshot, or one
  broken file becomes a corrupt diff across the whole corpus and the real error scrolls away.
- **idempotence, verified.** Running it three times: 153 changed, then 1, then 0. The second run
  mattered — a snapshot that changes on every regeneration would break the gate permanently, so
  "run it twice and expect zero" is now the check.

The orphan check is scoped to `example/learn` only. Applied to `tests/` it reported **53 false
orphans**, because that directory legitimately mixes generated snapshots (`jwt-tests.rkt`) with
hand-written rackunit suites (`tesl-test.rkt`, `web-test.rkt`, …). A warning that is wrong 53 times
trains the reader to ignore it — the same failure mode as a noisy lint, and the same fix.

**One more sweep gap, worth recording because it is silent.** The first version of the script used
`DIRS="example/learn example tests"` — and `example/*.tesl` does **not** glob into a subdirectory,
so `example/chat/` and `example/kanel/` (10 committed snapshots between them) were missed. That
surfaced as exactly one confusing gate failure — `ASSERT chat-backend.tesl: exact output mismatch at
line 79` — long after the sweep had reported clean. The directory list now mirrors ci.sh's own
(`LEARN_FILES` / `KANEL_FILES` / `CHAT_FILES` / `EXAMPLE_TOP_FILES` / `TEST_FILES`) and says so, so
the next person adding an example subdirectory has one place to look.

### C3. A live footgun found the hard way: `--build-dir` outside the repo truncates `embedded_docs.ml`

While measuring the playground artifact, a `dune build --build-dir` pointing **outside** the repo
silently truncated `compiler/lib/embedded_docs.ml` to `let files = []`.

The mechanism: `compiler/lib/dune`'s embedded-docs rule is `(mode promote)`, and
`compiler/gen/gen_docs.ml` finds the repo root by walking **up from its own path in the build
directory**. From `/tmp/...` that walk fails, `emit` is fail-open (a missing file is silently
skipped), so it produces an empty document list — and dune promotes the truncation straight into the
source tree. The whole manual disappears from the binary and nothing errors.

Restored from HEAD and re-promoted; `embedded_docs.ml` is 2 309 552 bytes with the manual intact.
`playground/build.sh` now hardcodes its build directory inside the repo with a comment saying why it
must never be configurable. **This is a live footgun for anyone using `--build-dir` in this repo,
playground or not**, and it is the reason the "Embedded-docs sync" gate phase exists — but that
phase only catches it if the truncation is not committed.

### C4. Gate status, stated precisely (FINAL)

`./ci.sh` — **17 of 18 phases OK.** The exception is phase 5, *Embedded-docs sync*, and it is
**not a correctness failure**: that phase is `git diff --quiet -- compiler/lib/embedded_docs.ml`,
i.e. a commit-hygiene check that the promoted snapshot has been committed. It cannot pass in a
working tree with uncommitted documentation changes, by design. Verified separately that the
snapshot is *current*: two consecutive `dune build`s leave it byte-identical.

Everything else, including every phase this work added or touched:

| Phase | |
|---|---|
| 1 Build, 2 Dune test | OK — 36 secret-surface + 6 security-lint cases among them |
| **3 Lesson catalog (new)** | OK — 77 lessons, metadata valid, index in sync |
| 6 Doc integrity (new) | OK — 278 links, 56 anchors, section map round-trips both ways |
| 7 Manual coherence (newly wired) | OK — 194 assertions that were orphaned from the gate |
| 8 Format, 9 Validate | OK — every lesson compiles, lints and is fmt-stable |
| 10 Exact-match snapshots | OK — **77 snapshots, 0 differ** |
| 11-14 Test blocks, mutation, integration, CLI smoke | OK |
| **15 CLI portability** | OK — including the new libsodium ratchet (resolves, resolves *lazily*, actionable hint when absent) |
| 16-18 Racket suites | OK — **`crypto-runtime-tests.rkt` and `secret-runtime-tests.rkt` both green in the gate** |

### C5. Two more client-triggerable 500s in `JWT.verify`, both fixed

Fixing the insecure examples meant they now actually verify signed tokens — which is how these
surfaced. Both are pre-existing bugs in `tesl/jwt.rkt`, not new ones, and both turn attacker-supplied
input into a 500 on a path where every other rejection is a 401.

1. **A malformed token raised instead of failing.** `Cookie: session=garbage` hit an uncaught
   `raise-user-error`, so **every JWT-protected endpoint had a client-triggerable 500** — and a
   distinguishable-response oracle. Now `check-fail … 401`, which required restructuring to a `let*`
   chain because `check-fail` propagates as a *return value*, not an exception.

2. **A non-numeric `exp` claim raised a contract violation.** `(< "1785355686959" now)` is a
   contract error, so a *well-formed, correctly signed* token with a string `exp` produced a 500.
   Now treated as **expired**, and the fail-closed direction is the point: skipping the check on an
   unparseable `exp` would mean a token whose expiry cannot be read is accepted **forever**.
   Unreadable expiry must mean expired.

**Q-C5.1 — `JWT.sign`'s typed surface cannot express a valid token.** It is
`Dict String String -> JwtToken`, but `JWT.verify` compares `exp` against the clock numerically. So
a Tesl program that puts `exp` in as a string signs tokens **its own verifier rejects** — previously
with a 500, now with a 401. The corpus only avoids this because it passes a record literal with a
numeric field, which the runtime accepts while the declared type says otherwise. Worth its own item:
either the type admits a number, or `sign` rejects a non-numeric `exp` at compile time.

**Q-C5.2 — a check-shaped stdlib call must be BOUND, not nested.**
`Dict.lookup "sub" (JWT.verify …)` hands `Dict.lookup` a raw `check-fail` struct instead of a
value. `lesson57-jwt.tesl` has this latent in three functions whose tests only ever pass valid
tokens. Not a crypto bug — a general gap in how check-shaped results compose — and worth its own
item.

### C6. Test-harness debt the security fix exposed

`tests/example-api-test.rkt` posted `Cookie: user=mikael` at `example/todo-api.tesl`, which now
demands a signed session. The harness therefore has to mint one **the way a real login endpoint
would** — `JWT.sign` over `{sub, exp}` with the key the app reads from `SESSION_JWT_SECRET` — rather
than hardcoding a token string, so the fixture stays valid when the token format or expiry rule
changes. 20/20 passing.

**Also fixed there: the app's capability closure was incomplete.**
`capability todoWebService` did not imply `envRead`, even though the auth path reads the signing key
from the environment, so `main` and the `auth` function each had to list `envRead` separately and
**every caller — including the test harness — needed to know the app's internals.** `envRead` now
comes via `implies`, which is what a service capability is for.

### C7. Two debugger tests hardcoded line numbers into a lesson — the metadata sweep broke both

`tests/dap-conditional-smoke.rkt` had `(define CHECK-LINE 90)` and
`tests/dap-headless-inspect-conditional-smoke.rkt` had the literals `99` and `114`, all pointing
into `example/learn/lesson61-step-debugging.tesl`. Adding two metadata comment lines to that lesson
moved every one of them onto a **comment**, so the breakpoints were armed on lines with no
checkpoint, nothing ever fired, and the failures read as
*"should receive a stopped event for n==100"* — pointing at the DAP server rather than at the line
number. 1/3 and 4/5 cases failed respectively.

Both now **derive** their lines by searching the lesson for the construct they mean
(`^check checkScore`, `^  if score >= 90 then`, `^fn computeGrade`), and error loudly with the file
name if it is not found. Adding a comment to a lesson can no longer break a debugger test.

Worth stating as a rule, because it was two tests and would have been more: **a test must never
hardcode a line number into a file other people edit.** The failure is silent at the edit site and
misleading at the assertion site, which is the worst combination.

I bisected this against the pre-change debugger files first and it failed identically, which is how
I know the structural-redaction work was not the cause — a useful check before blaming the most
recent change to the most relevant-looking file.

---

## Part D — what I recommend you change in the two roadmap documents

These are the decisions I would most like reviewed, because each one says the plan should change
rather than merely reporting that it was followed.

### In `roadmap/completed/tesl_crypto.md`

1. **Correct the foreign-hash claim.** libsodium verifies Argon2i/Argon2id **only**; scrypt is behind
   a different function with a different format, and PBKDF2 is absent. Both limits are now tests.
2. **`Signature` needs hex transport in both directions**, or the webhook-verification use case that
   justifies the whole of Phase 2 cannot be written. Add `signatureHex` / `signatureFromHex` to the
   stated surface, and add SEC004 as the compensating check.
3. **Drop "CI can promote the category to errors"** — no such mechanism exists.
4. **Reduce the Tier-1 lint list from five checks to three**, with the refusals recorded. Two of the
   five cannot be made precise, and with no suppression mechanism "imprecise" means "permanently
   noisy on a correct tree".
5. **Re-read `roadmap/discarded/rate-limiting.md` now.** The item says to do this when Phase 1 lands;
   it has landed, and `hashPassword` on an unauthenticated endpoint is exactly the amplifier that
   document is about. The input-length bound is a partial mitigation, not a substitute.

### In `roadmap/completed/revised_onboarding.md`

6. **Strike the `lesson64` renumber.** The gap is filled by a real lesson, for zero renames.
7. **Strike the 75-file lesson rename.** Ordering now lives in metadata, which is the outcome D5
   wanted; renaming the files as well delivers nothing further, because once ordering is in metadata
   the filename numbers are inert. It also preserves the "I'm on lesson 12" affordance the roadmap
   was willing to lose, and keeps `ci.sh`'s hardcoded `lesson42` path and the
   `lesson07-consumer` → `Lesson07Home` import working.
8. **Re-scope Phase 3 (the site) around the playground page** rather than building a second,
   markdown-rendering pipeline. There is no dependency-free markdown renderer in the tree, a
   hand-rolled one is a maintenance liability needing its own tests, and the roadmap already keeps
   the README canonical.
9. **Add the `ci.sh` phase the playground wants**, which is not "it builds": it is
   *`tesl --check-json` and `teslCheck` agree on a fixture set*. The real failure mode is silent
   divergence between the browser and the CLI — that is how the spike caught its own linter
   contributing nothing. A snippet is in `playground/README.md`.
10. **Record the README's two anchor-backed headings** in `manual/anchors.md`, or retarget the
    citations in `LANGUAGE-SPEC.md:54,74` and `manual/FAQ.md:513`. They are a contract now whether or
    not that was intended.

### Follow-up items worth filing on their own

| | Why |
|---|---|
| `.value` and arbitrary fields are **T_ANY** on `Int32`, `Money`, `PosixMillis`, `ExchangeRate` | A live fail-open class. `Crypto`'s three types are fixed; these are not |
| `Money n` typechecks as `String` | `"Money"` is in `known_qualifier_modules`, so the bare constructor resolves to a fresh type var |
| `JWT.sign : Dict String String` cannot express a numeric `exp` | So a program can sign tokens its own verifier rejects |
| A **check-shaped stdlib call must be bound, not nested** | `Dict.lookup "sub" (JWT.verify …)` passes a raw `check-fail` struct. Latent in three `lesson57-jwt.tesl` functions |
| ~~**W061 fires on a proof-only parameter**~~ | **NOT A BUG** — investigated and the change reverted; see Part E1. The warning found a hollow example of mine, and the linter already exempts a *self*-referential proof while correctly flagging a discarded obligation |
| `--build-dir` outside the repo **truncates `embedded_docs.ml`** | `(mode promote)` + a fail-open root walk in `gen_docs.ml`. Silent, and it commits the truncation |
| `jwt` is a capability on a pure HMAC | Known debt; recorded rather than propagated, since removing it breaks every `requires [jwt]` in the wild |

**A third instance of the same class:** `editor/tesl-mcp/tests/protocol-smoke.rkt` hardcoded `191`
**twice** — once to arm a conditional breakpoint on lesson61 and once to assert the line the server
reported back. The two-line metadata insertion moved the intended statement to 192, so the
breakpoint armed on a line where `n` is not yet bound, and the failure read
*"debug_inspect local n == \"-10\""* — as if the MCP debug surface were broken. Both now derive from
the source.

So: **three** tests across `tests/` and `editor/tesl-mcp/tests/` hardcoded line numbers into one
lesson file. Every one of them failed with a symptom pointing at the debugger rather than at the
line number. If a fourth appears, the fix is the same: search the source for the construct you mean
and error loudly if it is gone.

**The harness debt was wider than one file.** Three separate test sections posted plaintext cookies
at examples that now demand signed sessions: `tests/example-api-test.rkt` (todo-api),
`tests/tesl-test.rkt`'s admin-task section, and `tests/tesl-test.rkt`'s todo-api section. All three
now mint tokens the way a login endpoint would, via one shared `signed-session-cookie` helper.

The admin-task case is the interesting one: its old fixture sent `Cookie: user=anna; role=admin`,
i.e. **the client declaring its own role** — which was the privilege escalation being fixed. Testing
the 403 path honestly now means minting a *non-admin token*, not asking the client to claim it is a
non-admin. The test reads better than it did before, because the fixture can no longer express the
attack it was accidentally demonstrating.

`capability readTaskCookie` needed the same `implies envRead` treatment as `todoWebService`.

---

## FINAL gate result

```
  ✓  [1/18]  Build (dune build)                                   OK   21s
  ✓  [2/18]  Dune test (OCaml alcotest suite)                     OK  174s
  ✓  [3/18]  Lesson catalog (gen-lesson-index --check)      NEW    OK    3s
  ✓  [4/18]  Lifted-stdlib snapshots                              OK    0s
  ✗  [5/18]  Embedded-docs sync                                   FAIL  0s   ← see below
  ✓  [6/18]  Doc integrity (links, anchors, section map)    NEW    OK    3s
  ✓  [7/18]  Manual coherence suite (manual/tests)          WIRED  OK    0s
  ✓  [8/18]  Format (tesl fmt, in place)                          OK    2s
  ✓  [9/18]  Validate (compile + lint + format-check)              OK    1s
  ✓  [10/18] Exact-match .rkt snapshots                           OK    2s
  ✓  [11/18] Tesl test files (batch runner)                       OK   87s
  ✓  [12/18] Mutation testing (lesson42)                          OK   12s
  ✓  [13/18] Integration tests (httpclient + email)               OK   31s
  ✓  [14/18] tesl CLI smoke                                       OK    6s
  ✓  [15/18] CLI portability + libsodium ratchet            EXT    OK    6s
  ✓  [16/18] Racket suites (debugger / MCP / lifted / AI)          OK   97s
  ✓  [17/18] Racket aggregate suite (tests/all.rkt)                OK  162s
  ✓  [18/18] Boot smoke (App activation via tesl run)              OK   11s
```

**Phase 5 is the only failure, and it is not a correctness failure.** The phase is
`git diff --quiet -- compiler/lib/embedded_docs.ml` — a check that the promoted docs snapshot has
been **committed**. It cannot pass in a working tree with uncommitted documentation changes, and this
tree has 317 changed files including a rewritten README, a new manual page, a new lesson and a
generated lesson catalog.

Verified separately that the snapshot is **current, not stale**: two consecutive `dune build`s leave
it byte-identical, at 2 310 117 bytes with the manual prose present. So the phase will go green on
the commit that lands this work, with no further action.

I did **not** commit, because I was not asked to.

---

## Part E — follow-up items, fixed

The user asked for all seven follow-ups from Part D to be fixed. Three were mine; the rest went to
workers and are recorded below them.

### E1. W061 on a proof-only parameter — **INVESTIGATED, CHANGE REVERTED, no bug**

I first "fixed" this by exempting every proof-carrying parameter from W061, then re-derived it when
challenged and **reverted the change.** The warning was correct and the linter is more precise than I
credited. Recording the reasoning here because the symptom is genuinely tempting.

**The motivating instance was a TRUE positive.** My first draft of `lesson64` was:

```tesl
fn storeNewPassword(newPassword: String, hash: PasswordHash ::: HashFor newPassword) -> String =
  Crypto.fingerprint newPassword          # hash never touched
```

That function accepts a hash and throws it away. W061 found a **hollow example**, not a false
positive. The correct fix was the one I had already made for other reasons — give the lesson a real
database so `storeNewPassword` actually writes the hash to a column — after which W061 went quiet
with no linter change at all.

**W061 already draws exactly the right line.** It collects names used in the body **and in every
parameter's proof annotation**, and that distinction is the whole design:

| Shape | W061 | Why that is right |
|---|---|---|
| `x: T ::: P x` | quiet | the proof names `x`, so `x` counts as used. The witness-only pattern — *"I need proof someone authenticated, not who"* — needs **no escape at all** |
| `h: H ::: P otherParam` | **fires** | the proof names something else, so `h` really is dead weight: you demanded a hash *of that plaintext* and discarded it |

The second row is precisely the Crypto shape. So the check is not "unused parameter" naively applied
to proofs — it distinguishes a witness from a discarded obligation.

**Measured before reverting:** with the exemption in place, W061 fires on **zero** files across
`example/`, `example/learn/`, `example/chat/`, `example/kanel/`, `templates/` and `tests/`. So the
exemption had **no beneficial instance** in the entire corpus, while it did silence a real design
smell. That is the wrong trade in both directions at once.

**And the escape works anyway**, verified end to end: `_user` compiles, satisfies an `api` block's
route wiring, and silences W061 — so even if a witness-only case did need it, the documented
mechanism is already there.

Net result: `linter.ml` is unchanged from HEAD except for a comment recording this investigation, and
`test_linter.ml` gains **two tests pinning the existing line** (self-proof quiet, relational-and-unused
flagged) — coverage that did not exist before and that will now fail if anyone re-adds the exemption.

**The lesson for me, not the codebase:** I treated a warning on my own draft as a linter defect
instead of reading what it was telling me about the draft. The tell was there — the "fix" required
special-casing the exact shape the language is built around, which is usually a sign the warning has
found something real.

### E2. `--build-dir` outside the repo can no longer truncate the manual — FIXED

`compiler/gen/gen_docs.ml`'s repo-root walk returned the starting directory unchanged after 8 levels
— a fail-open default. Combined with `(mode promote)` and a per-file `emit` that silently skips
missing files, a `--build-dir` outside the repo produced `let files = []` and dune wrote that
**empty document list back into the source tree**, deleting the whole manual from the binary with no
error. It actually happened during this work.

Now returns `None` and **aborts with `exit 2`** and a message naming the likely cause. Verified by
running the generator from `/tmp`: it refuses instead of emitting. A missing root is never a
legitimate state — this generator only ever runs from dune inside the repo — so aborting is the only
safe answer.

### E3. The `jwt`-on-a-pure-function debt is recorded where it will be found — DOCUMENTED, and
removal REFUSED

`roadmap/completed/capability_completeness.md` now carries the ruling. To be explicit, since the
instruction was "fix them all": **I did not remove the `jwt` capability, and I recommend not
removing it.** It is a breaking change to every `requires [jwt]` in the wild — a declaration that
becomes unnecessary is a compile error under the unused-capability checks, so every existing JWT
program needs editing for **zero** safety gain. `roadmap/completed/tesl_crypto.md` reached the same
conclusion independently ("do not churn it").

What was missing was not the fix but the *record*: nothing said "`jwt` is grandfathered, do not infer
the rule from it". Now `Tesl.Crypto`'s pattern is named as the one to copy, and
`test_capability_registry.ml`'s oracle fails if a pure Crypto function is ever gated — which is the
actual enforcement, rather than a comment.

---

## Part F — the playground, published (user request)

### F1. `.github/workflows/playground.yml` — build and publish to Pages on every push to `main`

**The workflow is a thin caller, not the build.** `roadmap/completed/revised_onboarding.md` requires the
output stay host-agnostic — "no GitHub-specific plugins, no Actions-only build logic, no
Pages-specific path assumptions" — so a forge move is a CI-config change rather than a rewrite. All
the logic is in `playground/build.sh`, which a developer runs identically; the workflow enters the
flake dev shell, runs that script, checks the artifact, and hands the directory to Pages. Only
`.nojekyll` is GitHub-specific, and it is created in the workflow rather than by the script for
exactly that reason.

**The published URL is deliberately not cited anywhere in the repo.** Per D1 and Phase 3, the README
stays the one canonical link: a `*.github.io` address has to be abandoned at the planned forge move,
and an abandoned URL is worse than none.

Four pre-deploy assertions, each tied to a regression rather than to "did it build":

| Assertion | What it catches |
|---|---|
| `teslCheck` is exported | the page loads and every check silently does nothing |
| `lessons.html` exists **and links every lesson** | a lesson lost its metadata header, or `python3` was absent and `build.sh` skipped the index with only a warning |
| artifact **< 2 MB** | something referenced `Embedded_docs`, tripling the bundle (measured 1 127 187 B → 3 424 269 B, so the threshold has a wide margin) |
| artifact > 200 KB | a truncated build |

**Δ-F1.1** — my first version detected the embedded manual by grepping the bundle for a prose string.
That string came from `TESL.md`, which this same work **deleted**, so the check would have silently
passed forever. Replaced with the size ceiling, which I can justify from measured numbers rather than
from a marker I cannot verify without building. Worth recording as a small lesson: a content marker
is only as good as your ability to test that it is still there.

### F2. Every lesson is one click from the browser checker

`playground/gen-lessons-page.py` generates `lessons.html`: all 77 lessons, grouped by track in
reading order, each linking into the playground **with its source already in the share fragment**.

**A separate page rather than a picker inside the playground** — the user's own refinement, and it is
the better design on three counts:

1. It costs the playground page **nothing**. The corpus is 750 KB raw / 190 KB gzipped, comparable to
   the entire compiler bundle. The embedded-manual measurement already taught this: keep large
   content out of the thing that has to load fast.
2. Every lesson gets a **stable permalink** — which is what Phase 3 actually asked for ("lessons
   rendered with … a stable permalink each"). A dropdown selection is not a URL you can send someone.
3. It reuses the **existing** share-hash mechanism rather than inventing a second path for source to
   reach the playground.

The order, the titles and the prose all come from the `# lesson:` / `# summary:` headers — the *same*
single source `manual/lessons.md` is generated from — so the two catalogs cannot disagree and adding
a lesson needs no edit here. Prerequisites render as links to those lessons' own playground pages.

Verified: 77 links, largest fragment ~12 KB (raw deflate, byte-compatible with the browser's
`CompressionStream("deflate-raw")`), and `lesson64`'s fragment decodes **byte-exactly** back to the
file on disk. No fragment has a length that `atob` would reject.

`lesson07-consumer` is **flagged in the index**, not silently omitted: it imports a sibling module and
the browser checker works on one buffer at a time. A reader should know before clicking.

---

## Part G — the follow-up sweep found more than the seven items

### G1. `print` removed from the surface language

Maintainer's decision, and the right one. `print` was ambient (no import), typed `t_fun [_a] t_unit`,
and a bare type variable unifies with anything — so `print mySecret` typechecked and wrote the
plaintext to stdout, defeating the whole `secret` guarantee. Removed from `stdlib_env`, the
always-available list, `stdlib_docs_entries.ml`, and **W090 deleted with it** (a lint for a name that
cannot exist is unreachable code that only confuses). `print x` is now
`error[T001]: unknown name: print`, which is a stronger diagnostic than the warning was. Zero call
sites in the corpus, so no migration.

**It was worse than first measured:** while a call-site rejection was briefly implemented, the worker
confirmed the stdlib's own `Secret` and `JwtSecret` leaked through `print` too, because
`ctx.secret_types` only tracks `secret`-keyword declarations. Removing the name closes that as well —
an argument for removal over rejection that I had not thought of.

Two fixtures depended on it and both now assert something stronger: `test_review74_gibberish`'s PY04
went from "W090 warns" to "the name does not exist", and `test_s13_fail_closed_boundary`'s Unit-return
fixture uses the `Unit` value instead of borrowing a sink it never needed.

### G2. The bare-`TVar` sweep — clean, with two adjacent findings

All **321** `stdlib_env` rows enumerated; **26** have a bare type variable in a parameter slot. **None
of the other 25 renders or serialises it.** They partition cleanly into wrap-shaped (`Something`,
`Ok`, `Tuple2`, …, where the secret stays a secret and stays subject to the wire rejection),
identity-shaped (`identity`, `const`, `attachFact`, …), caller-supplied callback slots (writing an
`a -> String` for a secret needs `.value` or interpolation, both already rejected), name-position
arguments (`deadJobs` takes a queue name), and `decodeAs`, which is the inbound direction the design
explicitly permits.

**Q-G2.1 — `Set.member` on a secret: RESOLVED, not a problem.**
Raised as a possible timing gap and closed after reading the representation.
`tesl/set.rkt` uses Racket's **immutable `equal?`-based hash sets**, so
`set-member?` is hash-then-compare: the hash is computed over the *whole*
candidate, and `equal?` runs only against keys in the same bucket.

That destroys the oracle. The attack `==`-on-a-secret is lowered to a
constant-time compare to prevent is **prefix extension** — submit candidates,
measure, learn how many leading bytes matched, iterate one byte at a time. Through
a hash set, a candidate differing from a real key in its last byte lands in an
unrelated bucket and never reaches a byte comparison, so there is no
"guess one more byte" primitive. Reaching the compare at all requires a hash
collision with a real key, which is not a prefix step.

Residual, stated so it is not mistaken for a guarantee: the hash is computed over
the secret and its cost varies with the value's **length** — and length is not the
thing being protected. So this is "no usable oracle", not "constant-time".

**The reason is a property of the REPRESENTATION, not of the API**, so it is now a
comment in `tesl/set.rkt` warning against switching to a list- or assoc-backed
set. On a list-backed set the oracle would be real. That comment is the actual
deliverable here — a future performance change is exactly how this would silently
become a vulnerability.

**Q-G2.2 — `asTool` unverified.** `asTool : a -> Tool` derives a JSON schema from the referenced
function's *parameter* types. Its argument is a function reference rather than a value, so no leak
was demonstrable, but nobody has confirmed that a secret-typed parameter on an `asTool`'d function is
treated as inbound-only. Worth a look by whoever owns the agent surface.

### G3. Two more live bugs, found by tightening

**`example/learn/lesson43-orderable-types.tesl:127` never worked.**
`fn createdBefore(t1: PosixMillis, t2: PosixMillis) = t1.value < t2.value`, sitting directly under a
comment claiming *"PosixMillis supports `<` directly."* The committed snapshot proves it: it emitted
`(< (raw-value t1.value) (raw-value t2.value))` with `t1.value` as a **bare unbound Racket
identifier**. It typechecked only because `.value` on a stdlib nominal type was T_ANY. Now `t1 < t2`,
which is what the comment always said.

**`example/user-service-api.tesl`'s `jwtAuth` returned a `check-fail` struct instead of a 401.**
`Dict.lookup "sub" (JWT.verify token secret)` — the nested check-shaped call. This was the **live auth
function on every protected endpoint** in that example: a garbage cookie handed `Dict.lookup` a
`check-fail` struct as though it were a value. Found by the new nested-call rule, not by review.

### G4. Corrections to my own briefs, from the workers

- **`JWT.verify` is check-SHAPED without being check-NAMED.** It was in neither registry, so the rule
  as I specified it would not have caught the lesson57 bug at all.
- **The nested-call rule needs TWO hook sites.** A function body's *tail* expression goes through
  `check_expr`'s generic call arm, never `infer_expr`'s — and the repro is a tail.
- **An arity guard is mandatory.** Without it the rule killed `List.filterCheck (checkInRange 0 100) xs`,
  which is the entire purpose of `filterCheck`/`allCheck`. Found by `dune test`, not by the corpus.
- **`known_qualifier_modules` could not simply be trimmed.** It has a second consumer — the
  unbound-name walker treats a dotted name as one unit — and `MoneyRate` is a pure qualifier with no
  same-named type, so removing it there would have broken `MoneyRate.perHour`. A separate derived list
  was the right shape.
- **`Time.posixToMillis` does not exist**; I invented it in the brief. The real surface is
  `Time.posixToSeconds` / `diffMs` / `formatTime`, and that is what the diagnostics name.
- **Only 2 of the 3 flagged `lesson57` functions were real** — the third used `JWT.decode`, which does
  not verify and is not check-shaped.

**Q-G4.1 — `Units_catalog.quantity_modules` has the `Money n` hole too.** 13 of its 14 entries are
alias type names, so `Length 5` still typechecks as anything. Deliberately not changed: quantities are
import-gated and hijack-checked through a different mechanism (`active_aliases`), so it deserves its
own pass.

---

## Part H — roadmap reorganisation

`roadmap/next/` went from four items to two.

| Item | Moved to | Why |
|---|---|---|
| `tesl_crypto.md` | **completed/** | Phases 0-4 landed; Phase 5 extracted to its own item. Header now records that Phase 2's `Authentic`-on-`JWT.verify` piece was initially missed and reported as landed when it was not, and is now implemented |
| `primitive_gaps_and_outbound_hardening.md` | **completed/** | Every item resolved. Items 1, 2 and 4 shipped earlier; item 3 was `Tesl.Crypto`; **item 5 (`Bytes`) closed by deciding not to do it** — the crypto surface returns hex/`String`, so nothing needs a real binary type. One item closed by a decision rather than by code is still closed, which is why this is *completed* rather than split |
| `revised_onboarding.md` | **completed/** | Phases 1-4 all landed. Header carries a per-phase table, the two recommendations its own analysis produced that were deliberately **not** followed (the `lesson64` renumber and the 75-file rename, both made unnecessary by putting ordering in metadata), and pointers to where the scoped-out and discarded parts went |
| `lesson_splits.md` | **discarded/** (new) | Six evidence-backed candidates preserved so reopening does not mean re-reading the corpus |
| `response_metadata_and_cookies.md` | **stays in next/** | Genuinely blocked and not started — crypto's Phase 5, extracted |
| `playground_polish_and_adoption.md` | **new in next/** | Phase 3's real remainder plus the adoption items, scoped to the checking playground, with the runnable-version door explicitly left open |

**Δ-H.1 — `revised_onboarding.md` was NOT split.** The instruction allowed splitting, and I considered
carving the incomplete parts into a successor item. There was nothing left to carve: Phase 3 is
complete as delivered, the human trials are out of scope by decision, the splits are discarded, and
the one genuine remainder became its own item. A successor holding only "syntax-highlight the lesson
pane" would have been a worse home for it than the playground item, which has the surrounding context.

### Two stale references the move exposed

- **`manual/best-practices.md` told users outbound HTTP has no timeout.** *"Tesl's HTTP client does not
  yet take a timeout … Until outbound timeouts land"* — but that was item 1 of
  `primitive_gaps_and_outbound_hardening.md` and it **shipped**. So the manual was advising a
  workaround for a limitation that no longer exists, and pointing at a roadmap path. Rewritten to
  describe the deadlines that now exist (`TESL_HTTP_CONNECT_TIMEOUT_MS`, `TESL_HTTP_TIMEOUT_MS`,
  `TESL_HTTP_STREAM_IDLE_TIMEOUT_MS`) and to keep the advice that still holds — a bounded failure is
  not a removed failure, so a flaky upstream still wants its own queue.

  Worth noting how this survived: the doc-integrity check verifies links and anchors *resolve*, not
  that prose is still **true**. A completed roadmap item is exactly when that kind of claim goes
  stale, and nothing catches it.

- **12 files referenced the moved paths** (`ci.sh`, four compiler/runtime source comments, the
  playground docs and workflow, and the roadmap files themselves). All repointed.

### One adjustment to the doc-integrity check

Its hand-typed-count rule fired on this log — `"77 lessons, metadata valid"` — which is a **finding**,
not drift. Dated `IMPLEMENTATION-LOG-*.md` files are now exempt from that rule for the same reason
`roadmap/` is excluded from the whole scan: they record what was measured on a day, and a record that
may not state a measured number is useless. Their links and anchors are still checked, which is the
part that can actually rot.

---

## Part I — the final gate run found two more real bugs

Both were introduced-or-exposed by the follow-up work, and both would have shipped silently because
each worker verified `--check` but not the lessons' **test blocks**. Phase 11 of `./ci.sh` is what
caught them, which is the argument for the lessons being regression tests rather than prose.

### I1. `<` on `PosixMillis` never worked, and the language advertised that it did

`Checker.ty_is_ord` admits `TCon ("Int" | "Float" | "PosixMillis")` and every dimensioned quantity —
but generated code emitted a **bare Racket `<`**. A `PosixMillis` is a `newtype-value` at runtime
(`tesl/time.rkt` wraps it in both `nowMillis` and `secondsToPosix`), and `raw-value` deliberately does
**not** strip a newtype wrapper because the SQL layer depends on that. So:

```tesl
fn createdBefore(t1: PosixMillis, t2: PosixMillis) -> Bool = t1 < t2
```
> `<: contract violation; expected: real?  given: (newtype-value … PosixMillis 1000000)`

**This is issue #28's class at a second site.** That issue fixed `>=`/`<=` on a newtype *column
inside a SQL where-clause* — `unwrap-non-null` did not strip `newtype-value` while `==` did. The
identical gap existed on the plain **expression** path and was never closed, because `==` routes
through `tesl-equal?` (which unwraps) while the ordered operators routed nowhere at all.

Fixed by giving them a home: `tesl-lt?` / `tesl-le?` / `tesl-gt?` / `tesl-ge?` in
`tesl/private/runtime.rkt`, which strip the wrapper and are **fail-closed** — a non-real operand
raises a named error naming the likely cause (a `ty_is_ord` bug) instead of surfacing Racket's
contract violation. 88 snapshots regenerated; idempotent.

**How it stayed hidden, and a correction to a worker's claim.** The lesson previously read
`t1.value < t2.value`, which *worked* — `.value` on a stdlib nominal type was T_ANY, and the emitted
`t1.value` resolved. The checker worker changed it to `t1 < t2` and reported that the old form "never
worked", citing the committed snapshot. **That was wrong**: I checked out the previously committed
`.rkt` and it loads and passes. What was true is that closing the `.value` hole removed the only
working idiom *without* providing a replacement — so the tightening was right and incomplete, and
this is the missing half.

### I2. `JWT.verify` — the argument-normalisation bug again, in a second module

`string-split: contract violation; given: (newtype-value … JwtToken …)`.

`tesl/jwt.rkt` unwrapped its arguments as
`(raw-value (if (newtype-value? token) (newtype-value-value token) token))` — testing for the wrapper
**before** resolving. A `named-value` wrapping a `JwtToken` falls through the `if`, `raw-value`
unwraps the *named-value*, and the result is still a `newtype-value`.

**Latent until the `Authentic` retrofit made `JWT.verify` check-shaped**, which changed how call sites
pass the argument. This is byte-for-byte the bug recorded as A3/Bug 3 in this log, fixed in
`crypto.rkt` earlier the same day — four occurrences of the wrong order in `jwt.rkt`, all now routed
through one `jwt-raw-string` helper whose comment states that **the order is the whole point**.

Two independent modules made the identical mistake within hours, which says the idiom needs to be
findable: `tesl/string.rkt`'s `raw-str` is the house pattern, and it is worth a line in
`dev-docs/05-adding-stdlib-function.md`. Recorded as a follow-up rather than done here.

### I3. The snapshot sweep's directory list was wrong three times — now derived

`scripts/regen-rkt-snapshots.sh` started with a hand-written
`DIRS="example/learn example tests"`. That silently skipped `example/chat` and `example/kanel`
(`example/*.tesl` does not glob into a subdirectory); after adding those it still skipped
`tests/bench`. Each omission surfaced as exactly **one** confusing gate failure —
`ASSERT proof_hot.tesl: exact output mismatch` — long after the sweep had reported clean.

Three misses on the same list in one day is a signal about the list, not about the misses. It is now
**discovered**: every directory containing a committed `.rkt` with a sibling `.tesl`. That is the
definition of "holds a snapshot", it cannot drift, and a new example subdirectory needs no edit. An
explicit argument still overrides for a fast single-directory loop.

### I4. Three tests asserted the emitted comparison text

`test_integration.ml` pinned `(> *n 0)`, `(> 5 3)` and `(> (raw-value n) 0)` as byte-exact emitter
output; the ordered-comparison fix changes them to `tesl-gt?` / `tesl-le?`. Updated. Worth noting the
tests did their job — they are exactly the tripwire that says "you changed the emitted form", and the
right response was to confirm the new form is correct and re-pin it, not to loosen the assertion.

---

## Follow-ups still open at the end of this session

| | |
|---|---|
| **`Set.member` / `Dict` keyed by a secret** | RESOLVED as not-a-problem (Q-G2.1) — hash-then-compare removes the prefix oracle. The reason is now a comment in `tesl/set.rkt`, because it is a property of the representation |
| **`asTool` schema** | RESOLVED and now tested (`test_astool_schema.ml`, 30 checks) — a secret parameter is impossible by construction, only 6 primitives are admitted |
| `Units_catalog.quantity_modules` has the `Money n` T_ANY hole | 13 of 14 entries are alias type names, so `Length 5` still typechecks as anything. Import-gated through a different mechanism; deserves its own pass |
| `JWT.verify` should charge `time` | It reads the clock. Propagating it would touch every JWT-authenticated endpoint's capability closure — recorded and pinned by a test so a future change is deliberate |
| **The `raw-value`-first idiom needs documenting** | Two independent modules (`crypto.rkt`, `jwt.rkt`) made the identical argument-normalisation mistake within hours. `tesl/string.rkt`'s `raw-str` is the house pattern; it belongs in `dev-docs/05-adding-stdlib-function.md` |
| JWT `exp` unit migration | Hard-broken to RFC seconds as authorised. Any deployed token minted before this is now read as long expired — correct for beta, worth a release note |
| The playground parity CI phase | `tesl --check-json` vs `teslCheck` on a fixture set. Specified in `playground/README.md`; the spike measured 29/30 byte-identical. Not wired up |

### I5. My discovery-based sweep clobbered three hand-written stdlib shims

The fix for I3 — deriving the snapshot directory list instead of hand-maintaining it — introduced a
worse bug than the one it fixed, and it is worth recording in full because the failure signature
pointed nowhere near the cause.

`tesl/list.rkt`, `tesl/list-prim.rkt` and `tesl/either.rkt` sit beside `tesl/list.tesl` and
`tesl/either.tesl`, so the "a `.rkt` with a sibling `.tesl`" test matched them. But they are
**hand-written shims** that re-export a generated `*-derived.rkt` — not snapshots. The sweep replaced
each shim with a compile of the Tesl source, and the whole stdlib stopped loading:

> `tesl/list.rkt:18:11: only-in: identifier 'ListPrim.head' not included in nested require spec`

which then failed **48 lesson test blocks** with an error naming none of this. Restored from HEAD;
`tesl/` and `dsl/` are now excluded from discovery with the reason written at the exclusion.

Three things worth taking from it:

1. **The repo already knew this.** "`tesl/either|list.rkt` are hand-written shims, never blind-regen"
   was recorded from the issue-#40/41/42 work. I derived a rule from file *shape* when the real
   distinction is file *provenance*, which shape cannot see.
2. **A derived list is not automatically safer than a hand-written one.** It removed one failure mode
   (forgetting a directory) and added a worse one (including a directory that must never be touched).
   The right form is derived-plus-explicit-exclusions, which is what it is now.
3. **The lifted stdlib needs its own generator run.** `tesl/list-derived.rkt` comes from
   `scripts/gen-stdlib-rkt.sh`, whose output has a *different basename* from its input, so no sibling
   rule can find it. After any emitter change both scripts must run — the ordered-comparison fix
   changed the emitted `<`, and running only the snapshot sweep left `ci.sh` phase 4 red. That
   two-script rule is now stated in the script header.

**Process note on my own method here.** I reused one log path for concurrent gate runs, so a
completed run's summary overwrote a running one's and I briefly read a stale "5 phases failed" as
current. Trivially avoidable, and it cost a cycle of misdirected investigation. Final verification
runs to a distinct path.
