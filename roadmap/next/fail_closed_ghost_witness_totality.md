# Fail-closed: ghost-witness walker `check_gw` is non-total + misleading comment (P2)

Sibling of [[fail_closed_checker_hardening]] (umbrella).

## Why (the pattern)

`check_gw` inside `check_module` (`compiler/lib/proof_checker.ml:1842`) is the
in-file secondary ghost-witness / `detachFact` check. It ends in:

```ocaml
| _ -> ()                                     (* proof_checker.ml:1940 *)
```

and does **not** descend into `EApp` arguments, `EList`, `ERecord`, or a
non-record-shaped `EOk`. A `detachFact` ghost witness nested in any of those
positions is skipped by this walker.

Two problems:
1. **Non-total traversal** (smell #3): the walk is not structural over `expr`, so
   proof-bearing forms in un-walked positions escape.
2. **False safety comment**: the comment at `:1830-1838` claims `@8` "forces a
   decision here too". That is **false** — the `| _ -> ()` at `:1940` makes the
   match exhaustive and silences the `@8` warning. The comment overstates the
   guarantee, which is how latent holes get rationalized.

## Severity / honest scope

**Mitigated, not open.** The authoritative ghost-witness check is
`Validation_advanced.check_ghost_witness_predicates` (pipeline 1) — `check_gw` is a
documented *secondary* backstop (`:1830-1838`). So a witness missed here is caught
there today. The risk is (a) the misleading comment inviting reliance on a walker
that does not deliver, and (b) drift if the authoritative walker is ever narrowed.

## Fix

Two options, pick per appetite:
- **Minimal (correctness of the record):** fix the comment to state the truth — this
  is a non-total secondary walk backstopped by `check_ghost_witness_predicates`; the
  `@8` guarantee does NOT apply because of the `| _ ->`. Lowest effort, removes the
  dangerous false claim.
- **Full (fail-closed):** make `check_gw` descend via `Ast_visitor.fold_children`
  (the pattern `validate_no_ok_in_fn` already uses at `:418`/`:464`) so new expr
  variants are traversed automatically and nested `detachFact` is caught here too.

Prefer the minimal fix first (it is a soundness-of-documentation issue), and only do
the full traversal if we want to retire the external backstop dependency.

## Verification

`dune build && dune test`, `./ci.sh` 13/13. If doing the full fix, add a case with
`detachFact` nested inside an `EApp` arg / list / record and assert rejection.
