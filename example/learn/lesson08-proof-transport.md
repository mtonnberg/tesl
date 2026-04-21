# Lesson 8: Proof Transport — The Hidden Subject Model

## The envelope analogy

Every value in Tesl is like a sealed envelope in a post office:

```
┌──────────────────────────────────────────┐
│  ENVELOPE #A7F2C (hidden subject ID)     │
│  Contents: 25                            │
│  Stamps: [ValidAge ✓]                    │
└──────────────────────────────────────────┘
```

- The **envelope number** (A7F2C) is the hidden subject — an internal symbol you never see
- The **contents** (25) are the raw value — what `*age` gives you
- The **stamps** are proof facts — what `age ::: ValidAge age` expresses

When you bind `let age = checkAge(rawNumber)`, the system issues a new envelope
with a fresh number, puts the validated integer inside, and stamps it.

---

## What forgetFact does

`forgetFact(age)` removes the stamps but keeps the same envelope:

```
Before: ┌──────────────────────────────────────────┐
        │  ENVELOPE #A7F2C                         │
        │  Contents: 25                            │
        │  Stamps: [ValidAge ✓]                    │
        └──────────────────────────────────────────┘

After forgetFact:
        ┌──────────────────────────────────────────┐
        │  ENVELOPE #A7F2C (same!)                 │
        │  Contents: 25 (same!)                    │
        │  Stamps: (none)                          │
        └──────────────────────────────────────────┘
```

The envelope number did not change. The value did not change.
Only the stamps were removed.

This is safe: you can always *weaken* evidence. You cannot forge new evidence by forgetting.

---

## What detachFact does

`detachFact(age)` takes the stamps off and puts them in your hand:

```
Before:
        ┌──────────────────────────────────────────┐
        │  ENVELOPE #A7F2C                         │
        │  Contents: 25                            │
        │  Stamps: [ValidAge ✓]                    │
        └──────────────────────────────────────────┘

After detachFact:
        ┌──────────────────────────────────────────┐
        │  ENVELOPE #A7F2C                         │
        │  Contents: 25                            │
        │  Stamps: (none)                          │
        └──────────────────────────────────────────┘

        You hold:  [ValidAge ✓ about #A7F2C]
                   └─────────────────────────────┘
                   The stamp still says "about #A7F2C"!
                   It remembers its original envelope.
```

The detached proof is a first-class value. It carries:
1. The fact: "ValidAge"
2. A reference to the original envelope: "#A7F2C"

---

## What attachFact does — and why it doesn't forge

`attachFact(v, p)` physically places the stamps onto a different envelope.
But the stamps still say "about #A7F2C", not "about the new envelope":

```
Before:
        Envelope #B3E1A: { Contents: 30, Stamps: (none) }
        You hold: [ValidAge ✓ about #A7F2C]

After attachFact(v, p):
        Envelope #B3E1A: { Contents: 30, Stamps: [ValidAge ✓ about #A7F2C] }
```

Now consider: what happens at a call site that requires `ValidAge x`?

The function call checker runs: "does the argument carry a ValidAge fact
that matches the argument's own envelope number?"

```
Checking:  listenOnPort(v)    where v is envelope #B3E1A
Required:  ValidAge #B3E1A   (the function needs a fact about #B3E1A)
v carries: ValidAge about #A7F2C

Match?  NO — the stamp is for #A7F2C, not #B3E1A.
```

The call is rejected. `attachFact` cannot be used to forge evidence
that a different value is valid.

---

## Why two bindings of the same number have different subjects

```tesl
let a = checkAge(25)    # envelope #A7F2C, content 25, stamp ValidAge
let b = checkAge(25)    # envelope #D9K4P, content 25, stamp ValidAge
```

Both `a` and `b` have raw content 25 and carry ValidAge.
But their envelope numbers (hidden subjects) are DIFFERENT.

Why does this matter? Suppose you have:

```tesl
fn requiresSameSubject(x: Int ::: ValidAge x, p: Proof (ValidAge x)) -> Int = ...
```

The proof `p` must be about the same hidden subject as `x`.
You cannot pass `b`'s proof as evidence for `a`, even though they both hold 25,
because they are different envelopes.

This is the key insight: **GDP proofs are about identities, not about values**.
Two different bindings of the same integer are still proof-theoretically distinct.

---

## The let decomposition shorthand

```tesl
let (rawAge ::: ageProof) = age
```

This is exactly equivalent to:

```tesl
let rawAge = forgetFact(age)
let ageProof = detachFact(age)
```

Two steps in one. It reads: "destructure age into its proof-free identity (rawAge)
and its detached proof (ageProof)."

The `&&` variant:

```tesl
let (x ::: p && q) = combined
```

Means: `combined` carries a conjunction proof `P && Q`. Decompose into:
- `x` = the proof-free value
- `p` = the detached left-side proof (P)
- `q` = the detached right-side proof (Q)

Use `_` to discard a component you don't need:

```tesl
let (_ ::: p && _) = combined    # just want the left proof, discard value and right proof
```

---

## Practical summary

| Operation | Effect on subject | Effect on proof | When to use |
|---|---|---|---|
| `forgetFact(v)` | preserved | removed | Strip proof, keep identity |
| `detachFact(v)` | preserved | extracted as first-class | Move proof elsewhere |
| `attachFact(v, p)` | preserved | p added to v (still references original subject) | Physically move proof to a carrier |
| `let (x ::: p) = v` | x gets v's subject | p is detached from v | Destructure proof-bearing value |

The soundness guarantee: no combination of these operations can produce a proof
that a value satisfies a predicate it does not actually satisfy.
