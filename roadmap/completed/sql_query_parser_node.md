# Parse SQL queries into an AST node

**Status: Implemented.**

## Delivered

Tesl now builds a dedicated `ESqlQuery` node in the parser for all supported query forms:

- selects: `select`, `selectOne`, `selectCount`, `selectSum`, `selectMax`, `selectMin`,
  `selectCountBy`, and `selectSumBy`;
- writes: `insert`, `insertMany`, `upsert`, `update`, `delete`, and
  `deleteAndReturnResult`;
- clauses: `from`, `in`, `where`, ordering, limits, offsets, grouping, joins, and `returning`.

The parser consumes SQL clause keywords and source spans before constructing the node, including
multiline and parenthesized continuations. `sql_query.ml` owns the shared query payload and keeps a
compatibility parser for existing callers, but compiler consumers no longer recover SQL by
pattern-matching ordinary application syntax. The AST visitor, checker, capability validator,
index linter, proof validation, mutation handling, desugarer, and Go backend all consume the
canonical node.

Malformed SQL-shaped expressions fail closed through the normal structural diagnostics instead of
being silently emitted as ordinary function calls.

## Evidence

- `compiler/test/test_roadmap_emitters.ml` covers parser-produced SQL nodes and OpenAPI/SQL emitter
  behavior.
- Full compiler build and test suite pass, including SQL corpus and Go emitter snapshots.
- Existing examples and generated Go snapshots were regenerated without SQL emitter drift.

## Related files

- `compiler/lib/ast.ml`
- `compiler/lib/parser.ml`
- `compiler/lib/sql_query.ml`
- `compiler/lib/ast_visitor.ml`
- `compiler/test/test_roadmap_emitters.ml`
