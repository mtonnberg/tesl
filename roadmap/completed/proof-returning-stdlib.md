# Proof-Returning Standard Library Functions — Compiler Fix

> **Implemented** — proof-returning stdlib functions now work inline in comparisons, arithmetic, and function calls.

## What was fixed

The compiler's `raw_default=True` mechanism previously applied `raw-value` only to **variable references** (e.g. `*name`), not to **function call results**. This meant:

```tesl
# BEFORE (broken): String.trim returns a named-value; == fails
if String.trim(s) == "" then ...

# BEFORE (required workaround):
let t = String.trim(s)
if String.isEmpty(t) then ...
```

The fix: in `BodyCompiler.compile_expr`, when `raw_default=True` and the expression is a function call, wrap the result with `(raw-value ...)`:

```
# AFTER: works directly
if String.trim(s) == "" then ...
String.length(String.trim(s)) > 0       # chained calls also work
List.isEmpty(List.sort(xs))              # sort result usable inline
```

## Proof propagation rules

Proofs propagate when the **caller declares the return type** with `? ProofPredicate`:

```tesl
# Plain return — proof is stripped; caller gets plain String
fn normalize(s: String) -> String =
  String.trim(s)   # returns "hello", not named-value

# Proof return — proof is propagated; caller gets String ::: IsTrimmed result
fn normalize(s: String) -> String ? IsTrimmed =
  String.trim(s)   # returns named-value with IsTrimmed proof
```

The rule is: `raw_default = not return_has_proof(return_spec)`. If the return type has no proof annotation, the call result is unwrapped. If it has `? ProofPredicate`, the proof is preserved.

## Implementation

Changed in `tesl/private/compile_thsl.py`:
- `BodyCompiler.compile_expr`: added `(raw-value ...)` wrapper for function call results when `raw_default=True`
- Skip checker functions (`checker_functions` set) — they return `check-ok`, handled by `let/check`
- `compile_terminal_expression`: changed to pass `raw_default=False` for DSL function case (avoids double-wrapping)

## Regression tests

Seven new tests in `tests/thsl-test.rkt` (STD-034a through STD-034g):
- `String.trim(s) == ""` inline
- `String.toUpper(s) == "HELLO"` inline
- `List.sort(xs)` result used in nested call
- Chained proof-returning calls: `String.length(String.trim(s)) > 0`
