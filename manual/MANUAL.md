# Tesl Manual

The central entry point for all Tesl documentation. This is what `tesl help manual` prints.

Everything here is reachable from the command line — every link below has a matching
`tesl help manual <section>` command, and every command below maps to a file in this manual.

---

## Where do I start?

| If you want to… | Run | Reads |
|---|---|---|
| Install Tesl | `tesl help manual getting-started` | [GETTING-STARTED.md](GETTING-STARTED.md) |
| Understand the idea | `tesl help manual overview` | [overview.md](overview.md) |
| See every feature in one read | `tesl help manual tour` | [tour.md](tour.md) |
| See working code | `tesl help manual examples` | [examples.md](examples.md) |
| Write idiomatic Tesl | `tesl help manual best-practices` | [best-practices.md](best-practices.md) |
| Look up exact syntax | `tesl help manual language-spec` | [LANGUAGE-SPEC.md](../LANGUAGE-SPEC.md) |
| Get unstuck | `tesl help manual faq` | [FAQ.md](FAQ.md) |

New to Tesl? Read **overview → getting-started → examples**, in that order. Want the whole language
in one long read? See the **[guided feature tour](tour.md)**.

---

## CLI command map

`tesl` has three kinds of commands: **build/check commands** (operate on a `.tesl` file) and
**help commands** (read this manual). Run `tesl help` for the build/check commands; the help
commands are:

```text
tesl help                       # command-line usage (the build/check commands)
tesl help manual                # this page — the manual index
tesl help manual <section>      # one manual section (see the list below)
tesl help manual <section>#<anchor>  # jump to a sub-section (e.g. best-practices#proof-management)
tesl help examples              # the examples index (same as: tesl help manual examples)
tesl help search <query>        # full-text search across the whole manual
tesl help manual full           # the entire manual concatenated (for large-context LLMs)
tesl help full                  # same as 'tesl help manual full'
tesl help codes                 # list every diagnostic code the compiler can emit
tesl help <CODE>                # explain one diagnostic code (e.g. tesl help V001)
tesl explain <CODE>             # same as 'tesl help <CODE>'
```

> Diagnostics and editors cite precise sub-sections as `<section>#<anchor>`
> (e.g. `best-practices#validation-patterns`). `tesl help manual <section>#<anchor>`
> now **jumps straight to that sub-section** (it prints the anchored heading and its
> body); if the anchor does not resolve, the whole section is shown with a note. See
> [Stable anchors](#stable-anchors).

> Every compiler/linter diagnostic carries a **stable code** (e.g. `error[V001]`).
> A rendered error prints a `read more: tesl help manual <section>#<anchor>` deep-link
> and an `explain: tesl help <code>` pointer. Run `tesl help codes` for the full index,
> or `tesl help <code>` / `tesl explain <code>` for a single code's explanation and
> manual link.

### Manual sections

Each name below is a valid `<section>` for `tesl help manual <section>`. Aliases that the CLI
also accepts are shown in parentheses.

| Section | Aliases | What it covers |
|---|---|---|
| `getting-started` | `start`, `get-started` | Install, first project, the build/lint/test/run loop |
| `overview` | `tutorial` | What Tesl is, the proof model, and why |
| `tour` | — | The long-form, feature-by-feature guided tour of the whole language |
| `language-spec` | — | The formal language specification (the source of truth) |
| `examples` | — | Every bundled example, grouped by topic, with run instructions |
| `best-practices` | — | Recommended patterns, naming, testing, the proof cost model |
| `faq` | — | Common questions and "why did I get this error?" |
| `anchors` | — | The stable manual anchor/ID scheme (this is what error messages cite) |
| `deploy` | — | Deploying a Tesl web API: `tesl build`, the Docker image, database flavours |
| `tesl-manifest` | `manifest` | The `tesl.toml` project manifest schema (read by `tesl build` / `tesl db`) |
| `dev` | — | Pointers into the contributor docs |

Anything else is resolved as a best-effort lookup: `tesl help manual <name>` will also find a
top-level example (e.g. `tesl help manual todo-api`) or a lesson
(e.g. `tesl help manual lesson17-telemetry`).

---

## Stable anchors

Manual sections have **stable, documented anchors** so that compiler error messages and editor
tooling can link to a precise sub-section without breaking when prose around it changes.

The scheme is:

```text
<section>#<anchor>
```

For example, a "proof not found" diagnostic points you at:

```text
tesl help manual best-practices#proof-management
```

The full list of guaranteed-stable anchors, the slug rules, and the stability contract live in
their own section:

- **[Stable Anchor Scheme](anchors.md)** — `tesl help manual anchors`

If you are writing tooling that deep-links into the manual, read that page first.

---

## Full table of contents

### 1. Getting started

- **[Getting Started Guide](GETTING-STARTED.md)** — install and build your first API
- **[Overview](overview.md)** — what Tesl is and the problem it solves
- **[Installation](../INSTALL.md)** — install via Nix flake (no clone required)

### 2. Core concepts

- **[Guided Feature Tour](tour.md)** — the long-form, feature-by-feature walkthrough of the whole
  language (also `tesl help manual tour`)
- **[Language Specification](../LANGUAGE-SPEC.md)** — the formal specification (source of truth)
- **[Proof Cost Model](best-practices.md#proof-cost-model)** — proofs are zero-cost, erased in
  release and `--debug` alike; the debugger reads proof/type from compile-time

### 3. Building APIs

- **[Examples Index](examples.md)** — complete, grouped list of bundled examples
- Runnable starting points:
  - [Todo API](../example/todo-api.tesl) — CRUD over PostgreSQL
  - [Admin Task API](../example/admin-task-api.tesl) — task management with auth
  - [Queue API](../example/queue-api.tesl) — background jobs
  - [Chat Backend](../example/chat/chat-backend.tesl) — real-time SSE

### 4. Learning resources

- **[Intro Tutorial Series](../example/intro/)** — short, ordered prose tutorials
- **[Learn Lessons](../example/learn/)** — 50+ structured lessons (`tesl help manual <lesson>`)

### 5. Best practices

- **[Best Practices Guide](best-practices.md)** — patterns, naming, testing, proof cost model
- **[AI / Agent Testing](ai-testing.md)** — testing `Agent { … }` tools, entitlements, and structured output

### 6. Reference & deploy

- **[Language Specification](../LANGUAGE-SPEC.md)** — complete grammar and semantics
- **[Stable Anchor Scheme](anchors.md)** — anchor IDs for deep-linking
- **[FAQ](FAQ.md)** — troubleshooting and common questions
- **[Deploying a Tesl web API](deploy.md)** — `tesl build`, the Docker image, and database flavours
  (also `tesl help manual deploy`)
- **[`tesl.toml` project manifest](tesl-manifest.md)** — the manifest schema read by `tesl build` /
  `tesl db` and written by `tesl init` (also `tesl help manual tesl-manifest`)

### 7. Contributing

- **[Developer Docs](../dev-docs/)** — architecture and contribution guides.
  `tesl help manual dev` opens the index and `tesl help manual dev-docs/<file>` opens a specific
  guide (e.g. `tesl help manual dev-docs/02-parser`). These live at the repo root in `dev-docs/`
  but are **embedded in the `tesl` binary**, so the commands work from an installed binary with no
  repository checkout.

---

## Search tips

- `tesl help search <term>` searches every embedded manual page and example, line by line.
- Section names that appear in error messages (e.g. *"see 'tesl help manual best-practices#validation-patterns'"*)
  are exactly the `<section>#<anchor>` pairs documented in [anchors.md](anchors.md).
- Every `.tesl` example file is searchable and individually openable via `tesl help manual <name>`.

---

## See also

- **[Stable Anchor Scheme](anchors.md)** — deep-link IDs
- **[README](../README.md)** — project overview and quick start
- **[Guided Feature Tour](tour.md)** — the long-form language walkthrough
- **[LANGUAGE-SPEC.md](../LANGUAGE-SPEC.md)** — formal specification
