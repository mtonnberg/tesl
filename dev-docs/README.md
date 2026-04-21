# Tesl Language Developer Documentation

This folder contains guides for developers who want to **contribute to Tesl
itself** — the compiler, runtime, DSL macros, and standard library.

If you want to learn how to *write* Tesl applications, start with
`example/learn/lesson00-hello-world.tesl` instead.

---

## Guides

| File | What it covers |
|---|---|
| `01-overview.md` | Repository layout, compilation pipeline, running tests |
| `02-parser.md` | How `.tesl` text becomes dict-like frontend model objects across the extracted parser stages |
| `03-module-system.md` | Import graph, SCC detection, module metadata |
| `04-body-compiler.md` | BodyCompiler, expression compilation, `raw_default` |
| `05-adding-stdlib-function.md` | Step-by-step: add a new standard library function |
| `06-gdp-runtime.md` | `named-value`, `detached-proof`, how proofs attach and travel |
| `07-sql-layer.md` | Entity macros, parameterized queries, newtype coercion |
| `08-queue-pubsub.md` | Queue runtime, LISTEN/NOTIFY, outbox pattern |
| `09-adding-tests.md` | Test patterns, infrastructure, regression test conventions |
| `10-common-patterns.md` | Gotchas, quick reference table, diagnostic commands |
| `11-frontend-ir.md` | Generator-facing frontend IR stage and `emit_ir` architecture |

---

## Quick start for a new contributor

1. Read `01-overview.md` to understand the big picture.
2. Run the test suite to confirm your environment works:
   ```bash
   tesl test example/learn/lesson05-intro-to-proofs.tesl
   ```
3. Pick a task from `roadmap/now/` and read the relevant guide.

For adding a standard library function: `05-adding-stdlib-function.md`.
For fixing a compiler bug: `02-parser.md` + `04-body-compiler.md`.
For fixing a runtime/proof bug: `06-gdp-runtime.md`.
For fixing a SQL/database bug: `07-sql-layer.md`.

---

## Key files

| File | Role |
|---|---|
| `compiler/` | OCaml compiler (built with `dune build` inside the `compiler/` directory; generates the `tesl` binary) |
| `compiler/bin/main.ml` | CLI entry point — `tesl` commands: compile, `--check`, `--check-json`, `--fmt`, `--lint`, and all editor JSON flags |
| `compiler/lib/parser.ml` + `compiler/lib/lexer.mll` | Parser and lexer: `.tesl` text → AST |
| `compiler/lib/ast.ml` | AST type definitions shared across compiler stages |
| `compiler/lib/type_system.ml` | Structural HM type checker |
| `compiler/lib/proof_checker.ml` | GDP proof ownership and shape checker |
| `compiler/lib/linter.ml` | Opinionated linter |
| `compiler/lib/formatter.ml` | Source formatter (`--fmt`) |
| `compiler/lib/emit_racket.ml` | Racket code emitter (`.tesl` → `.rkt`) |
| `compiler/lib/ir.ml` | Frontend IR type definitions |
| `compiler/lib/emit_elm.ml` | `tesl generate elm` — experimental Elm type/decoder generator |
| `compiler/lib/emit_ts.ml` | `tesl generate ts` — experimental TypeScript/Zod generator |
| `dsl/private/evidence.rkt` | Core proof structs |
| `dsl/private/check-runtime.rkt` | Proof evaluation, `define-checker`, `define/pow` |
| `dsl/sql.rkt` | SQL layer, entity macros, parameterized queries |
| `dsl/types.rkt` | Newtypes, ADTs, records, JSON codecs |
| `dsl/web.rkt` | HTTP handlers, `define-handler`, `serve` |
| `tesl/queue.rkt` | Queue and pub/sub runtime |
| `tests/private/postgres-test-support.rkt` | Shared-cluster PostgreSQL test harness and per-test database isolation |
| `tests/tesl-test.rkt` | Main test suite (657+ Racket tests) |
