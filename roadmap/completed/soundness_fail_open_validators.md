# Fail-open boundary validators — the review's critical soundness class

## Why (confirmed forgeries, reproduced first-hand)
The boundary-minting validators are non-total hand-rolled AST walks that fall
through on unrecognised forms. Because proofs are erased, each gap is a silent
production forgery. Confirmed (all `--check` exit 0; unwrapped controls rejected):

- **PF-3/4/5/6, AUTH-1, PFC-1** — `check`/`establish`/`auth` body wrapped in
  `transaction {}` / `with database` / `with capabilities` mints any declared fact
  (incl. `Authenticated` = total auth forgery). Root: `validate_ok_expr`
  (`proof_checker.ml:552`) descends into `EIf/ECase/ELet/ELetProof` and bottoms out
  on `| _ -> ()` (line 778) — never entering `EWith{Database,Capabilities,Transaction}`.
  Sibling walkers in the SAME file (359/392/512) DO descend. Divergent traversal.
- **PFC-2** — a plain `fn` returning `Maybe (T ? P)` / `Either L (T ? P)` mints `P`
  on an arbitrary value; the "only check/auth/establish may introduce a proof" gate
  isn't applied to container/named-pack returns.
- **F1/F2** — a `handler` returning `-> T ? FromDb (Id == x)` with a hand-crafted
  record (no DB read of `x`) forges DB provenance; `body_has_db_site` guards the
  `RetAttached` form but not `RetNamedPack`.
- **SHADOW-1/2/3** — the no-shadowing (V001) walk misses bare `EConstructor` args,
  `EFail` messages, and lambda-in-ctor positions, letting a shadow forge a proof.
- **EE-1** — existential enforcement bypassed by wrapping the value in any
  non-variable expression.
- **SC-01** — ForAll conjunction comparison is order-sensitive `pp_proof` string
  compare (`proof_checker.ml:670`), disagreeing with the order-insensitive plain
  path — a false-negative today, the decide-by-spelling smell.

## Fix (remove the class, then the instances)
1. Make `validate_ok_expr` **total + fail-closed**: add
   `EWith{Database,Capabilities,Transaction} { body } -> validate_ok_expr body`,
   explicitly enumerate the leaf variants, and **delete `| _ -> ()`** so OCaml
   exhaustiveness forces every future variant to be classified. Do the same to the
   `RetMaybeAttached`/ForAll sub-paths that string-compare (route through the
   structural key / normalize).
2. Apply the `RetAttached` proof-minting + `body_has_db_site` gates to
   `RetNamedPack` (and the container `Maybe (T ? P)` / `Either` forms).
3. Make the shadow walk total (descend ctor args, fail msgs, lambda bodies as new
   scopes correctly).
4. Descend existential enforcement into non-variable wrappers.

## Tests (mandatory negatives, + passing controls)
Every repro above → REJECTED, with the unwrapped control still accepted.
Plus a **metamorphic** test (see verification_methodology): wrap every accepted
`ok`/return in `transaction{}`/`with`/ctor and assert the verdict is unchanged.

## Status: DONE (core) — 2026-07-02
`validate_ok_expr` + the two `establish` fact-ctor walks now descend into
`EWith{Database,Capabilities,Transaction}`; `validate_ok_expr` is a total,
`| _ -> ()`-free match. Shadow walk descends into ctor args / fail msgs. ForAll
comparison order-insensitive. Verified: PF-3/4/5/6, AUTH-1, PFC-1, SHADOW-1/2/3,
SC-01 all rejected (controls accepted); 99+38 example/tests green; regression
tests in `compiler/test/test_review75_reviewfixes.ml`.
**Also closed (2nd pass):** F1/F2 (non-existential named-pack `FromDb (Col == rhs)`
insert forgery — `check_nonexist_named_pack_insert`), EE-1 (existential insert with a
wrapped/computed id fails closed). Regression cases R75_F1/F2/F1ok/EE1.
**Still carved → `roadmap/later/review_2026_07_deferred.md` §1:** PFC-2
(container-wrapped minting — direct forms gated; the container case needs
engine-level proof-lifting).
