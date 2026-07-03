## CLOSED (2026-07-03)

Both residual gaps are now statically rejected. `check_ghost_witness_predicates` /
`check_ghost_in_func` (`compiler/lib/validation_advanced.ml`) was rewritten to a
**subject-aware witness comparison**: it threads a `type_env`/`subject_env`/`proof_env`
through the function body (mirroring `check_record_field_proof_construction`'s
env-threading walk), so at each witnessed construction site
`R { f1: e1, … } ::: witness` it can

1. compute `required` = the full invariant proof with each record FIELD NAME
   substituted (`subst_proof`) by the SUBJECT of that field's value expression
   (`subject_of_expr`), and
2. resolve the witness's FULL carried proof (predicate + subjects) through the shared
   proof engine (`carried_proofs_of_expr` on an `EOk` wrapper, plus `proofs_of_expr`
   for let-bound check/establish results; Fact-typed params are seeded into
   `proof_env` via `proof_of_fact_type`).

When BOTH sides resolve it compares them with `proof_matches` (predicate name AND
subject args) — a predicate difference emits the legacy V001 message, a pure subject
difference emits a new "ghost witness for `R` proves … but the invariant requires …"
message. The change is strictly **additive**: whenever the witness or the required
proof cannot be fully resolved it FALLS BACK to the prior predicate-name-only check,
so no legitimate witnessed construction that compiled before regresses. The
missing-witness (bare-construction) and field-recursion arms are unchanged.

Regression coverage: `test_proofsuite_record.ml` gained `O9` (subject mismatch —
right predicate, wrong subjects) and `O10` (detachFact of a local check result
carrying the wrong predicate), both `should_fail`; the O4/O5/O6 positives still pass.
Full `dune test --force` green; whole-corpus compile sweep unchanged (no
newly-rejected programs).

---

# Record ghost-witness validation — close the residual subject/source gaps

## Status (2026-07-03)

A record type with a cross-field invariant (`record R { … } ::: Pred a b`) requires
a ghost witness (`R { … } ::: proofVar`) at every construction site. Most of the
obligation is now enforced by `check_ghost_witness_predicates` /
`check_ghost_in_func` (`compiler/lib/validation_advanced.ml`):

- **CLOSED** — bare construction with **no witness** at all is rejected
  (GDP-RECORD-WITNESS, 2026-07-03; see `test_proofsuite_record.ml` `O4c`).
- **CLOSED** — a witness carrying the **wrong predicate** supplied as a `Fact`
  parameter is rejected (`O4` "ghost witness predicate mismatch").
- **CLOSED** — a record/entity **field** proof (`f: T ::: P f`) constructed from a
  raw value is rejected (`O1`/`O7`).

## The residual gaps (both OPEN — same root: the witness's predicate+subject are not fully reconciled against the invariant on every witness form)

Both of these **compile today but should be rejected**:

1. **Witness subject mismatch.** A witness that carries the right predicate about the
   *wrong subjects* is accepted:
   ```tesl
   record OrderLine { price: Int  quantity: Int } ::: PriceExceedsQuantity price quantity
   fn mk(price: Int, quantity: Int, a: Int, b: Int,
         wrong: Fact (PriceExceedsQuantity a b)) -> OrderLine =
     OrderLine { price: price, quantity: quantity } ::: wrong   -- accepted; proof is about (a,b), not (price,quantity)
   ```
   The check compares the witness's predicate **name** to the invariant but does not
   require its **subjects** to be the record's own field values.

2. **`detachFact` of a local check result carrying the wrong predicate.** A witness
   produced by `detachFact` of a local `check`-result whose predicate differs from the
   invariant is accepted:
   ```tesl
   fn mk(price: Int, quantity: Int) -> OrderLine =
     let checkedP = check checkPos price               -- carries IsPositive price
     OrderLine { price: price, quantity: quantity } ::: (detachFact checkedP)  -- accepted; wrong predicate
   ```
   `check_ghost_in_func`'s `local_fact_map` resolves establish/check-returned predicates
   for the `detachFact param` form but not for a `detachFact <local-check-result>` here.

## Fix (remove the class, not the instance)

Make ghost-witness validation compare the **full normalized proof** (predicate name
**and** subjects, with the invariant's declared subjects substituted by the record
literal's actual field-value subjects) rather than only the predicate name — the same
subject-aware comparison `check`/`auth`/`establish` return-checking already uses
(`proof_checker.ml:606-649` and the 2026-07-03 establish subject fix). Resolve the
witness's carried proof through the shared proof engine (`proofs_of_expr` /
`extend_let_envs`) so every witness source (Fact param, `detachFact param`,
`detachFact <local check/establish result>`, `introAnd`/`andLeft`/`andRight`) is
handled uniformly, instead of the current per-form `local_fact_map` walk.

Regression coverage to add once fixed: flip the two cases above to `should_fail` in
`test_proofsuite_record.ml` (currently documented in the file header as the remaining
open subset), plus a positive control that a correct-subject witness still compiles.
