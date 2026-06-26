# Actually Zero-Cost Runtime Proofs

## Current state

Tesl's marketing copy and language spec describe proofs as "zero-cost at runtime
— all proof checking happens at compile time." This is accurate for the *check*
phase (the `check` keyword runs once, at the point of validation), but the claim
does not hold for how proof-carrying values are represented at runtime.

Every value that enters or exits a GDP-aware function is wrapped in a
`named-value` struct (defined in `dsl/private/evidence.rkt`):

```racket
(struct named-value (name value facts bindings) #:transparent)
```

- `name` — a gensym, unique identity for this witnessed value
- `value` — the raw underlying value
- `facts` — a list of s-expressions describing attached proof predicates
- `bindings` — a hash of named sub-bindings (for cross-parameter proofs)

Every call to a `fn` or `handler` defined with `define/pow` wraps its parameters
in `named-value` on entry and unwraps with `raw-value` on exit. This means:

1. **Allocation**: every proof-carrying call allocates at least one Racket struct.
2. **Indirection**: reading the underlying value costs one field dereference.
3. **Fact lists**: runtime fact lists are walked by `check-proof-satisfied?` at
   each `check` or `establish` call site — linear in the number of attached facts.

For a hot API handler receiving 5 proof-annotated parameters, that is 5 struct
allocations plus 5 field dereferences per request, before any application logic
runs.

## What "truly zero-cost" would mean

A truly zero-cost proof system would:

1. Erase all `named-value` wrappers after type-checking.
2. Compile proof-annotated parameters to their raw types in the emitted Racket.
3. Verify all proof obligations statically, emitting no runtime fact-walking code.
4. Only materialise proof structs at explicit `establish`/`attachFact` call sites
   (where the programmer is deliberately constructing a proof object to hand around).

This is achievable for the **common case**: a `check` function that returns
`T ::: P` is called once, the result is bound, and then passed to a function
that requires `P`. The compiler already tracks this statically (proof_checker.ml).
The emission layer (`emit_racket.ml`) could omit the `named-value` wrapper and
emit the raw value directly, since the proof has already been verified.

## What cannot be zero-cost without major work

- **Free-floating proofs** — `detached-proof` structs that are passed around as
  first-class values (e.g. `detachFact`, `attachFact`) genuinely need a runtime
  representation. Eliminating them would require dependent types or a richer
  effect system.
- **Cross-boundary proof transport** — when a proof is imported from another
  module at runtime (e.g. reading a validated value from the database), there is
  no compile-time witness; the runtime fact list is the only record.
- **`establish` results with dynamic fact sets** — e.g. `attachFact` that
  conditionally attaches a fact based on runtime data. These need the fact list.

## Proposed phased approach

### Phase 1 — Fix the marketing claim (low effort, immediate)

Update `LANGUAGE-SPEC.md`, `TESL.md`, and `README.md` to accurately describe the
proof cost model: *"proof checking happens once, at the validation call site; the
result is statically tracked by the compiler for the rest of the function. At
runtime, the compiler emits lightweight wrapper structs to carry proof identity;
for most web-API workloads this overhead is negligible."*

### Phase 2 — Proof-struct elision for fully-static paths (medium effort)

For functions where **all** proof obligations are statically resolved by
`proof_checker.ml` and no `detachFact`/`attachFact`/`establish` is used in the
function body, the emitter can:

- Emit parameters as their raw types (not `define/pow` parameters).
- Skip `named-value` wrapping on call.
- Skip `raw-value` unwrapping in the body.

This covers the vast majority of handler code (fetch from DB with proof,
validate, pass to business logic). Estimated savings: 3–6 allocations per
handler invocation.

**Constraint — debug builds must not elide.** The interactive debugger in
`roadmap/next/improved_devx.md` (workstream 1 / B3) displays a value's proofs by
reading the `facts` off the runtime `named-value` struct. Elision erases those structs,
so the agreed contract is that **elision only applies to release builds; `--debug`
compilation keeps the proof wrappers.** This is a natural extension of the gating below
(elision is opt-in/gated anyway) and lets the debugger and this item proceed in any
order. Practically: the `fi_static_proofs` fast path is suppressed when the compiler is
in debug mode.

Implementation sketch:
1. Add a flag to `func_info` / `func_decl`: `fi_static_proofs : bool` — set
   during validation when all proof params are statically resolved.
2. In `emit_racket.ml`, emit such functions with plain `define` instead of
   `define/pow`, and emit calls without `named-value` wrapping.
3. The `check` function emitter can emit raw value directly (skipping
   `ensure-named`) when the result is immediately passed to a statically-proven
   call site.

### Phase 3 — Kind inference and zero-cost parameterized types (larger effort)

Currently `List`, `Dict`, `Set` etc. require explicit type arguments (e.g.
`List Int`) because the type system lacks kind inference. Proper kind inference
would allow the type system to infer `List Int` from usage context and also
enable more precise type information for the proof elision pass.

## Should we remove all runtime proof checks now?

**No.** The compiler does not yet have a completeness proof for its static
proof checker. Removing all runtime checks prematurely would silently allow
unsound programs to execute. The correct path is:

1. Gain confidence in the static checker completeness (more tests, formal analysis).
2. Implement Phase 2 elision for the provably-safe subset.
3. Gate Phase 3 behind a compiler flag (`--zero-cost-proofs`) initially, so
   users can opt in and report regressions.
4. Make it the default once the test suite and real-world usage confirm soundness.

The runtime checks are a useful safety net during Tesl's alpha phase.
