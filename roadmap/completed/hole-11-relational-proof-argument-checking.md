# Hole #11 — proof reconciliation compares predicate NAMES, dropping ARGUMENTS

**Status:** deferred from the 2026-07-03 fix pass (needs args-aware comparison; regression risk). CONFIRMED live.
**Severity:** critical (SSE cross-tenant authorization bypass; HTTP auth-subject laundering).

## The hole
`proof_predicates` (validation_common.ml:403) and `pred_names_of_return_spec`
(validation_common.ml:519) return only predicate **names**, discarding every
argument. The endpoint↔auther/capture reconciliation in `validation_structural.ml`
(`check_auth_proof_via` / `check_capture_proof_via` / `check_server_handler_binding`)
compares those name-sets, so a **relational** proof the auther established about one
subject is accepted as a proof about a *different* subject the endpoint binds:

- SSE: an auther that proves `ChannelOwner session` (about the session) satisfies an
  endpoint clause requiring `ChannelOwner roomId` (about the URL channel key) —
  user A can subscribe to user B's stream. The flagship SSE example
  (LANGUAGE-SPEC.md:1729-1733) cannot be implemented soundly as advertised.
- HTTP variant compiles clean too (the auth-subject is bound to a value the auther
  never proved about).

The runtime provides no backstop: the auther is invoked single-arg with the request
only (dsl/web.rkt:1272,1881) and never receives the key; the compile-time proof is
erased.

## Why it was deferred
The fix is to compare the **full proof including its subject/arguments** — verifying
the auther establishes the predicate *about the same subject* the endpoint binds it
to. But `proof_predicates` is called in many places that only want names, and the
subject-correspondence rule (the auther's subject variable vs the endpoint's binding
name) is subtle — naive argument equality would reject legitimate auth where the
subject is renamed across the auther/endpoint boundary. Getting this right without
false-rejecting the working auth corpus needs care.

## Fix (class-level)
1. Add an **args-aware** comparison alongside `proof_predicates` (do NOT change
   `proof_predicates` itself — its name-only callers are correct). Use the existing
   structural `proof_key` (validation_common.ml:366) machinery, which already keys
   by (pred, resolved-args) and powers sound call-site discharge.
2. In `check_auth_proof_via`/`check_capture_proof_via`/`check_server_handler_binding`:
   after establishing the auther/capture produces predicate `P`, verify the
   **subject** it proves `P` about corresponds (via the endpoint's binding + the
   auther's return-spec subject) to the subject the endpoint's clause attaches `P`
   to. Reject a relational mismatch (`P session` supplied where `P roomId` required).
3. Fail closed on an un-relatable subject, with a platinum message naming both the
   established subject and the required subject.

## Verification
- SSE repro: endpoint `subscribe … ::: ChannelOwner roomId via ownerAuth` where
  `ownerAuth` proves `ChannelOwner session` → V001 (rejected).
- HTTP analogue rejected.
- The working auth corpus (todo-api cookieAuth `Authenticated requestUser`, the
  capturer `via` examples) stays green — the subject correspondence holds there.

## Status: DONE — 2026-07-04
Closed in commit `29321c0`. New `check_endpoint_proof_subject_binding`
(validation_structural.ml, registered validation.ml) + helper
`endpoint_proof_subject_mismatches`.

**Simplification vs. the deferred plan:** no args-aware comparison against the
via-fn's return spec is needed. An endpoint `auth <b> ::: P <s> via <f>` binds the
auther's result to `<b>`; the auther is invoked with the request alone
(dsl/web.rkt:1272,1881) and proves `P` about the value it RETURNS — i.e. `P <b>`,
the only proof transferred to the handler. So the handler's `P <s>` obligation is
discharged iff `<s>` == `<b>`. The check compares each required predicate's SUBJECT
(final arg — the subject-is-last convention) against the binding name and rejects a
differing clean-identifier subject, fail-closed, for both `auth` and `capture`
endpoint clauses. Literal / parenthesised / dotted subjects are left alone. Auth-fn
DEFINITIONS (`auth foo(..) -> x ::: P x`) are untouched — the check only iterates
`DApi` endpoints.

**Verify:** auth forge (`Authenticated roomId` bound to `user`) and capture forge
(`Positive otherId` bound to `taskId`) both reject with "relational proof forgery —
cross-subject authorization bypass"; control 0 errors. Regression PN12/PN13 (reject)
+ PC08 (subject=binding compiles) in test_proof_negatives.ml. Corpus `--check-all`:
example 92/92, tests 38/38 (no over-rejection — every corpus clause has
subject=binding). S7 = 135 kills. `dune test` green bar the known Racket 8.18/9.2
app-server `.zo` version-mismatch integration flakes (see
`align-dev-shell-racket-9.2.md`).
