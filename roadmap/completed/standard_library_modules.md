# Standard Library Modules

> **Implemented** — `Tesl.String`, `Tesl.List`, `Tesl.Int`, `Tesl.Float`, `Tesl.Either`, `Tesl.Dict`, `Tesl.Set` all available.

## Modules added / expanded

### Tesl.String (expanded)

25+ functions including: `String.trim` (→ `IsTrimmed`), `String.toUpper` (→ `IsUpperCase`), `String.toLower` (→ `IsLowerCase`), `String.split`, `String.join`, `String.contains`, `String.startsWith`, `String.endsWith`, `String.padLeft`, `String.padRight`, `String.replace`, `String.slice`, `String.indexOf`, `String.toInt`, `String.fromInt`, `String.lines`, `String.words`, `String.dropPrefix`, `String.dropSuffix`, `String.repeat`, `String.reverse`.

Check functions: `String.requireNonEmpty` (→ `IsNonEmpty`).

### Tesl.List (expanded)

40+ functions including: `List.map`, `List.filter`, `List.filterMap`, `List.foldl`, `List.foldr`, `List.sort` (→ `IsSorted`), `List.sortBy` (→ `IsSorted`), `List.head`, `List.tail`, `List.last`, `List.nth`, `List.take`, `List.drop`, `List.zip`, `List.zipWith`, `List.unzip`, `List.sum`, `List.product`, `List.maximum`, `List.minimum`, `List.any`, `List.all`, `List.count`, `List.contains`, `List.find`, `List.findIndex`, `List.range`, `List.repeat`, `List.unique`, `List.dedupe`, `List.partition`, `List.intersperse`, `List.groupBy`, `List.reverse`, `List.append`, `List.concat`, `List.flatten`.

### Tesl.Int (expanded)

20+ functions including: `Int.abs`, `Int.min`, `Int.max`, `Int.clamp`, `Int.isPositive`, `Int.isNegative`, `Int.isEven`, `Int.isOdd`, `Int.pow`, `Int.gcd`, `Int.lcm`, `Int.toString`, `Int.toFloat`, `Int.fromFloat`, `Int.sign`, `Int.digits`.

Check functions: `Int.nonZero` (→ `IsNonZero`). Safe arithmetic: `Int.divide` (requires `IsNonZero` denominator).

### Tesl.Float (new)

20+ functions: `Float.parse`, `Float.abs`, `Float.min`, `Float.max`, `Float.clamp`, `Float.ceil`, `Float.floor`, `Float.round`, `Float.sqrt`, `Float.pow`, `Float.log`, `Float.exp`, `Float.sin`, `Float.cos`, `Float.tan`, `Float.isNaN`, `Float.isInfinite`, `Float.toString`, `Float.toInt`.

### Tesl.Either (new — proper ADT)

`Either a b` is a proper two-parameter ADT with `Left value` and `Right value` constructors. Pattern-match with `case`:

```tesl
case parseAge(raw) of
  Left err  -> fail 400 err
  Right age -> ok age
```

Functions: `Either.map`, `Either.mapLeft`, `Either.andThen`, `Either.withDefault`, `Either.toMaybe`, `Either.fromMaybe`, `Either.isLeft`, `Either.isRight`, `Either.fromLeft`, `Either.fromRight`, `Either.partition`.

### Tesl.Dict (new)

Immutable key-value map (Racket `equal?`-based hash). 20+ functions: `Dict.empty`, `Dict.singleton`, `Dict.insert`, `Dict.insertWith`, `Dict.remove`, `Dict.lookup`, `Dict.get`, `Dict.member`, `Dict.size`, `Dict.isEmpty`, `Dict.map`, `Dict.mapWithKey`, `Dict.filter`, `Dict.filterWithKey`, `Dict.foldl`, `Dict.foldr`, `Dict.union`, `Dict.unionWith`, `Dict.intersection`, `Dict.difference`, `Dict.update`, `Dict.fromList`, `Dict.toList`, `Dict.keys`, `Dict.values`.

Use `Dict` (unparameterized) in type annotations — Dict is an opaque Racket type.

### Tesl.Set (new)

Immutable unique-element set. 20+ functions: `Set.empty`, `Set.singleton`, `Set.insert`, `Set.remove`, `Set.member`, `Set.size`, `Set.isEmpty`, `Set.union`, `Set.intersection`, `Set.difference`, `Set.isSubset`, `Set.map`, `Set.filter`, `Set.foldl`, `Set.any`, `Set.all`, `Set.partition`, `Set.fromList`, `Set.toList`.

Use `Set` (unparameterized) in type annotations.

## GDP proofs from stdlib

Functions that return proof-bearing values:

| Function | Proof | How to use |
|---|---|---|
| `String.trim` / `trimLeft` / `trimRight` | `IsTrimmed result` | `fn f(s: String) -> String ? IsTrimmed = String.trim(s)` |
| `String.toUpper` | `IsUpperCase result` | `fn f(s: String) -> String ? IsUpperCase = String.toUpper(s)` |
| `String.toLower` | `IsLowerCase result` | `fn f(s: String) -> String ? IsLowerCase = String.toLower(s)` |
| `List.sort` / `sortBy` | `IsSorted result` | `fn f(xs: List String) -> List String ? IsSorted = List.sort(xs)` |
| `Int.nonZero` (check) | `IsNonZero n` | `let d = check Int.nonZero(rawDenominator)` |
| `String.requireNonEmpty` (check) | `IsNonEmpty s` | `let s = check String.requireNonEmpty(rawInput)` |

**Limitation**: proof-returning functions cannot be used inline in comparisons — assign to `let` first. See `proof-returning-stdlib.md`.

## Tesl.Id — note on side effects

`generatePrefixedId` uses the current timestamp + random number and is therefore stateful. It does not currently require a capability, but it arguably should (tracked). In practice this is fine for handler code where side effects are expected.

## Tutorial

See `example/learn/lesson25-standard-library-strings-lists-ints.tesl`, `lesson26-time-and-posix.tesl`, `lesson27-either-dict-set.tesl`.
