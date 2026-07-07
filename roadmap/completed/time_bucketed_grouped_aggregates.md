# Server-side time bucketing + grouped-aggregate rows (GitHub #29)

**Status: IMPLEMENTED (2026-07-06); TimeZone ADT upgrade 2026-07-07.** Shipped as
designed below, then upgraded per review: the trunc functions take a **`TimeZone`
value instead of a raw Int offset** — a FIXED ADT (`Utc`, `FixedOffset minutes`, plus
489 IANA zone constructors baked from the system zoneinfo tree by
`scripts/gen-tz-zones.py`, links like Europe/Stockholm included). Zone constructors are
**DST-correct per instant**: the runtime reads the system tzdata directly
(`dsl/private/tzif.rkt` — TZif v2/v3 + POSIX footer rules, validated 0-mismatch against
Python zoneinfo across 312 zones × 95 instants and against PostgreSQL's own tzdata in
the parity suite: 91 checks incl. Lord Howe half-hour DST); on PostgreSQL zone keys
lower to `date_trunc(… AT TIME ZONE $zone)` so PG's engine does the per-row DST work.
`Time.offsetAt zone ts` exposes the instant's offset. A typo'd zone
(`EuropeStokholm`) is an unknown-constructor compile error; a raw Int offset is a type
error. tzdata-version caveat documented (future instants; pin via nix — e.g. tzdata
2026b makes British Columbia permanent MST). Seam test: tests/timezone-zones-test.rkt
(every baked zone resolves on this system, 1473 checks). Surface:
`Time.truncHour/Day/Week/Month/Year offsetMinutes ts : PosixMillis` (pure, engine in
`dsl/private/time-trunc.rkt` — Hinnant civil arithmetic) + `selectCountBy`/`selectSumBy
… groupBy <key>` returning `List (Tuple2 key aggregate)` ordered by key. Fail-closed
sweep landed with it: `groupBy` on scalar aggregates / plain select, missing or
duplicate `groupBy` on the *By forms, unknown key fields, trunc on non-PosixMillis
columns, and order/limit/offset/innerJoin on grouped forms are all compile errors
(`validation_advanced.ml check_group_by_rules`) — previously groupBy was silently
dropped at runtime, and expression keys emitted modules that failed to load.
PG bucket SQL (integer floor for hour/day/week, date_trunc for month/year) is
parity-tested against the reference engine on a real temporary PostgreSQL:
`tests/sql-group-by-pg-test.rkt` (41 checks; units × offsets incl. pre-1970 and +5:30).
Other tests: `compiler/test/test_group_by.ml` (10), `tests/sql-group-by-tests.tesl`
(8, Memory backend). Docs: LANGUAGE-SPEC query grammar + "Grouped aggregates" section,
lesson21 rewrite. Calendar FILTERING documented as client-side trunc + sargable range
where (no SQL bucketing needed for "rows today"/"last 5 days"/"sum today").

## Original ask (issue #29)

Bucket time entries by day/week/month **server-side** ("break March down per day" →
`[(2026-03-01, 120), (2026-03-02, 240), …]`), so the backend grounds a chart instead of
shipping every row. Two missing pieces:

1. a `PosixMillis` date-part/truncation usable **inside the query DSL** (a day/week/month
   bucket key from a `PosixMillis` column);
2. a grouped-aggregate query form returning **per-bucket rows** — today
   `selectSum`/`selectCount` return a single scalar even with `groupBy`.

Mikael's framing: keep `PosixMillis` as the Tesl surface type; a datetime may be used
*under the hood* if needed.

## What is actually true today (mapped 2026-07-06)

- `PosixMillis` = newtype over Int, stored as `BIGINT` millis (the one deliberate BIGINT
  exception, LANGUAGE-SPEC §11.8). **No storage change is needed** — bucketing can happen
  in the generated SQL expression (`date_trunc` on a converted timestamp, cast back to
  millis), which is exactly the "datetime under the hood, PosixMillis at the surface"
  shim with zero migration.
- `groupBy e.field` parses on every select form, is never type-checked
  (`groupBy e.noSuchField` compiles), and is **silently dropped** by every aggregate
  runtime — `selectSum … groupBy e.f` returns the whole-set scalar on both backends
  (lesson21 even documents this). `groupBy <expression>` (the issue's workaround) emits
  a Racket module that **fails to load** (`groupBy: unbound identifier`) — the classic
  checker-accepts-what-codegen-cannot-lower fail-open.
- Aggregates return bare proof-free scalars; `Tuple2` exists at both the type level and
  runtime (`adt-value` with `.first`/`.second`), so `(bucket, aggregate)` rows are
  representable; no query form projects non-entity rows today.

## Design

### 1. Calendar truncation functions (Tesl.Time)

```
Time.truncHour  : Int -> PosixMillis -> PosixMillis   -- offsetMinutes, instant
Time.truncDay   : Int -> PosixMillis -> PosixMillis
Time.truncWeek  : Int -> PosixMillis -> PosixMillis   -- ISO week (Monday start)
Time.truncMonth : Int -> PosixMillis -> PosixMillis
Time.truncYear  : Int -> PosixMillis -> PosixMillis
```

Each returns the **bucket-start instant** for the wall clock at a fixed UTC offset in
minutes (`0` = UTC; matches the fixed-offset `TimeZone` userland module in the issue
thread — DST-correct zones need the IANA db and stay out of scope). The result stays
`PosixMillis` — no new date type at the surface.

- They are ordinary runtime functions (pure integer + Hinnant civil-calendar arithmetic
  in `tesl/time.rkt`), so the same bucketing is available client-side, in folds, and in
  tests.
- Inside a query they are recognized structurally and lowered to SQL: hour/day/week as
  exact integer floor arithmetic on the BIGINT column; month/year via
  `date_trunc('month'|'year', to_timestamp((col+off)/1000.0) AT TIME ZONE 'UTC')`
  shifted back to millis. The **Racket function is the semantic reference**; a test
  asserts PG ≡ Racket on boundary instants (epoch, leap day, week/月 rollovers,
  negative offsets).
- The Memory backend calls the same Racket function — parity by construction.

### 2. Grouped-aggregate select forms

```
selectCountBy e from Entry [where …] groupBy <key>            : List (Tuple2 K Int)
selectSumBy e.minutes from Entry [where …] groupBy <key>      : List (Tuple2 K V)
```

- `<key>` is fail-closed structural: either `e.field` (a declared column; K = its
  declared type) or `Time.truncX <offsetExpr> e.field` on a `PosixMillis` column
  (K = `PosixMillis`; `offsetExpr` is an ordinary Int expression, bound as a SQL
  parameter). Anything else is a compile error.
- Exactly one `groupBy` clause is REQUIRED on the *By forms (compile error otherwise).
- Result rows are `Tuple2 key aggregate`, **ordered by key ascending** (`ORDER BY 1`;
  Memory backend sorts) — deterministic chart series.
- Proof story: like the scalar aggregates, results are plain proof-free values (no
  `FromDb` — no entity row flows out; never `ForAll`).
- Capability: `dbRead`, same as every read.
- PG: `SELECT <key-sql> , COALESCE(SUM(col),0) FROM t [WHERE …] GROUP BY 1 ORDER BY 1`;
  keys decode through the same field/newtype codec as entity reads (a `PosixMillis` key
  comes back as `PosixMillis`).
- `selectMaxBy`/`selectMinBy` deferred (same recipe; add on demand).

### 3. Close the existing groupBy fail-opens (the class, not just the instance)

- `groupBy` on the **scalar** aggregate forms (`selectCount`/`selectSum`/`selectMax`/
  `selectMin`) becomes a compile error with the hint "use selectCountBy/selectSumBy —
  the scalar form loses the per-group breakdown" (today: silently dropped).
- `groupBy` on plain `select`/`selectOne` becomes a compile error (today: PG 42803 at
  runtime on Postgres, silently ignored on Memory).
- A `groupBy` argument that is not a recognized key shape becomes a compile error
  (today: emits a module that fails to load).
- The group-key field is checked to exist on the entity (today: `e.noSuchField`
  compiles).
- lesson21's "groupBy returns the aggregate for the whole matching set" section and the
  spec grammar are rewritten accordingly.

### Implementation map

- **type_system.ml**: `Time.truncHour/Day/Week/Month/Year` types + Tesl.Time import
  list; `selectCountBy`/`selectSumBy` head names where the SQL registries need them.
- **parser.ml**: add the two heads to `is_select_expr` (modifier merging is already
  generic).
- **checker.ml**: `classify_lowered_query` + aggregate-type refinement for the new
  heads → `List (Tuple2 K V)`; infer the `offsetExpr` against Int; key-shape + key-field
  resolution shares one structural helper with the emitter-side seed.
- **validation** (`validation_common.ml` SQL registry, `validation_advanced.ml`):
  read-capability charge for the new heads; the groupBy fail-closed rules in §3.
- **emit_racket.ml**: seed `kind` + `group_key` extension; lower to
  `(select-sum-by (group-key 'day <off> <field-ref>) (entity-field-ref E 'col) (from E) (where …))`.
- **dsl/sql.rkt**: `group-key` struct; `select-count-by`/`select-sum-by` combinators
  (PG SQL builder + Memory group/sort via the shared trunc fn); key decode through the
  existing field codec.
- **tesl/time.rkt**: the five trunc functions (floor-div + Hinnant `civil_from_days`
  / `days_from_civil`).
- **Tests**: OCaml static suite (typing, fail-closed rejections); Tesl test file
  (Memory-backend grouped sums/counts incl. zone rollovers, trunc fns as plain
  functions vs known instants from the issue thread); PG parity test (self-skips
  without PostgreSQL) asserting PG bucket ≡ Racket bucket per unit.
- **Docs**: LANGUAGE-SPEC query grammar + aggregate section, lesson21 update,
  Tesl.Time list.

### Non-goals

- DST/IANA time zones (fixed offsets only — same boundary as the issue's userland
  module; revisit with a real tz database story).
- Changing `PosixMillis` storage (stays BIGINT millis; datetime exists only inside the
  generated SQL expression).
- General projection queries (`select (e.a, e.b)`) — only the `(key, aggregate)` pair
  forms.
