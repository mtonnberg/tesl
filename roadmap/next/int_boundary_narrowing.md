# Int is silently narrowed at storage/wire boundaries (NT-07)

## Decision (revised 2026-07-02)

Keep `Int` **arbitrary-precision (bignum)** and close the silent-truncation hole with a
**compile-time** contract — **no pervasive runtime range checks** (Tesl's zero-cost / compiler-is-
the-contract stance). Five parts:

1. **`Int` storage → Postgres `NUMERIC`** (arbitrary precision), not `BIGINT`. This is lossless: an
   `Int` of any magnitude round-trips through the DB with **no runtime check and no truncation**, so
   NT-07 is fully closed at the storage boundary while `Int` keeps its arbitrary-precision meaning
   (A9). (Migration below.)
2. **Add `Int32` as a distinct nominal type** → Postgres `integer`/int4 (compact) and JS-safe
   (2^31 < 2^53, exact in Elm/TS). Being nominal, it does **not** unify with `Int`.
3. **Compile-time width matching (free, no runtime cost):** the value written to a column must have
   the column's type. `Int` into an int4 column, or `Int32` into a `NUMERIC` column, is a **type
   error** — accidental narrowing is unrepresentable. Widening `Int32 → Int` is a total safe
   conversion; narrowing `Int → Int32` is an **explicit** `Int32.fromInt : Int -> Maybe Int32` the
   developer writes only where intended (the only value-range decision, and it's dev-chosen, not
   pervasive).
4. **Decode-boundary validation (the one unavoidable, cheap runtime touch).** Untrusted JSON is the
   one place a type cannot enforce range: the codec **decoder** range-checks an `Int32` field on the
   way in and returns a boundary error (400) for a value > 2^31. This is normal parse-time input
   validation at a single site — NOT the pervasive per-write/per-op runtime check we are avoiding.
   With it, `apiconsumer → tesl → db → back` round-trips soundly for `Int32`.
5. **Linter warning (ergonomics).** Warn when `Int` appears at **any** wire/serialized position —
   API return, request body, captures, SSE payload, codec-encoded record fields — with:
   *"JavaScript numbers cannot represent values above 2^53; use `Int32`, or a BigNumber/string
   codec for `Int`."* A warning, not an error, so internal/compute `Int` use is unaffected.

Also fixed here (orthogonal to width): tighten the runtime type oracle so **`Int` rejects flonums**
(`2.0` no longer satisfies `Int`).

**Rejected — rename `Int → Int64` / narrow `Int` to 64-bit:** reverses A9 (arbitrary precision) and
`test_a9_bigint`, is a breaking corpus/docs/spec rename, only matches the DB (not the 2^53 JS)
boundary, and introduces silent int64 arithmetic overflow. **Rejected — runtime range-check on
every DB write:** expensive and against the zero-cost stance; the compile-time width-match + a
single decode-boundary validation give the same safety without per-write cost.

## Why (NT-07, med)

`Int` is arbitrary-precision (Racket bignum), but Postgres integer columns are 64-bit
(`int8`/BIGINT) and the Elm/TS codecs emit JS `Number` (a double, exact only to 2^53). A value
> 2^53 (JS client) or > 2^63 (BIGINT) is well-typed and computes correctly in Racket yet silently
truncates/overflows at a serialization or storage boundary the type system doesn't model.
"Well-typed" does not imply "round-trips". The runtime oracle also conflates `Int`/`Float`.

## Fix (concrete)

- **Types/mapping:** `Int → NUMERIC`; new nominal `Int32 → integer`/int4 (the `integer` column type
  already exists — `dsl/sql.rkt:227`; the `Int → 'bigint` mapping at `dsl/sql.rkt:130` becomes
  `Int → 'numeric`). **Leave `PosixMillis → BIGINT` as-is** (it is a 64-bit millis timestamp, not an
  arbitrary `Int`; don't widen it).
- **Conversions:** `Int32.fromInt : Int -> Maybe Int32` (explicit narrowing, the only value check);
  `Int` from `Int32` is a total widening (no check).
- **Compile-time write check:** at `insert`/`update`/`set` sites the assigned value's type must equal
  the column's declared type (nominal `Int` vs `Int32`); mismatch is a type error.
- **Decoder:** the `Int32` codec decode range-checks (> 2^31 → boundary error); encode is exact
  (int4 fits a JS number).
- **Oracle:** `Int` predicate rejects flonums.
- **Linter:** new warning code — `Int` at any wire/codec boundary → warn (message above).
- **Possible future follow-ons (tracked here, no separate item):** further additive widths
  (`Int64`/`Int16`) and a named `BigNumber`/string wire codec for large `Int`, if a use case needs
  them — not required for soundness and out of scope for this item.

## Int32 type — implementation work

`Int32` is added as a **built-in nominal type**, not a lexer/parser keyword (type names are uppercase
identifiers resolved via the type environment, like `Int`/`String`). Touchpoints:

- **`compiler/lib/type_system.ml`** — register `Int32` as a built-in type distinct from `Int` (its
  own `TName "Int32"` that does **not** unify with `Int`), and expose it (+ its conversions) from a
  stdlib module so it is import-gated like other stdlib names (e.g. `Tesl.Int` or a new `Tesl.Int32`).
  Add signatures:
  - `Int32.fromInt : Int -> Maybe Int32` — checked narrowing (the ONLY value-range decision, and it
    is dev-chosen, not pervasive).
  - `Int32.toInt : Int32 -> Int` — total widening (no check; bignum already covers int32 range).
- **Runtime impl (`.rkt`, alongside the numeric stdlib):** `Int32.fromInt` returns `Something` iff
  `-2^31 ≤ v < 2^31` else `Nothing`; `Int32.toInt` is the identity on the underlying integer.
- **SQL mapping (`dsl/sql.rkt`):** add `Int32 → 'integer` (int4) to the type→column map; the existing
  `'Integer → 'bigint` becomes `'Integer → 'numeric` (see Fix above). `'integer → "INTEGER"` DDL
  already exists (`:227`).
- **Codecs (`emit_racket.ml` codec path + `emit_ts.ml` / `emit_elm.ml`):** `Int32` encodes as a plain
  JS number (int4 is exact under 2^53); **decode range-checks** and raises a boundary error (400) for
  a value outside int32. `Int`'s codec is unchanged (the linter warns on its wire use; a
  string/BigNumber `Int` codec is the future follow-on).
- **Checker:** nominal distinctness falls out of `Int32` being its own non-aliasing `TName`; add the
  compile-time **column-write match** at `insert`/`update`/`set` sites (assigned value's type must
  equal the column's declared type — `Int`↔NUMERIC, `Int32`↔int4; a mismatch is a type error). No
  runtime cost.
- **Arithmetic decision:** `Int32` is a **boundary/storage type with no arithmetic** — to compute,
  widen to `Int` (`Int32.toInt`, total), do bignum math, and narrow back with `Int32.fromInt` at the
  storage/wire boundary. This keeps arithmetic overflow-free and check-free (no runtime cost); a later
  ergonomic option (implicit `Int32→Int` widening, or `Int32`-native ops returning `Int`) is a
  follow-on, not core.
- **Linter:** the wire/codec-boundary `Int`-warning code (message in the Decision) points users at
  `Int32`.
- **Imports/surface:** `Int32`, `Int32.fromInt`, `Int32.toInt` are exposed from their stdlib module
  and subject to the normal import-scope checks (so an unimported use is a compile error, consistent
  with the rest of the stdlib).

## Consequences / migration

- **Schema migration:** existing `Int` columns are `BIGINT` today → become `NUMERIC`. Needs a
  migration for existing tables, and the read path must parse a `NUMERIC` result back to a bignum
  (Postgres returns it as a decimal string / exact rational). Space/perf: `NUMERIC` is larger and
  slower than `BIGINT` — which is exactly why `Int32` (int4) exists for the common bounded case, and
  why the linter steers boundary/storage fields toward it.
- No behavior change for internal `Int` arithmetic (still bignum, never overflows).

## Tests

- An `Int` far exceeding 2^63 written to its `NUMERIC` column and read back → **exact** (no
  truncation, no runtime check involved).
- Assigning an `Int` to an `Int32` column (or vice versa) → **compile-time type error**.
- `Int32` round-trip: in-range consumer value → decode → int4 → read → encode → **exact**;
  out-of-range inbound (> 2^31) → **decode boundary error (400)**, not a silent wrap.
- `Int32.fromInt` on an out-of-range `Int` → `Nothing`; in-range → `Something`.
- Oracle: `2.0` no longer satisfies `Int`.
- Linter: `Int` in return / request body / capture / SSE / codec-field → warning; `Int32` there → no
  warning.

## Status (2026-07-02) — soundness DELIVERED; one compile-time refinement remains

The silent-truncation hole is CLOSED and every piece below is gate-green (all 11
phases, incl. the live-PG aggregate):

- **Oracle** — `Int` rejects flonums (`exact-integer?`); `2.0` no longer satisfies
  `Int`. Closes the Int/Float conflation. (commit "NT-07 part 1")
- **`Int → NUMERIC`** — arbitrary-precision, lossless for any magnitude; auto-migration
  widens an existing `bigint`/`integer` column to `numeric` in place. `PosixMillis`
  (a nominal newtype over `Integer`) stays `BIGINT` via `newtype-base->db-type`.
- **`Int32`** — a JS-safe (< 2^31) nominal boundary type (does not unify with `Int`),
  in `Tesl.Int32` (`Int32.fromInt : Int -> Maybe Int32` checked narrowing;
  `Int32.toInt : Int32 -> Int` total widening); runtime `tesl/int32.rkt`; stored as
  `int4`. `int32?` is the registered runtime type, so the **codec decode range-checks**
  an incoming `Int32` field (> 2^31 rejected, not silently wrapped). (commit "part 2")
- **W091 linter** — advisory warning when `Int` appears at an API body/capture/return
  or a codec-encoded record field; steers to `Int32`. (commit "part 3")
- **Corpus example** `example/int32-boundary.tesl` (batch-runner-verified) + regressions
  (`R75_NT07`, `W091P/N`). (commit "part 4")
- **Bare construction is width-checked**: `Widget { count: <Int> }` where `count: Int32`
  is a compile error ("cannot unify Int with Int32").

**Remaining refinement:** the compile-time width-match at the `insert`/`update`/`set`
SQL forms specifically (their record arg parses as `EConstructor name [bare ERecord]`,
bypassing the typed-record field-check that already guards bare construction). This is
DEFENSE-IN-DEPTH over the loud runtime failure — an out-of-range `Int` written to an
`int4` column is rejected by Postgres (no *silent* truncation), so soundness holds; the
refinement only moves that to compile time. A correct fix threads the entity field
types through the insert/update handler's record arg. Further widths (`Int64`/`Int16`)
and a large-`Int` string/BigNumber wire codec remain in-file follow-ons.
