# Improved Proof Attachment on Return Values

**Status:** Partially implemented. Core `?` operator shipped. Two items deferred.

---

## What was shipped

### The `?` named-pack return operator

`-> Type ? EntityProofs [::: OtherProofs]` is the canonical way to return a GDP-named value with proof.

**Entity-append rule:** every leaf predicate in the `?` group gets `_entity` appended as its last argument. `&&` and `||` distribute recursively. The `:::` group is independent — no entity appended.

```tesl
-- Entity proof only
handler getTodo(...) -> Todo ? FromDb (Id == todoId) = ...

-- Compound entity proofs
fn makeValue(n: Int ::: Positive n && Small n) -> Int ? Positive && Small =
  n

-- Entity proof + independent proof cargo
fn make(n: Int ::: Positive n, user: String ::: Admin user)
  -> Int ? Positive ::: Admin user =
  n ::: detachProof(user)

-- Proof function + detach on one return line
fn buildWithProofs(n: Int, u: String ::: Admin u)
  -> Int ? Positive ::: Admin u =
  let p = provePositive(n)
  n ::: p && detachProof(u)
```

At the callsite, the `let` binder name becomes the GDP subject:
```tesl
let item = getItem(id)
# item :: Item item ::: FromDb (Id == id) item
```

The `?` is the Tesl equivalent of Haskell's `~~` naming operator. The SQL layer produces 2-arg `FromDb` facts `(FromDb (Id == pk-subject) entity-subject)` so both identities are in the proof. The retargeting gap is closed: `attachProof(otherEntity, detachProof(realEntity))` fails the subject check.

---

## Deferred: list query proofs (`ForAll`)

`-> List Note ::: ForAll (FromDb (AuthorId == user))` requires dependent types to express "all elements satisfy P." Deferred.

**Future direction the user sketched:** `ForAll (FromDb (AuthorId == user))` as a proof annotation on list results, where `List.head list` gives `Maybe (Note ? FromDb (AuthorId == user))` — propagating the element proof from the collection to the extracted element. This is not dependent types — it is a finite, well-defined rule about element-extraction operations. Implement when concrete usage patterns emerge.

---

## Deferred: proof-bearing ADT type arguments (`Maybe (Int ::: IsPositive x)`)

`-> Maybe (Int ::: IsPositive x)` would say "if `Something`, the inner Int carries `IsPositive x` where `x` is the input parameter." This requires `:::` to be a GDP-level type operator (currently `:::` is only surface syntax, not a GDP grammar element). Implementing it requires:
- Extending `parse_gdp` to recognise `(Type ::: Proof)` as a `binding-type` node
- Updating `validate-adt-return` in `web.rkt` to check element proofs
- Updating `runtime-type-satisfied?` in `types.rkt`

**Why deferred:** the primary use case — "validate input and return it with proof" — is already fully covered by `check` functions:

```tesl
check isSafeTitle(title: String) -> title: String ::: TitleSafe title =
  if String.length(title) <= 120 then ok title ::: TitleSafe title
  else fail 400 "title too long"
```

The binding return spec `title: String ::: TitleSafe title` already returns the *same value* (same GDP subject) with the proof attached. This is semantically identical to the desired `Maybe (String ::: TitleSafe x)` pattern for non-optional cases.

For optional cases where `Nothing` is a valid non-error outcome, `-> Maybe (Fact (IsPositive x))` already works — return just the fact, the caller already has `x`.

The ergonomic benefit of the full ADT `:::` syntax has not yet been validated in real usage. Implement when concrete patterns emerge.

---

## Compound `?` proofs with non-entity cargo: resolved

The earlier confusion about whether `IsCached todoId` should get `_entity` appended was resolved by the `?` / `:::` split: everything LEFT of `:::` gets `_entity` (entity proofs); everything RIGHT of `:::` is independent cargo. Users decide which group each proof belongs to. No ambiguity.

```tesl
-- IsCached todoId is independent cargo, not about the entity:
-> Int ? Positive ::: IsCached todoId
-- emits: (? Int _entity ::: ((Positive _entity) && (IsCached todoId)))
```
