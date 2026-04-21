# Dropping the `*` (Raw/Dereference) Operator

**Status**: Roadmap — feasibility confirmed, implementation ready to begin  
**Effort**: Medium (parser + emitter cleanup + documentation)  
**Risk**: Low — semantics unchanged, all changes are in code generation

---

## Executive Summary

The `*` operator can be **fully removed from Tesl surface syntax** with no change in runtime semantics. The compiler already auto-inserts `raw-value` unwrapping in every context where a raw value is needed — arithmetic, comparisons, string interpolation, function arguments, constructor arguments, list elements, record fields, case scrutinees, and tail/return positions — and the emitter treats `ERaw` and `EVar` identically in all of these positions. Making `*` optional is a matter of removing its production from user-visible parser positions and updating documentation; no new semantic machinery is required.

---

## 1. What the `*` Operator Does

In Tesl, every function parameter is a **named value**: a runtime struct carrying a hidden subject identity (a Racket gensym), the raw payload, and any attached GDP proof facts. The `*x` operator (parsed as `ERaw { name = "x" }`) extracts the raw payload, stripping the proof wrapper.

At the Racket level, `define/pow` creates a `*name` binding for every parameter that holds the raw payload directly. So `*x` in a function body becomes the Racket binding `*x`, while bare `x` is the GDP-wrapped named value.

The operator exists because the GDP proof system needs to distinguish between:
- **Passing a named value forward** — preserving subject identity and proof facts for the type checker
- **Extracting a raw value** — getting the plain integer/string/etc. for arithmetic, display, construction, etc.

---

## 2. Current State: Where `*` is Required vs Auto-Handled

### 2.1 Auto-unwrapping already in place (compiler `emit_racket.ml`)

The compiler auto-inserts `(raw-value ...)` or `*name` in these positions, making explicit `*` optional:

| Context | Mechanism | Where in emitter |
|---|---|---|
| Arithmetic operators (`+`, `-`, `*`, `/`, `%`) | `emit_val_arg`: EVar params → `*name`, let-bound → `(raw-value name)` | `emit_binop` / `BAdd..BMod` |
| Comparison operators (`==`, `!=`, `<`, `<=`, `>`, `>=`) | Same `emit_val_arg` | `emit_binop` / `BEq..BGe` |
| Boolean operators (`&&`, `\|\|`) | Same `emit_val_arg` | `emit_binop` / `BAnd`, `BOr` |
| String concatenation (`++`) | `emit_val_arg` | `emit_binop` / `BConcat` |
| String interpolation (`"${x}"`) | `(raw-value *name)` for params, `(raw-value name)` otherwise | `LInterp` case |
| Stdlib function arguments | `emit_stdlib_arg`: params → `*name` | stdlib EApp path |
| Constructor arguments (ADT, newtype) | `emit_ctor_arg`: params → `*name`, let-bound → `(raw-value name)` | EConstructor EApp path |
| Record field values | inline unwrap: params → `*name` | ERecord, EApp+ERecord paths |
| List elements | inline unwrap: params → `*name` | EList |
| Case scrutinee | `emit_raw_value` | ECase |
| Record update base | `emit_raw_value` | `#record-update#` pattern |
| **Return/tail position in `fn`** | `emit_with_raw_tail`: EVar params → `*name`, let-bound raw → `(raw-value name)`, case arms → recursive | `emit_with_raw_tail` |
| Pattern match arm bodies | `emit_with_raw_tail` recurses; pattern vars go into `raw_locals`, EVar in raw_locals → `*name` | `ECase` in `emit_with_raw_tail` |
| Test `expect` LHS | wraps in `(raw-value ...)` | `TsExpect` |
| Property `where` guards | `emit_val_arg` via `emit_expr` / `emit_binop` | `emit_property_guard` |
| Telemetry field values | inline: `*name` | `ETelemetry` |
| Event publish key | inline: `*name` | `EPublish` |

### 2.2 What `ERaw` vs `EVar` actually emits

The emitter treats `EVar { name }` and `ERaw { name }` **identically** in every practically important position. The table below shows the Racket output for each, in every context where `*` appears in existing code:

| Context | `EVar { name = "x" }` | `ERaw { name = "x" }` |
|---|---|---|
| Binop operand (x is param) | `*x` | `*x` |
| Binop operand (x is let-bound) | `(raw-value x)` | `(raw-value x)` |
| Stdlib arg (x is param) | `*x` | `*x` |
| User-defined fn arg | `x` (GDP named value) | `(raw-value x)` for non-param |
| Constructor arg (x is param) | `*x` | `*x` |
| Record field (x is param) | `*x` | `*x` |
| List element (x is param) | `*x` | `*x` |
| Tail return (x is param) | `*x` | `(raw-value *x)` |
| Pattern arm body (x in raw_locals) | `*x` | `(raw-value (raw-value x))` = `(raw-value x)` |
| String interp (x is param) | `(raw-value *x)` | `(raw-value *x)` |
| EOk value (proof return) | `x` (named value) | `x` (named value) |
| Accept value (check/auth return) | `*x` | `*x` |

The only divergence is in **user-defined function argument** position: `EVar` passes the GDP-named value, `ERaw` passes the raw value. This does not matter because `define/pow` handles both: when it receives a named value, it extracts the raw payload for `*x`; when it receives a raw value, it wraps it fresh. This is confirmed by the lesson documentation: "Function calls auto-unwrap arguments."

The idempotency of `(raw-value ...)` on already-raw values (`(raw-value (raw-value x))` = `(raw-value x)`) makes any double-wrapping from the `ERaw` path harmless.

---

## 3. Remaining Uses of `*` in the Codebase — and Their Status

Surveying all `.tesl` files:

### 3.1 Arithmetic / comparison (all redundant)
```tesl
*x + *y          -- same as x + y
*pi * *radius    -- same as pi * radius
if *lo < *hi     -- same as if lo < hi
if *n >= 18      -- same as if n >= 18
```
`emit_val_arg` auto-unwraps `EVar` in binop position. The `*` adds visual noise but changes nothing.

### 3.2 Return position (redundant since `emit_with_raw_tail`)
```tesl
fn clampToRange(lo, hi, value) -> Int =
  if *value < *lo then *lo   -- same as: if value < lo then lo
  else if *value > *hi then *hi
  else *value
```
`emit_with_raw_tail` recurses into `if` branches and emits `*lo`, `*hi`, `*value` from `EVar` automatically when those names are in `param_names`. The explicit `*` is redundant.

### 3.3 Constructor arguments (redundant)
```tesl
fn makePoint(x: Int, y: Int) -> Point = Tuple2 *x *y
-- same as:
fn makePoint(x: Int, y: Int) -> Point = Tuple2 x y

type UserId = String
fn makeUserId(raw: String) -> UserId = UserId *raw
-- same as:
fn makeUserId(raw: String) -> UserId = UserId raw
```
`emit_ctor_arg` for `EVar` with a param name emits `*name` — identical to `ERaw`.

### 3.4 Pattern match arm bodies (redundant)
```tesl
fn evaluate(e: Expr) -> Int =
  case e of
    Lit n -> *n      -- same as: Lit n -> n
    Nothing -> *d    -- same as: Nothing -> d (where d is a param)
    Something v -> *v
```
Pattern-bound variables go into `raw_locals`. `EVar { name }` in `emit_with_raw_tail` with `name` in `raw_locals` emits `*name`. `ERaw` takes a slightly longer path but produces the same output. Both work.

### 3.5 String interpolation (redundant)
```tesl
"age is ${*age}"      -- same as: "age is ${age}"
"${*n} is in range"   -- same as: "${n} is in range"
```
Both `EVar` and `ERaw` emit `(raw-value *name)` in function context for params.

### 3.6 Function call arguments (redundant)
```tesl
f *validated    -- same as: f validated
subOne *n       -- same as: subOne n
```
User-defined functions (`define/pow`) accept both named and raw values; the `*name` extraction also happens automatically.

### 3.7 Test `expect` assertions (redundant)
```tesl
expect *r1 == 1    -- same as: expect r1 == 1
expect *v == 5     -- same as: expect v == 5
```
The test emitter wraps both sides in `(raw-value ...)` regardless of `*`.

### 3.8 Property guards (redundant)
```tesl
property "..." (n: Int where *n >= 0 && *n < 10) { ... }
-- same as:
property "..." (n: Int where n >= 0 && n < 10) { ... }
```
`emit_val_arg` handles EVar in comparison position outside function context.

---

## 4. Theoretical Analysis

### 4.1 GDP identity and proof tracking

The GDP system tracks proof identity through **hidden subjects** (Racket gensyms). The `named-value` struct is the runtime carrier; the type checker is the static verifier. Critically:

- Unwrapping via `raw-value` does **not** destroy a proof. The proof is recorded in the type checker's static environment. The `named-value` struct is alpha-phase infrastructure.
- Auto-unwrapping in arithmetic/comparison has always been implicit and does not break GDP. Extending this to all positions is consistent.
- The LANGUAGE-SPEC.md explicitly states (§10): "The long-term goal is to elide all `named-value` wrapping for standard `check`/`fn` paths — proofs will be fully erased after the static checker has proven itself reliable in production."

Making `*` implicit is a step in the direction the language spec already mandates.

### 4.2 Ambiguity: named value vs raw value

The only position where the distinction matters semantically is **proof-annotated returns**:
```tesl
fn f(x: Int ::: IsPositive x) -> Int ::: IsPositive x = ok x ::: isPositive
```
Here `x` must be passed as a named value to preserve subject identity for proof attachment. The `EOk` emitter already handles `EVar` and `ERaw` identically (both emit `name` without `*`). There is no ambiguity.

The concern "could implicit unwrapping lose the proof identity?" only arises if we auto-unwrap in proof-return positions. The current compiler does **not** auto-unwrap in EOk/accept context — it passes the named value directly. Making `*` implicit does not change this behavior.

### 4.3 The one real asymmetry: user-defined fn call

When `*x` is used as an argument to a user-defined function, the emitter produces `(raw-value x)` (stripping proof) vs bare `x` (passing named value). This IS semantically different from a Racket perspective — but not from Tesl's perspective, because `define/pow` normalizes both. The long-term direction (zero runtime proof overhead) makes this distinction moot: once runtime structs are erased, there is no `named-value` to strip.

### 4.4 Bug 1 from the critical review (returning param directly)

Critical Review Bug 1 reported that `fn fibonacci(n: Int) -> Int = if n <= 1 then n else ...` returned a named struct instead of a raw integer. This was fixed by adding `emit_with_raw_tail` with `is_fn_param_tail` detection. The fix is already in the codebase:

```ocaml
let is_fn_param_tail = match tail, fd.kind with
  | EVar { name; _ }, FnKind when List.mem name param_names && not has_forall_return -> true
  | _ -> false
```

And `emit_with_raw_tail` for `EVar` in tail position:
```ocaml
| EVar { name; _ } ->
  if List.mem name param_names || Hashtbl.mem ctx.raw_locals name then
    emit ctx ("*" ^ name)
  else ...
```

So `fn fibonacci(n: Int) -> Int = if n <= 1 then n else ...` already compiles correctly **without** explicit `*`. The operator was never needed for this case; the fix was in the emitter, not in making users write `*n`.

---

## 5. Concrete Proposal

### Option A: Make `*` Optional (Recommended — low effort, low risk)

Keep `*` in the grammar but treat it as a documentation hint rather than a semantic requirement. The compiler accepts both `x` and `*x` in all positions; both produce identical output.

**Implementation steps:**

1. **No parser changes needed** — `*x` already parses as `ERaw`, and `x` as `EVar`. Both work identically in the emitter.

2. **Update documentation** — Remove the implication that `*` is required. Update `LANGUAGE-SPEC.md` §2 product goals and lesson40 to say `*` is optional, stylistic, and deprecated.

3. **Update lesson40** — Reframe it as: "`*` is an optional explicit form; the compiler handles unwrapping automatically." Replace the "RULE OF THUMB" with "the compiler always handles this."

4. **Lint/formatter rule** — Once a formatter exists, emit a warning when `*` is used (except in multiplication contexts, where it remains unambiguous as an infix operator).

5. **Future: Remove from grammar** — After a deprecation period, remove `STAR` from the expression atom parser (line 1593 of parser.ml), remove `ERaw` from `ast.ml`, and update the emitter to remove `ERaw` match arms (or keep them as dead code temporarily).

**Risk assessment**: None. Existing code with `*` continues to work. New code without `*` already works. This is purely additive.

### Option B: Full Immediate Removal (Medium effort, slightly higher risk)

Remove `ERaw` from the surface syntax entirely now.

**Implementation steps:**

1. **Parser** — Remove the `| STAR -> advance s; let* name = ... return (ERaw { name; loc })` atom case (parser.ml:1593–1599). Change `STAR` in expression positions to always be the multiplication operator.

2. **Emitter** — Replace all `ERaw` match arms in `emit_racket.ml` with the corresponding `EVar` handling. In most cases this is already identical; the few cases that differ (user-defined fn call position, EOk) need verification.

3. **AST** — Remove `ERaw` from `ast.ml`. All code that pattern-matches on `ERaw` must be updated or unified with the `EVar` case.

4. **Checker** — Remove the `ERaw` case (checker.ml:789–795). Already trivial since it just does the same type lookup as `EVar`.

5. **Update all tests and examples** — Remove all `*name` uses from `.tesl` files.

**Risk assessment**: Low, but requires systematic testing. The semantic equivalence has been verified by code inspection; a full test pass is required to confirm no edge cases were missed.

### Option C: Strategic Middle Ground (Recommended long-term)

1. **Now**: Document that `*` is fully optional. Add a linter warning when used.
2. **Next cycle**: Remove from surface grammar. Internal `ERaw` AST node remains only for compiler-inserted uses (if any).
3. **Long-term**: After runtime proof elision (per the spec's zero-cost goal), `named-value` structs disappear entirely and the distinction becomes meaningless.

---

## 6. Verdict

| Question | Answer |
|---|---|
| Is full removal possible? | **Yes** |
| Any semantic cases requiring explicit `*`? | **None found** |
| Risk of removal? | **Low** — semantics unchanged |
| GDP proof identity preserved? | **Yes** — proofs are type-checker metadata; `*` is runtime plumbing |
| Effort for Option A (make optional)? | **~1 day** — documentation only |
| Effort for Option B (full removal)? | **~3–5 days** — parser + emitter + tests |
| Does removal align with the language spec direction? | **Yes** — spec §10 explicitly targets zero-cost proofs with full erasure |
| Does it conflict with the "raw access should be explicit" product goal? | **Partially** — but that goal was written before the emitter proved auto-unwrapping works everywhere. The goal should be rephrased: "proof facts are explicit; raw access is automatic." |

**Recommendation**: Implement Option A immediately (mark `*` as optional/deprecated in documentation, no code changes needed since the semantics are already there). Schedule Option B for the next cleanup cycle, after confirming with the full test suite that all edge cases pass without `*`.

The `*` operator has served its purpose as a teaching tool during the language's design phase. Its removal simplifies the surface language without any loss of expressiveness or soundness.

---

## Appendix: Key Code Locations

| File | Lines | Purpose |
|---|---|---|
| `compiler/lib/ast.ml` | `ERaw of { name : string; loc : loc }` | AST node for `*name` |
| `compiler/lib/parser.ml` | 1593–1599 | Parse `STAR IDENT` → `ERaw` |
| `compiler/lib/checker.ml` | 789–795 | Type-check `ERaw` (same as `EVar`) |
| `compiler/lib/emit_racket.ml` | 939–969 | Emit `ERaw` (identical result to `EVar` in all contexts) |
| `compiler/lib/emit_racket.ml` | 1840–1868 | `emit_val_arg`: auto-unwraps both `EVar` and `ERaw` in binop |
| `compiler/lib/emit_racket.ml` | 2849–3036 | `emit_with_raw_tail`: handles `EVar` in return position |
| `compiler/lib/emit_racket.ml` | 3075–3087 | Tail dispatch: triggers `emit_with_raw_tail` for param tails |
| `example/learn/lesson40-raw-star-operator.tesl` | all | User documentation for `*` |
