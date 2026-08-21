# Tesl Language Developer Documentation

> Audience: contributors to Tesl itself — the compiler, runtime, DSL macros, and standard library. The two former user-facing guides here (`deploy.md`, `tesl-manifest.md`) have moved onto the user/manual path; only redirect stubs remain in this folder.

This folder contains guides for developers who want to **contribute to Tesl
itself** — the compiler, runtime, DSL macros, and standard library.

If you want to learn how to *write* Tesl applications, start with
[`manual/GETTING-STARTED.md`](../manual/GETTING-STARTED.md) instead.

[`CONTRIBUTING.md`](../CONTRIBUTING.md) at the repo root is the short router into this folder — the
same content as the quick start below, in the file the forge shows on issues and pull requests. This
page is the authoritative version; that one only points here.

---

## Quick start for a new contributor

Do these in order. Steps 1–4 are the environment; step 5 is the only command that
tells you whether the tree is green.

### 1. Enter the nix dev shell — the supported environment

```bash
git clone https://github.com/mtonnberg/tesl && cd tesl
nix develop            # or: direnv allow  (the repo ships a .envrc containing `use nix`)
```

The dev shell is the *only* supported environment. It pins Go, OCaml + dune and
PostgreSQL, exposes the Go Tesl tools, and starts a local PostgreSQL cluster (step 4).
Building outside it eventually fails in a way
that looks like a code bug and is not one.

### 2. Build the compiler

```bash
cd compiler && dune build
```

That produces **`compiler/_build/default/bin/main.exe`** — the compiler binary
every script, test, and editor integration in this repo expects.

`dune build` also *promotes* generated files, notably
`compiler/lib/embedded_docs.ml` (~2 MB, bakes `manual/` and `example/` into the
binary). Never hand-edit a promoted file: edit the source it is generated from and
let dune re-promote it.

### 3. `TESL_REPO_ROOT` must point at *this* checkout

The compiler, Go runtime sources, templates, and stdlib resolve through `TESL_REPO_ROOT`.
If it is unset or wrong, **the stdlib will not resolve** and you get import failures
that look like missing-module bugs.

```bash
echo "$TESL_REPO_ROOT"        # must be the checkout you are working in
```

The dev shell exports it, and direnv exports it on `cd`. **That is a trap in a git
worktree:** direnv's export keeps pointing at the *main* repository, so the
worktree silently builds and tests against the main tree — snapshot tests then
compare against the wrong sources and fail (or, worse, pass) for reasons that have
nothing to do with your change. In a worktree, set it explicitly:

```bash
export TESL_REPO_ROOT="$PWD"                                      # inside the worktree
export TESL_OCAML_COMPILER="$PWD/compiler/_build/default/bin/main.exe"
```

### 4. PostgreSQL

Several suites need a live PostgreSQL. The dev shell's `shellHook` runs
[`scripts/postgres-start.sh`](../scripts/postgres-start.sh) for you: a
project-local cluster under `.tesl-postgres/` on **127.0.0.1:55432**, user `tesl`,
with the `todo-api`, `admin-task-api` and `chat` databases created. To drive it by
hand:

```bash
bash scripts/postgres-init.sh     # initdb (idempotent)
bash scripts/postgres-start.sh    # start  (idempotent)
bash scripts/postgres-stop.sh     # stop
```

Suites that need PostgreSQL **self-skip** with an explicit `SKIPPED` line when it
is absent, so "green" without a database is weaker than it looks. Have it running.

### 5. `./ci.sh` at the repo root is the authoritative gate

```bash
./ci.sh                  # from the repo root, inside the dev shell
```

This is the single command that decides whether the codebase is green. It runs the
compiler, Go runtime, Go source manifests, generated snapshots, mutation, integration,
tooling, template, and Go SSO E2E gates.

Two things about it trip people up:

- **`compile-examples.sh` and `compiler/ci.sh` are thin shims** that `exec` into
  `./ci.sh`. They exist only so older hooks and muscle memory keep working. One
  gate, three names; `./ci.sh` is the real one.
- **`dune test` alone is NOT sufficient.** It misses the example sweep, generated
  Go snapshots, runtime manifests, tooling, and end-to-end gates.

Run `./ci.sh` before you commit.

### 6. Never changed this compiler before?

Do [`12-your-first-compiler-change.md`](12-your-first-compiler-change.md) — one real
improvement to a diagnostic, end to end, including the three tests it breaks on the
way and why each failure is the right one. It is the fastest way to meet this
repo's single-source machinery in a context where breaking it is harmless.

### 7. Pick something to work on

Read [`01-overview.md`](01-overview.md) for the big picture, then take a task from
`roadmap/next/` (the active queue) or `roadmap/later/` (the backlog) and read the
guide it points at.

---

## First-hour gotchas

| Symptom | Cause and fix |
|---|---|
| Generated Go output is stale | Remove `.tesl-stuff/go-build/` or run `tesl clean`, then rebuild. |
| Snapshot tests fail on files you never touched | `TESL_REPO_ROOT` points at another checkout — see step 3. Especially likely in a git worktree. |
| `embedded_docs.ml is stale` (`ci.sh` phase 4) | You changed something under `manual/` or `example/`. Run `cd compiler && dune build` to re-promote it and commit the regenerated file alongside your change. |
| Stdlib imports fail at runtime | `TESL_REPO_ROOT` unset, or the compiler was never built (step 2). |
| A phase reports `SKIPPED` | An optional dependency is missing (PostgreSQL, Python, MailHog, Nix, or browser tooling). Never a hard failure — but also not coverage. |

---

## Workflow

**Trunk-based.** Commits go straight to `main`. There is no `CODEOWNERS` file, no
review requirement and no branch protection to satisfy — `./ci.sh` is the review.
Use a branch only when you actually want one (a long-lived experiment, or work you
intend to hand off).

**The roadmap is the queue.** `roadmap/next/` is what is actively being worked on,
`roadmap/later/` the backlog, and `roadmap/discarded/` holds decisions that were
considered and rejected — read those before re-proposing something, they record
*why not*. When an item is done, **move its file from `roadmap/next/` to
`roadmap/completed/`** in the same commit as the work, rewritten to describe what
was actually built rather than what was planned. `roadmap/completed/` is the
project's decision log.

**Docs are single-sourced and partly contracted.** `manual/anchors.md` lists
anchors that compiler diagnostics cite as `<section>#<anchor>`, and
`compiler/test/test_error_codes.ml` fails the build if one stops resolving — so
never rename or move an anchor-backed heading without migrating the anchor.
`manual/tests/` is a standalone dune project (`cd manual/tests && dune runtest`)
that checks manual coherence without building the compiler.

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
| `12-your-first-compiler-change.md` | **Start here if you are new.** One real diagnostic improvement (`W020`), end to end: the edit, the tests it breaks, the byte-exact diff, the regression test, the finished change |
| `zero-cost-proofs-contract.md` | Proof erasure as the only mode — the as-built compile-time proof/declared-context contract |
| `deploy.md` | *(moved → [`manual/deploy.md`](../manual/deploy.md))* Deploying a Tesl web API — `tesl build`, the generated Docker image, database flavours. This file is now a redirect stub. |
| `tesl-manifest.md` | *(moved → [`manual/tesl-manifest.md`](../manual/tesl-manifest.md))* `tesl.toml` project manifest schema read by `tesl build` / `tesl db`. This file is now a redirect stub. |

Every guide here is also in the binary, with no checkout:
`tesl help manual dev` opens this index and `tesl help manual dev-docs/<file>` opens one guide —
e.g. `tesl help manual dev-docs/12-your-first-compiler-change`.

Where to start, by task:

- first change of any kind → `12-your-first-compiler-change.md`
- add a standard library function → `05-adding-stdlib-function.md`
- fix a compiler bug → `02-parser.md` + `04-body-compiler.md`
- fix a runtime/proof bug → `06-gdp-runtime.md`
- fix a SQL/database bug → `07-sql-layer.md`

---

## Key files

| File | Role |
|---|---|
| `ci.sh` | **The authoritative gate.** `compile-examples.sh` and `compiler/ci.sh` `exec` into it |
| `compiler/` | OCaml compiler — `dune build` here produces `compiler/_build/default/bin/main.exe` |
| `compiler/bin/main.ml` | CLI entry point — `tesl` commands: compile, `--check`, `--check-json`, `--fmt`, `--lint`, and all editor JSON flags |
| `compiler/lib/parser.ml` + `compiler/lib/lexer.mll` | Parser and lexer: `.tesl` text → AST |
| `compiler/lib/ast.ml` | AST type definitions shared across compiler stages |
| `compiler/lib/type_system.ml` | Structural HM type checker |
| `compiler/lib/proof_checker.ml` | GDP proof ownership and shape checker |
| `compiler/lib/error_codes.ml` | The diagnostic code catalog — code, title, explanation, manual anchor |
| `compiler/lib/diag_fix.ml` | Machine-applicable diagnostic fixes (LSP quickfix, `agent-context`) |
| `compiler/lib/linter.ml` | Opinionated linter |
| `compiler/lib/formatter.ml` | Source formatter (`--fmt`) |
| `compiler/lib/emit_go.ml` | Go code emitter (`.tesl` → Go module) |
| `compiler/lib/ir.ml` | Frontend IR type definitions |
| `compiler/lib/emit_elm.ml` | `tesl generate elm` — experimental Elm type/decoder generator |
| `compiler/lib/emit_ts.ml` | `tesl generate ts` — experimental TypeScript/Zod generator |
| `compiler/gen/gen_docs.ml` | Generates `compiler/lib/embedded_docs.ml`, promoted on every `dune build` |
| `runtime/go/teslrt/check.go` | Runtime proof/check result handling |
| `runtime/go/teslrt/database.go` | Database and entity runtime |
| `runtime/go/teslrt/json.go` | JSON codecs and value conversion |
| `runtime/go/teslrt/server.go` | HTTP routing and handlers |
| `runtime/go/teslrt/queue.go` | Queue and pub/sub runtime |
| `nix/tesl-cli-body.sh` | The installed `tesl` CLI wrapper (verb dispatch); the flake builds `tesl` from it |
| `scripts/run-go-test-manifest.sh` | Authoritative Go execution of every tracked `tests/*.tesl` source |
| `runtime/go/teslrt/*_test.go` | Go runtime and integration coverage |
