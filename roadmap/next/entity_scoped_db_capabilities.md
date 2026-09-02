# Scope the database capabilities to entities

## What

Make `dbRead` / `dbWrite` carry the entities they cover, in the two-word form the language
already has for caches:

```tesl
fn recentNotes() -> List Note requires [dbRead Note] = …

capability readMyDb implies dbRead Note, dbRead Author, dbRead Comment

main() -> App requires [readMyDb, envRead] = …
```

Every function that queries states the entities it touches; the requirement propagates to
`main`, whose own `requires` states the grant. A requirement nothing granted is a compile
error at the call edge that needs it, exactly as an ungranted capability is today.

**Extend the same treatment to queues and SSE.** `queueRead`/`queueWrite` and `pubsub` are
all-or-nothing in the same way — any code holding `pubsub` may publish to any channel — so they
want `queueWrite <Queue>` and `pubsub <Channel>`. Caches already work this way (`cacheCap
<Name>`); the inconsistency is that one resource got it and three did not.

## Why

Two problems, one mechanism.

**A query against an unconnected database silently reads memory.** Only the database `main`'s
App names is ever connected; a second Postgres-backed database is inert, so its entities'
queries answer from the in-memory table — in production, with no error. Today that is defined
behaviour (see the connection-points note in `migrate_to_golang.md`) and there is no way to
reject the program.

**`dbRead`/`dbWrite` are all-or-nothing.** Any code holding `dbWrite` can delete any row of any
entity. Entity-scoped grants give least privilege where it is cheap to state: a handler that
must not delete `User`s provably cannot.

## Why capabilities rather than a whole-program check

The obvious alternative — compare the entities a program queries against the App's database —
needs whole-program reachability: the queries are spread across the module graph and the App is
in the entry module. Capabilities go the other way. A requirement PROPAGATES up to `main`
through machinery that already exists, and `main` either grants it or does not. The call graph
is already walked; nothing has to discover anything.

It also handles the case a root-comparison cannot express: a `fn` called both from a handler
(App grants DbA) and from a test bound to DbB is legal under both, because the requirement is
satisfied by whoever grants it.

The precedent is in the language already: `cacheCap <Name>` is a parameterised capability,
parsed as a two-word name (`parser.ml:266`) and collapsed to an identifier at emission
(`emit_racket.ml:170`).

## Why the entities are STATED, not inferred

The compiler could compute what a function touches — queries name entities and entity →
database is static — and that would cost the corpus nothing. It was considered and rejected
(maintainer, 2026-08-17): a requirement that is not written is not a contract. The value of
`requires` is that every call edge is checkable against a local claim; infer it instead and a
caller cannot know what a callee touches without looking through it, which is the whole-program
property this design exists to avoid, reintroduced by the back door.

So the lists are written, and the corpus pays for it: **280 `requires` clauses name
`dbRead`/`dbWrite`** (against 33 alias declarations — the corpus does NOT mostly use aliases),
with `requires [dbRead]` and `requires [dbRead, dbWrite]` alone accounting for 96 sites in
`example/`. Aliases are the tool that keeps a signature short, and a mechanical first pass can
propose one alias per module from the entity sets it finds.

## Why the two-word form rather than a list

`requires [dbRead Note, dbRead Author]` keeps each capability an ATOMIC NAME, exactly like
`cacheCap Foo` — so capability identity stays string identity and satisfaction stays set
membership, and the capability checker does not change at all. `dbRead [Note, Author]` would
instead make a capability carry a type reference, which turns cross-module comparison into name
resolution and satisfaction into a subset test per verb: a change to the capability algebra
itself, and the largest hidden cost in the whole item.

The list form is strictly nicer to read and should arrive later as SUGAR that desugars to the
repeated form — once the verbosity has actually been felt, rather than before.

## Risks

- **Churn is the cost, and it is real:** ~280 `requires` clauses plus every `main`. There is no
  cheap version — the cheap version was inference, and inference is what makes the check
  worthless.
- **`main`'s `requires` grows too**, deliberately: the grant is written where every other grant
  is written, rather than derived from `App { database: D }`. Deriving it would leave the App
  type and every `main` untouched, but it would make this one capability's grant work
  differently from all the others, and the asymmetry is not worth the saved lines.
- **A bare `dbRead` must still mean something.** Either it keeps meaning "every entity" (and
  the check only bites where someone opted in) or it becomes an error. The second is the honest
  one and is what makes the 280 sites mandatory rather than optional.
- **Emission stays put.** Capabilities erase, so `emit_go` is unaffected and `emit_racket` can
  keep emitting the bare `dbRead` name — the check is static. Worth confirming rather than
  assuming.

## Sequencing

After the current Go-migration batch is committed. Every corpus file this touches is a file
whose `.rkt` snapshot moves and whose Go emission needs re-verifying, and interleaving that with
a port in flight would make both harder to attribute.

## Related

- `roadmap/next/delete_result_return_type.md` — the other stdlib-shape item found the same week.
- The connection-points note in `roadmap/next/migrate_to_golang.md` records the behaviour this
  item makes checkable.
