# Parse SQL queries into an AST node

## What

Tesl writes a query as ordinary application syntax — `selectOne t from Task where t.id == id`
parses as `EApp`/`EBinop`, not as a dedicated node — and the structure is RECOVERED
afterwards by `lib/sql_query.ml`. Move that recovery into the parser: build a real
`select`/`insert`/`insertMany`/`upsert`/`update`/`delete` node, and have every consumer read
it instead of re-deriving it.

## Why

- **Errors point at the wrong place.** A typo'd clause keyword (`frm` for `from`) is reported
  against the enclosing expression, because by the time anything notices, the token is gone.
  A parser node reports the token.
- **The structure is inferred, not stated.** Recovery is ~140 lines of pattern matching over
  expression shapes; a shape the matcher does not anticipate is silently "not a query"
  rather than a malformed one.
- Already partly addressed: the recovery is shared (2026-08-14) so no backend reimplements
  it, and an unrecognised SQL keyword is now a `--check` diagnostic rather than an emit-time
  `failwith`. This item is the deeper fix, not a blocker for the Go DB work.

## Scope

All 8 select forms (`select`, `selectOne`, `selectCount`, `selectSum`, `selectMax`,
`selectMin`, `selectCountBy`, `selectSumBy`), the writes (`insert`, `insertMany`, `upsert`,
`update`, `delete`, `deleteAndReturnResult`), and the clause keywords (`from`, `in`, `where`,
`order`, `limit`, `offset`, `groupBy`, joins, `returning`). Five consumers switch from
recovery to reading the node: `emit_racket`, `emit_go`, `index_lint`, `validation_advanced`,
`checker`.

## Evidence it must carry

Byte-identical `.rkt` snapshots prove the EMITTERS agree, but not that the parser accepts the
same programs — so this needs its own acceptance-set evidence: compile every corpus file and
diff the diagnostics before and after. That is why it is its own item rather than part of a
migration slice.
