# Parameterized ADTs

## Status: **Implemented**

Parameterized ADTs are now a first-class feature of Tesl. Users can declare generic container types with any number of type parameters.

## What was implemented

### Parser
- `parse_type_form` reads lowercase identifier tokens between the type name and `=` as type parameters
- `parse_adt_variants` and `parse_adt_more_variants` accept and thread the `params` list
- All three `TypeAdt` construction sites pass `params` correctly

### Type checker (`checker.ml`)
- `build_adt_def` uses the `params` list to create rigid type variables (negative IDs `-1`, `-2`, …)
- Constructors get polymorphic type schemes `{ vars = rigid_ids; mono = ctor_mono }`
- `ty_of_type_expr_with_params` substitutes named type var references
- `collect_type_defs` registers parameterized ADT definitions correctly

### Emitter (`emit_racket.ml`)
- `TypeAdt` with `params = []` emits `(define-adt Name ...)` (unchanged)
- `TypeAdt` with `params` emits `(define-adt (Name a b) ...)` — the Racket `define-adt` macro already supports this syntax

### Racket runtime (`dsl/types.rkt`)
- The `define-adt` macro already handles `(define-adt (Name param ...) ...)` syntax
- `runtime-type-satisfied?` already supports ADT type arguments with `adt-spec-parameters` and `param-env` substitution
- `adt-application-spec`, `adt-type-arguments`, `instantiate-adt-field-template` already in place

## Documentation
- `LANGUAGE-SPEC.md` § 11.6 updated with parameterized ADT grammar, examples, and explanation
- `example/learn/lesson37-parameterized-adts.tesl` — comprehensive learn lesson covering Box, Option, Either, Pair, Tree

## Tests
- `compiler/test/test_parser.ml`: `test_parameterized_adt`, `test_single_param_adt`, `test_non_parameterized_adt_no_params`
- `compiler/test/test_emit.ml`: `test_parameterized_adt_emission`, `test_single_param_adt_emission`

## Surface syntax

```tesl
type Either a b
  = Left  value:a
  | Right value:b

type Box a
  = Box value:a

type Tree a
  = Leaf
  | Node left:(Tree Int) value:Int right:(Tree Int)
```

## Notes
- There is no limit on the number of type parameters
- Type inference handles parameterized ADTs fully — no explicit type arguments needed
- Recursive parameterized ADTs are supported (e.g. `Tree`)
- Parameters in field types are written as the lowercase identifier: `value:a`
- For recursive fields, use the full applied type: `left:(Tree Int)`
