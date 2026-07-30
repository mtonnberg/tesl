# An unwrapped check result still escapes through six value positions

> **Status: IMPLEMENTED 2026-07-30.** Landed as `Checker.reject_check_result_in_value_position`
> (`compiler/lib/checker.ml`), sharing `call_head_check_shaped_expr` with the `let`-binding
> rule so "saturating call" is decided in one place across all positions. Wired into every
> value-consuming site: `ECase` scrutinee (`infer_expr` + `check_expr`), record field value
> (the typed-literal arm, the `TypeName { .. }` constructor arm, both branches of the
> ADT-inline-record arm, and the `{ p | f = v }` record-update arm — a field turned out to be
> checked from four separate call sites, not one), `EList` element (`infer_expr` + `check_expr`),
> both `EBinop` operands (the general path only — the SQL `where`-clause path is untouched,
> out of scope here), and a string-interpolation hole. The `if`-condition shape needed no arm
> of its own: it is caught transitively through the binop operand it is built from, as the
> design tension section anticipated. Ships the same machine-applicable `check `-insertion fix
> as the binding rule.
>
> Tests: `compiler/test/test_check_binding_gap.ml`, new "six more escape routes" groups (14
> new cases: 6 refusals + 8 non-regressions covering the checked form, partial application,
> bare reference, and a composed check in a case arm's tail). `./ci.sh` green modulo
> pre-existing, unrelated environment gaps in this sandbox (libsodium not installed, so
> Crypto/JWT/session-cookie native tests fail; `js_of_ocaml` missing, so playground-parity
> is skipped) — none touch the checker paths this change edited.

## The gap

A check-shaped callee (`JWT.verify`, `Int.nonZero`, `Float.requireNonZero`,
`Units.requireNonZero`, `Dict.requireKey`, `Crypto.checkPassword`, a user `check` function, …)
returns a check RESULT: the payload on success, a `check-fail` struct on failure. Only `check`
unwraps it and propagates the failure. Three positions now refuse to let the raw wrapper
escape — a nested argument (`checker.ml`'s `reject_nested_check_calls`), a `check`-headed bare
statement, and every `let` binding form (`reject_unchecked_check_binding`, which closed
`check_binding_gap.md` on 2026-07-30).

**Six value positions are still open.** Each of these compiles today, and each binds or reads
a `check-fail` struct as if it were the value, ON THE ERROR PATH ONLY:

```tesl
case Int.nonZero b of        # case scrutinee — arms match against a check-fail struct
  _ -> "x"

R { n: Int.nonZero b }       # record literal field
[Int.nonZero b]              # list element
1 + Int.nonZero b            # binop operand
"v=${Int.nonZero b}"         # string interpolation
if Int.nonZero b > 0 then …  # if condition (via the binop operand above)
```

Verified against the working tree at the time `check_binding_gap.md` landed: all six typecheck
clean. They are the same defect shape as the closed cases — invisible to a test suite that
feeds valid input, wrong only when the check fails.

## Why this was not folded into the binding rule

Scope. `check_binding_gap.md` asked for the `let`-RHS position and its verification bar was
written against it; that change already grew to cover `let _ = …` and `let (x ::: p) = …`, and
it had to make `check Units.requireNonZero` dimension-preserving before the rule had a legal
spelling to point at. Widening the same pass to every value position is a different-sized
change with a different false-positive surface, and it needs the decision below made
deliberately rather than as a side effect.

## The design tension to resolve

The rule cannot be "every sub-expression", because two shapes must stay legal:

- **TAIL position.** A `check`/`auth` body's tail expression IS its own verdict — returning
  another check's result is how checks compose. `reject_nested_check_calls` is explicit about
  leaving tails alone, and the checker does not track "am I in tail position" uniformly, which
  is the real work here.
- **A check FUNCTION, not a result** — a bare reference (`check f a b`'s head,
  `List.filterCheck checkPositive xs`) and a partial application (`Dict.requireKey "sub"`).
  `call_head_check_shaped_expr` already draws this line by arity; reuse it, do not reinvent it.

So the shape of the fix is: extend the existing check-shaped detection to the remaining value
positions, sharing `call_head_check_shaped_expr`, with ONE explicit notion of "this position
consumes a value, so an unwrapped check result escaping here is a defect" — and an equally
explicit list of the positions that do not (tail, `check` head).

## Verification bar

- Each of the six shapes above is a compile error naming the callee, with the `check`-insertion
  fix where the edit is expressible (the `let`-RHS rule's
  `Diag_fix.verified_insert_before` applies unchanged when the callee is a saturating call).
- A check body returning another check's verdict in tail position still compiles.
- `List.filterCheck checkPositive xs`, `Dict.requireKey "sub"`, and `check f a b` still compile.
- The existing corpus still compiles, or each newly-rejected site is a real latent bug that
  gets the `check` it was missing (the binding rule found 15 such sites; expect more here).
- `./ci.sh` green.

## Related

- `roadmap/completed/check_binding_gap.md` — the binding half, and the `Units.requireNonZero`
  work it required.
- `checker.ml` — `is_check_shaped_name`, `call_head_check_shaped_expr`, `check_shaped_arity`,
  `reject_nested_check_calls`, `reject_unchecked_check_binding`.
- `compiler/test/test_check_binding_gap.ml` — where the new cases belong.
- `LANGUAGE-SPEC.md` §`let` — the prose lists the three closed positions and would need the
  rest added.
