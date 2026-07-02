# Int boundary — remaining width-match + additive widths (NT-07 follow-ons)

**Status:** OPEN · **Effort:** compile-time width-match S–M
· **Split from** `roadmap/completed/int_boundary_narrowing.md` (NT-07). The soundness hole
(silent Int truncation at storage/wire boundaries) is **CLOSED and gate-green** in that item;
this file tracks only the parts that were **not** implemented there. None is required for
soundness — they are defense-in-depth and additive ergonomics.

## 1. Compile-time width-match at the `insert`/`update`/`set` SQL forms (defense-in-depth)

NT-07 delivered the compile-time width contract everywhere a record is typed normally —
**bare construction is width-checked** (`Widget { count: <Int> }` where `count : Int32` is a
compile error, "cannot unify Int with Int32"). The one place it is **not** yet enforced at
compile time is the `insert`/`update`/`set` SQL write forms: their record argument parses as
`EConstructor name [bare ERecord]`, which bypasses the typed-record field-check that guards
ordinary bare construction.

- **Soundness already holds without this:** an out-of-range `Int` written to an `int4`
  (`Int32`) column is rejected by **Postgres at write time** — a loud runtime failure, *not* a
  silent truncation. This item only moves that rejection from runtime to compile time.
- **Fix:** thread the entity's declared field types through the `insert`/`update` handler's
  record argument so the same field-type check that already guards bare construction fires at
  the SQL write site (assigned value's type must equal the column's declared type — `Int`↔
  `NUMERIC`, `Int32`↔`int4`; mismatch is a type error, no runtime cost).
- **Prior attempts (from the NT-07 pass, both reverted):** (a) running `infer_expr` on the whole
  arg broke the corpus (14 fails: "bare record" / "unknown constructor"); (b) matching
  `EConstructor [ERecord]` and checking fields didn't fire. A correct fix needs the entity
  field-type table available at the write site, matched positionally/by-name against the record
  arg — verify corpus-green at each step (`compiler/_build/default/bin/main.exe --check-all
  example`) before touching the `.rkt` snapshots.
- **Test:** assigning an `Int` to an `Int32` column via `insert`/`update`/`set` → compile-time
  type error (today it compiles and fails loud at Postgres).

