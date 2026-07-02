# 06 — GDP Runtime and Trusted Boundary

> Audience: contributors working on the GDP proof runtime and trusted boundary (`compiler/lib/proof_checker.ml`, `dsl/private/`).

This document describes the current trusted boundary in Tesl. The Python-era compiler references are obsolete; the active compiler is the OCaml implementation under `compiler/lib/`, and it lowers Tesl programs into the Racket runtime.
## The current pipeline
At a high level, Tesl now flows through these stages:
1. lexing in `compiler/lib/lexer.mll`
2. parsing in `compiler/lib/parser.ml`
3. structural/type checking in `compiler/lib/checker.ml` and `compiler/lib/type_system.ml`
4. proof-shape checking in `compiler/lib/proof_checker.ml`
5. post-check semantic validation in `compiler/lib/validation.ml`
6. Racket lowering in `compiler/lib/emit_racket.ml`
`compiler/lib/compile.ml` orchestrates those stages and converts their errors into the CLI/editor diagnostic surface.
## What is trusted on the compiler side
### Parser and AST
- `compiler/lib/lexer.mll`
- `compiler/lib/token.ml`
- `compiler/lib/parser.ml`
- `compiler/lib/ast.ml`
These are trusted to turn source text into the intended AST without silently reinterpreting the program.
### Type checker
- `compiler/lib/type_system.ml`
- `compiler/lib/checker.ml`
These are trusted to reject malformed types, out-of-scope names, bad imports, wrong-arity/wrong-shape calls, and other structural typing mistakes.
### Proof checker
- `compiler/lib/proof_checker.ml`
This layer is trusted to enforce proof ownership/subject rules and to reject proof shapes that should not be expressible in ordinary code.
### Validation layer
- `compiler/lib/validation.ml`
This layer runs after parsing/type/proof checking and is trusted to enforce cross-cutting semantic rules that are not just local typing problems, including:
- server binding completeness
- codec proof coverage
- call-site proof satisfaction
- `ForAll` propagation checks
- `Exists` return/body validation
### Emitter
- `compiler/lib/emit_racket.ml`
This is trusted to lower the checked AST into the sanctioned Racket runtime forms. A bug here can turn a sound front-end judgment into unsound runtime behavior, so emitter changes deserve the same level of scrutiny as checker changes.
## What is trusted on the runtime side
The emitted Racket code runs on top of the GDP/runtime substrate in the Racket tree, especially:
- `dsl/private/evidence.rkt`
- `dsl/private/check-runtime.rkt`
- `dsl/web.rkt`
- `dsl/types.rkt`
- `dsl/sql.rkt`
- the public stdlib/runtime modules under `tesl/*.rkt`
These files are trusted to preserve the meaning of proofs, handlers, codecs, entities, queues, and runtime checks after lowering.
## Where `compile.ml` fits
`compiler/lib/compile.ml` is not a separate semantic stage; it is the orchestration layer.
Its important responsibilities are:
- run `Parser.parse_module`
- run `Checker.check_module_with_metadata`
- run `Proof_checker.check_module`
- run `Validation.check_module`
- emit Racket through `Emit_racket.compile_to_string`
- normalize all those failures into CLI/editor diagnostics
If behavior changes in the compiler pipeline, `compile.ml` is usually where the stage wiring or user-visible error surface must stay aligned.
## Practical trust-boundary guidance
When changing any of the trusted layers above:
- add a focused regression near the changed module
- add at least one antagonistic test if the bug could produce unsound proofs or silently wrong runtime behavior
- validate both compile-time rejection and runtime behavior when the change crosses the checker/emitter/runtime boundary
For proof-sensitive changes, do not stop at “the code compiles.” Make sure the intended impossible program is still impossible, and that the intended valid program still lowers to the right runtime form.
## Good validation targets
Depending on the change, start with:
- `compiler/test/test_proofs.ml`
- `compiler/test/test_validation.ml`
- `compiler/test/test_types.ml`
- `compiler/test/test_integration.ml`
- `compiler/test/test_review*_antagonistic.ml`
Then run broader compiler or runtime suites as needed.
