# 02 — The Tesl Parser
Tesl currently uses a hand-written recursive descent parser in OCaml. The parser no longer lives in a split Python frontend; the active implementation is the compiler in `compiler/lib/`.
## Current parser files
- `compiler/lib/lexer.mll` — turns source text into a token stream, including `INDENT` / `DEDENT` / `NEWLINE`
- `compiler/lib/token.ml` — token definitions
- `compiler/lib/parser.ml` — recursive descent parser over the token stream
- `compiler/lib/ast.ml` — typed AST produced by the parser
## End-to-end flow
The parsing entry point is `Parser.parse_module` in `compiler/lib/parser.ml`.
1. `Lexer.tokenize filename source` produces positioned tokens.
2. `Parser.make_stream` wraps them in a mutable stream.
3. `parse_module` consumes:
   - the optional `#lang tesl` header
   - the module header (`module ... exposing [...]`)
   - imports
   - top-level declarations
4. `extract_doctest_decls` appends doctest-derived `DTest` declarations after ordinary top-level parsing.
The result is an `Ast.module_form`, not a dict-like intermediate model.
## Token stream model
`parser.ml` operates on a simple token stream:
- `peek` / `peek2` inspect upcoming tokens
- `advance` / `consume` move forward
- `current_loc` and `tok_loc` attach source locations to errors and AST nodes
Public parser functions return `Ok value` or `Err parse_error`; callers convert those into diagnostics instead of relying on exceptions for ordinary parse failures.
## Module and declaration parsing
The top-level control flow is:
- `parse_module`
- `parse_module_header_body`
- `parse_imports`
- `parse_top_decls`
- `parse_top_decl`
`parse_top_decl` dispatches directly on the current token and builds `Ast.top_decl` values such as `DFunc`, `DRecord`, `DType`, `DApi`, `DCodec`, `DTest`, and so on.
There is no separate frontend-module parser anymore; all top-level Tesl syntax is parsed in this one OCaml module.
## Expressions, types, and layout-sensitive forms
`parser.ml` contains dedicated helpers for each major syntactic family:
- expressions (`parse_expr`, statement/test helpers, SQL/query lowering helpers)
- type expressions (`parse_type_expr`, `parse_type_app`, return-spec parsing)
- bindings and proof annotations
- records, ADTs, entities, codecs, APIs, servers, tests, queues, workers
The lexer emits indentation tokens, so the parser can handle indentation-sensitive constructs like function bodies, `if`, `case`, and test blocks without a second preprocessing pass.
## A parser detail worth keeping in mind
Route bodies have an endpoint-specific binding parser now. `parse_api_body_binding` intentionally stops before the route return arrow so syntax like:
`post "/todos" body todo: NewTodo -> Todo`
is parsed as body type `NewTodo` plus route response `Todo`, rather than incorrectly parsing the body as `NewTodo -> Todo`.
If you change API parsing, keep route arrows, `via`, and proof annotations in mind together.
## Where parsing stops
The parser is responsible for syntax and AST construction only. It does not do:
- type checking
- proof checking
- semantic validation
- Racket emission
Those stages happen later in:
- `compiler/lib/checker.ml`
- `compiler/lib/proof_checker.ml`
- `compiler/lib/validation.ml`
- `compiler/lib/emit_racket.ml`
## Practical workflow when changing syntax
1. Update tokens in `lexer.mll` / `token.ml` if needed.
2. Extend `ast.ml` when the syntax needs a new AST shape.
3. Change `parser.ml` to build that shape.
4. Update downstream consumers (`checker.ml`, `proof_checker.ml`, `validation.ml`, `emit_racket.ml`, `ir.ml`, generators) if the AST contract changed.
5. Add antagonistic tests that try to break the exact parsing boundary you changed.
## Validation
Start with focused compiler tests:
- `compiler/test/test_frontend.ml`
- `compiler/test/test_diagnostics.ml`
- `compiler/test/test_ir.ml`
- any review/antagonistic suite that covers the affected syntax
Then run broader compiler validation if the change touches shared syntax paths.
