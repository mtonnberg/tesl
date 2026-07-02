# Int is silently narrowed at storage/wire boundaries (NT-07)

## Decision (revised 2026-07-02)

Keep `Int` **arbitrary-precision (bignum)** — do NOT rename or narrow it. Close the
silent-truncation soundness hole **at the boundary**, and add a bounded type that expresses
round-trip-safety in the type. Three parts:

1. **Runtime fail-loud (the soundness guarantee).** At the DB-write and codec encode/decode
   boundaries, range-check the value against the target width and raise a **loud boundary error**
   instead of silently truncating/overflowing. For `Int` (→ `BIGINT`) that means a value that won't
   fit the column (> 2^63) — or, crossing to a JS-`Number` client, > 2^53 — fails loud rather than
   silently losing precision. This holds regardless of the declared type, so it can't be bypassed.
2. **Add `Int32` (additive bounded type)** → Postgres `integer`/int4 (saves space) and JS-safe
   (2^31 < 2^53, so exact in Elm/TS). Encode **and decode** are range-checked, so it round-trips
   soundly: `apiconsumer → tesl → db → back` works for in-range `Int32` values, and an out-of-range
   inbound value is a loud boundary error, not a silent wrap.
3. **Linter (ergonomics, warning).** Warn when `Int` appears at **any** wire/codec boundary — API
   return, request body, captures, SSE payload, codec-encoded record fields — suggesting `Int32`
   (or another bounded type). A **warning**, not an error, so internal/compute `Int` use is
   unaffected.

**Why keep bignum instead of renaming `Int → Int64`:** `Int` never round-trips reliably anyway —
JS `Number` is a double (exact only to 2^53), and `Int → BIGINT` truncates > 2^63 — so the fix is to
make the *safe* type (`Int32`) carry the round-trip guarantee while `Int` stays the internal/compute
type guarded by fail-loud at the boundary. `Int` **already** maps to `BIGINT`
(`dsl/sql.rkt:130` `'Integer → 'bigint`), so there is **no column migration** for `Int`. Renaming
`Int → Int64` was rejected: it reverses the A9 "arbitrary-precision Int" decision (and `LBigInt` /
`test_a9_bigint`), is a breaking corpus/docs/spec rename, matches only the DB (not the 2^53 JS)
boundary, and introduces silent int64 arithmetic overflow. Further bounded widths (`Int64`, `Int16`,
a named `BigInt`) are **additive later** if needed.

## Why (NT-07, med)

The type system's `Int` is arbitrary-precision (Racket bignum), but Postgres integer columns are
64-bit (`int8`/BIGINT) and the Elm/TS codecs emit JS `Number` (a double, exact only to 2^53). A value
> 2^53 (JS client) or > 2^63 (BIGINT) is well-typed and computes correctly in Racket yet silently
truncates/overflows at a serialization or storage boundary the type system doesn't model.
"Well-typed" does not imply "round-trips". The runtime type oracle also conflates `Int`/`Float`
(`2.0` satisfies `Int`) — orthogonal to width, fixed here too.

## Fix (concrete)

- **Now (this item):**
  - Boundary range-check (**fail loud**) at DB write + codec encode/decode, for `Int` and `Int32`.
  - Tighten the runtime type oracle so `Int` **rejects flonums** (`2.0` no longer satisfies `Int`).
  - Add the `Int32` type → `integer`/int4 column (the `integer` column type already exists in the
    SQL layer; `dsl/sql.rkt:227`), JS-`Number` codec, with in/out range-checks.
  - Linter warning code: `Int` at any wire/codec boundary → warn, suggest `Int32`.
- **Later (`roadmap/later/bounded_int_types.md`):** further additive bounded integers
  (`Int64`/`Int16`/named `BigInt`) if a use case needs them — not required for soundness.

## Tests

- `Int` > 2^63 written to a BIGINT column, and `Int` > 2^53 encoded to a JS-number codec → **loud
  boundary error in BOTH directions**, not silent truncation; in-range values round-trip.
- `Int32`: an in-range value sent by an API consumer → decode → int4 → read back → encode → **exact**
  (full apiconsumer→tesl→db→back round-trip); an out-of-range inbound value (> 2^31) → boundary
  error, not a silent wrap.
- Oracle: `2.0` no longer satisfies `Int`.
- Linter: `Int` in a return / request body / capture / SSE payload / codec-encoded field → warning;
  `Int32` in those positions → no warning.

## Status

Active in `roadmap/next`. The boundary guard + `Int32` + linter land here; the type-level EXPANSION
beyond `Int32` (`Int64`/`Int16`) is the only part deferred (`roadmap/later/bounded_int_types.md`).
(Supersedes the earlier "rename `Int → Int64`" decision and the stale "CARVED → later" line.)
