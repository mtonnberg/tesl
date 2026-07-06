# Fail-closed: `validate_param_proof_subjects` skips non-RetAttached returns (P1)

> **DONE 2026-07-06.** Return-spec match is now exhaustive (no `| _ ->`); the
> `RetMaybeAttached` binding and `RetExists` binder(s) joined `valid_names` and
> their annotations are subject-checked. **Scope refinement found during
> verification:** subject-vs-parameter validation is only OWNED here for the
> signature-scoped forms (RetAttached / RetMaybeAttached / the RetExists
> binder's own annotation). Pack/quantifier forms (RetNamedPack, ForAll family,
> RetExists BODY) may legitimately name body locals (ProofSuite-H PosH11:
> `exists accId: String => Account ::: IsOpened acc` with `acc` let-bound), so
> those arms are explicit documented DEFERRALS to the discharge judgment — and
> the deferral is pinned end-to-end by a test proving discharge rejects a bogus
> named-pack subject. Tests: `test_fail_closed_hardening.ml` ("return-proof
> subjects" group). Gate: dune test + ci.sh green.

Sibling of [[fail_closed_checker_hardening]] (umbrella). **The one ACTIVE
fail-open of the seven.**

## Why (the pattern)

`validate_param_proof_subjects` (`compiler/lib/proof_checker.ml:173`) checks that
every subject named in a proof annotation is a real parameter (or return-binder)
name — it catches a proof that references a name that does not exist. For the
**return spec** it does this only for `RetAttached`:

```ocaml
(match fd.return_spec with
 | RetAttached { binding = b; _ } -> (* ... validate b.proof_ann subjects ... *)
 | _ -> ());                                  (* proof_checker.ml:218 *)
```

The `| _ -> ()` silently skips subject-validation for every other proof-bearing
return form: `RetNamedPack` (`entity_proof` / `other_proof`), the `RetForAll`
family (`proof`), `RetExists` (`body`), and `RetMaybeAttached` (`binding.proof_ann`).
Same shape at `:178-181`, where `return_binding` (added to the set of valid subject
names) is extracted only from `RetAttached`, so a `RetMaybeAttached` binder is not
even in `valid_names`.

Because the match ends in `| _ ->`, the `@8` non-exhaustiveness guard is defeated:
a new proof-bearing `return_spec` constructor compiles clean and is silently
un-validated.

## Severity / honest scope

This is the clearest **structural** fail-open of the seven, but likely not a
standalone forgery: a return proof naming a nonexistent subject would generally
also fail the discharge judgment (`proof_discharge`), since no leaf carries a proof
at a subject that does not exist. So today the practical effect is a **degraded /
missing diagnostic** and a **latent** hole (a future return form, or an interaction
where discharge does not backstop, goes unchecked). It should still be closed — the
skip is exactly the class this theme exists to eliminate, and relying on another
pass to accidentally cover it is the anti-pattern.

## Fix

Enumerate the return spec (no `| _ ->`). Factor the subject-validity check into one
helper `check_subjects loc proof` and call it for every proof-bearing form:
`RetAttached` (as today), both `RetNamedPack` proofs, the `RetForAll`/`RetSetForAll`/
`RetMaybeForAll`/`RetMaybeSetForAll`/`RetForAllDictValues`/`RetForAllDictKeys`
`proof`, `RetExists` `body` (recurse), `RetMaybeAttached` `binding.proof_ann`. The
non-proof forms (`RetPlain` non-Fact) get an explicit `-> ()` with a reason. Add
the `RetMaybeAttached` / named-pack binder(s) to `valid_names` where applicable.
Reference the exhaustive `check_ret` walk in `check_undefined_predicates`
(`:1209-1225`) — it already enumerates every return_spec variant wildcard-free.

## Verification

`dune build && dune test`, then `./ci.sh` 13/13. Add a red→green antagonistic case:
a `fn`/`check` whose `RetNamedPack` or `RetForAll` return names a bogus proof
subject must now be rejected here (it was silently accepted by this pass before).
Confirm no shipped `.tesl` regresses in the Validate phase.
