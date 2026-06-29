# App simplification: `main : () -> App`, queue/worker folding, capability rewiring

**Status:** USER-FACING `.tesl` MIGRATION + WIRING-CHECK + CACHE config-type DONE
(committed; example batch 113/113, OCaml dune green, racket suite all-pass). The parser
still accepts BOTH old and new syntax, so the tree is green.

## Phase C UPDATE (2026-06-29, second pass — findings)

Migrated ~16 `.ml` test fixtures to new syntax (test_types by hand; the rest via 3
verification-gated workflows). After this pass, **all config-block old syntax is gone**:
`grep` for `postgres {` / `smtp {` / bare `database|queue|channel|email NAME {` across
`compiler/test/*.ml` + `tests/*.rkt` returns NOTHING. Aggregate `dune test` is green.

REMAINING Phase C (the ONLY deletable-old-construct usages left — verified by grep):
- `workers X for Q {}` / `deadWorkers X for Q {}` MAPPING blocks: test_review39_antagonistic,
  test_review74_sig, test_review67_block_validation, test_library_negative (LKWN04/LIMN04),
  `tests/tesl-test.rkt`. → fold into `Queue.jobs`. (5 `.ml` in flight via workflow wf_9da8639f;
  tesl-test.rkt is Racket — migrate by hand.)
- old `main {}` block: test_proofsuite_identity, `tests/tesl-test.rkt`.
- `startWorkers`/`serve … on` statements: `tests/tesl-test.rkt` only.

### TWO findings that change Phase D

1. **`with capabilities [...] { … }` must be KEPT** (revise landmine list). It is a
   general RUNTIME capability-grant block, still needed by SCRIPT-style mains
   (`main() -> Unit requires [] = with capabilities [email] { … }`) — the integration
   tests (test_email_integration, test_httpclient_integration) rely on it because a
   non-App `main` does NOT auto-grant its `requires`. Only `main() -> App` auto-grants
   (via the desugar). So Phase D KEEPS all of `parse_with_stmt` (both `with database`
   AND `with capabilities` arms). The design-doc goal "remove `with capabilities`" is in
   tension with script-mains — DECISION NEEDED before removing it (recommend KEEP).
2. **smtp port-range validation REGRESSED** (pre-existing, surfaced now). The old
   `email X { smtp {} }` validator checked `port` ∈ 1..65535 (validation_structural.ml
   ~775, guarded `when config_expr = None` so now bypassed). The new typed-record
   `SmtpConfig` path validates `port` is an Int but NOT its range — `port: 70000` and
   `port: 0` now compile clean. test_email's 2 port-range tests were rewritten to Int-type
   checks. FOLLOW-UP: re-add a port-range check to the typed-config path (check_typed_config_blocks).

### Revised Phase D deletion targets (after keeping `with capabilities`)
DELETE: old `main {}` block parse path; `parse_start_workers_stmt`/`parse_serve_stmt`;
`workers X for Q`/`deadWorkers X for Q` MAPPING-block parsers; old config-block parsers +
`parse_pg_value` + `postgres{}`/`smtp{}` sub-blocks; `config_schema.ml` + `raw_fields`
(reconcile LSP `--config-context-json` first). KEEP: ALL of `parse_with_stmt`
(`with database` + `with capabilities`), `worker`/`deadWorker` fn decls,
`EWith*`/`EStartWorkers`/`EServe` AST nodes, `channel` lexer token.

⚠️ **CORRECTION (2026-06-29):** the previous status claimed TEST-FIXTURE MIGRATION was
DONE — it is NOT. Phase C (migrating the ~15 `.ml` test fixtures that still embed OLD
config/startup syntax, + the tesl-test.rkt Q01 fixtures) is the real remaining blocker
before Phase D (deleting the old parser branches) can land. Because the parser accepts
both syntaxes, Phase C can be done incrementally with the tree green throughout; the
DELETION (Phase D) must be the LAST step, after no test uses old syntax.

### Phase C progress (this pass)
- ✅ `compiler/test/test_types.ml` `test_module_queue_runtime_statements` migrated +
  verified (`dune exec test/test_types.exe` green). Proven end-to-end pattern (folded
  Queue + `main() -> App`) — use it as the template.

### Phase C remaining — per-file migration list
MECHANICAL (embedded Tesl is incidental setup → migrate to new syntax):
- `debug_db.ml` (db block; executable harness), `test_formatter.ml` (db+queue blocks —
  ⚠️ asserts EXACT formatted output, so migrate input AND regen expected via `tesl --fmt`),
  `test_review26_antagonistic.ml` (db blocks + `with database` in handlers — `with
  database` STAYS, only `database X {}` → `= Database {}`), `test_debug.ml`,
  `test_email_integration.ml` + `test_httpclient_integration.ml` (⚠️ need MailHog/python3/
  racket — available in the compile-examples.sh env), `test_library_boundary.ml` /
  `test_library_negative.ml` / `test_library_syntax.ml` (`main {}` boilerplate →
  `main() -> App`), `test_validation.ml`.
- `test_advanced.ml` `test_main_block`: asserts `main { 0 }` parses to `MainKind` — this
  tests the OLD main-block being DELETED. Rewrite to `main() -> App = App {…}` (still
  `MainKind`).
PREMISE (assertion IS about old-config validation → rewrite to target NEW validation):
- `test_email.ml` (~55 tests: parser/type/structural-validation/capability for the OLD
  `email X { smtp {} }` block + `with_db` helper building `database MainDB { postgres {} }`).
  Rewrite to `= Email { database:, smtp: SmtpConfig {…} }`. NEW error strings (verified):
  missing db → `` `Email` is missing required field `database` ``; unknown db →
  `` email `X` references unknown database `Y` ``.
- `test_review59_antagonistic_backend.ml` + `test_review67_block_validation.ml`:
  `deadWorkers X for Q {}` MAPPING blocks (PREMISE) → fold into `Queue.jobs` + `App.queues`.
- `tests/tesl-test.rkt` Q01-class fixtures embedding old config syntax.

### CRITICAL Phase-D landmines (discovered 2026-06-29 — read before deleting)
1. **`with database X { … }` is KEPT** — still used in HANDLER bodies for SQL context
   (e.g. `example/learn/lesson48-sql-inner-join.tesl`, 8+ uses). `parse_with_stmt` must
   keep its `DATABASE` arm; only the `with capabilities [...]` arm is deleted.
2. **`worker` / `deadWorker` function decls are KEPT**; the `workers X for Q {}` /
   `deadWorkers X for Q {}` MAPPING blocks + `startWorkers`/`startDeadWorkers`/`serve … on`
   statements are what get DELETED (replaced by `Queue.jobs` folding + `App.queues`).
3. **Folded `Queue {}` REQUIRES `database`; `App {}` REQUIRES `database` + `api`** — so
   migrated queue/main fixtures must add real `database`/`server` decls.
4. **`config_schema.ml` + `raw_fields` feed the LSP `--config-context-json`** (hover +
   completion for config-block fields). Deleting them requires the LSP to source field
   info for the NEW typed blocks elsewhere, or config-field hover/completion regresses.
   Reconcile before deleting config_schema.
5. Deletion targets once Phase C is clear: old `main {…}` path, `parse_start_workers_stmt`,
   `parse_serve_stmt`, the `with capabilities` arm of `parse_with_stmt`, `parse_pg_value` +
   old `postgres {}`/`smtp {}` sub-blocks, the old `database`/`queue`/`channel`/`email`
   block-form parsers, `config_schema.ml`, `raw_fields`. KEEP: `with database` arm,
   `worker`/`deadWorker`, `EWith*`/`EStartWorkers`/`EServe` AST nodes (App desugar
   synthesizes them), the `channel` lexer token.

### Proven new-syntax templates (from the green corpus)
- Queue (folded): `queue Q requires [cap] = Queue { database: D, jobs: [Job <JobType>
  <workerFn> (Something <deadFn>)], retry: QueueRetryStrategy {…}, numberOfWorkers: N }`
  (see `example/learn/lesson28-dead-letter-queue.tesl`).
- Email: `email E = Email { database: D, smtp: SmtpConfig { host, port, username,
  password, tls } }` (see `example/learn/lesson60-email.tesl`).
- App/main: `main() -> App requires [...] = <lets> App { database: D, api: S, port: P,
  queues: [...], email: [...], sseChannels: [...] }` (see lesson28 / user-service-api).

Progress (this pass):
- Phase A — `App.static` schema field + `lower_main_app` now wraps the WHOLE main
  body in the capability+database scope (so DB-context startup like `seedExampleData()`
  works as `let _ = …` before the `App { … }`), and threads `static:` into `EServe`.
- Phase B — ALL user-facing `.tesl` migrated to `main() -> App` (13 files; example
  batch 113/113 green: Format/Compile/Lint/Fmt/Tesl-tests). `medical-journal_wip`
  removed by the user. Bare-main demo files (queue-api, lesson17) got a minimal App;
  debug-test (untracked scratch) had its main removed. Folded queues use
  `jobs: [Job T handler (Maybe dead)]` + `numberOfWorkers`.
- Phase E — `check_app_wiring` (validation_structural.ml) restores undeclared-ref
  detection for the NEW typed forms: queue/sseChannel/email `database:` refs and the
  App activation refs (`database`/`api`/`queues`/`email`/`sseChannels`) must resolve to
  locally-declared decls. +4 R67_WIRE regression tests. No false positives on the
  migrated corpus. This is the safety layer that lets the old block syntax be deleted.

REMAINING (sequenced):
- Phase C — migrate the OLD `postgres { … }` / `database X { … }` / `queue X { … }`
  fixtures embedded in ~24 `compiler/test/*.ml` files to the new `= Database/Queue/…`
  syntax (PRE-EXISTING task-#9 debt — these were already red before this pass), and
  REWRITE the behavior tests whose premise is old-config validation (test_review67
  queue/channel-structure, test_review68 queue-channel-database, test_email) plus the
  Q01-class fixtures in tests/tesl-test.rkt. This is the fragile string-literal work
  the note below warns automated conversion broke; do it per-file with --check
  verification.
- Phase D — delete old parser/config code (old `main { … }` path, parse_start_workers_stmt,
  parse_serve_stmt, parse_with_stmt, parse_pg_value + old postgres/smtp blocks, the old
  database/queue/channel/email block parsers, config_schema.ml, raw_fields). KEEP
  DWorkers/EWith*/EStartWorkers/EServe (the App desugar synthesizes them) and the
  `channel` lexer token (the new `sseChannel`/`channel` syntax uses it). Gated on Phase C.
- (Separately, per the user) remove the runtime gated proof/capability safety net in
  dsl/ — see zero_cost_capabilities.md / remove_old_safety_net.md.

(original status below)
**Status:** CORE IMPLEMENTED & GREEN (accept-both); migration + old-code removal remain.

Implemented this pass (all green, old syntax still accepted so the tree stays green):
- `main() -> App requires [...] = App { database, queues, email, sseChannels, api, port }`
  parses (routes to `parse_fn_decl_named MainKind "main"`) and DESUGARS to the existing
  imperative startup: `(module+ main … (with-capabilities [R] (call-with-database D
  (begin (start-workers! …) (start-dead-workers! …) (serve api #:port port …)))))`.
- Folded `queue NAME requires [R] = Queue { jobs: [Job J fn (Something dead)], retry:{…},
  numberOfWorkers: N }`: parser stores `requires`; desugar synthesizes `<Q>Workers` /
  `<Q>DeadWorkers` `workers_form`s + records `number_of_workers`; the `main`→`App` desugar
  emits `start-workers!`/`start-dead-workers!` per `App.queues` using the queue's
  `requires`/`numberOfWorkers`.
- Structural validation: `App` schema (required `database`/`api`, etc.) validated where
  an App-style `main` returns it; folded `queue` schema (`jobs` accepts `Job` entries,
  `numberOfWorkers`). `App` record body is NOT type-checked by the main checker (its
  fields reference decls by name) — skipped like config blocks.
- NO capability-checker rewiring needed (it's already per-`requires`); `with capabilities`
  scope is generated by the `main`→`App` desugar.
- Stdlib: `Tesl.App` (exports `App`), `Job`/`QueueRetryConfig`/`Linear` in the emit
  config-only import filter.

REMAINING (the large mechanical tail, do together with the deferred config cleanup):
- Migrate `main`/`queue` sites + the config-block `.ml` fixtures + docs to the new syntax.
- Rewrite the old-config/old-main validation tests.
- Delete old code: old `main {…}`/`with capabilities`/`workers`/`deadWorkers`/
  `startWorkers`/`serve`-stmt + old block parsers/`parse_pg_value`/`config_schema`/
  `channel` keyword/`raw_fields`.

---
(Original plan below.)

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

## KEY FINDING — the capability checker needs NO rewiring (de-risks the pass)

Investigated the current machinery. The static capability checker
(`validation_capabilities.ml` `check_handler_capabilities` / `collect_needed_capabilities`)
is **already per-function and scope-UNAWARE**: for each `DFunc` it collects the
capabilities its body uses and checks them against that function's declared `requires`
(`func_decl.capabilities`). It does NOT consult `with capabilities` scopes at all — those
are enforced only at RUNTIME by the Racket substrate. So:

- Removing `with capabilities` does **not** require rewiring the static checker. The
  per-function `requires` checking stays as-is.
- The only thing `with capabilities` does is establish the runtime capability scope at
  startup. In the App model, the **desugar generates** that scope from `main.requires`
  (and per-queue `requires`).

So the App pass is NOT a deep checker change. It is:
**parser (new `main`/`queue` forms) → DESUGAR that lowers the declarative forms into the
EXISTING imperative AST → migrate → delete old.** Emit and the cap checker are reused.

### Desugar bridge (the heart of it)

- `main() -> App requires [R] = App { database: D, queues: [Q…], email: [E…],
  sseChannels: [C…], api: S, port: P }` lowers to the existing imperative `main` body:
  `with capabilities [R] { with database D { startWorkers … (per Q) ; startEmailWorker …
  (per E) ; serve S #:port P … } }` — i.e. build the same `EWithCapabilities` /
  `EWithDatabase` / `EStartWorkers` / `EServe` / runtime calls the old `main` used.
- Folded `queue X requires [R] = Queue { jobs: [Job J fn (Something dead)], retry:{…},
  numberOfWorkers: N }` lowers to: the existing `queue_form` (database/jobs/retry) PLUS
  synthesized `workers_form` (J→fn) and dead `workers_form` (J→dead) prepended to the
  module (same trick as synthesized capturers). `numberOfWorkers`/`requires` feed the
  `startWorkers` the `App` desugar generates for each activated queue.

Relevant current anchors: `main` parses to `DFunc {kind=MainKind; capabilities=…}`
(parser.ml ~5002-5054); imperative startup forms `EWithCapabilities`/`EWithDatabase`
(parser ~2462-2494) and `EStartWorkers`/`EServe` (desugared to `ERuntimeCall`,
desugar.ml ~119-146); `workers_form` parse ~4285-4313, emit emit_racket ~6111-6125;
`parse_requires` (parser ~1013-1032) is reusable for queue/main.

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
