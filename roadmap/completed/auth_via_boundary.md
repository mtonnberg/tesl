# Auth `via` frontend validation + multi-subject authorization

## Why
- **AUTH-VIA (high):** `auth <binding> via <authFn>` is never validated at the
  frontend for (a) existence of `authFn`, (b) its kind, (c) whether it produces the
  declared predicate — whereas capture `via` has all three
  (`check_capture_proof_via`, `validation_structural.ml:1010`). A typo'd/wrong-kind
  `via` passes `--check-json` and fails only at Racket load or first request. Also:
  auth-wiring reconciliation is gated behind `if auth_preds <> []`, so a module with
  zero auth fns loses the checks.
- Multi-subject (IDOR/BOLA): relational `OwnedBy resource user` proofs are
  inexpressible at the boundary because auth and capture checkers each see only their
  own value.

## Fix
- Add `check_auth_proof_via` mirroring the capture path: authFn must exist, be
  `AuthKind`, and produce the declared predicate.
- Trigger auth-wiring reconciliation on "the endpoint HAS an auth clause", not on
  "the module declares ≥1 auth fn".

## Tests
via undeclared fn → REJECTED; via a `check` (wrong kind) → REJECTED; via fn whose
predicate ≠ declared → REJECTED; correct via → accepted.

## Status: DONE (AUTH-VIA) — 2026-07-02
Added `check_auth_proof_via` (validation_structural.ml), wired into validation.ml.
Endpoint `auth <b> ::: P via <fn>` now validates: fn exists, is check/auth kind,
and produces the declared predicate. Verified: undeclared `via` rejected; real
auth-via examples still pass (99+38 green); regression test R75_AV01/02.
**Carved:** the multi-subject (IDOR/BOLA) boundary-proof story is a design change →
`roadmap/later/review_2026_07_deferred.md`.
