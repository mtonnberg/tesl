# Session witness gate — bind the credential to the subject (Password & Machine `loginMethods`)

## Status
DEFERRED / design. Prototyped 2026-07-31 and **rejected as unsound** (see below).
Companion to `roadmap/next/ensure_sso_works.md` (Open Questions 15/18; Risks
46/56/63/64) and `roadmap/later/fail_closed_mint_matching_structural.md`. The SSO
flow, the `loginMethods [Sso]` fail-closed allowlist, and the machine-credential
`Machine` keyword are already landed; what is missing is the enforcement that a
`[Sso, Password via <fn>]` / `[…, Machine]` server mints an app session ONLY for a
subject a real credential check authenticated.

## Motivation
Under `loginMethods [Sso, Password …]` the compiler today only checks that the
policy function exists. The canonical login is unforced:
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

### Proposal C — bind the token too (`SubjectOf token subject`) — DEFENCE IN DEPTH
Complementary to A or B, not standalone. Make `setSessionCookie` additionally
demand that the witnessed subject equals the token's `sub` claim:
```tesl
Http.setSessionCookie : (subject: String ::: LoggedIn subject)
                        (token: JwtToken ::: SubjectOf token subject) -> Unit
```
Prevents minting a cookie whose signed token says X while the login witness is for
Y (e.g. login as yourself, then set a token minted for someone else). On its own
it does NOT fix the unbound-subject hole (an attacker forges both to the same
`"admin"`), so it must be layered on A or B. `SubjectOf` is minted by the
session-token builder from the same subject it stamps into `sub`.

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
Ship **Proposal A** (identity-bearing `Credential`, subject derived from the
verified credential) as the primary gate — it removes the forgeable free-subject
argument, which is the root cause, and matches the opaque-type precedent. Layer
**Proposal C** on top as defence-in-depth so the JWT `sub` and the login witness
can never diverge. Keep **Proposal B** as the lighter alternative if introducing a
new opaque `Credential` type is considered too much surface; keep **Proposal D**
only as a last resort. The SSO callback path is already sound and unchanged.

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
