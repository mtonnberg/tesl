# First-Class Database Indexes

Declare secondary / composite / unique indexes on an `entity`, create them
during the existing auto-migration, and use the whole-program query set to
check them at compile time.

## Status: Phases 1 + 2 IMPLEMENTED 2026-08-04

Shipped exactly as designed below, meeting this item's own move-to-completed
criterion. Phase 3 (the whole-program missing-index lint) was deliberately not
built and is tracked separately in `roadmap/next/missing_index_lint.md`.

What landed:

- Surface `[ "unique" ] "index" "[" field {"," field} "]" [ "as" <string> ]` as
  an entity-body entry (LANGUAGE-SPEC §11.8). `index`/`unique`/`as` stayed
  contextual identifiers — `parser.ml:at_entity_index` uses one token of
  lookahead, and a ratchet test pins that a field, a `let` binding and a
  function parameter named `index` all still compile.
- `entity_index` in ast.ml; `check_entity_indexes` +
  `check_index_name_collisions` in validation_structural.ml (all six rules,
  plus the empty-list case);
  emit_racket emits one `#:indexes ((kind (field …) name-or-#f) …)` datum.
- Runtime: `parse-entity-indexes` (total — unknown kind raises),
  `entity-index-effective-name` (derived `<table>_<col>…_idx` + 63-byte
  truncation with an FNV-1a suffix), `index-create-sql`,
  `postgres-existing-indexes` / `postgres-index-present?` (column list +
  uniqueness, never name), and `postgres-ensure-entity-indexes!` wired into
  `postgres-ensure-entity!` with the fresh / populated split.
- Memory backend enforces declared UNIQUE indexes on insert, upsert and update
  (`check-in-memory-unique-indexes!`), with PostgreSQL NULL semantics.
- Phase 2: `check_upsert_conflict_target` rejects any `onConflict` column list
  that is neither the primary key nor a declared `unique index`, matching the
  emitter's upsert shape exactly (a looser prefix match reported one upsert
  three times — pinned by a test).
- Tests: `compiler/test/test_database_indexes.ml` (27 cases),
  `tests/sql-index-tests.rkt` (34 cases), and `run-index-tests` in
  `tests/postgres-test.rkt` (indexes present in `pg_index` after boot,
  idempotent re-boot, PostgreSQL enforcing the unique index, empty-table
  treated as fresh, populated-table warn-vs-refuse split).

Two findings from doing it:

1. The Memory-backend unique enforcement immediately caught real duplicate
   fixture data in `example/learn/lesson21-sql-reference.tesl` — two tests
   inserting a product named "Hammer". That file declares no `database`, so all
   its tests share one module-level store and never reset; the parity
   enforcement is what surfaced it.
2. `entity-spec` is a positional struct; adding `indexes` needed the
   `tests/tesl-test.rkt:4970` hand-written constructor updated too. Only two
   construction sites exist, which is why this was cheap.

## Motivation

Today Tesl can declare **no** index at all. `primaryKey` yields the implicit
PK B-tree; nothing else is expressible. Every non-trivial production table
needs more, so this is a hard adoption blocker for real workloads: an app with
`select i from Issue where i.orgId == orgId order i.createdAt desc limit 50`
sequentially scans the whole table on every request forever, and the only
workaround is running `CREATE INDEX` out of band, which Tesl neither knows
about nor preserves — a fresh environment silently comes up unindexed.

**It is not only a performance gap — it makes an existing language feature
unsound in production.** `upsert E { … } onConflict [cols] doUpdate [cols]`
(LANGUAGE-SPEC §13, `<upsert-expr>`) lowers to PostgreSQL
`insert … on conflict (cols) do update …` (dsl/sql.rkt:2319). Postgres
requires a unique index on exactly `cols` to infer a conflict target;
without one it raises *"there is no unique or exclusion constraint matching
the ON CONFLICT specification"* at runtime. Since Tesl can only produce a
unique index for the primary key, **every `onConflict` on a non-PK column
list fails in production** — and there is no way to fix it in the language.

Worse, it fails green: `in-memory-upsert-one!` (dsl/sql.rkt:1478-1496) finds
the conflicting row by a linear scan over *whatever* conflict fields were
named, with no uniqueness requirement at all. So `onConflict [email]` passes
`tesl test` on the Memory backend and dies on Postgres. That directly
violates the Memory/Postgres parity principle the spec states for NULL
semantics ("so tests are faithful to production", §11.8). The whole corpus
only ever exercises `onConflict [id]` (the PK), which is why this has never
been caught: `example/learn/lesson21-sql-reference.tesl:323` is the single
use site.

Secondary drivers: `innerJoin E on a.x b.y` (§13) joins on an unindexed
column by construction today; `order`/`limit` pagination has no supporting
index; and the queue subsystem already needs indexes badly enough that one is
hardcoded (`tesl_jobs_dequeue_idx`, dsl/sql.rkt:2031) — a runtime-owned
privilege user entities do not get.

## Verified groundwork (2026-08-04)

Compiler:
- `entity_form` (compiler/lib/ast.ml:292) = name, table, primary_key, fields,
  loc. `field_def` (ast.ml:56) already carries `db_type` (`@db(...)`) and
  `proof_ann`, so per-field annotations have precedent.
- `parse_entity_form` (parser.ml:3212) is a fixed clause sequence
  (`entity` NAME `table` STR `primaryKey` IDENT) followed by
  `parse_field_defs` (parser.ml:3131), which is a `while … until RBRACE`
  loop — it tolerates a new entry shape in the body without restructuring.
- `table` / `primaryKey` are real lexer keywords (lexer.mll:29-30), but the
  SQL clause words (`where`, `order`, `onConflict`, `doUpdate`) are **not** —
  they are parsed as plain identifiers and recognised positionally
  (checker.ml:4889, validation_common.ml:362). `index` must follow the
  latter pattern, not the former: making `index` a global keyword would break
  every existing program using it as a variable or field name.
- `emit_entity` (emit_racket.ml:6023) emits
  `(define-entity Name #:source … #:table "…" #:primary-key … [Proof field : Type #:db-type …] …)`
  — adding a keyword argument is mechanical.
- `check_entity_structure` (validation_structural.ml:771) already validates
  non-empty table name + `primaryKey` naming a declared field. Natural home
  for index validation.
- `entity_json` (ir.ml:599) is the `--doc-json` / `tesl doc` catalog shape.
- Linter: codes W001–W091 exist, no registry — add a pass and call it from
  `lint_file` (linter.ml:1628). Next free codes are W092, W093.
- **No compile-time check whatsoever** on `onConflict` targets. `conflict :
  string list` (emit_racket.ml:884) is passed straight through.

Runtime:
- `entity-spec` (dsl/sql.rkt:166) = name, source, primary-key, fields,
  predicate, table. `field-spec` (:168) = entity, proof-name, key, type,
  primary-key?, column, db-type, nullable?.
- `postgres-ensure-entity!` (:1930) is the auto-migration: creates the table
  if absent; if present, adds missing columns **only when the table is
  empty** (:1948-1952 errors otherwise), allows only the lossless
  BIGINT/INTEGER→NUMERIC widening (:1972), and validates nullability and PK
  columns (:1987-2013). Conservative and fail-loud by design.
- `ensure-database-ready!` (:2079) wraps **all** DDL in **one**
  `call-with-transaction` (:2085). This is the decisive constraint:
  `CREATE INDEX CONCURRENTLY` cannot run inside a transaction block.
- No advisory lock; concurrent instances each run the transaction and rely on
  `if not exists` idempotence (:2031 precedent).
- Introspection helpers to mirror: `postgres-table-exists?` (:1877),
  `postgres-column-metadata` (:1892), `postgres-primary-key-columns` (:1904).
- Column naming goes through `field-column-name` (:263) and quoting through
  `quote-sql-identifier` — index DDL must reuse both, never re-derive.
- Memory backend rows are a `hash` keyed by PK (:1465) and `select` is a
  linear scan with predicate match (:1412) — a perf index is inherently a
  no-op there.
- Money/MoneyRate fields expand to 2 / 3 columns (`field-column-definitions-sql`,
  :495) and are already refused as PK (:438) and as upsert conflict keys
  (:2295, comment: *"A Money conflict target would need a unique index over
  both derived columns … fail closed"*).

## Recommended design

### Syntax — entity-body entries, not a field annotation

```tesl
entity Issue table "kanel_issues" primaryKey id {
  id:        String
  orgId:     String
  slug:      String
  status:    IssueStatus
  createdAt: PosixMillis

  index [orgId, createdAt]
  unique index [orgId, slug]
  index [status] as "kanel_issues_status_idx"
}
```

Grammar addition:

```text
<entity-body-entry> ::= <entity-field>
                      | [ "unique" ] "index" "[" <identifier> { "," <identifier> } "]"
                        [ "as" <string> ]
```

Rationale for this shape over the alternatives:

- **Entity-level, not `@db`-style per-field `@index`.** Composite indexes are
  the ones that matter in practice (`[orgId, createdAt]` is the shape of
  almost every real query), and a per-field annotation cannot express column
  order at all. One form that covers 1..n columns beats a shorthand that
  covers only n=1 plus a second form for the rest — Tesl has repeatedly paid
  for having two spellings of one rule. A single-column `index orgId`
  shorthand can be added later as pure sugar over the same AST node if users
  ask; do not ship both now.
- **Inside the field braces, not a new clause before them.** Locality (the
  index reads next to the columns it names) and it is the only position that
  needs no change to the fixed `parse_entity_form` clause sequence.
  Disambiguation from a field literally named `index` is one token of
  lookahead: `index :` is a field, `index [` / `unique index` is an index
  entry. `index` stays a contextual word, never a reserved keyword.
- **Auto-generated deterministic names, optional `as "…"` override.** Default
  `<table>_<col1>_<col2>_idx`, uniqueness-and-length handled by the compiler
  (see Traps). `as` exists for one concrete reason: adopting a database that
  already has hand-made indexes, so `create index if not exists` matches the
  existing object instead of building a duplicate.
- **No sort direction in v1.** Postgres scans a B-tree backwards, so
  single-column `DESC` buys nothing; only mixed-direction composites need it,
  and those are rare enough to defer.

### Phase 1 — declaration, validation, DDL

Compile-time validation (extend `check_entity_structure`,
validation_structural.ml:771 — cheap, whole-program `--check` gets it free):

1. every named identifier is a declared field of that entity;
2. no repeated field inside one index;
3. no two indexes on the same entity with the same (column list, uniqueness) —
   dead write-amplification;
4. Money / MoneyRate fields rejected as index columns, matching the existing
   PK and conflict-key refusals (sql.rkt:438, :2295);
5. an index whose column list is exactly the `primaryKey` is rejected as
   redundant (the PK index already exists);
6. explicit `as` names must be unique across **all entities in a database**,
   not per entity (see Traps).

DDL, threaded through the existing `postgres-ensure-entity!` flow, split by
the case distinction the current migration already makes:

| Table state | Plain index | Unique index |
|---|---|---|
| Created now (empty) | `create index if not exists` inline, in the existing transaction | `create unique index if not exists` inline |
| Exists, empty | same as above | same as above |
| Exists, non-empty, index absent | **warn loudly and boot**, printing the exact `CREATE INDEX CONCURRENTLY …` statement | **refuse to boot**, printing the same statement |

The asymmetry is the point, and it is the recommendation most likely to be
argued with, so stating the reasoning explicitly: a missing *plain* index is
a performance defect, and refusing to start a production service over a
performance defect is disproportionate — a deploy that merely adds an index
declaration must not be able to take the service down. A missing *unique*
index is a **correctness** defect: the program declares an invariant the
database is not enforcing, and `onConflict` inference (Phase 2) depends on it
existing. Booting anyway would be exactly the fail-open pattern this codebase
keeps having to close. Empty tables take neither branch because building an
index on zero rows is instant and lock-free.

Not attempting to build indexes on a populated table also avoids the
transaction constraint entirely: plain `CREATE INDEX` takes a `ShareLock`
that blocks writes for the whole build (an outage on a large table), and
`CONCURRENTLY` — the safe form — is illegal inside `call-with-transaction`
(sql.rkt:2085). Handing the operator the exact `CONCURRENTLY` statement is
strictly better than either option the runtime can perform itself. A
`tesl db sync-indexes` subcommand that runs those statements outside any
transaction (and reports `INVALID` leftovers from a failed concurrent build)
is the natural follow-up, but is not required for this phase.

Presence detection must compare **column list + uniqueness**, queried from
`pg_index`/`pg_attribute`, **not** index name. Name matching would report a
permanent phantom-missing index for every adopted database whose equivalent
index happens to be spelled differently.

Memory backend: plain indexes are accepted and ignored (nothing to index).
Unique indexes are **enforced** by the same linear scan the backend already
uses, because the parity principle is explicit in the spec and Phase 2's
compile-time story is only trustworthy if `tesl test` fails the same way
Postgres does.

### Phase 2 — the correctness payoff: check `onConflict`

With unique indexes declarable, `upsert … onConflict [cols]` becomes
checkable: error at compile time unless `cols` is exactly the `primaryKey`
or exactly matches the column list of a declared `unique index` on that
entity. Diagnostic should name the fix — the `unique index [cols]` line to
add. This converts today's production-only runtime failure into a compile
error, closes the Memory-passes/Postgres-fails divergence, and is small once
Phase 1 exists (the conflict list is already in hand at emit_racket.ml:884).

Do **not** mint a proof from a unique index in this phase. A `unique index`
is tempting evidence for an at-most-one-row fact, but the index can be
dropped or created outside Tesl, and the empirical lesson from this codebase
is that inferring a fact from an unverified external condition is how
forgeries get in. Note it as a future proof-carrying opportunity and leave
uniqueness purely operational for now.

### Phase 3 — whole-program missing-index lint

This is the part no other language can do, and the reason to build indexes
into Tesl rather than documenting `psql`. The compiler already knows every
query in the program and every column each one filters, joins, and orders
by. Compare that set against the declared indexes:

- **W092** — a query filters/joins/orders `E` on column(s) with no index that
  can serve them. Suppress when the columns are the primary key, and when the
  backend is `Memory`.
- **W093** — a declared index no query in the program uses. Pure write cost.

Warnings only, never errors: index need is a function of table size and
selectivity, which the compiler cannot see. Leading-column-prefix awareness is
enough matching sophistication for v1 (an index on `[orgId, createdAt]`
serves a filter on `orgId`).

## Out of scope for this item

- Partial indexes (`where status = 'pending'`) — needs a predicate
  sublanguage in the entity body. Valuable (the hardcoded queue index is
  exactly this shape) but a separate decision.
- Expression indexes, `GIN`/`GiST`/`BRIN` types, `INCLUDE` columns,
  collations, fillfactor.
- Dropping indexes that exist in the database but are no longer declared.
  Follows the existing migration philosophy: Tesl adds, never destroys.
- Index-aware query planning or a cost model. Tesl emits SQL; Postgres plans.

## Traps

- **63-byte identifier limit.** Postgres silently truncates longer names with
  a `NOTICE`, and two generated names sharing a 63-byte prefix then *collide*,
  so `if not exists` matches the wrong object. Generated names must be
  truncated-with-hash by the compiler, deterministically.
- **Index names are per-schema, not per-table** (they are `pg_class`
  relations). Two entities each declaring `as "created_at_idx"` collide at
  runtime. Validate `as` names across the whole `database`, not per entity.
- `CREATE INDEX CONCURRENTLY` is illegal in a transaction block, and leaves an
  `INVALID` index behind on failure that must be dropped before retrying.
- Money/MoneyRate fields are multi-column; anything walking index columns must
  go through the existing column-expansion helpers, never assume 1 field = 1
  column.
- The emitter is the authority: a lint or validation passing proves nothing
  about the SQL that ships. Cover the emit path structurally.

## Tests required

- Compile-time: one case per validation rule above, plus a case asserting
  `index` still works as an ordinary field name and as a variable name.
- Seam test (emitter-is-authority): for a fixture entity, assert the emitted
  Racket carries the index list, and assert the exact generated DDL string.
- Postgres integration (tests/postgres-test.rkt has the migration harness at
  :176/:211): after boot, `pg_index` actually contains the declared index;
  the non-empty-table plain case warns and boots; the non-empty-table unique
  case refuses; a duplicate-data unique build fails loudly.
- Parity: the same `onConflict [non-pk]` program fails on both Memory and
  Postgres backends (this is the regression that motivates the item).
- Structural ratchet on index kinds so a future kind cannot be added without
  handling in every walker.

## Scope

Medium. Phase 1 is a small AST/parser addition, one validation function, one
emit keyword, and DDL in an existing flow. Phase 2 is small and is the
highest correctness-per-line work in the item. Phase 3 is the largest piece
and is independently shippable.

Docs to update: LANGUAGE-SPEC §11.8 grammar + column-mapping section,
manual database chapter, `tesl doc` entity catalog (ir.ml:599), and
regenerate embedded docs (ci.sh phase 5 fails on any uncommitted docs edit).

Move to `completed/` when: a declared composite and unique index are created
by auto-migration and verified present in `pg_index` by an integration test,
and `onConflict` on a non-PK column list is a compile error unless a matching
`unique index` is declared (Phases 1+2).
