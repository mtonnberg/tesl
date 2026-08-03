# Session witness gate — bind the credential to the subject (Password & Machine `loginMethods`)

## Status
Next (design reviewed 2026-08-03: do it, ship A+C as one unit — see
Recommendation and the SSO-interaction section). An earlier prototype
(2026-07-31) was **rejected as unsound** (see below).
Companion to `roadmap/next/ensure_sso_works.md` (Open Questions 15/18; Risks
46/56/63/64) and `roadmap/later/fail_closed_mint_matching_structural.md`. The SSO
flow, the `loginMethods [Sso]` fail-closed allowlist, and the machine-credential
`Machine` keyword are already landed; what is missing is the enforcement that a
`[Sso, Password via <fn>]` / `[…, Machine]` server mints an app session ONLY for a
subject a real credential check authenticated.

## Motivation
Under `loginMethods [Sso, Password …]` the compiler today only checks that the
policy function exists, plus a **presence allowlist**: the phase-3 scan
(`validation_structural.ml:1768`) walks the module for `Http.setSessionCookie` /
`Crypto.checkPassword` occurrences and rejects them under a server whose
`loginMethods` doesn't declare the matching method. That gates WHERE minting
happens, and is silent about WHO. The canonical login is unforced:
```tesl
if credentialsAreGood body then
  let token = JWT.sign (Dict.singleton "sub" body.user) (signingKey())
  let _ = Http.setSessionCookie token          # no evidence body.user authenticated
```
`credentialsAreGood : Bool` is a forgeable recognisable shape and `JWT.sign` will
sign any claims, so the session is minted with zero kernel evidence. This is the
mixed-mode bypass (Risks 46/56/63/64). We want the session-minting chokepoint to
DEMAND a runtime-minted witness that the subject logged in via a declared method.

## What we prototyped, and why it was rejected
Approach: `Http.setSessionCookie` demands `subject ::: LoggedIn subject`, where
`LoggedIn` is owned by a new `Tesl.Auth` module and minted only by check-shaped
combinators fed by an existing verification fact:
```tesl
Auth.passwordSession : (verified ::: PasswordVerified verified) (subject: String)
                     -> subject ::: LoggedIn subject
```
It built, and fired correctly for the bound case. **But it is unsound**, because
`Crypto.checkPassword stored candidate` mints `PasswordVerified stored` bound to
the stored HASH, not to any subject. The `subject` is an INDEPENDENT argument:
```tesl
let verified = check Crypto.checkPassword attackerHash attackerPassword
let subject  = check Auth.passwordSession verified "admin"   # LoggedIn "admin" (!)
let _        = Http.setSessionCookie subject token
```
type-checks — an attacker verifies their OWN password and mints a session for
`"admin"`. Privilege escalation. A sound-looking but forgeable witness is worse
than the current, honestly-documented gap, so the prototype was reverted.

## The root cause, stated once
`LoggedIn subject` is only meaningful if the credential fact that produces it is
itself **about that subject**. Every existing verification fact is bound to key
material or to an opaque payload, never to an identity:
`PasswordVerified stored`, `Authentic payload`, `Authentic claims`,
`ProxyBound presented`. The fix, in every proposal below, is to introduce a fact
that names the subject and can only arise from material the store has tied to
that subject.

Note the SSO path is ALREADY soundly bindable and needs none of this: the
runtime-owned callback derives the subject from the IdP's verified claims and
mints the session itself (not app code), so `[Sso]`-only is complete today.

## Proposals

### Proposal A — identity-bearing credential record; derive the subject (RECOMMENDED)
Remove the free subject argument entirely: the session combinator returns the
subject that lives INSIDE the verified credential, so there is nothing to forge.
```tesl
# Opaque, like PasswordHash — no user constructor, so a (subject, hash) pair
# cannot be assembled by hand.  Only the store lookup mints one.
type Credential

Auth.credentialFor : (subject: String) -> Maybe Credential          # requires [dbRead]
# Constant-time verify; on success returns the credential's OWN subject,
# carrying LoggedIn.  401/None otherwise.
Auth.passwordLogin : (cred: Credential) (candidate: String) -> String ::: LoggedIn <cred.subject>

# Machine is identical, keyed by installation:
Auth.machineCredentialFor : (installationId: String) -> Maybe Credential   # requires [dbRead]
Auth.machineLogin         : (cred: Credential) (presentedToken: String) -> String ::: LoggedIn <cred.subject>
```
Because `Auth.credentialFor` is keyed by the subject, the returned `Credential`
provably belongs to it, and `passwordLogin` yields `LoggedIn` for exactly that
subject. To obtain `LoggedIn "admin"` you must hold admin's `Credential` AND its
correct password. `Http.setSessionCookie (subject ::: LoggedIn subject) token`
then compiles only downstream of a real login.
- Pros: kills the root cause (no independent subject); smallest possible attack
  surface; mirrors the opaque-`PasswordHash` precedent; ergonomic.
- Cons: introduces a typed credential-store surface (`Credential` + two lookups +
  two logins) and a runtime credential table shape. Set-side (signup/reset) must
  be the only writer of `Credential`, gated the same way.

### Proposal B — subject-bound verification predicate (`VerifiedFor subject`)
Keep separate lookup + check, but make the fact carry the subject via
cross-parameter binding, reusing the existing `HashFor`/`SameCurrency` machinery.
```tesl
# The lookup proves the hash belongs to the subject:
Auth.storedHash : (subject: String) -> Maybe (PasswordHash ::: CredentialFor subject)   # requires [dbRead]
# checkPassword's success fact is now ABOUT the subject:
Crypto.checkPasswordFor : (subject: String)
                          (stored: Maybe PasswordHash ::: CredentialFor subject)
                          (candidate: String)
                        -> Bool ::: PasswordVerifiedFor subject
Auth.passwordSession : (v: Bool ::: PasswordVerifiedFor subject) (subject: String)
                     -> subject ::: LoggedIn subject
```
Even though `subject` is still passed to `passwordSession`, the DEMANDED proof
`PasswordVerifiedFor subject` names that same binding, and it can only exist if a
`CredentialFor subject` (store lookup keyed by subject) preceded it. An attacker's
own credential yields `PasswordVerifiedFor attacker`, so
`passwordSession thatProof "admin"` fails the `PasswordVerifiedFor "admin"`
demand. Escalation blocked by cross-param naming.
- Pros: reuses the existing cross-parameter proof machinery (the `Dict.get` /
  `SameCurrency` shape); no new opaque type; additive to `Crypto`.
- Cons: more surface pieces to keep consistent; two ways to check a password
  (`checkPassword` vs `checkPasswordFor`) invites picking the unbound one — so the
  unbound `checkPassword` may need to be disallowed at a session mint.

### Proposal C — bind the token too (`SubjectOf token subject`) — REQUIRED COMPANION
Not defence-in-depth: **A (or B) without C is still bypassable**, so A+C ship as
one unit. Make `setSessionCookie` additionally demand that the witnessed subject
equals the token's `sub` claim:
```tesl
Http.setSessionCookie : (subject: String ::: LoggedIn subject)
                        (token: JwtToken ::: SubjectOf token subject) -> Unit
```
Why A alone is insufficient (2026-08-03 analysis): the cookie's effective
identity is the token's `sub`, not the witness, and `JWT.sign` signs any claims.
So any user who can legitimately log in as THEMSELVES can sign a token with
`sub = "admin"` and call `setSessionCookie ownLoggedIn adminToken` — the witness
gate passes, the session is admin. A alone only proves "someone logged in", not
"this cookie is that someone". Conversely C on its own does NOT fix the
unbound-subject hole (an attacker forges both to the same `"admin"`), so neither
half is standalone. `SubjectOf` is minted by the session-token builder from the
same subject it stamps into `sub`.

### Proposal D — whole-module dataflow (WEAKER FALLBACK)
Under a `loginMethods` server, require the EXACT `subject` value flowing into
`setSessionCookie` to be def-use-linked to the subject produced by a credential
check in the same function (a precise def-use taint on the same value, not merely
"a check happened somewhere"). This is the structural route the header-trust
discharge also needs (see `fail_closed_mint_matching_structural.md`). The sixth
review disfavours recognisable-shape discharges, but a same-value def-use link is
materially stronger than the SEC006-style presence check that was rejected. Use
only if a typed credential surface (A/B) is judged too heavy.
- Pros: no user-facing contract change; no new types.
- Cons: dataflow analysis to build and defend; harder to prove sound; drifts as
  the language grows (the exact failure mode the kernel-witness approach avoids).

## Recommendation
Ship **Proposal A + Proposal C as a single unit** (identity-bearing `Credential`
with the subject derived from the verified credential, plus the `SubjectOf`
token binding). A removes the forgeable free-subject argument — the root cause —
and matches the opaque-type precedent; C closes the token/witness divergence
that would otherwise leave A bypassable by any legitimately-logged-in user (see
Proposal C). Neither is optional. Keep **Proposal B** as the lighter alternative
if introducing a new opaque `Credential` type is considered too much surface —
but note B carries a decide-by-spelling trap (two ways to check a password;
picking unbound `checkPassword` fails open), and its mitigation (disallow the
unbound form at mint sites) makes it nearly as heavy as A. Keep **Proposal D**
only as a last resort. The SSO callback path is already sound and unchanged.

## SSO interaction (verified in code 2026-08-03)
- **No breakage risk from the new `setSessionCookie` demand:** the SSO callback
  mints its session inside the runtime (`dsl/web.rkt` `sso-route` struct,
  `mint-session`), never through typed app-level `Http.setSessionCookie`, so the
  proof demand cannot touch the SSO path.
- **SSO makes this gate MORE urgent, not less:** mixed-mode
  `[Sso, Password via fn]` is the SSO-era feature, and without the witness gate
  adding `Password` to an SSO server plants an arbitrary-mint hole next to a
  sound SSO path. This gate is what makes mixed mode honest.
- **Corpus churn is confined to the Password path:** `setSessionCookie` appears
  only in `example/learn/lesson76-sessions.tesl` and
  `tests/session-cookie-tests.tesl`; the SSO lessons (78/80) never call it.

## Implementation findings (probed 2026-08-03, before writing any of it)

These were established empirically against the current compiler and remove the
main design unknown, but the work itself is NOT started.

- **`LoggedIn` must be minted by an AUTH-shaped row, not a check-shaped one.**
  Proposal A derives the subject from inside the credential, so the fact lands on
  a value the combinator PRODUCES rather than on one of its arguments. Every
  check-shaped stdlib row today attaches its fact to a PARAMETER
  (`PasswordVerified stored`, `Authentic payload`, `ProxyBound presented`), and a
  `check` whose return binder is not an input is rejected —
  `check login(...) -> subject: String ::: LoggedIn subject` fails with
  `T001: unknown name: subject`. The `auth` form is exactly the one that produces
  its subject, and the same shape compiles clean as `auth`. So
  `Auth.passwordLogin` / `Auth.machineLogin` are AuthKind.
- **That makes them the FIRST AuthKind stdlib rows.** `stdlib_func_infos` contains
  zero `fi_kind = AuthKind` entries today, so the machinery that consumes auth
  producers is currently only ever fed USER functions:
  `collect_auth_predicates`, `check_auth_proof_via`, the auth-drop /
  positional-slot integrity checks in `check_server_completeness`, and
  `Checker.stdlib_check_shaped_names` (which filters on CheckKind only). Each is a
  place a stdlib AuthKind row may need threading, and none of it is exercised
  today — budget for that rather than assuming the rows just drop in.
- **`Http.setSessionCookie` goes from arity 1 to arity 2** with a proof demand on
  each parameter (`type_system.ml:1002`, currently
  `mono (t_fun [t_jwt_token] t_unit)`). Put the `LoggedIn` subject FIRST so a
  1-arg call is a hard type error rather than a silent no-op (the prototype
  lesson, recorded below).

## Blocking decisions (must be settled BEFORE coding)

Both are in Open Questions below and both change a security-critical PUBLIC
surface, so guessing costs more than asking. The doc's own history is the
argument: a prototype was built, found forgeable, and reverted — "a sound-looking
but forgeable witness is worse than the current, honestly-documented gap".

1. **Where the credential store lives.** Proposal A implies a runtime credential
   TABLE with a fixed shape (`Auth.credentialFor` is keyed by subject and returns
   an opaque `Credential`). Is that a first-class `Tesl.Auth`-owned table, or does
   the app keep its own entity and only the subject-bound FACT get standardised
   (Proposal B)? This decides whether `tesl/auth.rkt` owns a schema, and it is not
   reversible once apps store credentials in it.
2. **Set-side gating.** Signup / password-reset must be the only writers of a
   `Credential`. Does writing one need its own capability + policy (Risk 64)? A
   verify path gated while the create path is open is a half-closed gate.

## Where it plugs in (any proposal)
- `compiler/lib/type_system.ml`: new `Tesl.Auth` rows + module-owned row +
  `tesl_known_module_names`; the `Http.setSessionCookie` demand (arity/proof).
- `compiler/lib/validation_common.ml`: check-shaped `stdlib_func_infos` entries
  minting the subject-bound fact and `LoggedIn`.
- `compiler/lib/proof_checker.ml`: `LoggedIn` (and any `CredentialFor` /
  `PasswordVerifiedFor`) owned by `Tesl.Auth`, minted ONLY by these sites and NOT
  in `proof_discharge`'s `stdlib_auto_preds` (fail-closed).
- `compiler/lib/validation_structural.ml`: keep the `[Sso]`-only refusal; add
  per-method attribution so a witness combinator whose method is not declared in
  this server's `loginMethods` is refused (the allowlist stays exhaustive).
- Runtime `tesl/auth.rkt` (+ the credential-store shape) and `tesl/http.rkt`;
  `emit_racket.ml` module→file map; `stdlib_docs_entries.ml`.

## Gotchas / must-verify
- The escalation regression is the acceptance test: an attacker verifying their
  OWN credential must NOT be able to mint `LoggedIn` for another subject.
- Second acceptance test (the A-without-C bypass): a user holding a valid
  `LoggedIn` for themselves must NOT be able to set a cookie whose token was
  signed with a different `sub` — `setSessionCookie ownLoggedIn adminToken` must
  fail the `SubjectOf` demand at compile time.
- `setSessionCookie` demand placement: put the proof-carrying argument FIRST so a
  partial application cannot silently skip it (a 1-arg call must be a hard type
  error, not a no-op — learned from the prototype).
- Corpus churn is real and intended: `example/learn/lesson76-sessions.tesl`,
  `tests/session-cookie-tests.tesl`, the `templates/*` READMEs and
  `compiler/test/test_session_cookie.ml` must be migrated to a real login flow and
  their byte-exact `.rkt` snapshots regenerated; api-test round trips must stay
  green (`ci.sh` emits each `tests/*.tesl` → `raco test`).
- `LoggedIn` must be minted by the runtime-owned SSO callback too (it already
  mints the session itself; expose the fact at the proof layer only).

## Open questions
- Does the credential store belong in `Tesl.Auth` (a first-class typed table) or
  is it left to the app's DB layer, with only the subject-bound FACT standardised
  (Proposal B)? The former is more turnkey; the latter is less surface.
- Set-side gating (signup / password reset): should writing a `Credential` /
  `PasswordHash` require its own capability + policy so the create path is gated
  the same way the verify path is (Risk 64)?
- Interaction with session refresh: a `JWT.verify`-backed re-issue should mint
  `LoggedIn` by DERIVING the subject from the verified claims (sound), so it needs
  no credential lookup — confirm this `Auth.verifiedSession (claims ::: Authentic
  claims) -> String ::: LoggedIn <sub>` shape is accepted alongside A/B.
