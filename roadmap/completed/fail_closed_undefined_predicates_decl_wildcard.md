# Fail-closed: `check_undefined_predicates` latent decl-wildcard (P4, latent)

> **DONE 2026-07-06.** Outer decl loop enumerated (no wildcard). One precision
> found during the audit: DCapture and DApi DO carry proof-annotated bindings
> (`capture x: T ::: P x via chk`, endpoint `auth`) — their predicate
> consistency is owned by the dedicated pipeline-1 passes
> (`check_capture_proof_via`, api/server structural checks), which tie each
> annotation to the minting `via` checker; the enumerated arm states this
> explicitly instead of implying "no proofs live there". `check_ret` untouched
> (already the exhaustive reference).

Sibling of [[fail_closed_checker_hardening]] (umbrella).

## Why (the pattern)

`check_undefined_predicates` (`compiler/lib/proof_checker.ml:1142`) rejects a proof
that references a predicate name that is not a declared fact / imported predicate.
Its **return-spec** sub-walk `check_ret` (`:1209-1225`) is the reference example of
a fail-closed traversal — every `return_spec` variant enumerated, `RetExists`
recurses `body`, `RetPlain _ -> ()` explicit, **no wildcard**. Keep it as the model
for the other siblings.

The only fail-open spot is the outer decl loop:

```ocaml
| _ -> ()                                     (* proof_checker.ml:1297 *)
```

Safe today (proof annotations live on `DFunc` / `DRecord` / `DEntity`, all handled),
but a **latent** hole: a new decl kind that can carry a proof annotation would have
its predicates unchecked (an undefined predicate would then be minted / referenced
silently).

## Severity / honest scope

Latent, not active. Lower stakes than capabilities (an undefined predicate tends to
fail elsewhere), but it is the same blanket-wildcard class.

## Fix

Enumerate the outer `top_decl` match instead of `| _ -> ()`; non-proof-bearing decl
kinds get an explicit `-> ()` with a reason. `check_ret` needs no change — it is
already exhaustive.

## Verification

`dune build && dune test`, `./ci.sh` 13/13. Guard is the enumeration (future variant
fails to build until handled). Keep `return-proofs: missing predicate` and
`undefined predicate` negatives green.
