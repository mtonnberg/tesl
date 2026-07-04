# ForAll Proofs — Lists That Remember Their Origin

A single value can carry a proof stamp. So can a whole list. When Tesl runs a query the entire result is annotated with proof about every element in it — and filtering *expands* that proof rather than losing it.

---

## Every select returns a proof-annotated list

```tesl
-- Return type is not just List Todo.
-- It is List Todo annotated with ForAll (FromDb (OwnerId == user.id)).
-- Every element is proven to have come from the DB with ownerId == user.id.
let mine = select todo from Todo where todo.ownerId == user.id
```

A function that accepts `List Todo ::: ForAll (FromDb)` cannot receive a hand-crafted list — the proof is unforgeable except through the SQL layer.

---

## Filtering expands the proof, never loses it

```tesl
fact IsOpen (todo: Todo)

check checkOpen(todo: Todo) -> todo: Todo ::: IsOpen todo =
  case todo.status of
    Open -> ok todo ::: IsOpen todo
    Done -> fail 422 "already completed"

handler listOpenTodos(user: User ::: Authenticated user)
  -> List Todo ? ForAll (FromDb (OwnerId == user.id) && IsOpen)
  requires [dbRead] =
  let mine = select todo from Todo where todo.ownerId == user.id
  List.filterCheck checkOpen mine   # proof grows: now includes IsOpen
```

`List.filterCheck` runs `checkOpen` on each element and keeps only the ones that pass. The returned list carries the combined proof `ForAll (FromDb (OwnerId == user.id) && IsOpen)` — both conditions are proven for every element.

---

## Why filterCheck instead of filter?

```tesl
-- Plain filter: proof is gone, returns List Todo with no ForAll annotation
let open = List.filter (\t -> t.status == Open) mine

-- filterCheck: proof grows to include the check's predicate
let open = List.filterCheck checkOpen mine
```

`List.filter` accepts a plain boolean function — no way to produce proof. `List.filterCheck` accepts a `check` function — it both filters and extends the annotation.

A downstream function that requires `List Todo ::: ForAll (IsOpen)` cannot receive output from plain `filter`. The compiler enforces that real validation happened, not just a predicate call.

---

## Zero runtime overhead

At runtime a `ForAll`-annotated list is a plain list. The annotation is fully erased after type-checking — no per-element boxing, no wrapper structs, no measurable overhead versus a regular filter.

---

## ForAll flows into map

If the list carries `ForAll IsPositive`, every element the lambda receives already has `IsPositive` attached — so you can call proof-requiring functions directly inside `List.map`:

```tesl
fact IsPositive (n: Int)

check checkPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "must be positive"

fn doublePositive(n: Int ::: IsPositive n) -> Int =
  n * 2

fn doubleAllPositive(ns: List Int ::: ForAll IsPositive ns) -> List Int =
  List.map (\n -> doublePositive n) ns
  #          ^^^
  #          each n carries IsPositive n from the ForAll —
  #          the call to doublePositive type-checks
```

Without the `ForAll IsPositive` annotation on the list, the lambda would be a compile error — `doublePositive` requires the proof and a plain `List Int` cannot provide it.

---

## Signatures become precise documentation

```tesl
-- Only open todos owned by this user, proven to be from the DB
handler listOpenTodos(user: User ::: Authenticated user)
  -> List Todo ? ForAll (FromDb (OwnerId == user.id) && IsOpen)

-- All messages in a specific room, proven from the DB
handler getMessages(roomId: String ::: ValidRoomId roomId)
  -> List Message ? ForAll (FromDb (RoomId == roomId))
```

You know what the list contains without reading the implementation. The compiler verifies the claim.

---

*Next: [Background jobs without Redis →](06-queues.md)*
