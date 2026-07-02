# Int is silently narrowed at storage/wire boundaries

## Why
**NT-07 (med):** the type system's `Int` is arbitrary-precision (Racket bignum), but
Postgres integer columns are 64-bit and the Elm/TS codecs emit JS `Number`. A value
> 2^53 (or > int8 range) is well-typed and computes correctly in Racket yet silently
truncates/overflows at a serialization or storage boundary the type system doesn't
model. "Well-typed" does not imply "round-trips". The runtime type oracle also
conflates `Int`/`Float` (`2.0` satisfies `Int`).

## Fix (carve: guard now, type story later)
- Now: at the DB write / codec-encode boundary, range-check `Int` values that target
  a fixed-width column / JS number and fail loudly (a boundary error) instead of
  silently truncating; tighten the runtime oracle so `Int` rejects flonums.
- Later (`roadmap/later/bounded_int_types.md`): a type-level bounded-integer story
  (`Int64`/`Int32`/`SafeInt`) so the boundary constraint is visible in the type.

## Tests
an `Int` exceeding int8 written to a BIGINT column / encoded to a JS-number codec →
loud boundary error, not silent truncation; in-range values round-trip.

## Status: CARVED → `roadmap/later/review_2026_07_deferred.md` §7 — 2026-07-02
