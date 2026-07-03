# Int boundary — compile-time width-match at SQL sites (NT-07 follow-on)

**Status:** COMPLETED (2026-07-02) — gate-green (all 11 phases, incl. live-PG aggregate).
· **Split from** `roadmap/completed/int_boundary_narrowing.md` (NT-07). NT-07 closed the
silent-truncation soundness hole; this item moved the remaining check from a runtime backstop
to a **compile-time** error, and — per the maintainer decision — made it a **strict, no-coercion
contract at every SQL site**.

## Delivered

**A column must be written and queried with its EXACT declared type — no coercion at any SQL
boundary.** An `Int` into an `Int32` column, or a bare primitive into a newtype column, is a
compile-time error at `insert`, `update … set`, AND `where` (previously only bare record
construction was checked; the SQL forms silently accepted the wrong type, caught — if at all —
only by Postgres at write time).

- **`insert` (`checker.ml`):** `insert Ent { .. }` flattens to `EConstructor Ent :: ERecord { .. }`
  (the constructor split from its record by the outer `insert` application). The insert arm
  rebuilds the tight `EApp { EConstructor; ERecord }` unit and infers it, so the existing
  typed-record field-by-field width check fires. (This was the arm that previously short-circuited
  to `TCon name`, leaving the record unchecked.)
- **`update … set` (`validation_advanced.ml`):** the `update b in Entity` row binder is threaded
  over the following `set` statements; each `set b.field = value` checks the assigned value's type
  against the column's declared type.
- **`where` made strict:** removed the §11.6 newtype-transparency (`resolve_nt`) from the WHERE
  field/RHS comparison, so a bare primitive compared to a newtype column is a type error too. The
  Int-vs-Int32 primitive case was already caught; this closes the newtype-coercion case.
- **Design decision (maintainer):** *all* SQL sites strict — coercion is not accepted anywhere.
  JSON/HTTP decode still constructs a newtype from its primitive (that boundary stays transparent);
  SQL does not. Documented in `LANGUAGE-SPEC.md` §11.6.

## Fallout fixed (real coercion bugs the check surfaced)

- `example/todo-api.tesl`: `ownerId: "mikael"` → `ownerId: UserId "mikael"` (a raw String was being
  written to a `UserId` column).
- `example/learn/lesson18-…` and `lesson29-…`: the `id: NoteId` column was vestigial (every use was
  `String` + a `ValidNoteId` proof) → column changed to `String`, unused `type NoteId` dropped.
- `compiler/test/test_review75_reviewfixes.ml`: fromdb fixture `ownerId: UserId` → `String`.

## Also fixed (latent codegen bug surfaced by the showcase)

`emit_racket.ml` `emit_with_raw_tail` emitted a bare `(with-database (lambda () …))` (unbound
identifier, missing the database name) instead of `(call-with-database <db> (lambda () …))` for a
`with database { .. }` block with a multi-statement tail body. Fixed to mirror the main path.

## Tests / docs

- `test_review75`: 6 new cases — insert/set/where × (Int→Int32 | String→newtype) rejected, plus a
  positive all-exact-types case.
- `example/learn/lesson67-newtype-columns.tesl`: showcase lesson — a `Sku` newtype column with
  insert / `update … set` / `select … where`, in-memory tests asserting the round-trip.
- `LANGUAGE-SPEC.md` §11.6: documents SQL-strict (no coercion) vs JSON/HTTP-transparent.

## Not done (intentionally out of scope — no open item)

Additive nominal widths (`Int64`/`Int16`) and a large-`Int` string/BigNumber wire codec. Neither
is required for soundness; the W091 linter already steers `Int` off the wire. Revisit only if a use
case needs them.
