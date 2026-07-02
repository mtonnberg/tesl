# 11 — Frontend IR and `--ir`

> Audience: contributors working on the frontend IR in the compiler (`compiler/lib/ir.ml`, `compiler/bin/main.ml`).

The current frontend-facing IR lives in the OCaml compiler, not in Python staging modules. The implementation is `compiler/lib/ir.ml`, and the CLI surface is `tesl --ir` in `compiler/bin/main.ml`.
## What `--ir` is today
`tesl --ir file.tesl`:
1. reads the source file
2. parses it with `Parser.parse_module`
3. serializes the parsed `Ast.module_form` with `Ir.module_to_json`
It is a JSON inspection/export surface for records, ADTs, newtypes, entities, facts, codecs, and API endpoints.
## Important current boundary
The IR is not a separate normalized frontend pipeline stage right now.
- `--ir` uses `compiler/lib/ir.ml`
- generated TypeScript currently comes from `compiler/lib/emit_ts.ml`
- generated Elm currently comes from `compiler/lib/emit_elm.ml`
The TS and Elm generators consume `Ast.module_form` directly. They do not currently compile from `Ir.module_to_json` output.
So this IR is useful as:
- a stable-ish inspection/debugging format
- a contract for tooling and tests
- a place to keep frontend-relevant structural information explicit
But it is not yet the sole internal source of truth for code generation.
## Main implementation points
`compiler/lib/ir.ml` is organized around a few key responsibilities:
- `type_expr_to_text` and `proof_expr_to_text` for readable textual summaries
- `proof_tree_json` for structured proof trees
- `binding_json` / `record_field_json` / `entity_field_json` for binding and field serialization
- `response_json` and `semantic_return_json` for route return shapes
- `fact_json_of_func` for turning `check` / `auth` / `establish` declarations into fact metadata
- `endpoint_json` for API endpoint serialization
- `module_to_json` for assembling the full module payload
## What the IR contains
The current module JSON includes:
- module/source metadata
- records
- ADTs
- newtypes
- entities
- facts and fact logic
- codecs
- endpoints
For endpoint bindings, the IR now preserves:
- `fact` — first fact for convenience/backward compatibility
- `facts` — the full flattened fact list
- `proof_tree` — the structured proof tree, including composite proofs such as `ProofA && ProofB`
That applies to endpoint `auth`, `capture`, `body`, and attached-return bindings as well as ordinary record fields.
## Facts and simple constraints
`fact_json_of_func` derives frontend-relevant fact metadata from function declarations:
- `check` functions may produce `logic.kind = "simple"` plus extracted constraints
- `auth` functions produce `logic.kind = "auth"`
- `establish` and non-simple facts produce `logic.kind = "server_only"`
Constraint extraction is intentionally narrow. The IR currently knows about a small set of simple comparisons and string predicates that downstream generators can map to Zod/Elm helpers.
## What `--ir` does not guarantee
`tesl --ir` is parse-driven. It is not the same thing as `tesl --check`.
That means:
- it can describe parsed structure even when later semantic stages would reject the program
- it does not run the full type/proof/validation pipeline before printing JSON
For semantic correctness, use `tesl --check` or the relevant compiler tests alongside `--ir`.
## Current users of the IR
Today the most important consumers are:
- regression tests in `compiler/test/test_ir.ml`
- antagonistic/review suites such as `compiler/test/test_review40_antagonistic.ml`
- humans debugging frontend-facing structural output
The TS and Elm generators still mirror some IR logic separately instead of reading this JSON back in.
## When to edit `ir.ml`
Change `ir.ml` when you need frontend/tooling-visible structure to be explicit, especially for:
- proof/fact extraction
- route body/response shape
- codec metadata
- entity/record field metadata
- endpoint binding metadata
If a bug is “the compiler knows this, but frontend/tooling output erased it,” `ir.ml` is usually the right place.
## Validation
Use:
- `compiler/test/test_ir.ml` for focused IR coverage
- antagonistic suites for previously broken behaviors
- targeted generator tests if the same conceptual shape must also remain aligned in TS/Elm output
