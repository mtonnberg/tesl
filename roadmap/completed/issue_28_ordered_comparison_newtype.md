# GitHub #28 — ordered `>=`/`<=` in select-where traps on a newtype column/operand

**FIXED 2026-07-06.** Adding an ordered comparison (`>= / <= / < / >`) on a
**newtype** column/operand (e.g. `PosixMillis` over `Int`) to a `select … where`
made the request 500 at runtime, while `==` on the same shape worked. `tesl
check` stayed clean.

## Root cause

In `dsl/sql.rkt`, ordered query comparisons run every operand and row value
through `ensure-ordered-query-value!`, which accepts only `number?`/`string?`
after `unwrap-non-null`. `unwrap-non-null` stripped a `Something(v)` (Maybe) but
**not a `newtype-value`**. So a `PosixMillis` operand — a `newtype-value`
wrapping an `Int` — reached the check still wrapped and raised:

```
sql: field at on entity Ev does not support ordered comparison >= for operand
value #(struct:newtype-value … PosixMillis 1783345346908); expected a string or number
```

`==` (`eq-predicate`) does not call `ensure-ordered-query-value!` and compares
via `equal?`, which is happy with wrapped structs — hence the reported
`==`-works / `>=`-traps asymmetry. Plain `Int` columns worked because the
operand was already a bare number.

## Fix

Extend `unwrap-non-null` (dsl/sql.rkt) to also unwrap a `newtype-value` to its
base (and recurse through `Something`), so both the ordered-value guard and the
actual comparison see the underlying `Int`/`String`. One-line-class change; used
consistently by eq / comparison / in / like matching, so newtype columns now
compare correctly everywhere (equality already worked; ordered now does too).

## Verification

- Regression: `tests/sql-newtype-range-tests.tesl` — a `PosixMillis` window
  `select e from Ev where e.at >= lo && e.at <= hi` returns the in-window row
  and excludes out-of-window rows (2 tests). Traps before the fix, passes after.
- Int range unchanged (existing behaviour, re-checked on real Postgres).
- `./ci.sh` 13/13.

## Note on the reporter's env

The reporter also observed that standalone api-tests returned 500 even for an
equality-only module on `2c24c04` — I could NOT reproduce that (my api-tests run
green on `2c24c04` against both in-memory and real Postgres), so that part looks
like a local build/harness issue on their side, not a compiler regression. The
`>=`/`<=` newtype trap above is the real, reproduced defect and is fixed.
