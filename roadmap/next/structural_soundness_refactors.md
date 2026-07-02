# Structural soundness refactor — S6a (S5b is DONE, see below)

> **S5b landed 2026-07-02** (gensyms hyphenated, reserved-name machinery deleted).
> **S6a remains** — a structural **upgrade**, not an open soundness hole (the current
> rejection-based validation already rejects the unsound SSE-with-body case).
> A parallel attempt confirmed **S6a is feasible and byte-exact zero-emitted-diff**
> (binary `endpoint_clause = Http of http_clause | Sse of sse_clause`; SSE cannot
> hold body/response/return by construction; consumed via non-`_` matches across
> parser/ir/checker/validation_structural/emit_racket/emit_elm/linter/compile), but
> it landed on a 72-commit-stale worktree base that cannot be cleanly integrated
> with this wave's heavy edits to the SAME files (checker/ir/emit_racket/
> validation_structural). **S5b was blocked**: its S5a reserved-name machinery and
> `test_eval_review_fixes.ml` are absent from that stale base, and hyphenation +
> machinery-deletion + a ~175-`.rkt`-snapshot regen must be one atomic change on the
> current base. Confirmed S5b scope: **8 underscore gensym patterns across 21
> call-sites** in `emit_racket.ml` (`tesl_ignored_%d`×6, `tesl_proof_binding_%d`×4,
> `tesl_checked_%d`×4, `tesl_proof_bind_%d`×2, `tesl_case_%d`×2, `tesl_lazy_import_path_%d`,
> `tesl_lazy_import_%d_%d`, `_tesl_p%d_%d`) + the one already-hyphenated `tesl-lambda-%d`.
> Redo both as a focused pass on a worktree cut from the CURRENT `main`.

> Relocated 2026-07-02 from `close_all_open_issues.md` (Wave 3, items C11/S6a and
> C10/S5b). Backlog IDs: **S6a**, **S5b** (`stability_deferred_backlog.md`).

These are structural-guarantee **upgrades**, not open soundness holes — the current
validation already rejects the unsound cases. Each replaces a rejection-based guard with
a construction that makes the unsound state unrepresentable.

---

## S6a / C11 — routes via an exhaustive clause sum-type

*Closes generator class G3.* Review §8.1 (block-grammar proliferation).

### The problem

HTTP and SSE endpoints share a route representation, so an SSE endpoint *can structurally
hold* a body/response field even though it must not. Today the validation **rejects** the
unsound combinations, but nothing at the type level prevents them from being constructed.

### Fix approach

Split HTTP/SSE into distinct endpoint variants (or a `clause` sum type) consumed via
non-`_` matches, so an SSE endpoint structurally cannot hold a body/response. (S6b —
multi-channel SSE — was reversed as redundant and is done.)

There is an unsettled shape decision: a **ternary** split (SSE | GET | POST-etc) vs a
**binary** split (SSE | HTTP). Settle this before the refactor.

### Effort

**L** — a moderate AST refactor touching a public AST layer plus all three emission
paths.

---

## S5b / C10 — DONE (2026-07-02)

Every generated temp is now minted with a lexer-illegal hyphen (`tesl-case-N`,
`tesl-ignored-N`, `tesl-p-N-M`, …), so a user binder can never collide with one by
construction; `is_reserved_generated_name` / `check_reserved_generated_names` were
deleted (the 5 EMIT-1 "reserved name rejected" tests flipped to "accepted") and a
property test pins that no underscore-grammar temp is ever emitted. All 124
`.tesl`-paired `.rkt` snapshots + the lifted-stdlib snapshots regenerated. See
`roadmap/completed/review_2026_07_closed_items.md`. Full gate green.

---

## Refs

- Review: §8.1 (19 bespoke block grammars; the "smaller core" the spec defers).
- Backlog: `stability_deferred_backlog.md` → **S6a**, **S5b**.
- Source: AST layer + `emit_racket.ml` (three emission paths); `validation_names.ml`
  (reserved-name machinery to delete in S5b).
