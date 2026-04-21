# Status: Alpha, Real, Moving Fast

Tesl is alpha. That's worth being direct about.

---

## What alpha means, concretely

- **Breaking changes are expected** — the language is still being tightened
- **Backward compatibility is not a goal yet** — if a better design is found, the old syntax goes
- **The runtime is Racket** — Tesl compiles to Racket, which runs on the Racket VM; Racket is a mature, capable platform but not what most teams are running today
- **PostgreSQL only** — the SQL and queue layers are designed around PostgreSQL specifically
- **No "create new project" command yet** — write `.tesl` files anywhere and point `tesl check`/`tesl run` at them

---

## What works today

| Feature | Status |
|---|---|
| Types, ADTs, pattern matching, records, newtypes | Working |
| Proof annotations (`:::`) — `check`, `auth`, `establish` | Working |
| Capabilities (`requires [...]`) | Working |
| Typed SQL — `select`, `selectOne`, `insert`, `update` | Working |
| Transactions (`with transaction`) | Working |
| Background job queues + workers + dead-letter | Working |
| Real-time SSE channels (`channel`, `publish`, `subscribe`) | Working |
| `api-test` blocks | Working |
| Mutation testing (`tesl --mutate`) | Working |
| VS Code / VSCodium extension + LSP (diagnostics, hover, go-to-def) | Working |
| TypeScript client generation | Experimental |
| Elm client generation | Experimental |
| Standalone binary (`raco exe`) | Roadmap |
| Dedicated migration tool | Roadmap |
| Package manager | Roadmap |

---

## How to try it today

```bash
# Install (Nix required):
nix profile install github:mtonnberg/tesl

# Or just run without installing:
nix run github:mtonnberg/tesl -- help
```

Write `.tesl` files anywhere — no repo clone needed:

```bash
tesl check  my-api.tesl    # type-check
tesl run    my-api.tesl    # compile + execute
tesl fmt    my-api.tesl    # format in-place
```

See [`INSTALL.md`](../../INSTALL.md) for home-manager, NixOS, and editor setup.

The `example/learn/` folder in the repo has 53 progressive lessons — from hello world through ADTs, proofs, typed SQL, queues, and SSE — each as a small runnable `.tesl` file with inline explanations.

---

## The goal

> "The intended long-term shape is a language that is small, opinionated, explicit, and boringly reliable for API work — one that people who just want things done will choose because it is the easiest path to a working and stable product."

The bet behind Tesl: most API bugs are not fundamentally "business logic is hard" bugs. They come from validation being forgotten, auth being implicit, effects being hidden, and domain guarantees evaporating a few function calls after the boundary. Push those concerns into the language, and the common cases become structurally correct.

---

## Get involved

The language is in active development. Feedback, bug reports, and ideas are welcome — open a GitHub issue.

*Tess the Type Seal — Tesl's mascot — is a friendly seal who stamps your code approved, or puts on a magnifying glass and points helpfully at the exact problem. Never a wall of stack trace.*

---

*Back to the beginning: [Title slide →](00-title.md)*
