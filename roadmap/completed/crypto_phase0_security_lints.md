# Crypto Phase 0 — the `Security` diagnostic category, the Tier-1 lints, and the insecure examples

**Landed 2026-07-29.** Implements `roadmap/next/tesl_crypto.md` § *Phase 0 — Stop the bleeding*
and § *Security lints* (Tier 1). No language surface added; one new diagnostic category, three
lints, eight corrected `.tesl` files, one one-line runtime change.

`roadmap/discarded/security_hardening_audit.md:160` (**L2**) recorded *"`auth` is a crypto-free
trust root; insecure session pattern … No built-in signed-session / secure-cookie primitive"*.
The dangerous half of L2 was the **guidance**, not the missing primitive: the plaintext,
guessable session cookie (`cookies "user" == "admin"`) had propagated into the corpus people copy
from, including both `tesl init` scaffolds. That half is now closed. The remaining half — setting
an `HttpOnly` / `Secure` / `SameSite` response cookie — is blocked on a response-metadata language
feature and is tracked separately (see `roadmap/next/tesl_crypto.md` § Phase 5).

---

## The governing rule, which decided everything below

> A security lint ships only if it is **actionable** (one obvious fix, ideally machine-applicable),
> **precise** (a clean codebase is COMPLETELY silent), and **about something Tesl can enforce**.
> Anything failing those belongs in documentation.

A noisy security lint is **worse than none** — it trains people to ignore the whole category — and
Tesl has **no suppression mechanism of any kind** (verified: nothing in `linter.ml` or
`error_codes.ml` implements per-site suppression, and there is no `--strict`, env var or config
key). So a false positive cannot be silenced at all; the only remedy is turning the whole linter
off. That asymmetry is why two of the five specified checks were refused rather than shipped.

---

## Shipped

### The `Security` category

`compiler/lib/error_codes.ml` gained a ninth category, `Security`, with the `SEC` prefix, so
`tesl help codes` groups security findings apart from style lints and a reader can tell what kind
of finding it is from the code alone.

Three couplings had to be updated, and only two of them are compiler-enforced:

| Site | Enforced? |
|---|---|
| the `category` variant | — |
| `category_name` | **yes** — exhaustive match, a new constructor is a compile error |
| the `cats` list in `index ()` | **no** — the one silent coupling. Omit `Security` there and `tesl explain SEC001` works while `tesl help codes` never mentions the category, and no test fails. Now commented as such, and pinned by `test_security_lints.ml`'s `SECURITY group is in \`tesl help codes\`` case |

`summary_line`'s `"  %-9s %-11s %s"` needed no change: `SEC001` is 6 chars and `(security)` is 10,
inside the 11-wide field.

### SEC001 — authorization decided by comparing request data with a string literal

Fires inside an `auth` body when a value derived from `request.cookies` / `.headers` /
`.queryParameters` is compared with `==` / `!=` against a string literal. This is audit L2's root
stated exactly. **The most valuable single check in the item.**

Taint is structural (any subexpression reading one of those three fields taints the whole
expression) and is propagated through `let`/`let (… ::: …)` bindings and through `case` arm pattern
binders when the scrutinee is tainted, to a fixpoint. Tesl forbids shadowing
(`LANGUAGE-SPEC.md §13.2`), so a flat per-declaration name set is sound and needs no scope
threading.

**Taint is cleared by verification** — `Crypto.checkSignature`, `Crypto.checkPassword`,
`JWT.verify`, or any `check` / `auth` call. Without that, the lint would fire on its own
recommended fix (comparing an already-verified role against `"admin"` is correct authorization),
which is the fastest possible way to get a category ignored.

`.body` and `.path` are deliberately **not** tainted: an `auth` comparing `.path` against a
literal is route logic, and a request body is validated by a `check`, not an `auth`.

### SEC003 — a string literal used as key material

Structural, never entropy guessing: a string literal in the value position of `Secret`, or in the
**key** position (first argument) of `Crypto.signWith` / `Crypto.checkSignature` /
`Crypto.keyFingerprint` / `Crypto.hmacSha256`.

`Secret` has a constructor on purpose (`IMPLEMENTATION-LOG-crypto-and-onboarding.md` § Δ-A2.2) —
something must be able to mint one from a config read. SEC003 is what stops that constructor from
becoming a place to type a key. Entropy scanning was refused by the roadmap itself: the
known-answer NIST/RFC vectors in `tests/crypto-runtime-tests.rkt` would light it up permanently.

### SEC004 — timing-unsafe MAC comparison

Fires when a `Crypto.signatureHex` result is compared with `==` / `!=`, directly or through a
`let`. `==` on `String` short-circuits at the first differing byte, so the comparison time leaks
how much of the correct tag the caller guessed.

This check exists because `Crypto.signatureHex` / `signatureFromHex` had to be added for outbound
and inbound transport (`IMPLEMENTATION-LOG-crypto-and-onboarding.md` § Δ-A2.1) — a MAC tag is
public data, so both directions are safe, but the residual risk
`Crypto.signatureHex a == Crypto.signatureHex b` is expressible. `Signature` itself still has no
`==`; SEC004 covers the hex escape hatch.

---

## Specified and deliberately NOT shipped

### "an `auth` body mints a fact from an unverified request value"

**Measured blast radius: 21 files** containing `Dict.lookup "<key>" <req>.cookies`, including
**both `tesl init` scaffolds** (`templates/minimal/app.tesl`, `templates/api/app.tesl`), nine
lessons the roadmap does not name, and the `tests/critical-review-48-*` review corpus. (The
roadmap's suggested grep, `cookies "`, matches nothing at all — the real spelling is
`Dict.lookup "<key>" <req>.cookies`.)

Refused because **every honest `auth` reads request data** — that is what an `auth` is for. The
read is not the signal; the *literal comparison* is, which is what SEC001 keys on. With no
suppression mechanism, a legitimate fixture (a review corpus file that deliberately models the
bad shape, a test double) could not be silenced, so the category would be permanently noisy on a
correct tree. It fails the precision clause outright.

### SEC002 — an authorization decision made from a client-supplied role field

The live demo was `example/admin-task-api.tesl:52-57`, where the client declared its own `role`
cookie and the handler at `:61-69` trusted it for the admin branch — a real privilege escalation.

**Not precisely detectable by `linter.ml`.** The decision chain is
`auth` reads `request.cookies "role"` → stores it in a record field → the record crosses a
function boundary as a handler parameter → the handler reads the field → compares it with a
literal. That needs cross-function dataflow *and* the type information to know which record field
corresponds to which auth binding; the linter has neither (no types, essentially no dataflow). The
available proxy — "a field named `role` read out of `request.cookies`" — is a name-based Tier-2
check, which the roadmap defers to Phase 4 behind the suppression mechanism, and correctly so.

So it was closed the other two ways: **the file itself is fixed** (the role is now a claim inside
a signed token, i.e. the client cannot promote itself), and it is written up in
`manual/best-practices.md` § Security under *"Never let the client declare its own privileges"*,
which says plainly that Tesl cannot check this one for you.

### SEC005 — a `Crypto.hashPassword` result reaching `insert` without a `HashFor`-constrained parameter

Implementable — `insert` is an ordinary `EApp` with head `EVar "insert"`, and callee parameter
annotations are available in the AST — but **not makeable precise**, which is the binding
constraint.

The bug `HashFor` prevents is hashing the **wrong one of several same-typed plaintexts in scope**,
and that only exists in the change-password and password-reset shapes. In the ordinary signup
handler there is exactly one plaintext in scope, so hashing the wrong one is impossible, and
`insert User { passwordHash: Crypto.hashPassword body.password }` is clean code by any reasonable
standard. A lint that fires there is noise on a correct program.

Narrowing it to "two or more plaintext candidates in scope" requires either types (which locals
are `String`) or the Tier-2 curated name list (`password`, `newPassword`, `oldPassword`, …). Both
are Phase 4 work, and the name-list version needs the suppression mechanism. Filed there rather
than shipped half-precise. `HashFor`'s residual gap is therefore still open, and is now stated as
such in `manual/best-practices.md` § Security → *Passwords*, which shows the constraining
signature.

### No structured fixes on any shipped code

The roadmap asked for machine-applicable fixes "where possible", and for SEC004 specifically. On
inspection, none of the three admits an in-place edit that would compile:

- **SEC001** — the fix is a verification the linter cannot synthesise (it does not know the key,
  the payload, or where the session is minted).
- **SEC003** — the fix is `Secret (requireEnv "…")`, and the environment variable's **name** would
  have to be invented.
- **SEC004** — the correct rewrite is `check Crypto.checkSignature key sig payload`, which yields a
  proof-carrying value, **not** a `Bool`. The offending comparison is almost always an `if`
  condition, so replacing it in place changes the type of the condition and stops compiling. The
  surrounding control flow has to be restructured.

A quick-fix that does not compile is worse than prose, so all three ship with a message that names
the exact replacement shape and a `best-practices#security` deep-link instead. Consequently
`Diag_fix.titled_codes` needed no new entry and `test_fix_titles.ml` is unaffected.

---

## Measured blast radius

Over **154 files** (`example/*.tesl`, `example/learn/*.tesl`, `example/chat/*.tesl`,
`templates/*/app.tesl`, `tests/*.tesl`):

| Check | Diagnostics before the fix | After |
|---|---|---|
| SEC001 | **1** (`example/learn/lesson06-proof-check-proof-auth.tesl:89`) | 0 |
| SEC003 | 0 | 0 |
| SEC004 | 0 | 0 |
| **total** | **1** | **0** |

**The roadmap's claim that the auth lint "fires on six real files today" is wrong** — the real
number is **one**. The other five Phase-0 files never compared a cookie against a literal; they
minted the authentication fact *directly* from the cookie value, which is the broad lint that was
refused above. They were just as insecure; they were simply not detectable by a precise check. That
is worth remembering as a general lesson: the six files were found by reading, not by grepping, and
the lint that would have flagged all six is the one that cannot ship.

SEC003 and SEC004 are zero because no `.tesl` in the corpus used `Tesl.Crypto`'s keyed operations
before this change; they are ratchets against the code people are about to write now that the
module exists.

---

## The eight files

Two honest shapes were used, chosen per file rather than uniformly:

- **`Crypto.checkSignature`** (payload cookie + `sessionSig` cookie, verified in constant time,
  yielding `Authentic payload`) — used where showing the primitive *is* the point.
- **JWT** (one `session` cookie, `JWT.verify` checks the HMAC **and** the `exp` claim and auto-401s,
  claims travel inside the signature) — used everywhere a role or several claims are needed, since
  it is one cookie instead of two and it is what `example/learn/lesson57-jwt.tesl` already teaches.

| File | What it looks like now |
|---|---|
| `example/learn/lesson06-proof-check-proof-auth.tesl` | The `auth` verifies a signed session with `check Crypto.checkSignature` inside the `auth` body — deliberately, because the lesson's subject is the three proof-minting kinds, and "a `check` nested in an `auth`, converting *the server signed this* into a domain fact" is exactly on topic. Still teaches `check`/`establish`/`auth`; one comment block explains why the old `userId == "admin"` was wrong |
| `example/learn/lesson55-testing-auth-and-capabilities.tesl` | Still a lesson about testing auth. `JWT.verify` replaces the pass-through; a `mintSession` helper signs a token so an api-test can produce a valid cookie, and **two api-tests were added** (3 → 5, all passing): a made-up cookie value is rejected, and a *well-formed token signed with the wrong key* is rejected. The first of those is the test that would have PASSED against the old version, which is precisely why the old version was not authentication; the second is the only one that actually exercises the signature check. The signing key is written in the file, with a comment saying it is there only so the lesson's tests are self-contained (an env read would make the lesson's own tests depend on an unset variable in CI) |
| `example/todo-api.tesl` | `auth cookieAuth` reads a `session` cookie and takes the user id from the verified `sub` claim. `capability todoReadHttpCookie implies jwt`; the auth gained `envRead` |
| `example/admin-task-api.tesl` | The privilege-escalation demo is gone: **both** the subject and the role are now claims inside the signed token, so editing a cookie invalidates it. A comment states that a client-sent value is a *request* to be an administrator, never evidence of being one |
| `example/ai-conversation-service.tesl` | Consumer identity comes from the verified `sub` claim, which is what makes the file's own cross-consumer isolation tests mean something. `provider` and `apiKey` stay as request inputs on purpose — a preference and the consumer's own BYOK key, with nothing authorized on their basis — and that is stated in a comment |
| `templates/minimal/app.tesl` | The `tesl init` minimal scaffold verifies a signed session; the role is a signed claim rather than a second cookie. Carries a `READ THIS BEFORE YOU CHANGE IT` comment naming the old hole and showing the `JWT.sign` call that mints the token |
| `templates/api/app.tesl` | Same, and the comment points out that the `sub` claim living inside the signature is what makes the file's `todo.ownerId != requestUser.id` ownership check mean anything |
| `tesl/jwt.rkt` | `(define-secret-newtype JwtSecret String)`, plus a client-triggerable-500 fix — see below |

### Two things found by making the fix actually run

Both were caught by lesson55's new forged-cookie api-tests, which is the argument for having them.

**1. `JWT.verify` raised on a structurally malformed token** — `raise-user-error` for "expected 3
dot-separated parts", and an unguarded `base64url-decode` on the signature and payload segments.
The token comes off the wire, so `Cookie: session=garbage` produced an uncaught exception: a **500
on every JWT-authenticated endpoint, triggerable by any client**, and an oracle distinguishing
"not a token" from "wrong signature". Since this Phase-0 change routes four shipped examples and
**both `tesl init` scaffolds** through `JWT.verify`, shipping that would have traded one hole for
another. Every other rejection in the function was already `check-fail … 401`; these three now
agree with them, matching `Crypto.signatureFromHex`, which the crypto work made
"malformed input fails the verification cleanly; it never raises" for exactly this reason. Pinned
by lesson55's *"rejects a made-up cookie value"* api-test.

Fixing it also required restructuring the function body: `check-fail` propagates as a **return
value**, not an exception, so `(unless … (check-fail …))` discards it and execution continues into
`list-ref`. The internal `define`s became a `let*` chain so every rejection is genuinely the
function's result.

**2. A `check`-shaped stdlib call must be BOUND, not nested.** `check-fail` propagation happens in
`wrap-runtime-named-binding` (`dsl/web.rkt:331`), i.e. at a `let`. So
`case Dict.lookup "sub" (JWT.verify token secret) of …` hands the raw `check-fail` **struct** to
`Dict.lookup`, which fails with a type error instead of returning 401. The fix in every touched
file is `let claims = JWT.verify …` first, then read the claims out of `claims`.

This is a **latent trap in the existing corpus**, not something this change introduced:
`example/learn/lesson57-jwt.tesl`'s `getUserFromToken` / `decodeToken` / `wrapAndVerify` all nest
`JWT.verify` inside `Dict.lookup`, and their tests only ever pass valid tokens, so the failure path
is untested. It is a `fn` rather than an `auth`, so it is not currently on a request path — but the
lesson is what people copy. Worth its own small item: either make the nested form work, or make
the checker reject it.

**3. `Dict.fromList [["k", v]]` does not typecheck** — the list-of-pairs spelling in
`example/learn/lesson57-jwt.tesl`'s step-1 comment is wrong (`cannot unify List with Tuple2 a`);
the real form is `Dict.fromList [Tuple2 "k" v]` with `import Tesl.Tuple exposing [Tuple2]`, or
`Dict.singleton "k" v` for one entry. That comment had been copied into the scaffolds by this
change and is corrected there; the lesson-57 original is left for whoever owns that file.

Supporting edits, because a scaffold whose README no longer works is its own kind of defect:

- `templates/{minimal,api}/tesl.toml` — a `SESSION_JWT_SECRET = "CHANGE-ME-dev-only"` row in
  `[env]`, with a comment saying to replace it, keep the real value out of version control, and
  rotate it there rather than in the source (which is what `SEC003` reports).
- `templates/{minimal,api}/README.md` — the `curl -b 'user=alice'` examples now show the 401 they
  correctly produce, plus a new **Authentication** section stating that a bare `cookies "user"`
  check is not authentication, explaining that the scaffold ships the *verify* half and not the
  *mint* half (who may sign in is the one thing a scaffold cannot guess), and giving the `JWT.sign`
  snippet for a login route.
- `templates/README.md` — the template table says *signed-session `auth`*, not *cookie `auth`*.

All five `.rkt` snapshots for the touched examples were regenerated and are byte-exact;
`example/learn/lesson57-jwt.rkt` is unchanged by the `JwtSecret` redaction (the change is
runtime-side only).

---

## `JwtSecret` redaction

`tesl/jwt.rkt:44` became `(define-secret-newtype JwtSecret String)`. That macro is
`define-newtype` plus a registration in `dsl/types.rkt`'s secret-type registry, so it is purely
additive at runtime: identical representation, identical SQL round-trip, `.value` still works
(verified — `example/learn/lesson57-jwt.tesl` and `tests/jwt-tests.tesl` compile unchanged and
their snapshots do not move), and `(secret-value? (JwtSecret "abc"))` is now `#t` while
`(secret-value? (JwtToken "…"))` stays `#f`.

The redaction **sinks** — telemetry, the three debugger surfaces, structured logging — are owned by
the concurrent `secret`-keyword work and are not touched here. This declaration is what makes
`JwtSecret` visible to them.

`JwtSecret "…"` is deliberately **outside** SEC003's scope. SEC003 covers the `Secret`-typed key
positions of `Tesl.Crypto`. Extending it to `JwtSecret` would fire on every test in
`example/learn/lesson57-jwt.tesl` (which needs a fixed key to assert determinism), and with no
suppression mechanism that is unsilenceable noise on the file that teaches JWT.

---

## Documentation

`manual/best-practices.md` gained a **`## Security`** section — a new stable anchor,
`best-practices#security`, which every `SEC0xx` entry deep-links to. Per the contract in
`manual/anchors.md`, the anchor was also added to that file's table and given its own case in
`manual/tests/test_embedded_docs.ml`, so losing the heading fails the build instead of silently
dead-linking the whole category.

The section covers: *a cookie check is not authentication* (with the wrong and right shapes side by
side, and a table of the three honest options), *never let the client declare its own privileges*
(the undetectable one, stated as the reader's job), keys from the environment, verify-don't-compare
tags, passwords and `HashFor`, and a closing subsection on **what Tesl deliberately does not
check** and why — so a reader who wonders "why doesn't the compiler catch X?" finds the answer
rather than assuming X is safe.

---

## Tests

`compiler/test/test_security_lints.ml` (6 cases, all green):

- the `SECURITY` group appears in `tesl help codes` — the silent `cats` coupling;
- every `Security` entry explains, deep-links, and is `SEC`-prefixed;
- **each check as a pair**: a positive fixture that must fire and a negative fixture — the honest
  version of the same program — that must be completely silent. A ratchet with only the positive
  half is satisfied by a lint that fires on everything. SEC001 gets four negatives specifically,
  including *comparing an already-verified value against a literal* and *a literal comparison
  outside an `auth`*;
- **the precision claim as a test**: the whole shipped corpus (`example/`, `example/learn/`,
  `example/chat/`, `templates/*/`, `tests/`) must produce **zero** SEC diagnostics. This is the
  case that will fail if someone widens a check, and it is why "a clean codebase is completely
  silent" is now a property of the build rather than a measurement somebody took once.

---

## Notes for whoever picks up Phase 4

- The suppression mechanism is the **gating prerequisite** for anything name-based, and it is also
  what would let SEC002/SEC005 ship in a narrowed form. It should be narrow and greppable — a
  specific code at a specific site, with a reason — never a file- or project-wide off switch. A
  security suppression is an assertion that the author considered the finding, and should read
  like one.
- Linter diagnostics get `manual = None` and a **zero-width span** (`linter.ml`'s tail sets
  `end_line = d.line; end_col = d.col`), so a Security lint's editor squiggle is one character
  wide and its manual link comes solely from the `error_codes.ml` entry. Widening the span for the
  whole linter is a small, separate improvement.
- The security pass runs **first** in `lint_file`, with its own `try … with Failure _ -> ()`. The
  outer `try` covers every pass together, so a pass appended at the end silently never runs once
  an earlier pass raises on a lexer-fatal buffer — the wrong failure mode for a security finding.
  Keep it first.
