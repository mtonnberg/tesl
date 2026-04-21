# Tesl

**Tesl is an alpha-stage language project that is trying to make web APIs feel closer to a solved problem.**

The bet behind Tesl is that most API bugs are not fundamentally “business logic is hard” bugs. They come from validation being forgotten, auth being implicit, effects being hidden, and domain guarantees evaporating a few function calls after the boundary.

Tesl is trying to push those concerns into the language itself:

- validate once at the boundary, then carry the result as evidence
- make auth requirements visible in signatures instead of middleware folklore
- make capabilities and side effects explicit
- make common API infrastructure part of the language story instead of an afterthought

The goal is not to produce a clever research toy. The goal is to get to a point where a normal programmer asking _“what should I use for my next web API?”_ can answer _“Tesl”_ because the language makes the correct path the obvious path.

## Alpha status

Tesl is **alpha**.

That means, explicitly:

- the language is in active development
- breaking changes are expected
- backward compatibility is **not** a goal yet
- the implementation is real and useful for exploration, but it is not finished
- the current way to try Tesl is to clone this repository and write `.tesl` programs directly inside this repo checkout
- Feedback and ideas are most appreciated

There is not yet a polished standalone installation flow, package template, or “create new Tesl project” experience. Right now, this repository is both the implementation and the place where you try the language.

## What Tesl is trying to achieve

Tesl is trying to become a language for building web APIs, quickly and safely - where the important guarantees are structural rather than conventional.

In practical terms, that means:

- request validation should not disappear after decoding
- auth should not be something you merely remember to wire up
- effects should be declared and checked
- typed database access, queues, pub/sub, and telemetry should fit into one coherent programming model
- refactoring should preserve guarantees instead of silently eroding them

The intended long-term shape is a language that is small, opinionated, explicit, and boringly reliable for API work that people who just want things done will choose since it is the easiest way to a working and stable product.

### Who is Tesl for?

I’m building Tesl for productive web developers—people who today use TypeScript, C#, Java, or Kotlin and want to get things done without the language getting in their way. The goal is for you to feel immediately at home and actually enjoy the workflow.

The goal is to make the theoretically "best path" the path of least resistance—transforming formal logic like GDP (Ghosts of Departed Proofs) from a cumbersome hindrance into a genuine productivity boost. I’m really keen on having type theory enthusiasts involved to help ensure these abstractions remain sound, as long as the end result stays approachable for everyone else.


## Current state

Broadly, the project is here today:

- `.tesl` is the primary authoring surface
- there is a working compiler, CLI, formatter, and linter
- the repo contains larger examples, tests, and experimental client-generation work
- the current implementation is still a hybrid system: a frontend compiler plus a Racket runtime/substrate
- some important guarantees are already enforced statically, while some runtime integrity checks still exist in internal/trusted parts of the current implementation
- the language design is still being tightened; ergonomics and tooling are still moving targets

So the project is already past the “pure sketch” stage, but it is not yet at the “stable language you can bet a company on” stage.

## Non-goals / anti-goals

Tesl is **not** trying to be:

- a language with many equally valid styles and conventions
- a framework where auth, validation, and effects are mostly runtime wiring concerns
- a backward-compatible platform during alpha
- a general-purpose language before it is excellent at the web API problem
- a language where unsafe escape hatches are the normal way to get things done
- a project that preserves old syntax forever once a better design is found

The language is intentionally opinionated. If Tesl succeeds, it should do so by being small, sharp, and reliable — not by being endlessly permissive.

## Two ways to use this repository

### If you want to work on the language itself

This path is for people changing the compiler, runtime, tests, docs, or editor tooling.

### Development shell

```bash path=null start=null
nix-shell
```

The shell includes Racket, PostgreSQL tooling, `curl`, and `jq`.

### Bootstrap `#lang tesl`

```bash path=null start=null
nix-shell --run "bash scripts/bootstrap-tesl-lang.sh"
```

This links the current checkout as a `tesl` package for the active Racket installation. You need this before plain `#lang tesl` compilation through `raco make` works.

### Testing

**Write tests in `.tesl` files.** Tesl test blocks exercise the full pipeline
(parser → type-checker → proof-checker → emitter → Racket runtime). If a `.tesl`
test passes, the feature works end-to-end.

**Compiling is not testing.** `tesl validate` confirms the program is well-formed.
`tesl test` confirms it produces the right answers. Always do both.

```bash
# Validate a file (compile + lint + format check — no execution):
tesl validate example/sandbox.tesl

# Run test blocks inside a file:
tesl test example/sandbox2.test.tesl

# Fast compiler checks (OCaml tests + verify all .tesl files compile):
bash compiler/ci.sh

# Full pipeline (validate + Tesl tests + mutation testing + Racket aggregate):
bash compile-examples.sh
```

Drop to OCaml tests
(`compiler/test/*.ml`) only for "**this should not compile**-tests"(very important), compiler internals (parser edge cases, emitter output, diagnostic formatting).
Drop to Racket tests (`tests/*.rkt`) only for runtime substrate internals
(proof structs, HTTP dispatch, PostgreSQL integration). See `dev-docs/09-adding-tests.md` for details.

### If you want to try the language today

This path is for people who want to explore Tesl as a user.

**Important:** right now, “trying Tesl” means cloning this repository and writing `.tesl` files inside it. That is the supported path today.

### 1. Enter the dev shell

```bash path=null start=null
nix-shell
```

### 2. Bootstrap the language into Racket

```bash path=null start=null
nix-shell --run "bash scripts/bootstrap-tesl-lang.sh"
```

### 3. Validate a small Tesl example

```bash path=null start=null
nix-shell --run "tesl validate example/sandbox.tesl"
```

### 4. Compile a `.tesl` program through `#lang tesl`

```bash path=null start=null
nix-shell --run "bash scripts/bootstrap-tesl-lang.sh && raco make example/todo-api.tesl"
```

```bash path=null start=null
nix-shell --run "bash scripts/bootstrap-tesl-lang.sh && raco make example/admin-task-api.tesl"
```

### 5. Look at other `.tesl` examples in the repo

Current top-level `.tesl` examples include:

- `example/admin-task-api.tesl`
- `example/queue-api.tesl`
- `example/sandbox.tesl`
- `example/sandbox2.tesl`
- `example/sandbox2.test.tesl`
- `example/sandbox3.tesl`
- `example/todo-api.tesl`

### 6. Run some example APIs

The `.tesl` frontend is the intended surface. Some of the runnable examples below are still Racket-side runtime/lowering fixtures, but they are useful for seeing the system in action.

#### Document API

```bash path=null start=null
nix-shell --run "racket example/document-api.rkt"
```

Starts on port `8085` and exposes:

- `POST /docs`
- `GET /tasks/:taskId`
- `GET /tasks/admin/:taskId`

#### Bookmark API

```bash path=null start=null
nix-shell --run "racket example/bookmark-api.rkt"
```

Starts on port `8087` and exposes:

- `POST /bookmarks`
- `GET /bookmarks/mine`
- `GET /bookmarks/:bookmarkId`

#### Todo API with PostgreSQL

Start a local PostgreSQL instance first:

```bash path=null start=null
nix-shell --run "bash scripts/postgres-start.sh"
```

Then run the API:

```bash path=null start=null
nix-shell --run "racket example/todo-api.rkt"
```

Starts on port `8086` and exposes:

- `POST /todos`
- `GET /todos/mine`
- `GET /todos/:todoId`
- `PUT /todos/:todoId/complete`

Useful local PostgreSQL commands:

```bash path=null start=null
nix-shell --run "bash scripts/postgres-init.sh"
```

```bash path=null start=null
nix-shell --run "bash scripts/postgres-start.sh"
```

```bash path=null start=null
nix-shell --run "bash scripts/postgres-stop.sh"
```

Relevant PostgreSQL environment variables for the example are:

- `TESL_POSTGRES_HOST`
- `TESL_POSTGRES_PORT`
- `TESL_POSTGRES_DATABASE`
- `TESL_POSTGRES_USER`
- `TESL_POSTGRES_PASSWORD`
- `TESL_POSTGRES_SOCKET`

### Example requests

```bash path=null start=null
curl -sS -X POST http://127.0.0.1:8085/docs \
  -H 'content-type: application/json' \
  -d '{"title":"Quarterly roadmap","body":"Ship the DSL MVP"}' | jq

curl -sS http://127.0.0.1:8087/bookmarks/mine | jq

curl -sS -X POST http://127.0.0.1:8086/todos \
  -H 'content-type: application/json' \
  -d '{"title":"Write the first Tesl program"}' | jq
```

## Editor and Language Server

The `tesl` binary has built-in editor support. The language server in `editor/tesl-lsp/` bridges the compiler and your editor over JSON-RPC (LSP). A VSCodium/VS Code extension is available in `editor/vscode-tesl/`.

The compiler exposes the following JSON flags, which the language server uses to power live diagnostics, go-to-definition, hover types, completions, and occurrence highlighting:

| Flag | Purpose |
|---|---|
| `--check-json <file>` | Full diagnostic check — parse errors, type errors, and lint warnings |
| `--definition-json <file> <line> <col>` | Jump-to-definition location |
| `--occurrences-json <file> <line> <col>` | All same-file occurrences of a symbol |
| `--type-at-json <file> <line> <col>` | Inferred type of the expression at the cursor |
| `--field-at-json <file> <line> <col>` | Record field info at the cursor |
| `--completions-json <file> <line> <col>` | Context-aware completions (field and identifier) |
| `--local-bindings-json <file>` | All inferred local binding types in the file |

All flags return versioned JSON. See `editor/protocol.md` for the full compiler–editor protocol contract and `editor/README.md` for installation instructions.

## Notes on style and imports

Tesl is intentionally explicit.

Standard `.tesl` names are explicit. Import general built-ins from `Tesl.Prelude`, import constructor families with syntax like `Maybe(..)`, import built-in capabilities such as `time` explicitly, and pull specialized helpers like `cli.args`, `lookupPortArgument`, or `generatePrefixedId` from their dedicated modules instead of the Prelude.
