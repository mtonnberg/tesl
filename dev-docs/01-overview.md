# 01 — Tesl: End-to-End Compilation Overview

> Audience: contributors to Tesl itself — the compiler (`compiler/lib/`), runtime (`dsl/`, `tesl/`), tests, and tooling.

This guide is for developers who want to understand or contribute to Tesl itself.
For learning the Tesl *language*, start with `example/learn/lesson00`.

---

## Repository layout

```
tesl/
├── compiler/                         # OCaml compiler (dune project; `dune build` generates the `tesl` binary)
│   ├── bin/main.ml                   # CLI entry point (`tesl` binary)
│   ├── lib/parser.ml                 # Parser: .tesl text → AST
│   ├── lib/lexer.mll                 # Lexer
│   ├── lib/ast.ml                    # AST type definitions
│   ├── lib/type_system.ml            # Structural HM type checker
│   ├── lib/proof_checker.ml          # GDP proof ownership and shape checker
│   ├── lib/linter.ml                 # Opinionated linter
│   ├── lib/formatter.ml              # Source formatter
│   ├── lib/emit_racket.ml            # Racket code emitter (.tesl → .rkt)
│   └── lib/ir.ml                     # Frontend IR type definitions
├── dsl/                              # Racket DSL macros (runtime)
│   ├── capability.rkt                # Capability system
│   ├── check.rkt                     # Public proof/check API
│   ├── private/
│   │   ├── evidence.rkt              # Core proof structs (named-value, etc.)
│   │   └── check-runtime.rkt         # Proof evaluation, define-checker, etc.
│   ├── sql.rkt                       # Database / entity macros + runtime
│   ├── types.rkt                     # Newtypes, ADTs, records, JSON codecs
│   └── web.rkt                       # HTTP handlers, define/pow, serve
├── tesl/                             # Standard library Racket modules
│   ├── prelude.rkt, string.rkt, list.rkt, int.rkt, ...
│   ├── time.rkt                      # PosixMillis, nowMillis, formatTime
│   ├── queue.rkt                     # Queue/pub-sub runtime
│   ├── agent.rkt                      # AI agent runtime (providers, tool loop, conversations)
│   ├── agent-provider.rkt             # Real LLM provider transports (Anthropic / OpenAI-wire)
│   ├── env.rkt                        # env / envString / requireEnv
│   └── websocket.rkt                 # RFC 6455 WebSocket server
├── tests/
│   ├── tesl-test.rkt                 # Main Racket test suite (657+ tests)
│   └── sql-test.rkt, web-test.rkt, ...
└── example/
    ├── learn/                        # User-facing lessons 00–27
    ├── todo-api.tesl / .rkt          # Reference example
    └── chat/                         # Full chat app
```

---

## The compilation pipeline

```
user writes:          foo.tesl
                          │
                          ▼
               ┌──────────────────────────────┐
               │  tesl (OCaml compiler)        │
               │                              │
               │  1. lexer + parser           │  .tesl text → AST
               │  2. module validation        │  metadata + reference checks
               │  3. type_system              │  structural HM checking
               │  4. proof_checker            │  GDP ownership and shape checks
               │  5. emit_racket              │  Racket emission
               └──────────────────────────────┘
                          │
                          ▼
               ┌─────────────────────┐
               │  foo.rkt            │  Generated Racket with #lang racket
               └─────────────────────┘
                          │
                          ▼
               ┌─────────────────────┐
               │  raco make / raco   │  Racket compiler + runtime
               │  test               │  Executes DSL macros, runs tests
               └─────────────────────┘
```

The OCaml compiler is the **frontend**. It knows about Tesl syntax and static guarantees but not execution. The Racket DSL macros are the **backend** — they define the actual runtime semantics for proofs, capabilities, HTTP dispatch, SQL queries, etc.

Today the OCaml compiler is organized into library modules under `compiler/lib/`: `parser.ml` and `lexer.mll` handle text-to-AST parsing; `type_system.ml` runs the structural HM checker; `proof_checker.ml` handles GDP ownership and shape checks; `emit_racket.ml` generates Racket output; `linter.ml` and `formatter.ml` provide the linter and formatter. `compiler/bin/main.ml` is the CLI entry point that wires these stages into the `tesl` binary.

### What the OCaml compiler does NOT do

- Parse or evaluate Racket
- Execute the generated application/runtime logic
- Produce bytecode

Static and runtime safety are split across three layers:
1. **Structural type checking** in `compiler/lib/type_system.ml` — ordinary expression typing such as record literals, dotted field access, operator operands, and existential-return packing
2. **Proof/reference/static validation** in `compiler/lib/proof_checker.ml`
3. **Runtime checks** in the Racket DSL macros (`define/pow` validates types and proofs at call time) for boundary/core enforcement that remains after frontend checking

---

## A concrete example

Given this Tesl file:

```tesl
#lang tesl
module Ports exposing [isValidPort, ValidPort]
import Tesl.Prelude exposing [Int]

check isValidPort(p: Int) -> p: Int ::: ValidPort p =
  if 1 <= p && p <= 65535 then
    ok p ::: ValidPort p
  else
    fail 400 "port out of range"
```

The compiler generates roughly:

```racket
#lang racket
(require (file "/path/to/dsl/capability.rkt")
         (file "/path/to/dsl/check.rkt")
         ...)

(provide isValidPort ValidPort)

(define-checker
  (isValidPort [p : Integer])
  #:returns [p : Integer ::: (ValidPort p)]
  (if (and (<= 1 *p 65535))
      (accept (ValidPort p))
      (reject "port out of range" #:http-code 400)))
```

The `define-checker` macro (in `dsl/private/check-runtime.rkt`) does the actual work at runtime: validating types, running the body, attaching the `ValidPort` proof to `p` on success.

---

## Running the compiler manually

```bash
# Inside the dev shell (`nix develop` or legacy `nix-shell`):
tesl example/todo-api.tesl          # compile to Racket (stdout)
tesl --check example/todo-api.tesl  # type-check only
tesl --lint  example/todo-api.tesl  # lint warnings
tesl --fmt   example/todo-api.tesl  # format in-place
```

---

## Running the test suite

```bash
nix develop --command raco test tests/all.rkt 2>&1
# legacy: nix-shell --run "raco test tests/all.rkt 2>&1"
```

The authoritative aggregate suite:
- Calls the `tesl` OCaml binary as a subprocess to compile Tesl snippets
- Loads the compiled `.rkt` files via `dynamic-require`
- Uses rackunit assertions to verify behaviour
- Includes PostgreSQL integration tests (skipped if neither a shared test cluster nor `initdb`/`pg_ctl` is available)
- Reuses one temporary PostgreSQL cluster per aggregate run while still giving each PostgreSQL-backed test an isolated database
- Routes through `tests/internal-all.rkt`, while `tests/frontend-all.rkt` remains the narrower frontend-only aggregate
- `compile-examples.sh` now seeds the same `TESL_TEST_POSTGRES_SHARED_*` environment contract before its per-file `tesl test` sweep and final aggregate run, so repeated test invocations also reuse one temporary cluster when PostgreSQL tooling is available

See `dev-docs/09-adding-tests.md` for how to add tests.

---

## Next steps

- `02-parser.md` — How `.tesl` text becomes dict-like frontend model objects
- `03-module-system.md` — Imports, SCC detection, module metadata
- `04-body-compiler.md` — How function bodies compile to Racket
- `06-gdp-runtime.md` — How proofs work at runtime
