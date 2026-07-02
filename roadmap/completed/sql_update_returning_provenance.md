# Verify FromDb provenance of `update`/`delete`-`returning` values (review §3.2 write variant)

**Status:** OPEN · **Effort:** M · discovered while closing A2 (`stability_wave`).

## The problem (confirmed exit-0 on `stability_wave`)

`check_pk_match` (`compiler/lib/validation_capabilities.ml`) verifies a declared `FromDb (col == subj)`
provenance against the WHERE of a **`select`/`selectOne`** (and the sibling-mask/OR cases are now
closed — A2). But it does **not** verify the WHERE of a row-producing **write**
(`update … returning one`, `updateAndReturnOne`, `deleteAndReturnResult`). The write's WHERE
condition is not fused into a select-head spine (unlike selects, whose modifier chain is merged by
`merge_sql_continuation`), so `sql_root` never recognises it and no unification runs.

Reproduced by mutating the shipped `example/todo-api.tesl` `completeTodo`: changing the update from
`where todo.id == todoId` to `where todo.ownerId == requestUser.id` (wrong column for the declared
`FromDb (Id == todoId)`) still `--check`s at **exit 0**. The emitted `update-many!` writes by
`ownerId` yet the value is returned carrying `FromDb (Id == todoId)` — a forged write provenance
(BOLA-write). A where-less returning-update behaves the same.

## Why it matters

This is the "more dangerous" half of review §3.2: a read-only-looking handler can write to and then
"prove ownership of" rows it does not own. It's the same forgery class as the SELECT provenance
(now closed), leaking through the write path.

## Fix approach

Reuse the emitter's canonical SQL-clause extractor rather than re-deriving it: `collect_sql_clauses`
/ `extract_select_query` in `emit_racket.ml` already parse `update`/`delete`-returning WHERE clauses
(distinguishing `where` from `set` assignments) to emit SQL. Lift that extraction into a shared
module (e.g. `validation_common` or `ir`) so BOTH the emitter and `check_pk_match` derive the WHERE
from one source (dedup-by-construction), then unify the write's WHERE against the declared
`(col, subj)` exactly as selects are unified — with the same fail-closed rules already added in A2
(disjunction ⇒ reject; provenance tied to the returned value via the return-flow closure).

Ship with the missing negatives: wrong-column returning-update, where-less returning-update,
`OR` in a returning-update WHERE, and the guard-masks-update sibling case; plus positives (a
correct-column returning-update still compiles).

## Refs
- Review: `TESL-REVIEW-TECHNICAL.md` §3.2 (write variant, `A1-MASK-NODATAFLOW`).
- Source: `validation_capabilities.ml` `check_pk_match`; `emit_racket.ml` `collect_sql_clauses` /
  `extract_select_query` (the extractor to share).
