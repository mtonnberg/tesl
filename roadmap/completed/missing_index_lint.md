# Whole-Program Missing-Index Lint

Phase 3 of `roadmap/completed/database_indexes.md`, split out because Phases 1
and 2 (declaration + DDL + the `onConflict` compile check) shipped 2026-08-04
and this part is independently shippable.

## Status: IMPLEMENTED 2026-08-04

`compiler/lib/index_lint.ml`, called from `Linter.lint_file`; codes registered in
`error_codes.ml`; 21 cases in `compiler/test/test_index_lint.ml`.

Implementation notes worth keeping:

- **Queries are read through the EMITTER.** `Emit_racket.extract_select_query`
  and its siblings (`extract_multiline_select_query`, `extract_delete_query`,
  `extract_delete`, `extract_update`, `parse_upsert_expr`) are the same functions
  that produce the SQL, so the lint reasons about the query the program actually
  runs. A private re-parse would drift.
- **Usages are keyed on query identity** — (function, entity, binder) — **not on
  a source line.** Two things force it: the nested applications of one query's
  own spine each match the extractor with a partial clause list, and the
  multi-line clause form arrives through a rebuild carrying
  `Location.dummy_loc`. A line-keyed grouping reported that query twice (once at
  1:1, once with the weaker single-column suggestion). The reported position is
  the earliest real location for the query, falling back to the function.
- **One finding per missing index, not per call site.** Three call sites needing
  the same index produce one W092 saying "3 queries on `X` constrain …". Three
  copies of the same instruction is how a lint gets ignored wholesale.
- **`onConflict` columns mark an index used but never demand one** — a missing
  unique index there is already a hard compile error from Phase 2, so warning
  would duplicate it.

**It immediately found 7 real missing indexes in the shipped corpus**, all on
foreign-key-ish columns that every request filters by: `Todo.ownerId`,
`User.emailAddress`, `ChatUser.username`, `Message.roomId`, `Note.authorId`
(twice), `Document.ownerId`. All fixed. `user-service-api` got
`unique index [emailAddress]` rather than a plain one: `register` already
rejects a duplicate address with 409, so uniqueness was the intended invariant
and the index both enforces it and closes the race where two concurrent
registrations pass that check.

Verified load-bearing by mutation, not just by green tests: including `test`
blocks fails exactly the test-block silence case, and disabling the
Postgres-backend filter fails exactly the three backend-suppression cases.

## Why this is the interesting half

Indexes can now be declared, but nothing tells a developer they forgot one.
Every other language leaves that to production latency graphs or to `psql`,
because a compiler that sees one query at a time cannot know the program's whole
query set. Tesl can: every `where`, `order`, `innerJoin` and `groupBy` column of
every query in the program is already known at compile time, and so is every
declared index. Comparing the two is the differentiating feature — the reason
indexes belong in the language rather than in a migration folder.

## Design

- **W092** — a query filters, joins or orders `E` on column(s) that no declared
  index can serve. Leading-column-prefix awareness is enough matching
  sophistication for v1: an index on `[orgId, createdAt]` serves a filter on
  `orgId` alone.
- **W093** — a declared index that no query in the program uses. Pure write
  amplification; the inverse of the same analysis.

Both are **warnings, never errors**: index need is a function of table size and
selectivity, which the compiler cannot see. Suppress W092 when the columns are
the primary key (already indexed) and when the entity's database uses the
`Memory` backend (nothing to index).

W092 and W093 are the next free warning codes (linter.ml currently defines
W001–W091).

## Groundwork already in place

- Declared indexes: `entity_form.indexes` (ast.ml), one `entity_index` per
  declaration, validated by `check_entity_indexes`
  (validation_structural.ml).
- Query columns: the SQL clause walkers already exist for other passes —
  `check_sql_field_names` and `check_sql_where_clauses` resolve entity and
  field names per query, and `record_sql_operand_field_accesses` (checker.ml)
  already infers value-side field accesses for WHERE operands.
- Lint registration: add a pass and call it from `lint_file`
  (linter.ml:1628). There is no registry.

## Risks

- False positives are the whole risk. A noisy W092 gets suppressed wholesale and
  then the real ones are invisible. Prefer under-reporting: only warn when NO
  declared index has the column as a usable prefix.
- The linter does not run during `--check` (the SEC005 lesson), so this must not
  be the only place a genuinely required index is reported — which is exactly
  why the `onConflict` requirement was made a hard checker error in Phase 2
  rather than a lint.

## Scope

Medium — the largest piece of the original item. Mostly reusing the existing
per-query column resolution, plus the prefix-matching rule and two diagnostics.

Move to `completed/` when: a program filtering on an unindexed column warns with
W092, a declared-but-unused index warns with W093, and neither fires on the
existing corpus without a real cause.
