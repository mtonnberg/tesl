# 04 — Body Compiler, Reference Collector, and Semantics Validator

This guide covers the three Python classes that handle everything inside
function bodies: `BodyCompiler`, `ReferenceCollector`, and `BodySemanticsValidator`.

---

## Overview

After parsing, each `FunctionDecl` has `body_lines` — a list of raw indented
text lines. These lines are compiled by:

1. **`BodySemanticsValidator`** — walks the body, checks for semantic errors
   (unknown fields, non-exhaustive case, shadowing). Raises `ParseError` if invalid.
2. **`BodyCompiler`** — walks the body a second time, emitting Racket code.
   Also used by `ReferenceCollector`.
3. **`ReferenceCollector`** — collects all name references from every form
   (for the `validate_module_references` check).

---

## BodyCompiler

```python
class BodyCompiler:
    def __init__(self,
        dsl_functions: set[str],
        checker_functions: set[str],
        dotted_import_aliases: dict[str, str],
        adt_variant_fields: dict[str, tuple[str, ...]],
        home_proof_predicates: set[str] | None = None,
        constructor_to_all: dict[str, frozenset[str]] | None = None,
        function_arity: dict[str, int] | None = None,
        function_decls: dict[str, FunctionDecl] | None = None,
        entity_fields: dict[str, frozenset[str]] | None = None,
        job_type_to_queue: dict[str, str] | None = None,
        records_with_proof: dict[str, str] | None = None,
    ):
```

Key fields:

| Field | Purpose |
|---|---|
| `dsl_functions` | Names of functions defined in this module or imported from Tesl modules (not stdlib). Used to decide whether to emit `(raw-value ...)` around args. |
| `checker_functions` | Names of `check`/`establish`/`auth` functions. Used for `let x = check f(n)` lowering. |
| `dotted_import_aliases` | Maps `"String.length"` → `"thsl_import_String_length"` |
| `adt_variant_fields` | Maps ADT constructor names to their field names. Used in `case` pattern compilation. |
| `home_proof_predicates` | Set of predicates this module is allowed to construct. `None` = no restriction. |
| `constructor_to_all` | Maps each constructor to the full set of siblings (for exhaustiveness). |
| `function_arity` | Maps function name → number of declared parameters. Used for partial application. |
| `records_with_proof` | Maps record name → record-level proof text for records declared with `} ::: Fact`. Used to enforce the ghost witness requirement at construction sites. |

### Entry point: `compile`

```python
def compile(self, lines, initial_bound, return_spec, func_kind) -> str:
    self.active_func_kind = func_kind   # "fn", "check", "establish", "auth", "handler", "worker"
    structured = to_structured_lines(lines)
    expr, _ = self.compile_sequence(structured, 0, 0, set(initial_bound), return_spec)
    return expr
```

`initial_bound` is the set of parameter names (the function's arguments).

### `compile_sequence` — the body loop

Processes a list of structured lines as a sequence of statements:

```python
def compile_sequence(self, lines, index, indent, bound_names, return_spec):
    # Advances through lines at the given indent level
    # Returns (compiled_racket_expr, next_index)
```

Each statement is handed to `compile_statement`. The last statement is the
return value of the body (no explicit `return` keyword — last expression is the
result).

### `compile_statement`

Dispatches on the statement's text:

| Starts with | Compiled as |
|---|---|
| `let name = check expr` | `(let/check ...)` — monadic bind |
| `let name = expr` | `(let ([name expr]) ...)` |
| `let (x ::: p) = y` | proof decomposition |
| `if ... then` | multi-line if/else |
| `case ... of` | exhaustive case expression |
| `exists name =>` | existential packing |
| `with database X {` | `(call-with-database ...)` |
| `with transaction {` | `(call-with-queue-transaction ...)` |
| `ok expr` | `(accept ...)` / inline terminal |
| `fail code msg` | `(reject msg #:http-code code)` |
| `enqueue Job { ... }` | `(enqueue! ...)` |
| `publish Ch(key) Var { ... }` | `(publish-event! ...)` |
| `telemetry "key" { ... }` | `(call-with-telemetry-context ...)` |
| Otherwise | `compile_terminal_expression` |

### `compile_expr` — expression compilation

The heart of the compiler. Handles (in precedence order):

1. `|>` pipeline (left-to-right)
2. `<|` application (right-to-left)
3. `:::` proof attachment
4. `||` / `&&` boolean operators
5. `==`, `!=`, `<=`, `>=`, `<`, `>` comparisons
6. `+`, `-` additive
7. `*`, `/`, `%` multiplicative
8. `{...}` record literals
9. `[...]` list literals → `(list ...)`
10. `"..."` string literals (with `${expr}` interpolation)
11. Integer literals
12. `true` / `false` / `Nothing`
13. Implicit value unwrapping (parameters/locals auto-unwrapped at use sites)
14. `name(args)` function calls
15. ML-style `f x y` application
16. Dotted identifiers (`String.length`)
17. Plain identifiers

### Implicit value unwrapping

The OCaml compiler automatically emits `*name` (Racket `(raw-value name)`) for function parameters and locally-bound case variables whenever they appear in a context that requires a raw value — arithmetic operands, comparison operands, string interpolation, constructor arguments, and stdlib call arguments. There is no surface syntax for manual unwrapping; the compiler infers the correct representation from context.

Internally the emitter tracks two sets: `param_names` (function parameters) and `raw_locals` (case-bound variables). At each use site it checks whether the variable is in one of these sets and emits the appropriate form.

**String interpolation** always wraps each interpolated expression in
`(raw-value ...)` regardless of `raw_default`. This ensures that proof-carrying
`named-value` structs display as their plain payload in format strings rather
than printing as Racket struct literals.

```tesl
"order: price=${order.price}, qty=${order.quantity}"
```

compiles to:

```racket
(format "order: price=~a, qty=~a"
        (raw-value (field-access-ref order 'price))
        (raw-value (field-access-ref order 'quantity)))
```

### Ghost witness enforcement (`records_with_proof`)

When `records_with_proof` is populated (from records declared with `} ::: Fact`),
`compile_terminal_expression` enforces the ghost witness pattern at every
record construction site:

```python
# { ... } ::: witnessVar  — ghost witness: zero-cost, compiled as plain constructor
# { ... }                 — missing ghost witness: compile error
```

- `{ a: a, b: b } ::: proof` — compiled as `(Pair #:a *a #:b *b)` (no `attach-proof` call)
- `{ a: a, b: b }` — raises `ParseError` if `Pair` is in `records_with_proof`

The witness variable must be a locally bound proof variable. It is entirely
erased at compile time — the `:::` on a record literal produces no runtime code.

`records_with_proof` is populated in `_gen_single_module_content` and
`_gen_scc_content`:

```python
records_with_proof = {
    f["name"]: f["record_proof"]
    for f in module["forms"]
    if f["kind"] == "record" and f.get("record_proof")
}
```

#### Witness proof validation (`validate_ghost_witness`)

Supplying *any* proof is not enough — the compiler validates that the ghost
witness carries the **correct predicate** and the **correct proof subjects**
(i.e. the same value identities as the field expressions in the record literal).

This is done in `BodySemanticsValidator.validate_ghost_witness`, called from
`infer_expr` whenever a `{ ... } ::: proofExpr` is encountered and
`proofExpr` resolves to a `StaticProofInfo`:

1. **Identify the record type** from the set of field names in the literal
   (via `record_fields_map`).
2. **Parse the required proof template** from `records_with_proof[record_name]`
   (e.g. `"PriceExceedsQuantity price quantity"`).
3. **Build a subject mapping** `field_name → StaticSubject` by inferring the
   static type of each field value expression. `StaticSubject` carries both a
   display name and a unique ID; equality is based on the unique ID, not the
   display name.
4. **Instantiate the template** by substituting formal field names with actual
   subjects (`instantiate_fact`). If any subject is unresolvable, the
   instantiation is *partial* and only a shape check is performed.
5. **Compare against witness facts**:
   - Full check (`static_proof_satisfied`): all subjects resolved — predicate
     name and all argument identities must match.
   - Shape check (`static_shape_satisfied`): partial resolution — predicate
     name must match, arguments are unconstrained.

Errors produced:

```
# Wrong predicate:
ghost witness for `OrderLine` carries the wrong proof predicate
  expected a proof of `PriceExceedsQuantity`
  got: `(IsPositive n)`

# Wrong subjects:
ghost witness for `OrderLine` carries the wrong proof
  required: `(PriceExceedsQuantity p q)`
  got:      `(PriceExceedsQuantity p_intruder q)`
  the ghost witness must be the cross-field proof obtained for the EXACT
  values that appear in the record literal
```

`records_with_proof` and `record_fields_map` are built from the current module
only; cross-module ghost-witness validation is not needed because the
`BodyCompiler` for a callee module already enforces the ghost witness at the
definition site.

### Partial application

When a function is called with fewer arguments than its declared arity, the
compiler emits a `lambda`:

```python
# fn add(x: Int, y: Int) -> Int
# Called as: let addOne = add 1
# Emits:
(lambda (_thsl_p0_0) (add 1 _thsl_p0_0))
```

Tracked via `self.function_arity` and `self.partial_counter`.

### `compile_case`

```python
def compile_case(self, scrutinee_text, branch_lines, bound_names, return_spec):
    # Each branch: "Constructor fieldA fieldB -> body"
    # Emits: (match scrutinee [(Constructor fieldA fieldB) body] ...)
    # Validates exhaustiveness against constructor_to_all
```

For exhaustiveness: the set of constructors in the `case` must equal the full
sibling set from `constructor_to_all[constructor_name]`. Missing constructors
are reported as a compile error.

---

## dotted_import_aliases

When a module does `import Tesl.String exposing [String.length]`, the compiler
creates an alias:

```python
dotted_import_aliases["String.length"] = "thsl_import_String_length"
```

Then in the generated Racket:

```racket
(only-in (file "tesl/string.rkt")
  [String.length thsl_import_String_length])
```

And in body code: `String.length(s)` compiles to `(thsl_import_String_length s)`.

The alias uses `thsl_import_` prefix + dots replaced with `_`.

---

## ReferenceCollector

Used during validation (not code generation) to find all names referenced in
a module's forms:

```python
class ReferenceCollector:
    def collect_body(self, lines, initial_bound) -> set[str]:
        # Returns set of all names referenced in body (not counting bound names)
    def collect_expr(self, text, bound_names)
    def add_value_reference(self, name, bound_names)
        # Adds name to references if not in bound_names
```

`validate_module_references` then checks that every reference is either defined
locally or imported. This is how you get the error:
`"all non-local references must be defined … missing foo"`.

---

## BodySemanticsValidator

Subclass of `BodyCompiler` (or uses the same compilation infrastructure) that
runs before code generation to catch semantic errors:

- **Unknown entity fields**: `update note in Note set note.nosuchfield = v` → error
- **Fact construction in fn/handler**: `value ::: IsPositive x` in a `fn` body → error
- **Non-exhaustive case**: missing constructors
- **Name shadowing**: rebinding a name that's already in scope

These checks use the same `compile_*` infrastructure but emit nothing — they
just walk the structure and call `fail()` on problems.

---

## emit_forms and emit_function_form

After validation, `emit_forms` calls each form's emitter:

```python
def emit_forms(forms, compiler) -> list[str]:
    for form in forms:
        if form["kind"] == "function":
            lines.extend(emit_function_form(form["value"], compiler))
        elif form["kind"] == "adt":
            lines.extend(emit_adt_form(form))
        elif form["kind"] == "entity":
            lines.extend(emit_entity_form(form))
        # ... etc
```

`emit_function_form` builds the Racket `define-checker` / `define/pow` /
`define-handler` / `define-auther` / `define-trusted` call, compiling the body via
`compiler.compile(body_lines, arg_names, return_spec, func_kind)`.

```python
def emit_function_form(decl: FunctionDecl, compiler: BodyCompiler) -> list[str]:
    compiled_body = compiler.compile(
        decl.body_lines,
        {binding.name for binding in decl.args},
        decl.return_spec,
        decl.func_kind,
    )
    if decl.func_kind == "check":
        macro = "define-checker"
    elif decl.func_kind == "fn":
        macro = "define/pow"
    elif decl.func_kind == "handler":
        macro = "define-handler"
    # ...
    return [
        f"({macro}",
        f"  ({decl.name} {emit_args(decl.args)})",
        f"  #:returns {emit_return_spec(decl.return_spec)}",
        f"  {compiled_body})",
    ]
```
