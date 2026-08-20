# 01 — Tesl: End-to-End Compilation Overview

> Audience: contributors to Tesl itself — the compiler (`compiler/lib/`), Go runtime (`runtime/go/`), tests, and tooling.

This guide is for developers who want to understand or contribute to Tesl itself.
For learning the Tesl *language*, start with `example/learn/lesson00`.

---

## Repository layout

```
tesl/
├── compiler/                         # OCaml parser, checker, diagnostics, and Go emitter
├── runtime/go/
│   ├── cmd/                          # DAP, LSP, MCP, attach, and inspection tools
│   └── teslrt/                       # HTTP, SQL, queues, SSO, proofs, and codecs
├── tests/*.tesl                      # Authoritative Go test sources
└── example/                          # User-facing lessons and applications
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
│  5. emit_go                  │  Go module emission
               └──────────────────────────────┘
                          │
                          ▼
               ┌─────────────────────┐
│  Go module          │  Generated under .tesl-stuff/go-build/
               └─────────────────────┘
                          │
                          ▼
               ┌─────────────────────┐
│  go build / go test │  Builds and runs generated code
               └─────────────────────┘
```

The OCaml compiler owns parsing, static guarantees, and Go emission. The Go runtime defines execution semantics for proofs, capabilities, HTTP dispatch, SQL queries, queues, and SSO.

Today the OCaml compiler is organized into library modules under `compiler/lib/`: `parser.ml` and `lexer.mll` handle text-to-AST parsing; `type_system.ml` runs the structural HM checker; `proof_checker.ml` handles GDP ownership and shape checks; `emit_go.ml` generates Go output; `linter.ml` and `formatter.ml` provide the linter and formatter. `compiler/bin/main.ml` is the CLI entry point that wires these stages into the compiler binary.

### What the OCaml compiler does NOT do

- Execute the generated application/runtime logic
- Produce bytecode

Static and runtime safety are split across three layers:
1. **Structural type checking** in `compiler/lib/type_system.ml` — ordinary expression typing such as record literals, dotted field access, operator operands, and existential-return packing
2. **Proof/reference/static validation** in `compiler/lib/proof_checker.ml`
3. **Runtime checks** in the Go runtime for boundary/core enforcement that remains after frontend checking

---

## A concrete example

Given this Tesl file:

```tesl
module Ports exposing [isValidPort, ValidPort]
import Tesl.Prelude exposing [Int]

check isValidPort(p: Int) -> p: Int ::: ValidPort p =
  if 1 <= p && p <= 65535 then
    ok p ::: ValidPort p
  else
    fail 400 "port out of range"
```

The Go emitter generates roughly:

```go
func IsValidPort(p int64) teslrt.Check[int64] {
    if 1 <= p && p <= 65535 {
        return teslrt.Accept(p)
    }
    return teslrt.Reject[int64](400, "port out of range")
}
```

The Go runtime check helpers validate the boundary, run the body, and carry the `ValidPort` proof on success.

---

## Running the compiler manually

```bash
# Inside the dev shell (`nix develop`):
tesl compile example/todo-api.tesl  # emit a Go module
tesl --check example/todo-api.tesl  # type-check only
tesl --lint  example/todo-api.tesl  # lint warnings
tesl --fmt   example/todo-api.tesl  # format in-place
```

---

## Running the test suite

```bash
bash scripts/run-go-test-manifest.sh --run-all
bash scripts/run-go-example-manifest.sh --run-all
```

The authoritative test surfaces are Go source manifests plus OCaml compiler tests:
- `scripts/run-go-test-manifest.sh --run-all` executes every tracked `tests/*.tesl` source in disposable Go modules.
- `scripts/run-go-example-manifest.sh --run-all` executes every tracked example through Go.
- `runtime/go/**/*_test.go` covers runtime, protocol, DAP, LSP, MCP, security, and integration behavior.
- `compiler/test` covers parser, checker, proof, diagnostics, and emission invariants.

See `dev-docs/09-adding-tests.md` for how to add tests.

---

## Next steps

- `02-parser.md` — How `.tesl` text becomes dict-like frontend model objects
- `03-module-system.md` — Imports, SCC detection, module metadata
- `04-body-compiler.md` — How function bodies compile to Go
- `06-gdp-runtime.md` — How proofs work at runtime
