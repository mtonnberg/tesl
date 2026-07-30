# The check-binding gap — `let x = JWT.verify token key` compiles without `check`

> **Status:** Next · **Effort:** M. A checker rule; the hard part is scoping it precisely enough not
> to reject legitimate code.

## The gap

A check-shaped stdlib call (`JWT.verify`, `JWT.renew`, `Crypto.checkPassword`,
`Crypto.checkSignature`, `Money.requireSameCurrency`, `Int.nonZero`, …) returns a *check result* — a
value that is either the payload or a `check-fail`. Only `check` unwraps it and propagates the
failure as an HTTP status. Two places already enforce that you cannot ignore the wrapper:

- a **bare** call statement (`JWT.verify token key` on its own line) is rejected
  (`checker.ml:4295,4400` — "bare `check` call: the result must be bound with `let x = check …`");
- a call in a **nested argument position** (`Dict.lookup "sub" (JWT.verify token key)`,
  `Http.setSessionCookie (JWT.renew token key)`) is rejected (`checker.ml:1536+`,
  `call_head_check_shaped` / the argument-position walk) — because on the failure path the raw
  `check-fail` struct would be passed on as if it were a value.

But the **plain-`let` binding is not caught**:

```tesl
let claims = JWT.verify token key   # no `check` — COMPILES today
let fresh  = JWT.renew  token key   # same
```

Here `claims` / `fresh` is bound to a value that, on the failure path, is a `check-fail` struct
rather than the claims / the token. It typechecks (the callee's declared return type says nothing
about the check wrapper) and then misbehaves **only on the error path**, which is exactly why it
survives a test suite that feeds valid input. Surfaced 2026-07-30 during the `JWT.renew` work; it is
**pre-existing and general** — `JWT.verify` has always had it — and `JWT.renew` did not introduce it.

## Why it has not bitten harder (and why it still should be closed)

- The dangerous *sinks* are guarded elsewhere. `Http.setSessionCookie (JWT.renew …)` is caught by
  the argument-position rule; and `Http.setSessionCookie` validates at runtime that its argument is a
  well-formed JWT and raises otherwise, so a `check-fail` cannot reach a `Set-Cookie` header. So the
  session feature is fail-closed in practice.
- But the general shape — `let x = <check-shaped call>` then use `x` as if it succeeded — can still
  produce a wrong answer on the error path for any check-shaped function whose result is later read
  by field access, pattern match, or arithmetic. It is the same class the two existing rules exist to
  close; the `let` binding is just the case they miss.

## Goal

A `let`-binding whose right-hand side is a saturating call to a check-shaped callee, **without**
`check`, is a compile error with a guided fix ("bind it with `let x = check JWT.verify …`", offering
the `check` insertion as a machine-applicable edit).

## The design tension to resolve

The rule must NOT reject the legitimate reasons to name a check function without calling it:

- **partial application / higher-order use** — `List.filterCheck (checkInRange 0 100) xs`,
  `List.allCheck checkFn xs` hand a check *function* (a partial application), not a check *result*.
  The existing `check_shaped_arity` / `saturating` logic in `checker.ml` already distinguishes a
  saturating call from a partial one; reuse it, do not reinvent it.
- **a bare reference** — `check f a b` passes `f` as a bare head; that must stay legal.

So the rule fires only on a **saturating** call to a check-shaped callee in RHS position, mirroring
the argument-position rule that already draws exactly this line. The cleanest implementation is
probably to extend the existing check-shaped detection to the `let`-RHS position rather than write a
third independent walker — the three sites (statement, argument, let-RHS) should share one notion of
"an unwrapped check result is escaping here."

## Verification bar

- `let x = JWT.verify token key` (and `JWT.renew`, `Crypto.checkPassword`, …) without `check` is a
  compile error naming the callee, with a `check`-insertion fix that round-trips (apply → re-check →
  gone).
- `let x = check JWT.verify token key` compiles.
- `List.filterCheck (checkInRange 0 100) xs` and `check f a b` still compile (no false positives).
- The existing corpus still compiles, or each newly-rejected site is a real latent bug that gets the
  `check` it was missing.
- `./ci.sh` green.

## Related

- `checker.ml` — `is_check_shaped_name`, `call_head_check_shaped`, `check_shaped_arity`, the
  argument-position walk, and the two existing "bare check" diagnostics (`:4295`, `:4400`).
- `validation_common.ml` — the `CheckKind` rows (`JWT.verify`, `JWT.renew`, …) that define
  "check-shaped".
- `roadmap/completed/response_metadata_and_cookies.md` and the `JWT.renew` work, where this was
  found and where `compiler/test/test_session_cookie.ml` documents it as the one property the
  language does NOT yet enforce (`test_renew_in_argument_position_is_refused`).
