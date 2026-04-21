# Add Bidirectional Type Checking

## Context

This item should describe the next checker-quality step for the current compiler, not a future rewrite.

The current state is:

- The OCaml compiler already exists and is the active frontend.
- The checker lives in `compiler/lib/checker.ml`.
- The checker already has a substantial `infer_expr`-driven implementation.
- The compiler already has reliable source locations and emits diagnostics through `compiler/lib/compile.ml`.
- The editor stack already consumes compiler diagnostics through `editor/protocol.md`.

That means the value of this item is no longer "unlock the rewrite". The value is to improve the current checker architecture so diagnostics become more local and later semantic tooling is built on the right retained information.

---

## Goal

Keep Tesl's Hindley-Milner inference and let-generalisation, but drive the checker from expectations wherever the syntax already provides them.

The result should be:

- type errors that point at the actual bad expression
- diagnostics that explain why a type was expected
- better retained semantic information for later compiler-backed tooling

This is an internal checker-architecture improvement. It is not a surface-language feature.

---

## Why this still matters

The current compiler already gives Tesl a much better base than the old implementation:

- typed internal structures
- a real unification-based checker
- reliable source spans
- structured diagnostics

But a mostly inference-first checker still tends to discover mismatches at the unification site rather than at the programmer's actual mistake.

That matters in Tesl because many high-value errors occur in contexts that already carry strong expectations:

- top-level declarations with explicit return types
- record and entity literals
- handler bodies
- `if` conditions
- branch result types
- function application once parameter types are known

Bidirectional checking is therefore the next quality step for the existing compiler.

---

## Current implementation reality

The checker in `compiler/lib/checker.ml` has both `infer_expr` and `check_expr` entry points.
`check_expr` carries expectation frames with human-readable reasons through the tree.

The implementation covers:
- top-level `fn`, `handler`, `worker`, `check`, `auth` bodies against declared return types
- `if` conditions checked against `Bool`
- call arguments with named-parameter context
- record/entity literals against known field types
- expectation frame messages include the origin reason

Tests for this behavior are in `compiler/test/test_types.ml` (see `test_error_return_type_context_int`
and `test_error_if_cond_not_bool`).

That means this roadmap item is largely complete. The remaining work (Item 03 / IR-1) should
retain expectation metadata as it designs the semantic layer.

---

## What changes

Introduce two mutually recursive checker entry points:

- `infer_expr env expr` — infer a type when the surrounding context does not already determine it
- `check_expr env expr expected` — validate an expression against a known expected type

The fallback rule stays familiar: if there is no useful expectation, infer and unify.

This is a refinement of the current checker, not a replacement for HM inference.

Checking mode should be used where Tesl syntax already provides a trustworthy expectation:

- top-level `fn`, `handler`, `worker`, `check`, `auth`, and `establish` bodies against declared return types
- call arguments once the callee type is known
- record, entity, and ADT-constructor fields against declared field types
- explicit type annotations
- `if` conditions against `Bool`
- branch bodies when an enclosing context already fixes the result type

---

## Tesl-specific payoff

### 1. Return-type errors become local

If a `handler`, `fn`, `check`, or `auth` is declared to return a specific type, the checker should validate the body against that expectation directly and report the bad expression inside the body, not only the later unification failure.

### 2. Record and entity literal errors become local

When a literal is checked against a known record/entity type, each field can be checked against the declared field type. That means:

- wrong field value types point at the value
- missing fields can be reported clearly against the literal
- diagnostics can name the field that established the expectation

### 3. Call-site diagnostics become clearer

Once the callee type is known, each argument can be checked against the corresponding parameter type. Diagnostics can say which parameter was being checked, not just that two types failed to unify.

### 4. Branching diagnostics improve

`if` conditions can always be checked against `Bool`. Branches and `case` arms can be checked against an enclosing expected type when one exists, which prevents errors from surfacing only after the whole expression has been inferred.

### 5. Tooling gets better semantic breadcrumbs

This item is not only about messages. It should also define the expectation metadata that later semantic work retains.

That matters for:

- richer diagnostics
- future code actions
- semantic hovers
- IR-1 design

---

## Expectation frames

`check_expr` should carry structured expectation frames rather than only a naked expected type.

An expectation frame should record at least:

- the expected type
- source span / origin information
- a human-readable reason
- the structural role that introduced the expectation

Examples of reasons Tesl should be able to preserve:

- because `createUser` is declared to return `User`
- because field `email` in `User` has type `Email`
- because argument 2 of `authorize` expects `Session`
- because an `if` condition must be `Bool`

The immediate user-visible benefit is better diagnostics. The longer-term benefit is that IR-1 can retain the same expectation context instead of reconstructing it later.

---

## What stays the same

- Hindley-Milner inference remains the core type system
- let-generalisation remains
- there is no new surface syntax
- this is not a plan to add subtyping, traits, higher-rank types, or explicit-annotation-heavy typing rules
- GDP/proof checking remains a separate concern

This is a quality and architecture improvement, not a new type system.

---

## Relationship to other roadmap items

### `roadmap/next/05-improved-tooling.md`

Basic compiler-backed code actions can begin once fix payloads exist, but advanced semantic tooling should not harden around the current inference-only shape.

This item should therefore land before rename, richer semantic completions, and compiler-backed field diagnostics are built out in earnest.

### `roadmap/next/01-fix-bool-return-type.md`

Item 01 should land early enough that improved diagnostics consistently teach the canonical surface language rather than legacy aliases. Bidirectional checking improves *how* Tesl explains type errors; Item 01 helps ensure those explanations use the right language forms.

### `roadmap/next/03-ir-1-semantic-layer.md`

IR-1 should retain the final checker's view of expressions. If the checker knows both:

- the resolved type
- the active expectation context

then IR-1 should store both from day one instead of retrofitting expected-type information later.

IR-1 design can start in parallel, but IR-1 implementation should not freeze retained typing metadata before this item stabilizes.

### `editor/protocol.md`

The protocol does not need a redesign for this item. The point is to improve message quality and semantic metadata while preserving the current compiler/editor compatibility contract.

---

## Recommended implementation order

- [x] 1. Split the checker surface into explicit infer/check entry points without changing behavior yet.
- [x] 2. Introduce expectation frames with origin and human-facing reason text.
- [x] 3. Convert the highest-value forms first:
   - [x] annotated top-level bodies
   - [x] application
   - [x] record/entity literals
   - [x] `if`
   - [x] `case`
   - [x] list and tuple elements
   - [x] constructor arguments
- [x] 4. Upgrade diagnostics to report the primary mismatch location plus expectation notes.
- [ ] 5. Thread the stabilized expectation metadata into the IR-1 design.

This order keeps risk down while moving quickly toward the biggest quality wins.

---

## Non-goals

- Rewriting the compiler frontend again
- Reworking the Racket backend/runtime lowering as part of this item
- Solving rename or semantic editor features directly inside the checker item
- Replacing proof checking with ordinary structural typing
- Requiring explicit type annotations everywhere

---

## Success criteria

- [x] valid Tesl programs do not become invalid solely because bidirectional checking landed
- [x] return-type mismatches in `fn` / `handler` / `check` / `auth` bodies point at the offending expression
- [x] record and entity literal mismatches point at the field value or clearly report the missing field
- [x] argument mismatches point at the offending argument expression
- [x] diagnostics explain why the expected type arose, not only that unification failed
- [x] existing inference for unannotated local bindings still works
- [x] current compiler/editor protocol compatibility remains intact
- [ ] IR-1 design is updated to account for expected-type metadata where available (blocked on Item 03)
