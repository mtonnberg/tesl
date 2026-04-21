# Learning Material for Language Developers

> **Implemented** — `dev-docs/` folder with 10 comprehensive guides.

## What was built

A `dev-docs/` folder at the repo root containing:

| File | Covers |
|---|---|
| `README.md` | Index, quick start, key files |
| `01-overview.md` | Repo layout, compilation pipeline, running tests |
| `02-parser.md` | `parse_module`, block collection, form parsers, GDP grammar, split utilities |
| `03-module-system.md` | Module metadata dict, special modules, import graph, SCC/Tarjan's algorithm, proof predicate ownership |
| `04-body-compiler.md` | `BodyCompiler`, `compile_expr`, `raw_default`, partial application, case exhaustiveness, `ReferenceCollector` |
| `05-adding-stdlib-function.md` | Step-by-step walkthrough with checklist |
| `06-gdp-runtime.md` | `named-value`, `check-ok`, `detached-proof`, how proofs attach/travel, `define-checker`, `proof-fact-matches?` |
| `07-sql-layer.md` | `define-entity`, `field-spec`, parameterized queries, `FromDb` proofs, auto-migration |
| `08-queue-pubsub.md` | Three-thread worker model, `start-workers!`, outbox pattern, duplicate-delivery prevention |
| `09-adding-tests.md` | `compile-thsl-source`, `thsl-module-value`, test patterns (compile/call, error, HTTP dispatch, PostgreSQL) |
| `10-common-patterns.md` | Gotchas reference, `raw-value` vs newtypes, type-ref vs plain symbols, quick reference table |

## Key design decisions for the docs

- **Code-first**: every claim is backed by real code from the repo.
- **Accurate**: docs were written by reading the actual source files, not from memory.
- **Gotchas section**: the most common mistakes (multi-line ADTs, inline if, proof-returning stdlib, type-ref keys) are documented in both `02-parser.md` and `10-common-patterns.md`.
- **Quick reference table** in `10-common-patterns.md` maps every Tesl form to its generated Racket macro.
