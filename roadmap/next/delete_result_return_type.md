# Replace `DeleteResult` with a proven count

## What

`deleteAndReturnResult` answers `DeleteResult = NoRowDeleted | RowsDeleted Int`. Replace it
with a plain count carrying a proof:

```tesl
deleteAndReturnResult p from Entity where … -> n: Int ::: IsNonNegative n
```

## Why

- **It models an illegal state.** The payload is an unconstrained `Int`, so `RowsDeleted 0` is
  inhabited and means exactly what `NoRowDeleted` means — two representations of one state,
  which is the failure the rest of the language exists to prevent. A proof on the payload
  (`RowsDeleted (n: Int ::: IsPositive n)`) would close the overlap, but that keeps the ADT and
  its cost.
- **It is inconsistent with `selectCount`**, which answers a plain `Int` for the same kind of
  quantity.
- **Its one advantage is not real.** The argument for an ADT is that it makes the
  nothing-happened case a compile-time obligation. Until 2026-08-17 that was false in the worst
  way: the exhaustiveness checker rejected a `case` naming BOTH constructors and demanded a
  catch-all `_` instead — the most ignorable form there is. That bug is fixed, so the argument
  is now merely weak rather than inverted, but `if n == 0` reads no worse than a two-arm case
  over a count.
- **It costs a constructor set registered in three places** (`type_system.ml`, `checker.ml`,
  `validation_common.ml`). Those tables disagreeing is exactly what produced the exhaustiveness
  bug above.

## Scope

`tesl/db.rkt` and `dsl/types.rkt` (drop the ADT, return the count), the three constructor
tables, `emit_racket`, `emit_go` (`DeleteResult`/`TableDeleteResult`/`DbDeleteResult` in the Go
runtime collapse to the count the statement already computes), `LANGUAGE-SPEC.md`, and
`example/learn/lesson21-sql-reference.tesl`, which is the only corpus file that names the type.

## Evidence it must carry

A corpus compile before and after with the diagnostics diffed, plus the `.rkt` snapshot check —
this changes a stdlib RETURN type, so every caller's inferred type changes with it.

## Open

Whether `IsNonNegative` is the right proof or whether the count wants no proof at all. A row
count cannot be negative by construction, so the proof documents an invariant the runtime
already guarantees rather than one a caller must establish — which is the same argument
`tesl/int.rkt` makes for `Int.abs`, where the invariant "holds by definition; no runtime proof
wrapping".
