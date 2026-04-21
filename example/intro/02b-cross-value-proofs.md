# Proofs That Span Two Values

Basic proof stamps validate one value in isolation. But some invariants are inherently relational — a date range is only valid if the start is before the end, a discount is only valid relative to the original price, a spend is only valid relative to a budget. Tesl can encode those relationships as proofs too.

---

## A proof that relates two values

```tesl
fact ValidRange (lo: Int, hi: Int)   # the proposition: lo < hi

check checkValidRange(lo: Int, hi: Int) -> lo: Int ::: ValidRange lo hi =
  if lo < hi then ok lo ::: ValidRange lo hi
  else fail 400 "lo must be less than hi"
```

The proof predicate `ValidRange lo hi` mentions *both* values. When `lo` carries this proof, it doesn't just say "lo was validated" — it says "lo was validated *relative to this specific hi*."

---

## Consuming a relational proof

```tesl
fn clampToRange(lo: Int ::: ValidRange lo hi, hi: Int, value: Int) -> Int =
  if value < lo then lo
  else if value > hi then hi
  else value
```

`clampToRange` can only be called when `lo` carries `ValidRange lo hi` for the *same* `hi` passed as the second argument. Passing a `lo` that was validated against a different `hi` is a compile error — the proof subjects don't match.

```tesl
fn safePair(rawLo: Int, rawHi: Int, value: Int) -> Int =
  let lo = check checkValidRange rawLo rawHi   # lo now carries ValidRange lo rawHi
  clampToRange lo rawHi value                  # ✓ proof subjects match
```

---

## Record-wide invariants

Field-level proofs validate each field independently. But sometimes validity is a property of the *combination* of fields. Tesl expresses this as a record-level proof annotation:

```tesl
fact IsPositive (n: Int)
fact PriceExceedsQuantity (price: Int, quantity: Int)

record OrderLine {
  price:    Int ::: IsPositive price       # each field proven independently...
  quantity: Int ::: IsPositive quantity
} ::: PriceExceedsQuantity price quantity  # ...AND the pair proven together
```

The `:::` after the closing brace is a cross-field invariant: "an `OrderLine` is only valid when `price > quantity`." It is compile-time only — zero runtime cost.

---

## Enforced at the HTTP boundary

```tesl
check checkPriceExceedsQuantity(price: Int, quantity: Int)
    -> price: Int ::: PriceExceedsQuantity price quantity =
  if price > quantity then ok price ::: PriceExceedsQuantity price quantity
  else fail 422 "price must exceed quantity"

codec OrderLine {
  fromJson [
    {
      price    <- "price"    with_codec intCodec via checkPositiveInt
      quantity <- "quantity" with_codec intCodec via checkPositiveInt
    } via checkPriceExceedsQuantity   # runs after all fields pass
  ]
}
```

The codec validates each field individually, then runs the cross-field check. If any check fails the request is rejected before your handler runs. Inside the handler, `order.price > order.quantity` is a *proven* fact, not an assumption.

---

## What this enables

```tesl
fn processOrder(order: OrderLine) -> String =
  # No need to re-check price > quantity — the type guarantees it
  "processing order: price ${order.price}, qty ${order.quantity}"
```

Any function that receives an `OrderLine` gets the cross-field invariant for free. The compiler enforces that no `OrderLine` can be constructed without both the per-field proofs and the relational proof in place.

---

## The pattern in brief

| What you need to prove | Tool |
|---|---|
| A single value is valid | `check f(x) -> x ::: Predicate x` |
| Two values relate to each other | `check f(a, b) -> a ::: Relation a b` |
| All fields of a record are individually valid | `record R { field: T ::: Proof field }` |
| Fields of a record relate to each other | `record R { ... } ::: CrossFieldFact f1 f2` |

---

*Next: [Auth the compiler enforces →](03-auth.md)*
