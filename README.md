# Tesl — proof-carrying web APIs, for humans and AI agents

**Tesl is a beta-stage language for building web APIs, built for the AI era.** A `check` function
makes a validated value *carry its proof*, so once data is checked at the boundary the compiler
structurally prevents whole classes of forgotten-validation and defensive-boilerplate bugs
downstream. Auth, effects, typed SQL, queues, real-time pub/sub, and AI-agent tools are part of the
language, not bolted on.

> **Status: beta.** The guarantees below are real and compiler-enforced 
> guarantees with no runtime re-check ([runtime cost](manual/tour.md#runtime-cost)), and the trust
> boundary is drawn precisely in [`LANGUAGE-SPEC.md` §7](LANGUAGE-SPEC.md). Breaking changes are
> expected. Read this as the design intent and what is enforced today — not as a promise.

## The 60-second version

A `fact` is a named claim about a value. A `check` is the only way to introduce one. Ask for a proof
you have not earned, and the compiler stops you:

```tesl
fact ValidTitle (title: String)

check checkTitle(title: String) -> title: String ::: ValidTitle title =
  if String.length title > 0 then
    ok title ::: ValidTitle title
  else
    fail 400 "title must not be empty"

fn saveTitle(title: String ::: ValidTitle title) -> String =
  title

fn createTodo(rawTitle: String) -> String =
  saveTitle rawTitle          # rawTitle was never checked
```

```text
$ tesl check todo.tesl
error[V001]: call to `saveTitle` argument `title` does not statically satisfy declared proof `ValidTitle rawTitle`
Hint: validate `rawTitle` with a check function that establishes `ValidTitle rawTitle`
  --> todo.tesl:18:3

  read more: tesl help manual best-practices#proof-management  (explain: tesl help V001)
```

That error is the language selling itself. **Every diagnostic carries a stable code**, a precise
span, a manual deep-link, and often a machine-applicable fix — `tesl explain V001` tells you the
whole story and `tesl help codes` lists every code the compiler can emit. It is also why Tesl suits
an AI coding agent: the compiler, not a human reviewer, is the thing that says no.

## Quick start

From nothing to a running, type-checked web API:

```bash
# 1. Install Nix with flakes enabled — https://nixos.org/download  (skip if you have it)
# 2. Install Tesl
nix profile install github:mtonnberg/tesl

# 3. Scaffold a project and run it
tesl init myapi            # a couple of quick questions; add --yes to take defaults
cd myapi
tesl run app.tesl          # starts the project database if needed, serves on http://localhost:8086
```

`tesl init` writes a working, commented app (`app.tesl`), a manifest (`tesl.toml`), a `.env`, and an
`AGENTS.md`/`CLAUDE.md` for coding agents. With the default **managed** database, `tesl run`
auto-starts a project-local PostgreSQL and loads `.env`, so the API is live with no extra setup.

Ship it as a Docker image with `tesl build --with-postgres` (all-in-one) or `tesl build --app-only`
(bring your own database) — see [`manual/deploy.md`](manual/deploy.md).

**Honest caveat: Nix is a hard gate.** Nix is the only supported install path today. If you do not
have Nix and do not want it, this is where the trail ends for now — a standalone binary is on the
roadmap, not done. See [`INSTALL.md`](INSTALL.md).

## Where to go next — pick one

| You are… | Start here |
|---|---|
| **new to Tesl** | [`manual/GETTING-STARTED.md`](manual/GETTING-STARTED.md) — `tesl init` to your first proof error, step by step |
| **done with that, want to build** | [`manual/first-change.md`](manual/first-change.md) — add a real feature to the scaffold, hit a proof error on purpose, understand why the compiler is right |
| **an AI coding agent**, or pointing one at Tesl | [`AGENTS.md`](AGENTS.md) — the compile-check loop, targeted JSON queries, headless debugging |
| **convincing yourself** | [`example/intro/`](example/intro/) — a short prose introduction, then [`manual/overview.md`](manual/overview.md) |
| **reading the whole language** | [`manual/tour.md`](manual/tour.md) — the long read: auth, capabilities, typed SQL, queues, SSE, agents, `ForAll` proofs, tests |
| **looking something up** | [`LANGUAGE-SPEC.md`](LANGUAGE-SPEC.md) (source of truth), [`manual/best-practices.md`](manual/best-practices.md), [`manual/FAQ.md`](manual/FAQ.md) |
| **stuck** | `tesl explain <CODE>`, then [`manual/FAQ.md`](manual/FAQ.md) |
| **changing the compiler** | [`CONTRIBUTING.md`](CONTRIBUTING.md) — environment, the gate, the roadmap, the workflow; then [`dev-docs/README.md`](dev-docs/README.md) for the guides |

Everything above is also in the binary, with no checkout: `tesl help manual` for the index,
`tesl help manual <section>` for one page, `tesl help search <query>` to grep it all, and
`tesl help full` to dump the entire corpus into a large-context LLM.

## Editor and Language Server

The `tesl` install includes `tesl-lsp`, and the VSCodium/VS Code extension is on
[Open VSX](https://open-vsx.org) — search for **Tesl**. You get live diagnostics (with quick-fixes),
hover types, go-to-definition, completions, and occurrence highlighting, all straight from the
compiler. `editor/protocol.md` documents the compiler–editor JSON contract the LSP is built on.

## What Tesl is trying to achieve

Most API bugs are not "business logic is hard" bugs. They come from validation being forgotten, auth
being implicit, effects being hidden, and domain guarantees evaporating a few calls after the
boundary. So: validate once and carry the result as evidence; put auth requirements in signatures
instead of middleware folklore; make capabilities and effects explicit; make queues, pub/sub, typed
SQL, and agent tools part of the language story; and let refactoring preserve guarantees instead of
silently eroding them.

Tesl is deliberately opinionated, and deliberately **not**: a language with many equally valid
styles; a framework where auth, validation, and effects are runtime wiring; a general-purpose
language before it is excellent at the web-API problem; or a place where unsafe escape hatches are
the normal way to get things done. The goal is that a normal programmer asking *"what should I use
for my next web API?"* can answer *"Tesl"* — because the language makes the correct path the obvious
path.

## Beta status, plainly

The language is in active development, breaking changes are expected, and backward compatibility is
not a goal yet. The implementation is real and useful for exploration and non-critical apps, but it
is not finished: some guarantees are enforced statically, and some runtime integrity checks still
live in trusted internals. Feedback and ideas are most appreciated.
