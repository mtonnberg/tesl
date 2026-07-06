# Fail-closed: `validate_no_ok_in_fn` residual non-descents (P3)

> **DONE 2026-07-06.** All deliberate non-descent arms deleted in BOTH walkers;
> everything but the semantic arms (EOk/EFail/check-call) now routes through
> the `Ast_visitor.fold_children` catch-all — which already visits constructor
> args, case guards, cache/email operands and string-interpolation segments.
> The allowed re-attach arm (`EOk` with existing witness) additionally descends
> into its VALUE. Red→green: `Something (ok v ::: P v)` and an `ok` inside a
> case guard rejected in a `fn` (`test_fail_closed_hardening.ml`).

Sibling of [[fail_closed_checker_hardening]] (umbrella).

## Why (the pattern)

`validate_no_ok_in_fn` (`compiler/lib/proof_checker.ml:357`) enforces that a `fn`
(and other non-mint kinds) cannot use `ok` / `fail` / `check` to mint a proof at a
boundary it is not entitled to. This one is **mostly fail-closed**: both internal
walkers end in a *descending* catch-all —

```ocaml
| _ -> Ast_visitor.fold_children (fun acc c -> acc @ walk c) [] e   (* :418 / :464 *)
```

so a new `expr` variant is traversed automatically (this is the good pattern the
other siblings should adopt). The residual gaps are deliberate non-descents:
- `EConstructor` arguments are not walked (`:398` / `:450`).
- `ECase` guards are skipped.
- `EStartWorkers` / cache / email nodes return `[]`.

So an `ok` / `fail` / `check` buried inside a constructor argument (e.g.
`Something (ok x)`) or a case guard would escape this pass.

## Severity / honest scope

Low. These are documented, reasoned non-descents, and the constructs are unusual
positions for a mint expression. No known exploit. Tracked so the gap is explicit
rather than forgotten.

## Fix

Extend the walkers to descend into `EConstructor` args and `ECase` guards (reuse the
`Ast_visitor.fold_children` fallback already present, or add explicit recursion for
those two positions). Keep the intentional `[]` for worker/cache/email leaves if
those genuinely cannot contain a mint expression — but state the reason inline.

## Verification

`dune build && dune test`, `./ci.sh` 13/13. Add a case: `fn` returning
`Something (ok v ::: P v)` must be rejected. Confirm no shipped `.tesl` regresses.
