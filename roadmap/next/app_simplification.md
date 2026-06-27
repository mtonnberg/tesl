# App simplification: `main : () -> App`, queue/worker folding, capability rewiring

**Status:** planned. Do this AS THE NEXT PASS, immediately after the typed-config-block
migration (the `= Database/Queue/Email/SseChannel { … }` work) is fully finished and
committed (old block parsers / `parse_pg_value` / `config_schema` / `channel` keyword /
`raw_fields` removed).

This is a second breaking change. It builds directly on the typed-config-block work
(config blocks are already typed record values). It deliberately was NOT bundled into
that pass to avoid compounding two breaking migrations.

---

## Motivation

After the config-block redesign, `database`/`queue`/`email`/`sseChannel` are typed
record *declarations*. But the application ROOT is still imperative:

- `main with capabilities [...] { with database X { with capabilities [...] { startWorkers … ; serve … } } }`
- queues are split across `queue` + `workers X for Q` + `deadWorkers` + `startWorkers N`
  + a surrounding `with capabilities` block.

The proposal pushes the "config is a typed value" philosophy to the root and folds the
worker machinery into the queue.

## Proposed surface syntax

```tesl
queue EmailQueue requires [emailCap, pubsub, deadEmailCap] = Queue { # Queue declared in Tesl.Queue
  database: DemoDatabase
  jobs:
    [
      Job EmailJob processEmail (Something handleDeadEmail)
    ]
  retry: { #Type QueueRetryConfig declared in Tesl.Queue
    maxAttempts: 3
    backoff: exponential
    initialDelay: 10
  }
  numberOfWorkers: 2
}

main() -> App # App declared in Tesl.App
  requires [fullService, emailCap, deadEmailCap, enqueueEmail, pubsub] =
  let specialThing2 = envInt "SpecialEnvVar"
  let port = envInt "PORT" 8086
  App {
    database: DemoDatabase
    queues: [EmailQueue]
    email: [DemoEmail]
    sseChannels: [SomeSseChannel]
    api: DemoServer
    port: port
  }
```

## Design decisions

1. **`main : () -> App`** — `main` becomes an ordinary function (`requires [...]`,
   returns `App`) that *builds a description*; the runtime interprets the `App` record
   to start everything. Replaces the imperative nested `with database` / `with
   capabilities` / `startWorkers` / `serve` blocks. Lets users compute (`let port =
   envInt "PORT" 8086`) before returning.

2. **`App` is a new stdlib type** (`Tesl.App`), like `Database`/`Queue`. Fields:
   `database`, `queues: [Queue]`, `email: [Email]`, `sseChannels: [SseChannel]`,
   `api: Server`, `port`. OPEN QUESTION: does `port` live on `App` or on the server?
   Lean toward the server owning its own port (single source of truth) — revisit.

3. **Declaration vs activation.** The `queue` declaration defines workers/retry/jobs;
   listing it in `App.queues` ACTIVATES it. A queue not in `App.queues` doesn't run.
   `App` is the activation set (and the root of the wiring graph — see below).

4. **Fold workers into the queue.** `jobs: [Job EmailJob processEmail (Something
   handleDeadEmail)]` pairs each job type with its handler and an OPTIONAL dead-letter
   handler expressed as `Maybe` (`Something fn` / `Nothing`) — reuses the normal type
   flow. `numberOfWorkers: N` replaces `startWorkers N`. Removes the separate
   `workers` / `deadWorkers` / `startWorkers` constructs.

5. **Capabilities via `requires` lists; remove `with capabilities`.** Capability
   checking is rewired to flow DOWN from each declaration's `requires` (main's
   `requires`, each queue's `requires`, handler/auth `requires`) instead of UP through
   imperative `with capabilities` scopes. After this, the `with capabilities` keyword
   is deleted. THIS IS THE HEAVIEST PIECE — the cap checker currently keys off
   `with capabilities` scopes; rewiring it is the core compiler work.

## Cross-reference wiring check (the safety layer — do as part of/after this pass)

The infra blocks reference each other implicitly (a handler `enqueue`s a job, `publish`es
to a channel, etc.). DECISION: do NOT make these explicit via parametric type parameters
— that leaks infra into every signature and fights Tesl's "infra is invisible" value
prop. Instead, add a **compile-time wiring-graph check**: the keyword-bearing functions
ARE the edges of the graph, and the compiler already knows both endpoints' kinds.

Edges:
- `enqueue EmailJob {…}` → a queue must declare job type `EmailJob` (and be in `App.queues`).
- `publish DemoEvents(…)` / `subscribe DemoEvents` → a declared `sseChannel DemoEvents`
  (in `App.sseChannels`).
- `Email.send DemoEmail {…}` → a declared `email DemoEmail` (in `App.email`).
- `App.api` → server → its `handler` bindings; SQL / `with database` → `App.database`.

Flag: an `enqueue` of a job type no queue handles; a `publish`/`subscribe` to an
undeclared channel; a component referenced but missing from `App`; (warning) a declared
component never activated. Graph root = `App`. No type ceremony; infra stays invisible
in source but the wiring is verified at compile time.

## Sequencing & overlap notes

- The only construct overlapping the previous (typed-config-block) pass is `queue`. The
  current `Queue { database, jobs, retry }` is a clean SUBSET; this proposal EXTENDS it
  (adds `requires`, `numberOfWorkers`, richer `jobs` with handlers). So little is wasted.
- When finishing the previous pass's `.ml`-fixture migration, keep queue/main migrations
  MINIMAL — they get reworked here.

## Fold the old-config-code REMOVAL into this pass (learned mid-migration)

The typed-config-block pass migrated all USER-FACING `.tesl` (examples, lessons,
templates, scratch app) to the new syntax and is green. The old block parsers /
`parse_pg_value` / `config_schema` / `channel` keyword / `raw_fields` were NOT yet
removed, because ~5 test files are **tests OF the old config system** (e.g.
`test_review67` CF colon/unknown + QU/CH missing-database tests; old `config_schema`
behavior; `test_review68` queue-channel-database). Migrating their `.ml` fixtures to the
new syntax INVALIDATES those tests' premise — so removal requires rewriting/deleting
them, not mechanical conversion. An automated `.ml` block-conversion was attempted and
reverted (it broke 28 tests for exactly this reason).

DECISION: do the old-config-code removal + `.ml`-fixture migration HERE, with the App
pass, because this pass already (a) removes related old constructs (`with capabilities`
/ `workers` / `deadWorkers` / `startWorkers`), (b) rewrites the SAME test fixtures, and
(c) overhauls the capability checker. Doing both cleanups together avoids touching the
fragile `.ml` string-literal fixtures twice and avoids rewriting the old-config tests now
only to rewrite them again. Net: one deliberate cleanup pass over the test suite + docs,
then delete all the dead old config/main/worker/with-capabilities code at once.

A reusable `.tesl` config-block migrator exists (kept at `/tmp/migrate_config.py` during
the session; re-create from this doc if gone) — line-based, handles the structural
postgres→connection-ADT transform; `--no-imports` mode for `.ml` heredocs. It does NOT
handle single-line blocks or escaped `"…\n…"` strings, and does NOT rewrite tests.

## Implementation sketch (where the work lands)

- **Parser:** `queue NAME requires [...] { … jobs: [Job T fn (Maybe fn)] … numberOfWorkers: N }`;
  `main() -> App requires [...] = … App { … }`. App RHS is a typed record literal (same
  machinery as the config blocks). Remove `with capabilities` parsing (and `workers` /
  `deadWorkers` / `startWorkers` once folded).
- **Stdlib:** `Tesl.App` (`App` record) + register exports; `Job` constructor for the
  jobs list (`Job : JobType -> handlerFn -> Maybe deadFn -> …`, a reference-bearing form
  like `entities`/`payload`).
- **Checker:** rewire capability checking to start from `main.requires` + each
  component's `requires` (delete `with capabilities` scope logic). Add the wiring-graph
  check rooted at `App`.
- **Desugar/Emit:** lower the `App` record + folded queue into the existing runtime
  startup calls (`serve`, `start-workers!`, etc.) so the runtime substrate is unchanged.
- **Migrate:** all `main`/`workers`/`queue` sites; docs (`manual/`, `LANGUAGE_SPEC.md`);
  delete `with capabilities` / `workers` / `deadWorkers` / `startWorkers` once unused.
