## It should be very easy, but understandable, to work with proofs
Tesl should greatly reduce explicit proof juggling, but when proof terms do become visible they should still reflect the GDP foundation rather than hiding it behind magical retargeting or pair-like semantics.

## Core constraints
Any future composition/decomposition surface has to preserve the existing proof/name core:

- ordinary values are named-by-default and carry hidden subjects;
- `forgetProof` removes attached evidence but preserves the subject identity;
- `*x` is still the only raw projection;
- `attachProof` composes evidence but does not retarget a proof to a different subject;
- therefore any new surface decomposition form must elaborate to the existing core rather than introducing a separate runtime model of "value paired with proof".

## Chosen first surface direction
### Composition
```tesl
fn doStuff(y: Int ::: IsPositive y, z: Int) -> Int =
  ...
  let newProof = proveSomething(...)
  let w = z ::: newProof
  ...
```

This remains the canonical composition form.

Important detail: `z ::: newProof` is additive. If code wants to discard earlier attached proofs before adding new ones, it should do that explicitly with `forgetProof(z) ::: newProof`.

### Decomposition
```tesl
fn doStuff(y: Int ::: IsPositive y, z: Int) -> Int =
  let (yWithoutProof ::: yProof) = y
  ...
```

This is the first decomposition syntax to pursue.

We deliberately reject a separate `split y into ...` form for now. Using `let (x ::: p) = y` keeps composition and decomposition visually aligned through `:::` and lets later proof-pattern extensions grow from the same syntax.

## Meaning of `let (x ::: p) = y`
This form should be pure proof-aware sugar over the existing core.

It should elaborate as if the code had written:

- `x = forgetProof(y)`
- `p =` the first-class proof value extracted from `y`

That implies:

- `x` is not the raw payload of `y`; raw access remains `*x` / `*y`;
- `x` keeps the same hidden subject identity as `y`;
- `p` keeps the subject bindings of the proof it came from;
- the form is only valid when proof extraction is unambiguous under the core rules.

So this syntax must not be understood as ordinary tuple/pair destructuring. It is an elaboration convenience for proof-bearing values.

## Recursive proof values
Proofs should eventually be recursive types/terms, not only atomic leaves.

That means the proof side of decomposition should ultimately be able to denote structured proofs such as:

```tesl
let (x ::: p) = y
# where p may have proof shape:
# Proof1 x && Proof2 y && (Proof3 x y || Proof4 z)
```

The recursive structure matters. Tesl should not force users to flatten every conjunction/disjunction into unrelated temporary names when the structure itself is part of the proof story.

## Later decomposition extensions
Once the base `let (x ::: p) = y` form is sound and well-understood, it should be possible to extend the proof side with discard and recursive proof patterns, for example:

```tesl
let (yWithoutProof ::: _ && zIsPositiveProof) = y
```

This should be treated as a later extension, not the first step.

When this is added, it should be structure-directed or template-directed, not positional. `_` should mean discard, but the design should not accidentally give user-visible semantic meaning to the incidental ordering of independently attached facts.

## Proof-juggling helpers
Even with better attachment/decomposition syntax, some explicit proof manipulation will still be necessary.

Tesl therefore needs a small principled family of proof introduction/elimination helpers for conjunction/disjunction. The exact names can still be refined, but this is roughly the missing space currently described by names such as `introAndL/R`, `introOrL/R`, and related helpers.

Conceptually the language needs:

- conjunction construction plus left/right focusing or projection;
- disjunction left/right introduction plus elimination/case analysis.

These helpers should work on first-class proof values with subject bindings intact. They must not retarget proofs, fabricate proofs, or weaken the GDP soundness story. Their purpose is to make the rare explicit proof-juggling cases possible while keeping the default Tesl experience streamlined.

## Staging
A good staged path is:

1. stabilize `value ::: proof` as the composition surface;
2. add `let (x ::: p) = y` as the first decomposition form;
3. once that base is sound, add `_` and recursive proof-pattern decomposition;
4. add the proof intro/elim helper family needed for explicit proof manipulation;
5. only after that, re-evaluate whether parameter-level split sugar is still needed.
