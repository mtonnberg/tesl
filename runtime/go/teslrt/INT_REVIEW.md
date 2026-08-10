# `teslrt.Int` formal review

Status: first migration slice. Review again before any Go backend becomes stable.

## Representation invariant

`Int` has one canonical representation:

- `big == nil`: value is `small` and fits `int64`.
- `big != nil`: value is `big`, lies outside `int64`, and `small == 0`.
- Go zero value is Tesl integer zero.

Only `FromInt64` and `fromBig` construct representations. Every operation either
returns `FromInt64` on a checked fast path or normalizes through `fromBig`.

The zero-sized `noCompare [0]func()` field makes `Int` non-comparable. Raw `==`,
`!=`, `map[Int]`, and pointer-based big-integer equality therefore fail at Go
compile time. Use `Equal`, `Compare`, `Key`, and `Hash64`.

`noCompare` is the first field, avoiding trailing zero-sized-field padding. A
seam test pins both `unsafe.Sizeof(Int{}) == 16` on the supported 64-bit target
and `reflect.Type.Comparable() == false`.

## Aliasing and mutation

`math/big.Int` methods mutate their receiver. `bigInt` always returns a fresh
copy, `fromBig` clones spilled inputs, and no method exposes the stored pointer.
Copying an `Int` may share immutable backing storage, but no runtime operation
can mutate that storage.

## Arithmetic semantics

- `Add`, `Sub`, and `Mul` use checked `int64` fast paths, then exact `math/big`.
- `Neg(MinInt64)`, `Abs(MinInt64)`, and `MinInt64 / -1` spill exactly.
- `Quo` and `Rem` truncate toward zero, matching Racket `quotient`/`remainder`.
- `Mod` adjusts `Rem` so a non-zero result has the divisor's sign, matching
  Racket `modulo`.
- Division by zero and negative powers fail explicitly.
- `GCD` and `LCM` are non-negative; either zero input makes `LCM` zero.

## Encoding and hashing

Decimal parsing never enters through `float64`. JSON uses an unquoted canonical
decimal token, preserving existing Tesl server-codec semantics for large `Int`
values. Typed client string encoding remains a separate emitter obligation.

`IntKey` is canonical decimal text. `Hash64` is deterministic FNV-1a over the
same text. This is stable and correct, not intended as an adversarial hash-table
primitive; runtime Dict/Set code must retain collision-safe equality checks.

## Test evidence

`int_test.go` covers:

- zero value, parsing, boundaries around both `int64` limits;
- spill and normalization paths;
- quotient/remainder/modulo sign matrices;
- arithmetic, ordering, GCD, LCM, power, parity, digits, floats;
- immutable copies, keys, hashes, and exact JSON round trips;
- concurrent operations over copies sharing spilled backing storage;
- 2,000-case algebraic, ordering, canonical-form, and `math/big` properties.

`int_fuzz_test.go` supplies native fuzz targets for decimal/JSON round trips and
all exact arithmetic, including division, plus malformed raw JSON input. CI runs
every target in fuzzing mode on each build; scheduled CI should increase each
target to at least 60 seconds via `TESL_GO_FUZZTIME=60s`.
