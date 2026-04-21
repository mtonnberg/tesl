# ForAll List/Set Query Proofs

## Goal

Allow list-returning functions to annotate element-level proofs:

```tesl
fn listNotes(user: String ::: Authenticated user)
  -> List Note ::: ForAll (FromDb (AuthorId == user))
  requires [dbRead] =
  select note from Note where note.authorId == user
```

So that element extraction propagates the proof:

```tesl
case List.head(notes) of
  Nothing   -> fail 404 "no notes"
  Something note -> note   # note :: Note ? FromDb (AuthorId == user)
```

## Current state (2026-03)

`ForAll` is listed as open design question D-005 in `known_gaps.md`. The runtime and compiler do not support it. The `select` statement returns a plain `List Note` with no element-level proof.

## Design sketch

`ForAll P` is a collection-level proof predicate meaning "every element satisfies P". Key propagation rules:

- `List.head (xs ::: ForAll P)` → `Maybe (item ? P)` — extracting an element propagates the proof.
- `List.filter pred (xs ::: ForAll P)` → still `List item ::: ForAll P` — filtering preserves the invariant.
- `List.map f (xs ::: ForAll P)` → drops the ForAll (mapped type differs).
- `List.append (xs ::: ForAll P) (ys ::: ForAll P)` → `List item ::: ForAll P` — union of same-proven lists.

This is NOT dependent types — it is a finite set of structural rules about collection operations. No term-level quantification is required.

## Scope

Large. Requires:
1. New `ForAll` proof operator in the compiler's GDP expression grammar
2. Propagation rules in `BodyCompiler` for List operations
3. `select` statement returns `List entity ::: ForAll (FromDb ...)` automatically
4. Type checker validates ForAll annotations
5. Tests and lesson material

## Related

- `completed/improved_satifies_operator.md` — the `?` operator for single values is the atomic case; `ForAll` extends it to collections.


## Notes
- If a filter function uses a check as lambda then the filter function should return the ForAll proof. (Make very sure that this is logically sound and follows and adhere to the type theory) For example List.filter