# Holes #2 (establish delegation) & #5 (check-body subject guardrail) — incomplete guardrails on the trusted minting boundary

**Status:** deferred from the 2026-07-03 fix pass. Partially mitigated; residual gaps documented here.
**Severity:** medium (these live INSIDE the trusted `check`/`auth`/`establish` boundary — the human is expected to review those bodies — but the compiler's *extra* guardrails are spelling-based and incomplete, which can give false confidence).

## Context
`check` / `auth` / `establish` are the trusted proof-minting kinds. Like a
Ghosts-of-Departed-Proofs smart constructor in Haskell, the compiler cannot prove a
validator is *correct* — it trusts the body. Tesl adds *guardrails* on top (P001, the
ok-value-must-name-its-binding rule, the establish direct-subject check) to catch the
naive mistakes. The fixes in this review closed the guardrail gaps that were reachable
from NON-trusted kinds (holes #1/#2-fn/#3/#4). The two residual gaps below are gaps in
the guardrails on the TRUSTED kinds themselves.

## #2 (establish side) — delegation escapes the subject check
`establish factFor(_n) -> Fact (IsPositive _n) = proveConst()` where
`establish proveConst() -> Fact (IsPositive 7) = IsPositive 7`: the declared return
subject is `_n` (the caller's arg) but the body actually proves the fact about `7`.
The direct-form guardrail (proof_checker.ml:1604, `check_ctor_args`/`walk_args`)
compares the **literal args of the declared constructor** and catches
`= IsPositive 7`, but a **delegation** to another prove-function returns *that*
function's fact and slips past (the walker only inspects applications of
`declared_pred`, not calls to functions whose return spec IS `Fact (declared_pred …)`).

Fix: extend `walk_args` so that when the returning expression is a call to a function
`g` whose return spec is `Fact (declared_pred <ret_args>)`, it substitutes `g`'s
params with the call args and compares the resulting subject against the declared
subject. Handle the (possibly nested) delegation chain. Fail closed on an
un-resolvable delegate.

## #5 (check side) — the ok-value/guard subject rule is spelling-based
`check checkPos(guard: Int, payload: Int) -> payload: Int ::: Positive payload =
 if guard > 0 then ok payload ::: Positive payload else fail …` stamps `Positive`
on `payload` under a guard testing the *unrelated* `guard`; and `let result = 0 - n;
ok result ::: Positive result` launders a negative through a rebind. The compiler's
P001/§2096 guardrail blocks the naive `ok 42 ::: Positive n` (non-identifier /
name-mismatch) but is **spelling-based** and does not relate the guard/dataflow to the
stamped value — so it gives partial, potentially misleading assurance.

This is inherent GDP trust (a wrong `check` body is the author's bug, caught by human
review of the *named, localized* check functions — the value GDP delivers). The
actionable item is honesty + a stronger guardrail, not a soundness guarantee:
- Document plainly (README/tour/best-practices) that `check`/`auth`/`establish` bodies
  are the trust boundary: the compiler ensures you cannot *skip* a validator, not that
  a validator is *correct*. Do not let the P001 guardrail imply the stamp is verified.
- Optionally strengthen the guardrail toward dataflow: warn (not error) when the value
  carried by `ok v ::: P v` is not derived from a parameter that the success-path
  condition constrains.

## Related residual fail-open (Option A)
The `Fact`-typed **parameter** discharge path (validation_proof.ml:87-91) skips its
mismatch check when the carried-fact analysis returns empty
(`carried_fact_proofs <> []` guard) — a fail-open sibling of the (fixed) `Fact`-typed
FIELD hole #4. The corpus uses `Fact`-typed params (lesson12), so this must be closed
via the Option-A "make `proofs_of_evidence_expr` total / fail-closed" refactor rather
than a blunt guard removal (which would over-reject legit detached-fact passing when
the analysis can't see the proof).

See close_fail_open_without_runtime_layer.md — all three are instances of the same
"decide-by-spelling / fail-open-on-uncertainty on a minting boundary" class.

## Status: DONE — 2026-07-04
All three residual gaps closed:

- **#2 (establish delegation)** — commit `346802f`. `validate_check_return`
  (proof_checker.ml) now resolves a tail-call delegate whose declared return is
  `Fact (declared_pred …)`, substitutes the callee's params with the call args, and
  rejects a subject mismatch; fail-closed on an unresolvable delegate. Regression
  PN09 (reject) + PC05 (subject-preserving delegation compiles).

- **#5 residual `Fact`-typed-param fail-open** — commit `396923f`. When no carried
  proof is present, `check_call_proofs` (validation_proof.ml) falls back to the
  argument's declared `Fact` TYPE (via `infer_expr_type` + `proof_of_fact_type`) and
  rejects a head/subject mismatch, instead of skipping the check on the empty-carried
  branch. lesson12's legit `Fact`-typed params are unaffected (they resolve via the
  carried branch). Regression PN11 (`Fact(A)->Fact(B)` rejected) + PC07 (matching
  param forwards).

- **#5 check-side honesty** — commit `9402c00`. best-practices "Trust Boundary"
  subsection states the compiler ensures you cannot SKIP a validator but does not
  verify a validator body is correct.

**Consciously deferred (non-soundness, explicitly optional in this item):** the
dataflow *warning* for `ok v ::: P v` where `v` is not guard-constrained. It is opt-in
guidance, not a soundness guarantee (a wrong validator body is inherent GDP trust), and
the doc now sets the correct expectation. Not worth the false-positive noise.

**Verify:** PN09/PN11 reject, PC05/PC07 compile; 130-file corpus 0 errors; `dune test`
green (bar the known Racket 8.18/9.2 app-server `.zo` flakes); S7 = 135 kills.
