# Fail-closed checker hardening — umbrella

> **Theme / index.** Extends the fail-closed discipline proven out on the
> return-proof **discharge** judgment (`proof_discharge.ml`, 2026-07-06) to the
> other rejection judgments that live in `proof_checker.ml`. This doc is the map;
> the work lives in the sibling docs. It is not itself a work unit.

> **CLOSED 2026-07-06.** All seven audited judgments resolved (5 fixed, 2
> audited-no-action with the one follow-up confirmed). Antagonistic coverage in
> `compiler/test/test_fail_closed_hardening.ml`; gate green (dune test +
> ci.sh 13/13). Two verdict corrections against the original audit:
> `check_capabilities` was ACTIVE (not latent) — `DQueue`/`DAgent`/`DTest`/
> `DApiTest`/`DLoadTest` requires-lists were unchecked, reproduced on `test` —
> and P1's return-subject validation is correctly OWNED only for
> signature-scoped forms (pack/quantifier subjects may name body locals; their
> deferral to discharge is documented per-arm and pinned by an end-to-end
> test). P5 (mint-side string-vs-structural) remains in roadmap/later. New
> sibling finding filed separately: [[email_capability_not_composable]].

## Thesis

A soundness checker must **fail closed**: an unrecognized or unhandled shape is
REJECTED, never silently accepted. The over-reject direction (reject a program we
compile today) is caught by ci.sh's Validate oracle. The under-reject direction
(a guard is missing / skips a shape) is only caught if a test asserts that exact
rejection — so it is the dangerous direction, and the one this theme closes by
construction.

The mechanism the codebase already gives us: the file-level `[@@@ocaml.warning "@8"]`
(and `lib/dune`'s `-warn-error +8`) turns a **non-exhaustive match into a build
error**. So a match over `expr` / `return_spec` / `proof_expr` / `top_decl` with
**no `| _ ->` arm** is fail-closed by construction — a new AST variant cannot be
added without forcing a decision here. **Every `| _ ->` catch-all defeats that
guarantee.** The audit below classifies each judgment by whether it relies on a
catch-all and, if so, whether that catch-all is an active hole or only latent.

## Scope

The primary focus is the **non-discharge** judgments in `proof_checker.ml`. The
discharge / mint judgment itself (`validate_check_return`, `validate_ok_expr`) also
matches by string rather than structure — that is `fail_closed_mint_matching_structural.md`
below (discharge-side; see also [[discharge-refactor-plan]]). It is logged here as the
same fail-closed-consistency class but flagged **robustness, not a demonstrated hole**
(2026-07-06 investigation found no exploit).

## Audit map (2026-07-06)

| Sibling doc | Function | Verdict | Priority | Outcome (2026-07-06) |
|---|---|---|---|---|
| `fail_closed_param_proof_subjects.md` | `validate_param_proof_subjects` (173) | **ACTIVE fail-open** | P1 | FIXED (signature-scoped forms owned; pack/quantifier deferred to discharge, pinned) |
| `fail_closed_ghost_witness_totality.md` | `check_gw` in `check_module` (1842) | non-total; false `@8` claim; mitigated | P2 | FIXED (full structural descent + honest comment + case/let-proof witness state) |
| `fail_closed_no_ok_in_fn.md` | `validate_no_ok_in_fn` (357) | residual escapes (constructor args / case guards) | P3 | FIXED (all non-descents deleted; fold_children everywhere) |
| `fail_closed_capabilities_decl_wildcard.md` | `check_capabilities` (1027) | latent decl-wildcard | P4 | FIXED — was ACTIVE (test/queue/agent/apiTest/loadTest requires unchecked) |
| `fail_closed_undefined_predicates_decl_wildcard.md` | `check_undefined_predicates` (1142) | latent decl-wildcard | P4 | FIXED (enumerated; DCapture/DApi ownership documented) |
| `fail_closed_proof_no_dotted_path.md` | `check_proof_no_dotted_path` (478) | already fail-closed | none | no action (audit record) |
| `fail_closed_import_parse_errors.md` | `collect_import_parse_errors` (1106) | already fail-closed | none | follow-up confirmed (missing import → V001) |
| `fail_closed_mint_matching_structural.md` | `validate_check_return` (594) | string-not-structural match; **robustness, not a proven hole** | P5 | remains in roadmap/later |

## Cross-cutting fix pattern

Where a checker matches over a *closed* AST/spec/proof type, replace `| _ -> <accept>`
with an **enumerated** match (list every constructor; the ones that carry no
obligation get an explicit `-> ()` / `-> []` with a one-line reason). The `@8`
guard then forces every future variant through a decision. Where a checker cannot
enumerate (open string domains, cross-pass concerns), document why the skip is safe
and where the backstop lives. `check_ret` inside `check_undefined_predicates`
(1209-1225) is the reference example of an exhaustive, wildcard-free return-spec walk.

## Verification (every sibling)

`cd compiler && dune build && dune test`, then `./ci.sh` (13/13). A pure fail-closed
tightening can only reject MORE, so the load-bearing oracle is the **Validate**
phase (must still accept every shipped `.tesl`) plus a new red→green antagonistic
test proving the previously-skipped shape is now rejected.
