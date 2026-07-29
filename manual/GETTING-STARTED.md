# Getting Started with Tesl

Zero to a running, type-checked web API — and one deliberate proof error, because that is the moment
Tesl explains itself. Budget 20 minutes.

`tesl help manual getting-started` prints this page from the CLI.

---

## 0. Install

```bash
nix profile install github:mtonnberg/tesl
tesl help                       # confirms `tesl` is on your PATH
```

Nix is the only supported install path today. See [INSTALL.md](../INSTALL.md) for home-manager,
NixOS, editor setup, and the "try it without installing" variant. If you want to work on the Tesl
compiler itself instead, go to [dev-docs/README.md](../dev-docs/README.md).

---

## 1. Scaffold a project with `tesl init`

**`tesl init` is the recommended way to start a Tesl project.** Do not hand-roll a directory — the
scaffold is a complete, compiling, commented service, and everything below assumes it.

```bash
tesl init myapi        # asks a couple of questions; add --yes to take the defaults
cd myapi
```

You get:

| File | What it is |
|---|---|
| `app.tesl` | A working service: an `entity` on PostgreSQL, cookie `auth`, an **input proof** on the request body, an **output proof** on the response, and `test` blocks. Heavily commented. |
| `tesl.toml` | The project manifest — entrypoint, the `[env]` contract, database mode, deploy target. See [tesl-manifest.md](tesl-manifest.md). |
| `.env` | Local environment values, loaded automatically by `tesl run`. |
| `AGENTS.md` / `CLAUDE.md` | Instructions for AI coding agents working in this project (see [AGENTS.md](../AGENTS.md)). |
| `.gitignore`, `README.md`, `.vscode/launch.json` | Sensible defaults: `.tesl-stuff/` ignored, a project README, and a debugger launch config. |

> `.tesl-stuff/build/` holds the generated `.rkt` files and Racket bytecode. It is always safe to
> delete (`tesl clean`) at the cost of a fresh compile, and it should never be committed.

---

## 2. Run it

```bash
tesl run app.tesl
```

With the default **managed** database, this provisions a project-local PostgreSQL, loads `.env`, and
serves on <http://localhost:8086>. In another terminal:

```bash
# create a todo (the `user` cookie is what the scaffold's `auth` reads)
curl -sS -X POST http://localhost:8086/todos \
  -H 'content-type: application/json' \
  -H 'Cookie: user=demo' \
  -d '{"title":"Read the Tesl tutorial"}'

# and one that is deliberately too short — rejected at the boundary with a 400,
# before any handler code runs
curl -sS -X POST http://localhost:8086/todos \
  -H 'content-type: application/json' \
  -H 'Cookie: user=demo' \
  -d '{"title":"no"}'
```

That 400 is not a hand-written guard clause. It comes from a `check` wired into the body's codec.

---

## 3. Break it on purpose — meet the proof checker

Open `app.tesl` and find the `NewTodo` codec:

```tesl
codec NewTodo {
  toJson_forbidden
  fromJson [
    {
      title <- "title" with_codec stringCodec via isSafeTitle
    }
  ]
}
```

Delete ` via isSafeTitle`, then:

```bash
tesl check app.tesl
```

```text
error[V001]: codec 'NewTodo': decoder field 'title' requires proof predicates TitleSafe but has no `via` validation
Hint: add `via <checkFn>` so field 'title' is validated before decoding succeeds
  --> app.tesl:112:7

  read more: tesl help manual best-practices#validation-patterns  (explain: tesl help V001)
```

Read what just happened. `NewTodo.title` is declared as `String ::: TitleSafe title` — a string that
**carries proof** it is a safe title. A `check` is the only thing in the language that can mint that
proof. Remove the `via`, and there is no longer any path from raw JSON to a proven value, so the
program does not compile. Not a lint. Not a runtime error in production. A compile error, at the one
place where the mistake was made.

Put ` via isSafeTitle` back and `tesl check app.tesl` goes quiet.

**Every diagnostic works like this one:** a stable code, a precise span, a manual deep-link, and
often a machine-applicable fix.

```bash
tesl explain V001         # the full explanation for one code
tesl help codes           # every code the compiler can emit
```

Try one more: change `handler getTodo`'s return type from `Todo ? FromDb (Id == todoId)` to plain
`Todo`, then put it back. The `?` is how a proof travels *out* of the SQL boundary, and only the
`select` boundary can mint it — a handler cannot fabricate one.

---

## 4. The everyday loop

```bash
tesl check app.tesl        # parse + types + proofs, no execution
tesl validate app.tesl     # check + lint + format check — the one to run before committing
tesl fmt app.tesl          # format in place (--check to verify only)
tesl test app.tesl         # run the file's `test` / `api-test` / `load-test` blocks
tesl run app.tesl          # serve it (TESL_VERBOSE=1 for detailed logs)
tesl mutate app.tesl       # mutate the validation logic and confirm your tests catch it
tesl build --with-postgres # an all-in-one Docker image (see deploy.md)
```

Add files as the project grows and `tesl check` them together: `tesl check app.tesl db.tesl`.
A module's name and its file name must match — the compiler resolves imports by file name — so
`module TodoRoutes` lives in `todo-routes.tesl` (or `TodoRoutes.tesl`).

### Looking things up

```bash
tesl help manual best-practices    # one manual section
tesl help search transaction       # full-text search across the whole manual
tesl help codes                    # every diagnostic code
```

Your editor knows the rest: install the Tesl extension (see [INSTALL.md](../INSTALL.md)) for
diagnostics, hover types, go-to-definition, completions, and quick-fixes straight from the compiler.

---

## 5. The two ideas behind everything else

**Proofs (Ghosts of Departed Proofs).** `value ::: SomeFact value` means "this value carries proof
that `SomeFact` holds". Only a `check` mints a proof; from then on it flows through calls
automatically, and a function that asks for one it was not given is a compile error. Proofs are
**erased** after type checking — they cost nothing at runtime (the canonical
[proof cost model](best-practices.md#proof-cost-model) has the per-feature table).

**Capabilities.** Side effects are declared, not implicit:

```tesl
handler getTodo(todoId: String) -> Maybe Todo
  requires [dbRead] =
  selectOne todo from Todo where todo.id == todoId
```

Common ones: `dbRead`, `dbWrite`, `time`, `random`, `queue`, `pubsub`, `emailCap`. A handler can only
do what its `requires` list allows, and the compiler checks the whole call graph.

Both ideas, in full: [overview.md](overview.md) for the shape, [tour.md](tour.md) for every feature.

---

## 6. Structuring a larger project

```
myapi/
├── app.tesl            # api + server + main (the entrypoint in tesl.toml)
├── tesl.toml
├── src/
│   ├── types.tesl      # records, entities, newtypes
│   ├── validation.tesl # check / establish functions
│   ├── auth.tesl       # auth boundaries
│   └── routes/…        # handlers, grouped by resource
└── tests/
    └── todos.test.tesl
```

One module per file, explicit imports, and a layering of validation → types → logic → routes. See
[best-practices.md](best-practices.md) for the idiomatic version of all of this.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `command not found: tesl` | Add the Nix profile to your PATH: `export PATH="$HOME/.nix-profile/bin:$PATH"` |
| A diagnostic you do not understand | `tesl explain <CODE>` — the code is in the error, e.g. `error[V001]` |
| `proof not found` / `does not statically satisfy declared proof` | The value never went through a `check`. Validate at the boundary (a codec `via`, a `capturer via`, or an explicit `check` call) rather than re-checking downstream. |
| PostgreSQL connection errors | In managed mode, `tesl db` provisions and starts the local cluster; check the `TESL_POSTGRES_*` values in `.env` against [tesl-manifest.md](tesl-manifest.md). |
| Anything else | [FAQ.md](FAQ.md), or `tesl help search <term>` |

---

## Next steps

**One next step, and it is this one: [Your First Change](first-change.md)** — add a real feature to
the scaffold (a rename endpoint), hit a proof error while building it, and understand why the compiler
is right. 15 minutes. From the CLI: `tesl help manual first-change`.

After that, in any order:

1. **[Examples](examples.md)** — the bundled example catalog and the `example/learn/` lessons
2. **[Guided Feature Tour](tour.md)** — the long read: typed SQL, queues, SSE, agents, `ForAll`
3. **[Best Practices](best-practices.md)** — idiomatic patterns, testing, the proof cost model
4. **[Deploying a Tesl web API](deploy.md)** — `tesl build`, image flavours, runtime config
5. **[LANGUAGE-SPEC.md](../LANGUAGE-SPEC.md)** — the source of truth

---

## See Also

- [Manual Index](MANUAL.md) — back to the manual
- [Overview](overview.md) — the conceptual introduction
- [AGENTS.md](../AGENTS.md) — driving Tesl from an AI coding agent
- [INSTALL.md](../INSTALL.md) — install and editor setup
