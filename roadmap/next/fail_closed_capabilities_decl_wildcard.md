# Fail-closed: `check_capabilities` latent decl-wildcard (P4, latent)

Sibling of [[fail_closed_checker_hardening]] (umbrella).

## Why (the pattern)

`check_capabilities` (`compiler/lib/proof_checker.ml:1027`) rejects use of an
undeclared / unimported capability. Its decl loop ends in:

```ocaml
| _ -> ()                                     (* proof_checker.ml:1055 *)
```

which skips all non-`DFunc` / non-`DCapability` declarations. **Safe today**: only
`DFunc` carries a `.capabilities` list (`:1054`), and `DCache` / `DEmail` /
`DCapability` capability needs are folded into `build_cap_map` upstream. But it is a
**blanket `| _ -> ()`**, so the day a new declaration kind carries a `requires`
list, its capabilities go silently unchecked — a latent capability-safety
(security-relevant) hole.

## Severity / honest scope

Latent, not active. This is a security-adjacent judgment (capability safety), so
the latent risk is worth closing even though nothing exploits it today. Note there
is partial overlap with pipeline-1's `check_handler_capabilities`
(`validation.ml:96`) — confirm which decl kinds each owns before changing, so the
fix does not create a double-diagnostic or leave a gap between them.

## Fix

Replace the blanket `| _ -> ()` with an enumerated `top_decl` match: the decl kinds
that carry no capability requirement get an explicit `-> ()` with a reason; any kind
that does (now or future) is forced through a decision by `@8`.

## Verification

`dune build && dune test`, `./ci.sh` 13/13. Because it is latent, the guard is the
enumeration itself (a future variant fails to build until handled). Keep the
existing capability-negative tests green (`capabilities`, `adversarial: cap without
import`).
