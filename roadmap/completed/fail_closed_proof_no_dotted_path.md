# Fail-closed: `check_proof_no_dotted_path` — audited, NO ACTION

Sibling of [[fail_closed_checker_hardening]] (umbrella). Recorded for a complete
audit trail; no work item.

## Verdict (2026-07-06)

`check_proof_no_dotted_path` (`compiler/lib/proof_checker.ml:478`) is **already
fail-closed**:
- Exhaustive over `proof_expr` — only `PredApp` (`:480`) and `PredAnd` (`:488`,
  recurses both sides), **no `| _ ->`**. A new `proof_expr` constructor is a build
  error under `@8`.
- The `String.contains arg '.'` test (`:482`) is the literal rule being enforced
  (reject a dotted path in a proof arg), not a decide-by-spelling proof comparison.

## Action

None. Leave as-is. If `proof_expr` gains a variant, the build breaks here until a
decision is made — which is the property we want.
