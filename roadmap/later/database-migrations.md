# Schema evolution: snapshots, typed migrations, and zero-downtime rolling deploys

Rewritten 2026-09-02. The earlier draft proposed an `alter … add/remove` DSL with
up/down blocks, modelled on Rails/Flyway. This rewrite drops that direction. It is
built on what Lamdera Evergreen and Acadia do (both studied from their compiler
sources, docs and shipped binary — see "What the references actually do"), on what
Haskell Persistent got right and wrong, on the parts of Tesl that already exist and
make a better design possible (entity declarations as the single schema source,
proofs, whole-program query knowledge, the Memory/Postgres parity rule, the versioned
`fromJson` codec list), and on one constraint none of the references face: Tesl
programs run as horizontally scaled fleets behind rolling deploys, so **at every
instant the schema must be compatible with every code version currently serving**.

The bar (maintainer, 2026-09-02): migrations must ship as a solved problem, not a
toy. That rules out "run the migration, then deploy" as the story, because with a
rolling deploy that ordering does not exist.

## Summary of the proposal

1. **The schema is a hand-written, versioned module the program imports.** Entities
   (and the facts, checks and codecs their columns need) live in `schema module
   NotesSchema.V8`, the application says `import NotesSchema.V8 exposing [Note, …]`,
   and the `database` declaration names the module — not a string. Changing the
   schema is copying `V8.tesl` to `V9.tesl`, editing it, and bumping the imports; a
   stale import is a compile error with a mechanical fix. Older versions stay in the
   repo, frozen by a compiler-checked hash, so the next migration can name `V7.User`
   and be type-checked against it. This is Acadia's `database module` and Lamdera's
   `Evergreen/V7/Types.elm`, hand-owned rather than generated (maintainer, 2026-09-02:
   Tesl is explicit about where every type comes from).
2. **`tesl --migrate` diffs the previous schema module against the current one** and
   writes `migrations/V<n+1>.tesl`: a `migration V7 -> V8 { … }` form with one entry
   per entity. Additive, loss-free changes are filled in by the compiler. Anything
   else is a typed hole (`todo "…"`) that is a compile error until a human replaces
   it. This is Lamdera's `Unimplemented` and Acadia's `.plan` file at once.
3. **A row migration is an ordinary Tesl function** `fn migrateNote(old:
   NotesSchema.V7.Note) -> Migrated NotesSchema.V8.Note`, returning `Row` with the new
   row or `Reject` with a reason, and the migration file is one folded record
   (`Migration { from, to, same, entities }`) built from `Tesl.Migration` ADTs — no
   keywords. Because the new row type carries its field proofs and a column fact can be
   minted only by checks in its own schema module, the function cannot produce a row that
   violates the new invariants without going through such a check. Neither Lamdera nor
   Acadia can express a migration that is **invariant-correct per row**, checked by the
   same kernel that guards the HTTP boundary.
4. **The two-version rule is enforced at compile time, and everything else follows
   from it.** Every change is decomposed by the compiler into an **expand** step
   (compatible with V7 *and* V8 code) and a **contract** step (compatible with V8
   *and* V9 code). A change that cannot be decomposed is classified `OFFLINE` and
   must be acknowledged in the plan. Row functions never rewrite a column in place;
   they always produce new columns.
5. **Expand runs automatically when a V8 instance boots.** It is metadata-only DDL
   under an advisory lock with `lock_timeout` retries, and V7 instances tolerate it
   by construction, so there is no separate "run migrations" deploy step. This is
   the auto-migration the earlier draft wanted to remove, made safe by the rule.
6. **Backfill runs in the background from one V8 instance, in small batches, and
   lazily on read** in every V8 instance: a row whose generation marker (`_tesl_v`, a
   per-entity generation every table carries) is behind is passed through the
   embedded row function when read. V8 may use a new column
   only in projections (a compile error says so); the column becomes usable **inside
   SQL** (`where`, `order`, `groupBy`, joins, aggregates) from V9, once V7 is retired
   and the backfill is final — or immediately if declared `Maybe`. A
   compiler-generated **invalidation
   trigger**, installed at expand and dropped once V7 is retired, lowers a row's
   generation marker when a V7 instance updates one of its source columns — the only
   way a write from old code can be seen at all.
7. **"V7 is gone" is an explicit, irreversible state, not an observation.**
   `tesl_schema.min_version` names the oldest admitted version. Every transaction a
   V7 instance runs first takes a shared **transaction-scoped** advisory lock on V7's
   fence key and reads that state under it, and **retiring** V7 (advancing
   `min_version` to 8) happens only while holding V7's key exclusively — so no V7
   transaction is in flight at the moment of retirement and none can start after it,
   paused process or not, and nothing depends on which backend session a statement
   lands on, so transaction-mode poolers are fine for the request pool (the one
   dedicated DDL connection per instance is the exception, §6 invariant 7). Retirement
   happens at V9 boot (or earlier on demand). Only after it are V7's trigger dropped,
   the backfill declared final, `NOT NULL` set, and V7's columns dropped. Rolling back
   V8 → V7 is possible until retirement; V9 → V8 for the whole life of V9. The
   heartbeat table is observability, never a guard.
8. **The database records its history** (`tesl_schema`, one row per version and
   step) and the compiled program embeds the version it was built against. The boot
   gate refuses a binary more than one version away from the database in either
   direction. **Nothing is ever `ALTER`ed in a database that has data except the
   expand and contract steps a committed plan describes.**
9. **No down migrations.** A migration is a forward function. Rolling back is
   redeploying the previous binary, which the two-version rule guarantees still runs;
   undoing a schema change is a new forward migration.
10. **Row-level security policies** (Acadia's `Security.policy`) are the natural
    companion and are sketched in their own section; they become part of the
    snapshot so a policy change shows up in the plan for review.

## What actually happens today (verified 2026-09-02)

The Go runtime is the only runtime; Racket is gone. Schema handling is:

- `runtime/go/teslrt/postgres.go:226` (`bootstrap`): `create schema if not exists`,
  then per table `create table if not exists <table> (<columns>)`, then `create
  unique index if not exists` for each declared **unique** index. That is the whole
  of it.
- There is **no column reconciliation**. Nothing reads `information_schema`; nothing
  emits `ALTER TABLE`. A field added to an entity whose table already exists is
  invisible to the database, and the first query that touches the column fails at
  request time with a PostgreSQL "column does not exist" error, not at boot.
- Plain (non-unique) indexes are **not created at all** by the Go bootstrap
  (`compiler/lib/emit_go.ml`, the `unique` filter in the table emission: "a plain
  index is a hint … left to whoever tunes the database"). LANGUAGE-SPEC §11.8 still
  describes the Racket behaviour (warning with a `CREATE INDEX CONCURRENTLY`
  statement on populated tables). That paragraph is stale.
- `manual/tour.md` §"Schema and migrations" says "if you add a column to an entity,
  Tesl tells you at startup if it is missing". That was true of the Racket runtime
  and is **not true now**. LANGUAGE-SPEC §11.8 also cites an `auto-migrate?` option
  that §11.9's grammar does not have. Both need fixing regardless of this item.
- What does exist and is load-bearing for the design below:
  - `entity_json` in `compiler/lib/ir.ml:620` — the `tesl doc --doc-json` catalog
    already serialises name, table, primary key, fields and indexes per entity.
  - `codec … { fromJson [ {current}, {legacy} ] }` (roadmap/completed/json_codecs.md,
    "Historical / versioned decoders") — multiple decoders tried in order, one
    encoder. JSONB columns can already be read across shape changes **without a
    data migration**. The lazy migrate-on-read below is this idea generalised to
    columns.
  - The Memory backend enforces declared unique indexes with PostgreSQL NULL
    semantics — the parity rule that makes `tesl test` faithful.
  - The compiler sees **every query in the program** (this is what W092/W093, the
    missing-index lints, are built on), so a schema diff can be judged against
    actual use, not in isolation. It also sees every `insert`/`update`, which is
    what makes the compatibility check below decidable.
  - Entity fields carry proofs (`age: Int ::: Positive age`) and records carry
    record-level proofs. Only `check` functions mint them.

The earlier draft's "Feedback" note — users found auto-migration fine — described the
Racket runtime's add-missing-columns behaviour. Since the Go migration that
convenience is gone too, so the gap is now real in development as well as in
production: today the only way to add a field to a deployed entity is a hand-written
`ALTER TABLE` that Tesl neither knows about nor verifies.

## What the references actually do

### Haskell Persistent

`mkMigrate` derives a migration from the entity definitions by comparing them with
the live database. `printMigration` shows the plan; `runMigration` applies the
**safe** subset (new tables, new nullable columns, null-to-not-null relaxations,
type changes the database can convert); it **refuses** field removal (data loss) and
cannot detect renames ("Persistent has no way of knowing that `name` has now been
renamed to `fullName`"). `runMigrationUnsafe` overrides. Persistent's own docs warn
that automated migration is a development aid, not a production process.

Lesson kept: derive the diff from the declarations, never hand-write it; classify
safe versus lossy. Lesson learned from its failure: without a **prior version** to
compare against, renames and semantic changes are undecidable, and "safe" ends up
meaning "loss-free at the SQL level" rather than "correct". The fix is a committed
snapshot, not a smarter diff.

### Lamdera Evergreen

(From the saved docs page and `lamdera/compiler` `extra/Lamdera/Evergreen/*.hs`.)

- Every deploy with type changes snapshots the six core types **and every type they
  reference** into `src/Evergreen/V<n>/Types.elm`, committed to git. Functions are
  not snapshotted; modules are renamed into the `Evergreen.V<n>` namespace.
- `lamdera check` generates `src/Evergreen/Migrate/V<n>.elm`. For each changed type
  it writes a function `Old.T -> ModelMigration New.T New.Msg`. Where the type
  changed in a way the generator cannot resolve it writes
  `Unimplemented {- Type `Int` was added in V2. I need you to set a default value. -}`.
  The app **cannot deploy** while any `Unimplemented` remains.
- Migration results per type: `ModelUnchanged | ModelReset | ModelMigrated (model,
  Cmd msg)`, and for messages `MsgUnchanged | MsgMigrated … | MsgOldValueIgnored`.
  `ModelUnchanged` means "re-decode the old bytes with the new decoder" and is only
  valid if the wire shape is identical; the harness fails at decode time otherwise.
- Migrations are **pure functions**; there is no schema language. Renames are
  expressed in the function body (`{ total = old.counter * 100 }`).
- `--destructive-migration` writes an all-`Unchanged` file for throwaway data.
- Deployment is **stop-the-world**: one backend instance, the whole model in memory,
  the migration runs between the old process stopping and the new one starting.
  Evergreen never has two code versions running against one store.

Lessons kept: the version is a committed snapshot in the source language; the
migration is a typed function against that snapshot; the compiler writes the boring
90% and marks the rest with a hole that blocks deployment; the type checker, not a
runtime, decides whether a migration is complete. Not applicable: the deployment
model.

### Acadia (Evan Czaplicki's database language)

(From the docs bundle, `github.com/acadia-engineering/examples`, and the 0.3.0
binary. `acadia plan|sign|publish` are gated behind registration, so the plan file
format below comes from the home page example and the binary's strings.)

- Acadia code is **compiled against the actual database file** (`acadia make
  foods.sqlite`). "Never get out of sync with your database."
- `acadia plan` compares the code with the database and writes `v2.0.0.plan`, a
  source file whose header comment is the reviewable summary:

  ```
  migration
    1.0.0 --> 2.0.0

  endpoints
    Post.add        BREAKING CHANGE
    Post.rename     DROP
    Post.duplicate  CHANGE

  tables
    Post.posts      MIGRATE WITH dropColumn
  ```

  followed by `import OLD.Post as OLD`, `import Post as NEW` and the migration
  function `dropColumn : OLD.Post -> NEW.Post`. The `OLD.` module prefix is reserved
  for "the prior version of this module". Error classes in the binary
  (`D_TMissing`, `D_TExtra`, `D_TMismatch`, `D_MigrationNotFound`,
  `D_MigrationNotCorrect`, `D_ExpectingMigration`, `NOT EXPECTING A MIGRATION`) show
  the plan is checked in both directions: a table that changed **must** name a
  migration, and a table that did not change **must not**.
- `acadia sign` type-checks the plan and produces `v2.0.0.signed`, a signature over
  the plan's content ("This is like approving the plan"). `acadia publish
  v2.0.0.signed foods.sqlite` does "a final check to confirm that the database has
  not changed since your plan was signed" and applies it. Three steps: plan, approve,
  apply; the artefact applied is the one reviewed.
- Endpoints have **stable IDs across migrations**; adding or removing endpoints is
  part of the same plan (`BREAKING CHANGE` / `DROP` / `CHANGE`), so a client built
  against 1.0.0 is detected, not surprised.
- **Row-level security is mandatory.** `Table.table { primary, security, indexes,
  constraints }` — every table names a `Security.Policy security row`, and there is
  no `access`/`insert`/`update`/`remove` without passing the security token:

  ```elm
  rowLevelSecurity : Security.Policy UserID { row | owner : UserID }
  rowLevelSecurity =
    Security.policy
      { access = \user row -> row.owner == user
      , insert = \user row -> row.owner == user
      , update = \user before after -> before.owner == user && before.owner == after.owner
      , remove = \user row -> row.owner == user
      }
  ```

  `update` sees **before and after**, which is how "this column is immutable" is
  written (`before.id == after.id`). The docs state that Acadia performs "static
  symbolic evaluation so if `before.id == after.id` evaluates to True at compile time,
  it imposes no runtime overhead" — a policy clause discharged statically is erased.
  `Security.unrestricted` is the explicit opt-out.
- Deployment is **single-writer SQLite**: the publish step is the only writer while
  it runs. Like Lamdera, Acadia never has two code versions against one database.

Lessons kept: the plan is a **file you read**, with a header a reviewer can approve
without reading the body; the plan is checked against the database it will be applied
to, and again at apply time; unchanged tables must not carry migrations; policies
are declared on the table, are total over the four verbs, see before/after on update,
and are erased when provable. Not applicable: the deployment model.

### Where the rest of the industry is, and why it stopped there

The *mechanics* below are not new; the *guarantee* is. Expand/contract is established
practice (Stripe, GitHub, Braintree's "parallel change", Shopify), enforced by
checklists and review. Online schema-change tools exist: gh-ost and
pt-online-schema-change for MySQL, and for PostgreSQL **pgroll** (Xata) and
**Reshape**, which do almost exactly this document's runtime — expand, dual-write
triggers, backfill, contract — and expose each schema version through views so old
and new application versions each see their own schema. Diff-from-declaration
generators exist (Django `makemigrations`, Persistent, Prisma, EF Core). Databases
themselves keep shrinking the pain (PostgreSQL 11 fast defaults, MySQL instant DDL).

None of them closes the loop, for structural reasons rather than lack of effort:

- **Open world.** An ORM never sees every query — raw SQL, dynamic builders, other
  services on the same database — so "is V7 compatible with this DDL" is undecidable
  and tools stop at "helpful".
- **Ownership split.** Rails/Django deliberately treat the database as shared and
  migrations as separately reviewed files; the framework does not own the schema.
- **Deployment blindness.** The two-version rule comes from rolling deploys, which
  frameworks know nothing about by design. pgroll knows, and leaves "the old version
  is gone, run `complete`" as a **manual operator step** — the human step this
  document's retirement machinery automates.
- **Dynamic languages** cannot snapshot types, so typed old→new functions are
  unavailable to most of the ecosystem.

Tesl is a closed world — no raw SQL, every query and write shape visible, both
snapshots typed — which is the one precondition the others lack. pgroll was
considered as the runtime and not adopted: its backfills are SQL expressions rather
than proof-checked functions, its per-version views need `search_path` per connection
(session state, the pooler problem again), and it is a third-party dependency where
PostgreSQL built-ins (advisory locks, triggers, `CONCURRENTLY`, `NOT VALID`
constraints, `pg_stat_progress_*`) suffice.

## Design principles for the Tesl version

- **Declarations are the schema.** No separate DDL dialect. The diff is between two
  sets of `entity` declarations, both Tesl source.
- **The two-version rule is a compile-time check, not documentation.** A plan the
  compiler accepts is one where V7 and V8 can run against the same database at the
  same time. A plan that cannot satisfy that is labelled `OFFLINE` and must say so.
- **A migration is a `check` function, checked by the proof kernel.** Not a script.
  It is total over its declared result — the new row, or a typed rejection — and the
  return type's proofs are the acceptance criterion for every migrated row.
- **Fail closed, in the same direction as the rest of the language.** Unknown
  database state means the program does not start. A lossy diff without an explicit
  migration means the program does not compile.
- **Nothing is inferred that should be stated.** Renames, drops and resets are written
  down in the migration file by a person; the compiler proposes, never decides
  (consistent with the maintainer's 2026-08-17 rule for entity-scoped capabilities).
  But once stated, **everything mechanical is derived**: expand DDL, dual writes,
  backfill, lazy read, contract DDL, retirement, fence.
- **Parity.** Whatever the Postgres runner does per row, the Memory backend does in
  `tesl test`, so a migration function is a unit-testable Tesl function against
  snapshot fixtures.
- **Reuse what exists.** JSONB shape changes keep using the `fromJson` list. The
  catalog shape in `ir.ml` is the snapshot's skeleton. The whole-program query set
  judges a diff's blast radius and decides compatibility.

## The design

### 1. Versions: schema modules, not snapshots

- The program's schema version is an integer, `V1, V2, …`, linear. Two branches that
  both create `V8` collide in git, which is the desired outcome: the same schema
  cannot have two eighth versions. (Timestamps and semver were considered; both let
  incompatible histories merge silently.)
- **The unit of versioning is a `schema module`**, hand-written and committed, one file
  per version: `schema/notes/V8.tesl` declaring `schema module NotesSchema.V8`. It is
  the *only* thing this feature version-controls, and it may contain only what the
  data's shape needs — the compiler enforces the module kind, as Acadia does for
  `database module`:
  - `entity` declarations, with indexes and field proofs (proofs are part of the
    invariant history — a V7 row was **not** required to satisfy a proof added in
    V8, and the migration must reflect that);
  - the types, newtypes, ADTs and **facts** those entities name, the **checks** that
    mint those facts, the **codecs** JSONB columns need, and pure helper functions;
  - **nothing else**: no handlers, `api`, `server`, `main`, capabilities, `requires`,
    `database` declarations or effects. A schema module is shape plus the pure code
    that validates and encodes it.
- **Membership is declaration, not export.** Every `entity` *declared* in the schema
  module the `database` names is a table of that database — the `entities:` list of
  earlier drafts is gone. Exporting controls only what the *application* may name:
  a schema module exports facts, checks, codecs and helpers freely, and those are not
  tables; an unexported entity still has a table (and is reachable only from the
  migration file, which imports the module wholesale). One schema module belongs to
  exactly one `database` (naming it from two is a compile error), one `database` names
  exactly one schema module per version, and an `entity` declared anywhere other than
  a schema module is a compile error. A program with several databases has several
  schema module families.
- **The application imports the schema module explicitly**, like any other module:
  `import NotesSchema.V8 exposing [Note, Session, NonNegative, checkNonNegative]`.
  Every type is traceable to the file that declares it; there is no generated copy of
  the current version anywhere. The `database` declaration names the module too —
  `schema: NotesSchema.V8` — and that module reference, not a string, is the version
  the binary is built against.
- **Identity across versions is declared, not assumed.** `NotesSchema.V8.NonNegative`
  and `NotesSchema.V9.NonNegative` are two nominal facts, as `V8.UserId` and
  `V9.UserId` are two newtypes; without more, every proof-carrying or newtype column
  would need re-establishing in every migration and `Unchanged` would be a lie for
  proofs (maintainer, 2026-09-02). So the generator writes the **`same:` list** of the
  migration record (`Same ShopSchema.V8.NonNegative ShopSchema.V9.NonNegative`, §4)
  naming every type, newtype, ADT, fact and codec whose canonical
  **semantic closure** is identical in the two modules — for a fact, the transitive
  typed IR of every check that can mint it, the pure helpers they call, the codecs
  involved, the frozen stdlib functions reached and the primitive tags, not merely the
  check's own text (a helper that changed under an unchanged check changes the
  invariant); the compiler treats the two as one **inside the migration file only**
  (`NotesSchema.V7.ValidWordCount x` discharges `NotesSchema.V8.ValidWordCount x`). A declaration that
  changed gets no `same` line: it is a new type, and every entity with a column naming
  it is classified *needs re-validation* even if no column moved — the row function
  runs the new check over old rows, and `--schema dry-run` reports the rows that fail
  before the deploy. A person may delete a generated `same` line to force
  re-validation deliberately. The application itself never meets two versions (next
  bullet), so this is the only place identity is ever bridged. Facts that no column
  names — `Authenticated` — stay in the application and are never versioned.
- **One schema version per database, checked.** A program may import types from
  exactly the schema module its `database` names (plus, in a migration file, the
  previous one). Importing `NotesSchema.V7.Note` in a handler after the database moved
  to V8 is a compile error (MIG015) whose fix is the mechanical import bump the LSP
  offers. "Forgot to update an import" is therefore caught at the next compile, at the
  exact line, and cannot reach a build.
- **Many files, one bump.** A large application imports the schema module from dozens
  of files. A schema change then touches every one of them — and a **missed file cannot
  compile**: MIG015 fires at the exact import line of every file still naming the old
  version, and it is fix-all eligible, so one `source.fixAll` or `tesl --fix` rewrites
  them all. The risk is zero by construction; what remains is diff churn. Two
  mitigations, in order of preference: (1) import the schema module in few places by
  design — the entity types flow through function signatures, so only the modules that
  *name* `Note` in a signature or literal need the import, and in a well-factored program
  that is a handful of files, not dozens; (2) if churn still bites, a one-line
  **facade module** `schema/notes.tesl`: `module NotesSchema exposing [Note, …]
  reexporting NotesSchema.V8`, so the application imports `NotesSchema` and only the
  facade and the `database` line change per version. Tesl has no re-export today
  (exports are explicit and local); adding one is a small, general feature and a
  decision gate below. It keeps traceability at two greppable hops (facade → module)
  rather than one, which is the honest cost. What is **not** on the table is an
  implicit "import whatever version the database names": that would make the type's
  origin invisible at the import site, which is the property the maintainer asked this
  design to keep.
- **Older versions are frozen by hash, at compile time.** When `tesl --migrate` writes
  `migrations/notes/V8.tesl` it records the hash of `NotesSchema.V7`'s elaborated
  catalog in that file's header. From then on any edit to `V7.tesl` is MIG013 at
  compile time (and the boot gate re-checks the same hash against what the database
  recorded when V7 expanded). A frozen module's entities are **frozen record types
  with a column mapping**: they cannot be queried, inserted or named in a `database`;
  their only consumers are the migration file, the lazy read path and the backfill.
- **Changing the schema** is: copy `V8.tesl` to `V9.tesl` (or let `tesl --migrate`
  do the copy when no newer version exists), rename the module to `NotesSchema.V9`,
  edit the entities, point the application's imports and `database` at V9 (the
  compiler lists every site), then run `tesl --migrate` for the migration skeleton.
  Two schema versions live in the repo per database at minimum — the current one and
  the one before it, which the current migration is written against; older ones may
  be deleted once `--schema status` reports their generation final (§6 invariant 2).
- **What is generated and committed is small**: the migration file's skeleton
  (`migrations/notes/V8.tesl`, edited by a person) and the frozen stdlib slice it
  reaches (`migrations/notes/V8.stdlib.tesl`). Nothing about the *previous program's
  handlers* is recorded anywhere — an earlier draft generated a per-version "footprint"
  of the columns V7's code touched, and it was dropped (maintainer, 2026-09-02): a
  schema module cannot and should not know what the application does, and it does not
  need to. Two facts of the language make the frozen V7 module a **sound
  over-approximation** of V7's code: `insert E { … }` is a complete record literal, so
  any V7 insert writes every column V7 declares; and `select e from E` decodes the whole
  row, so any V7 read reads every column. The two-version check therefore assumes
  "V7 code may read and write every column `NotesSchema.V7` declares" and needs nothing
  else. (Precision — "V7 never inserted into `Session`" — could relax a `Legacy`
  requirement or a `ROLL-WINDOW RISK` label; it is a possible later refinement, not a
  soundness need.)
- The `database` declaration has one **mandatory** field for this feature,
  `migrations: NotesSchema.Migrate`, the module namespace under which the generated
  and hand-edited migration files live. Not optional and not a string: with several
  databases in one program the path is the key, and a default would be a guess.
- **What `schema:` and `migrations:` are, syntactically** — a small, explicit language
  addition, not a reuse of value expressions: a **module reference**, a new expression
  kind admitted only as the value of these two `Database` fields. `schema:` names an
  existing `schema module`; the integer schema version is its last path segment
  (`V8` → 8; anything else is a compile error). `migrations:` names a module *prefix*
  that need not exist as a module: the compiler discovers `NotesSchema.Migrate.V<n>`
  children by scanning the directory the prefix resolves to under the existing
  PascalCase-to-kebab-case file rule, orders them by `n`, and requires them to be
  contiguous. Nothing imports the prefix; the application never mentions the migration
  files at all (they are compiled because the `database` names their prefix).
- **No import alias is added.** A migration file bridges two schema modules with two
  plain module imports and qualified names — `import NotesSchema.V7`, `import
  NotesSchema.V8`, then `NotesSchema.V7.Note` and `NotesSchema.V8.Note` — which is
  how Tesl already disambiguates same-named types from two modules (§10.2, §10.3).
  Verbose, and exactly as explicit as the rest of the language; the generator writes
  the qualified names, and a person rarely types them.

  The principle (maintainer, 2026-09-02): **only the schema module is
  version-controlled by this feature.** Handlers, `main`, and `PostgresConfig` are
  deployed, not migrated; the feature keeps nothing of a handler at all.
- The compiled program embeds `SchemaVersion` (from the module the `database` names)
  and the SHA-256 of that module's elaborated catalog.

### 2. The two-version rule

With N instances behind a rolling deploy there are only three orderings of "run the
DDL" relative to "swap the code", and all three impose a compatibility requirement:

| Order | Requirement |
|---|---|
| A. DDL first, then roll | V7 code must run on the V8 schema |
| B. DDL during the roll | V7 and V8 code must both run on both schemas |
| C. Roll first, then DDL | V8 code must run on the V7 schema |

B is the general case and A/C are B with one side trivial. So at every instant
**the live schema must be compatible with every code version that is serving.** Two
consequences fall out:

1. Every change must decompose into an **expand** step compatible with V7 and V8, and
   a **contract** step compatible with V8 and V9. Nothing else is deployable without
   downtime. This is a law of rolling deploys, not a Tesl choice.
2. Given (1), expand can run **from the new instance at boot**: V7 tolerates it by
   construction. "Migrate, then deploy" as a separate pipeline step is a mirage for
   expand. What is *not* a mirage is the decision — rename or drop-and-add, which
   default, accept a loss — and that is made at compile time, in the plan.

**Decomposition table.** The compiler derives these from V7 snapshot + V8 program +
the migration file. "Not yet migrated" is a per-row fact recorded in a **row
generation column** `_tesl_v smallint not null` that every entity table carries
permanently (created with the table; added by `--schema adopt` on a pre-versioning
database, metadata-only because it has a default). The value is the entity's
**generation**, not the program's schema version: an entity's generation increments
only when a migration gives that entity a row function (`Migrate f`, `Rename`), and
stays put through every version in which the entity is unchanged or changed only in
ways a database default satisfies (a new `Maybe` column, a constant default, an
index, a `Legacy` dual write). The snapshot records, per entity, the generation each
schema version corresponds to. Without this, a global version in the marker breaks
the moment an entity sits out a release: `Session` rows at 7 stay at 7 through a V8
that did not touch `Session`, and a V9 migration of `Session` that selects `= 8` misses
every one of them — while advancing every row of every unchanged entity on every
release would be a marker-only rewrite of the whole database. With generations,
`Session`'s V9 migration is `gen 1 → gen 2` and selects `= 1`, whatever happened in
between. In the prose below "V7→V8" for an entity means "that entity's generation
before and after the V8 plan"; the plan header prints both (`User gen 3 → 4`).

`_tesl_v = g` is an **atomic statement about the whole row**: every column the
migration into generation `g` derives for this entity has been produced from the
row's current source values. Nothing may set it to `g` without having done all of
that, and nothing may raise it past the generation it actually completed.
The first revision used `new_col IS NULL` as the marker; that breaks the moment the
correct migrated value is itself `NULL` — a renamed `Maybe T`, a transform into
`Maybe T`, a row function that returns `Nothing` — because such a row is
indistinguishable from an unprocessed one, is re-eligible for every pass, and a
"final pass finds no `NULL`" can never terminate. `_tesl_v` is independent of the
values, works for every target type, and costs two bytes a row. Row functions may
still **never rewrite an existing column in place**: an in-place rewrite changes the
meaning of a column V7 is still writing, and no marker on the row can say which
writer's meaning the current value carries.

| Change in V8 | Expand (at V8 boot) | During V8's life | Contract (at V9 boot) | Class |
|---|---|---|---|---|
| new entity | `create table` | — | — | ONLINE |
| new `Maybe T` column | `add column … null` | — | — | ONLINE |
| new `T` column, constant default | `add column … not null default c` (metadata-only, PG 11+) | — | — | ONLINE |
| new `T` column, computed from the row | `add column … null`; V8 writes it; invalidation trigger on the source columns | lazy read via row fn — **projection only in V8**; usable inside SQL from V9 (or now, if `Maybe`); backfill | at V9 boot, after V7 retired: final pass, `set not null` (`NOT VALID` + `validate`), drop trigger | ONLINE |
| new field proof on existing column | — | V8 reads through `check`; V7 keeps writing unchecked values | `add check … not valid; validate` where expressible | ROLL-WINDOW RISK (prefer a validated new column + `Rename`) |
| `Rename a b` | `add column b null`; **V8 writes both** `a` and `b`; invalidation trigger on `a` | lazy read: `_tesl_v` below the target generation → take `a`; backfill | `drop column a`; drop trigger | ONLINE |
| type change / transform a new column with a row function | as rename, V8 writes `b` and, if `WriteBack g` given, `a`; trigger on `a` | lazy read via `f`; backfill | `drop column a`; drop trigger | ONLINE with `WriteBack`; otherwise ROLL-WINDOW RISK |
| column removed | V8 stops writing it, but V7 still **reads** it as non-null, so rows V8 inserts must carry a value: `Legacy c v` (constant → `set default c`, metadata-only) or `LegacyWith f g` (V8 dual-writes `g(row)`); `drop not null` alone only when the V7 snapshot proves V7 never decodes the column | — | `drop column` | ONLINE with `Legacy`; compile error without |
| entity removed | — (V7 still uses it) | — | `drop table` | ONLINE |
| new plain index | `create index concurrently` (outside transaction, background) | ready before it exists; slower until then | — | ONLINE |
| new unique index | `create unique index concurrently`; **readiness waits until it is `VALID`** (every new unique index; an `onConflict` on it is an additional hard dependency, not the criterion) | V7 may insert duplicates → build fails → drop `INVALID`, log keys, retry while V7 alive; once VALID, a V7 duplicate insert **fails** | — | ONLINE if V7 writes none of the indexed columns (index over new columns); otherwise ROLL-WINDOW RISK (§7) |
| index removed | — | — | `drop index concurrently` | ONLINE |
| `Maybe T` narrowed to `T` | as "computed column" into a new column | | drop old | ONLINE |
| primary key change | — | — | — | OFFLINE |
| `Reset` | — | — | — | OFFLINE (explicit data loss) |

**Writes from V7 instances during the window — the invalidation trigger.** (In every
example below `User` is at generation **3** in V7 and **4** in V8; the numbers in
the SQL are entity generations, never schema versions.) The
marker handles V7 *inserts* (V7 does not know `_tesl_v`; expand sets its `DEFAULT` to
`3` — `User`'s generation in V7 — so a V7 insert arrives marked unmigrated) and V7 *deletes*, but not a V7 *update*
of `a` on a row that has already been backfilled: `b` is now stale
and V8 trusts it. Neither code version can fix that — V7 does not know `b` exists and
V8 does not see the write. The only party that sees every write is the database, so
the invalidation lives there, for the window only. Expand installs one row trigger per
entity under migration, generated by the compiler, which knows exactly which V7 fields
each row function reads:

```sql
create function tesl_mig_v8_users() returns trigger as $$
begin
  -- a source column changed and the writer is not a V8 read-modify-write:
  -- that is a V7 writer. Mark the row unmigrated so the lazy read path and
  -- the backfill recompute every derived column from the new source values.
  if coalesce(nullif(current_setting('tesl.writer.users', true), '')::int, 0) < 4
     and (new.name is distinct from old.name) then
    new._tesl_v := least(old._tesl_v, 3);
  end if;
  return new;
end $$ language plpgsql;

create trigger tesl_mig_v8_users before update on users
  for each row execute function tesl_mig_v8_users();
```

**Who may write the marker, and how.** The re-review caught the first rule ("every V8
write stamps the new generation") stamping a row complete after an update that touched one unrelated
field of an unmigrated row. The rules that hold the atomicity above:

- a V8 `insert` writes every V8 column (plus the dual writes) and stamps `4`;
- a V8 `update` that touches **no** source column and **no** derived column of the
  migration leaves `_tesl_v` alone;
- a V8 `update` that touches a source or a derived column is emitted as
  **read-modify-write**: `select … for update` on the matching rows, materialise each
  through the row function if `_tesl_v < 4`, apply the update, write the full V8
  closure, stamp `4`. Blindly writing a derived column on a `3` row would be lost on
  the next lazy read (which would recompute it from the sources); blindly stamping `4`
  would lie. The compiler knows statically which `update` statements this applies to,
  only for entities with a migration in flight; the plan header lists them and the
  extra round trip they cost;
- an `upsert … onConflict … doUpdate [fields]` is two writers in one statement: the
  insert branch writes the whole row (stamp `4`, fine), but the conflict branch updates
  only the listed fields of a row that may be unmigrated, and `ON CONFLICT DO UPDATE`
  cannot call a row function. So, for an entity with a migration in flight: if the
  `doUpdate` list touches **no** source and **no** derived column, the upsert stays
  native and the conflict branch leaves `_tesl_v` alone (the non-updated columns come
  from the existing row and are still owed to the lazy path); otherwise the compiler
  emits it as a locked read-modify-write — `select … for update` on the conflict key,
  materialise, apply the listed fields, write the full closure, stamp — with `insert …
  on conflict do nothing` plus a re-select to close the insert race. The plan header
  lists the upserts this rewrites;
- backfill stamps `4` only in the same statement that writes every derived column,
  under the conditional predicate of §6;
- the trigger only ever **lowers**: `new._tesl_v := least(old._tesl_v, 3)`. A `2` row
  a V7 instance touches stays `2`; it is V7's migration, not V8's, that owes it work.

The trigger needs to tell a V7 writer from a V8 read-modify-write, and on a row that
was already `4` the marker alone cannot (both leave it `4`). So every V8
read-modify-write transaction first runs `select set_config('tesl.writer.users', '4', true)`
(transaction-local, so safe through a transaction pooler) and the trigger demotes only
when the writer's generation is **below** the trigger's target: `coalesce(nullif(
current_setting('tesl.writer.users', true), '')::int, 0) < 4`. The setting carries the entity
generation the writer materialised, and is set per entity touched
since one transaction may write several entities at different
generations. Ordered, not equality: while
V7 is not yet finalised the V6→V7 trigger (`User` gen 2→3) and the V7→V8 trigger (gen 3→4) coexist on the
same table, and a V8 read-modify-write — which chains 2→3→4 for the row — must satisfy
both; likewise a V9 read-modify-write must satisfy a V7→V8 trigger awaiting removal.
A writer at or above the target has materialised that target's closure by the
chaining rule; a writer below it, or no writer setting at all (V7 cannot produce
one), is demoted. With that, the trigger body is:

```sql
  if coalesce(nullif(current_setting('tesl.writer.users', true), '')::int, 0) < 4
     and (new.name is distinct from old.name) then      -- any source column
    new._tesl_v := least(old._tesl_v, 3);
  end if;
```
Cost: one PL/pgSQL row trigger on `UPDATE`, tens of microseconds, only on tables under
migration, for as long as V7 is **admitted** — that is, until V7 is retired (§6), which
is normally V9's boot. Dropping it earlier on the strength of "no V7 connection right
now" would let a rollback to V7 re-null a source column after the trigger is gone and
leave a derived value stale forever; the trigger's lifetime is tied to the state
transition, not to an observation. Only after retirement does one final `_tesl_v < 4`
pass make the backfill final. This is the mechanism
`pt-online-schema-change` uses (gh-ost reads the binlog instead); it is proven at
scale, not exotic. Rejected: `GENERATED ALWAYS … STORED` columns (not writable by V8,
SQL-expressible functions only) and "distrust `b` while V7 is alive" (correct, but
then every row must be recomputed once V7 is gone — a full-table rewrite).

**The one case no trigger fixes** is a new proof on an *existing* column with no new
column: V7 keeps writing unvalidated values for the roll window, and V8 reading them
through `check` rejects them. The plan labels this `ROLL-WINDOW RISK`, steers to the
new-column pattern (a validated copy, then `Rename`), and contract's `VALIDATE
CONSTRAINT` fails loudly if bad rows remain, leaving the contract pending rather than
silently applied.

**Trust boundary of the writer setting.** `tesl.writer.<entity>` is an ordinary GUC:
any client with write access to the table can set it and impersonate a newer writer,
and nothing in PostgreSQL prevents that. The design assumes what Tesl already assumes
everywhere else — **Tesl owns every write to its entity tables**, and the database
role the program runs as is not shared with other services, hand-run SQL or ETL. The
compile-time compatibility check is a whole-program statement and is only as true as
that assumption; an external writer is **unsupported** during a migration (it would
need to speak the generation protocol itself), and the manual says so under
`migrations#external-writers`. Read-only external access (reporting, BI on a replica)
is fine and unaffected.

**Why `WriteBack` exists.** In a rename, V7 requires `a NOT NULL`; V8 inserts must
keep writing `a` or V7's decode of V8-inserted rows fails. The compiler derives that
dual write (same value). In a transform a new column with a row function, writing `a` needs the inverse.
Either the migration supplies `WriteBack a b g` with `g : To.E -> a`'s type and the change is `ONLINE`,
or the plan labels it `ROLL-WINDOW RISK` (V7 instances may fail to decode rows V8
created, for the minutes the roll lasts) and requires that label to be acknowledged.

**The compatibility check itself** is static and cheap, because both write shapes
are known. Expand DDL is accepted iff:

- every column V7 code writes as `NOT NULL` still exists after expand and still
  accepts V7's writes (not dropped, not narrowed);
- every column V7 code reads still exists and still has V7's type, **and every row
  V8 writes carries a non-null value for it** if V7 decodes it as non-null — by V8
  still writing it, by a database default the plan set, or by a `Legacy` dual write.
  V7 decodes every column it declares, because a `select` returns whole entity rows;
- every column V8 code reads exists after expand, and every one it needs non-null is
  either written by V8, defaulted, or covered by a row function for the lazy path;
- no V8 query uses a column **introduced in V8** inside SQL unless it is `Maybe`;
  PostgreSQL evaluates `where`/`order`/`groupBy`/joins/aggregates on `NULL` before Go
  sees the row, and while V7 is admitted the column can be re-nulled at any moment, so
  no readiness gate can make it stable. The column is usable inside SQL from V9, whose
  readiness waits for the **final** backfill (stable, because V7 is retired first).
  The compile error names the queries and offers both ways out;
- every column V8 code omits on insert is nullable or defaulted after expand;
- a new unique index over columns V7 writes is flagged: V7 was compiled under a schema
  that permitted duplicates and will start failing on them the moment the index is
  `VALID`.

Contract DDL is accepted iff no V8 or V9 code reads or writes what it drops.

### 3. The diff and its classification

`tesl --migrate <entry.tesl>` loads the latest snapshot, elaborates the current
program, and computes per entity one of:

| Class | Examples | Plan output |
|---|---|---|
| **unchanged** | identical columns, indexes, proofs | `User unchanged` (required to be stated; a stale entry is an error, as in Acadia) |
| **additive, loss-free** | new `Maybe` column; new index; constant-default column; proof removed | `User additive` — the compiler derives the adapter (`Nothing` / the constant), emits the expand DDL, bumps no generation; a new entity is `Tag new` |
| **needs a value** | new non-`Maybe` computed column; new field proof; `Maybe T` narrowed; type change; newtype over an existing column; a removed column V7 still decodes (needs `Legacy`); **a fact or type a column names changed** (its check body or declaration differs, so no `same` line) — re-validation of every row through the new check | `User migrate migrateUser` with a generated function whose body has one `todo` per problem |
| **lossy** | column removed; entity removed; ADT constructor removed on a JSONB column | listed with what will be dropped at V9 contract and how many queries/handlers touched it — never silent |
| **ambiguous** | column removed and another of the same type added | proposed as `Rename name fullName` in a comment; the hole asks |
| **offline** | primary key change; `Reset` | `OFFLINE` in the header; the entity's rule list must contain `Offline "reason"` |

Classification uses the whole-program query set: a removed column that no query
reads and no handler writes is still lossy for the data, but the plan says so
("no query reads `User.legacyScore`; 0 handlers write it"), which is the information a
reviewer needs. `Money`/`MoneyRate` fields, which expand to several derived columns,
diff as one field.

### 4. The migration file: one record, ordinary functions

The migration file is a **folded record**, in the style Tesl already uses for
`Database { … }` and `App { … }`, plus ordinary functions. There are no contextual
keywords: every operation is a constructor of an ADT exported by a new stdlib module
`Tesl.Migration`. (Maintainer, 2026-09-02: the earlier keyword form — `Migrate`,
`Unchanged`, `Rename`, `Legacy`, `WriteBack`, `same`, `offline` — was a second little
language; this is one record.)

```tesl
# migrations/shop/v8.tesl — generated by `tesl --migrate`, edited by a person
module ShopSchema.Migrate.V8 exposing [migration, migrateUser]

import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Migrated(..), Same(..)]
import Tesl.Check exposing [Check.attempt, Attempt(..)]
import Tesl.Maybe exposing [Maybe(..)]
import ShopSchema.V7
import ShopSchema.V8

migration = Migration {
  from: ShopSchema.V7                       # module references (§1)
  to:   ShopSchema.V8
  same: []                                  # cross-version identities, generated (§1)
  entities: {                               # a record whose fields are the entity names
    User:    Migrate migrateUser [Rename name fullName]
    Session: Unchanged
    Legacy:  Drop                           # table dropped at V9 contract; V7 keeps using it
  }
}

fn migrateUser(old: ShopSchema.V7.User) -> Migrated ShopSchema.V8.User =
  let age = todo "V8 added `age: Int ::: NonNegative age`; ShopSchema.V7.User has id, email, name"
  Row (ShopSchema.V8.User { id: old.id, email: old.email, fullName: old.name, age: age })
```

**`Tesl.Migration`** — the whole vocabulary, as types. Honesty about what these are:
`Migration { … }` is a **compiler-known folded declaration**, in the same category as
`Database { … }` and `App { … }` today (a `Database` already types `entities: [Note]`
and `env "X"` contextually). It *looks like* ADT construction and its constructors are
exported from a stdlib module so they are greppable and importable like everything
else, but their arguments are typed **contextually by elaboration**, not by ordinary
monomorphic constructor signatures — `Default rank 0` and `Default label "unknown"`
could not both inhabit one ordinary `Rule`. The written signatures below use
*metavariables* (`field`, `value`, `fn`, `rowFn`, `typeRef`); the elaboration rules that
give them types follow the listing.

```tesl
type Entity
  = Unchanged                       # identical columns, indexes, and `same` types/facts
  | Additive (List Rule)            # only single-adapter changes; no row function; generation unchanged
  | Derived  (List Rule)            # compiler-derived row migration (rules only — e.g. a pure Rename);
                                    #   generation +1, no user function
  | Migrate  rowFn (List Rule)      # user row function `fn (Old.E) -> Migrated New.E`; generation +1
  | New                             # table created at expand
  | Drop                            # table dropped at contract
  | Reset                           # OFFLINE: discard every row

type Rule
  = Rename    field field           # compiler-owned identity: new = old, everywhere
  | Default   field value           # the constant a new non-Maybe column carries (also its SQL DEFAULT)
  | Legacy    field value           # V7-decoded column V8 dropped: the value V8 rows carry for it
  | LegacyWith field (fn)           # …computed from the new row (dual write)
  | WriteBack field field (fn)      # WriteBack oldField newField g: for a column V8 computes into
                                    #   `newField`, V8 also writes `g(new) : oldType` into the OLD
                                    #   column so V7 readers stay whole. Both endpoints named, for
                                    #   the same reason Rename names both: removed+added is ambiguous
  | Offline   String                # `Reset` / primary-key change acknowledgement

type Migrated a = Row a | Reject String

type Same = Same typeRef typeRef    # `Same ShopSchema.V8.NonNegative ShopSchema.V9.NonNegative`
```

**Elaboration rules** (the contextual typing that makes the record checkable; each
violation is a MIG diagnostic in the table under "Diagnostics"):

| position | type it must have | diagnostic |
|---|---|---|
| `from:` / `to:` | module references to `schema module`s, `to`'s version = `from`'s + 1 | MIG020 |
| `entities:` | a record whose field set is exactly the union of the two modules' entity names | MIG002 |
| `Migrate f rules` for entity `E` | `f : From.E -> Migrated To.E` — the specific pair, not a polymorphic shape | MIG021 |
| `Rename a b` | `a` a column of `From.E` absent from `To.E`; `b` a column of `To.E` absent from `From.E`; same column type | MIG022 |
| `Default b v` | `b` a new non-`Maybe` column of `To.E`; `v` a literal of `b`'s type | MIG022 |
| `Legacy a v` / `LegacyWith a g` | `a` a column of `From.E` absent from `To.E`; `v : a`'s type / `g : To.E -> a`'s type | MIG022 |
| `WriteBack a b g` | `a` old-only, `b` new-only, `g : To.E -> a`'s type | MIG022 |
| duplicate or conflicting rules on one column (e.g. `Rename a b` and `Legacy a v`) | — | MIG023 |
| `Same T U` | type references to same-kind declarations (fact/type/newtype/ADT/codec) in `From` and `To` | MIG024 |
| `Additive rules` | every change to `E` has a single derivable adapter given the rules | MIG016 |

What is genuinely new *syntax* is small and listed in §1: module references as record
values, entity names as record fields, bare column identifiers as values inside a
`Rule` (which `index [orgId]` and `onConflict [id]` already do inside an entity
context), and type references as `Same` arguments. What is new *machinery* is the
elaboration above — one contextual typing pass over a folded declaration, which the
compiler already has for `Database` and `App`.

**Row functions are ordinary `fn`s**, total by type: they return `Migrated New.E`,
`Row` with the new row or `Reject` with a reason. No `check` declaration kind is
extended, no proofless `ok` exists, and no HTTP status is written to be ignored. To
use a `check` inside one — the way a proof-carrying column is filled — the function
applies it **non-propagatingly** through `Check.attempt`, a small stdlib addition
with a direct precedent in `List.allCheck`:

```tesl
fn migrateUser(old: ShopSchema.V7.User) -> Migrated ShopSchema.V8.User =
  case Check.attempt ShopSchema.V8.checkNonNegative (defaultAgeFor old) of
    Failed reason -> Reject "user {old.id}: {reason}"
    Passed age    -> Row (ShopSchema.V8.User { id: old.id, email: old.email, fullName: old.name, age: age })
```

`Check.attempt` is a **compiler intrinsic**, not an ordinary library function — the
same category as `List.allCheck` (`→ Maybe (List T ::: ForAll P)`), which already
accepts a check as a first-class argument and intercepts its failure. Its typing rule:
for a check `f : (x: A) -> x: A ::: P x`, `Check.attempt f a : Attempt (A ::: P a)`,
where `type Attempt a = Passed a | Failed String`; `Passed` carries the proof-bearing
subject exactly as `let a' = check f a` would have bound it, `Failed` carries the
check's **message** with its HTTP status discarded — a migration is not an HTTP
response, but the validator's reason is exactly what `--schema dry-run`, the backfill
log and the lazy-path 500 should show, so it is not thrown away. Evaluation: call `f`;
a `fail` inside it becomes `Failed reason` instead of propagating. The runner maps `Reject` to: stop the backfill with
the primary key and reason; a 500 with the same reason in the log on the lazy path.
Invocation in a test is a plain call: `case migrateUser old of Row u -> … | Reject r -> …`.

**Rules the compiler enforces on a row function**, all syntactic, none semantic:

- Exactly one entry per entity in the union of the two modules; `Unchanged` on an
  entity whose shape changed, or `Additive` where a rule has no single adapter, is
  MIG002/MIG016.
- A **pass-through** column (present in both versions, no rule) must be initialised by
  the exact projection `title: old.title`; any other expression is MIG018. The
  compiler cannot prove `normalize old.title` equals `old.title`, so it does not try —
  the identity is syntactic.
- A **renamed** column must be initialised by the exact projection of its old name
  (`fullName: old.name`); anything else is MIG017. The record literal stays complete —
  no compiler-injected fields, no incomplete-literal exception — and the SQL rewrite,
  lazy decoder, backfill and dual write all implement the one identity the `Rename`
  rule declares. A real transformation is a new column plus a row function, and gets no
  identity rewrite.
- A **new** column is the only place an arbitrary expression is allowed, and it is
  where the generator writes the `todo`.
- The function may call functions of either schema module, functions declared in the
  migration file, and the standard library (frozen with it, §11) — never the
  application. Schema-module facts are **sealed** (§5), so "every check that can mint
  this fact" is the finite set in the declaring module.
- `todo "reason"` is a builtin expression that unifies with any type and is **always**
  a compile error carrying its message, so the generator can write a well-typed file
  that refuses to build.

**Derived migrations.** `Derived [Rename authorId ownerId]` is a pure rename: it needs a
generation bump and a backfill (the new column must be filled for old rows) but no user
function, so `Migrate` would be wrong and `Additive` would be a lie. The compiler
derives the row function from the rules. A migration whose every change is a `Rule`
with a compiler-derivable adapter is `Derived`; the generator picks it.

**`Additive [Default rank 0]`.** A new non-`Maybe` column needs a constant, and the
entity declaration has no default annotation by design (a persistent default is a
migration fact, not a shape fact); the `Default` rule supplies it, and it becomes both
the adapter for old rows and the column's SQL `DEFAULT` so V7 inserts satisfy it. A
new `Maybe` column needs no rule: `Nothing` is the only adapter.

**Tests.** The migration file may contain ordinary `test` blocks over its own pure
functions. The generated **compatibility test** lives in its own module (§4b).

### 4b. The generated compatibility module

`NotesSchema.Migrate.V8Compat` is generated, self-contained, and **frozen with the
migration**: it imports the two schema modules, the migration module and a generated
support module (`NotesSchema.Migrate.V8Support`, holding the precisely typed
`insertOldNote : NotesSchema.V7.Note -> Unit` and friends) — and **nothing from the
application**. Importing the application's `database` would (a) bind the test to the
production backend (`with database X` means X's configured backend, §11.14) and (b)
silently re-point a committed V8 test at whatever schema module the application names
later. So the tests run as unnamed tests against the automatic in-memory store, which
models `_tesl_v` and the lazy read path exactly as the PostgreSQL decoder does; both
schema modules' entities are legal SQL sources there and only there.

What is generated is **structural**: an old-shaped row is inserted at its generation,
read back through the new decoder, found by a rewritten predicate, and — where
`WriteBack` exists — read back through the old shape. What is **not** generated is a
universal "every valid old row migrates successfully" property: a row function is
allowed to `Reject` old rows the new invariant excludes, so such a property would fail
legitimately. Fixture rows are a `todo` the developer fills (or a `property` with
generators only when the row function is syntactically total: no `Reject` and no
`Check.attempt` in its body).

**Privilege boundary of the support module.** `insertOldNote : NotesSchema.V7.Note ->
Unit` is not a harmless helper: it writes a row in a *historical* shape with a
historical generation marker, bypassing the current entity's invariants, which is
precisely what the whole protocol otherwise forbids. So it is a **compiler-generated,
effectful, test-only** function: it requires the Memory store's `dbWrite` plus a new
capability `schemaTest` that only a `…Compat` module is granted; the generated
`…Support` module is marked test-only and importing it from any other module kind —
the application, a migration file, another test — is MIG025; it does not exist in a
production build at all. Store isolation between compatibility tests is the existing
per-test reset of the Memory store that every emitted test function already gets. Whether *production* rows are accepted is the binary's
`--schema dry-run`, not a unit test.

### 5. What proofs buy here

**Sealed facts.** A fact declared in a schema module and named by an entity column is
**sealed**: only `check` functions declared in that same schema module may mint it
(`ok x ::: NonNegative x` anywhere else — an application `check`, `auth` or `establish`
— is MIG019). Consumption is unrestricted. Without this, "every check that can mint
the fact", which `same` hashes and from which a PostgreSQL `CHECK` may be derived, is
not a finite set, and a stored invariant could be established by a validator the
schema never saw. Facts not named by a column (`Authenticated`) are unaffected.

`User` in V8 declares `age: Int ::: NonNegative age`. The generator cannot invent a
`NonNegative` fact, so the hole is left. The developer writes:

```tesl
fn migrateUser(old: ShopSchema.V7.User) -> Migrated ShopSchema.V8.User =
  case Check.attempt ShopSchema.V8.checkNonNegative (defaultAgeFor old) of
    Failed reason -> Reject "user {old.id}: {reason}"
    Passed age    -> Row (ShopSchema.V8.User { id: old.id, email: old.email, fullName: old.name, age: age })
```

`Reject` is the row function's one way out, and it is in its return type. During
backfill it stops the backfill and reports the primary key and reason; on the lazy read
path it is a 500 for that row with the same reason in the log — the row is unreadable
under the new invariant, which is the truth. The alternative — silently
coercing — is unavailable by construction, because only `check` mints
`NonNegative`. So the
acceptance criterion for every migrated row is exactly the invariant the rest of the
program relies on. Record-level proofs (`? Fact`) work the same way. This is the
property Lamdera cannot state (Elm types have no refinement) and Acadia handles only
via constructor discipline.

The binary's `--schema dry-run` runs the row functions over the real table **read-only** (no
writes, so no dead tuples, no WAL) and prints the rows that would fail, with
`--sample 1%` for a quick answer, so "will the proof reject any of our 40 million
rows" is known before the deploy, not during it.

### 6. Lifecycle of one migration

**Invariants the runtime holds (the correctness protocol).** These are the design,
not implementation detail; the review of 2026-09-02 found the first draft
describing each of them loosely enough to be wrong.

0. **Admission is a stored state, `tesl_schema.min_version`**, the oldest version
   allowed to hold a connection. It only ever increases, and only inside the
   *retire* transition below. Everything that must never happen while V7 could still
   write — dropping its trigger, calling its backfill final, setting `NOT NULL`,
   dropping its columns, using a new column inside SQL — is sequenced **after**
   `min_version` passes 7, never after an observation that V7 seems absent.
1. **Fence — transaction-scoped, two statements.** Every **write** transaction a
   `V<n>` instance runs (reads use the lock-free admission of §13) begins with `select pg_advisory_xact_lock_shared(fence(schema, n))` and
   **then, as a separate statement**, `select min_version from tesl_schema`; if
   `min_version > n` the transaction rolls back before any program statement runs, and
   the instance shuts down. Two statements, not one: under READ COMMITTED each
   statement takes its own snapshot at *its* start, so the read sees whatever
   committed before the lock was granted — whereas a single `select lock(), min_version
   …` takes its snapshot before blocking on the lock and can return the pre-retirement
   value after retirement has committed. Tesl transactions run at PostgreSQL's default
   READ COMMITTED (the runtime sets no isolation level; verified 2026-09-02), which is
   what makes the two-statement form sufficient. Should a stronger level ever be
   offered, the admission read must become `select min_version from tesl_schema for
   share` on the singleton row — under READ COMMITTED it re-evaluates to the updated
   row, under REPEATABLE READ/SERIALIZABLE it raises a serialization failure, both of
   which are refusals — at the cost of row-lock (multixact) traffic on one hot tuple;
   that is the reason it is not the default. A single autocommit query is wrapped the
   same way; `pgx`'s pipeline mode sends `BEGIN`, both fence statements, the query and
   `COMMIT` in **one round trip**, so the cost is server-side lock-table work (tens of
   microseconds), not latency. That one-round-trip shape is also a **tested
   deployment condition**, not an assumption about every proxy: it requires the
   pooler to keep one backend from `BEGIN` through both fence statements, the
   program's statements and `COMMIT`, under the extended protocol with pipelining
   (`pgx`'s). That is normal transaction-pooling behaviour — PgBouncer supports
   pipelined extended-protocol transactions from 1.21 — and the manual keeps a list of
   the poolers the compatibility suite is run against; anything not on it is
   unsupported rather than "probably equivalent". **Retiring V<n>** is one transaction: take
   `pg_advisory_xact_lock(fence(schema, n))` exclusively — which waits for every
   in-flight V<n> transaction and blocks new ones — set `min_version = n + 1`, commit.
   Because admission is read under the shared lock and written under the exclusive
   one, no V<n> transaction can ever run against a state that has retired it; a paused
   V<n> process either has no transaction open (and its next one is refused) or holds
   the shared lock (and retirement waits for it). Nothing here depends on *which
   backend session* a statement lands on, so a transaction-mode pooler (PgBouncer,
   RDS Proxy, …) is fine — the previous revision's session-level fence needed
   session-affine connections, tried to detect poolers with a `pg_backend_pid()`
   probe that is probabilistic under low load, and could orphan a session lock on a
   backend the pooler kept; that whole class of problem is gone. A deployment that
   *knows* it has direct connections may opt into the session-level variant
   (`PostgresConfig { fence: Session }`) to save the per-transaction work; the default
   is the transaction-scoped one, because a wrong opt-in is silent and a slow default
   is not. The heartbeat table (`tesl_schema_instances`) is observability — it tells
   `--schema status` who is alive — never the guard.
2. **Backfill writes are conditional on what they read, and an entity's generations
   chain one step at a time.** The pass into generation `g` selects rows with `_tesl_v
   = g-1` exactly — never `< g` — because a `g-2` row does not yet have the shape the
   row function is typed against; it is the previous generation's final pass, running
   concurrently in the same binary (§6 step 6), that brings it to `g-1`, after which
   this pass picks it up. A binary embeds the two most recent **migration files**
   (`V<n-1>.tesl` and `V<n>.tesl`, with their frozen stdlib slices), and the boot gate
   (§8) refuses to start while any entity still has rows two generations behind — a
   state the previous version's fleet was responsible for finishing — so those two
   files always suffice: older ones may be deleted once `--schema status` reports them
   finalised, and the compiler requires exactly those two to be present. The update
   predicate is `_tesl_v = g-1 AND <every source column> IS NOT DISTINCT FROM <the value
   read>`, and the write sets every derived column and `_tesl_v = g` together. A V7 update between
   the read and the write makes the predicate fail; the row stays unmigrated (the
   trigger already re-marked it) and the next pass recomputes. Without this,
   read `a = x`, V7 writes `a = y`, write `b = f(x)` stores a stale value that no
   trigger will ever revisit, because that write did not change `a`. The lazy read
   path has no such window: it computes from the row it just fetched.
3. **Lazy read fixes decoding, not SQL — so a column is introduced in one version
   and used inside SQL in the next.** A row function runs in Go after the rows are
   fetched; a new column used in `where`, `order`, `groupBy`, a join or an aggregate is
   evaluated by PostgreSQL first, on `NULL` — **unless the column's window value is in
   the compiler's SQL-expressible subset**, which in v1 is exactly two forms, both
   declared, never inferred: a `Rename a b` (identity, `b` is `a`) and a constant
   default. For those the emitter rewrites the window SQL per clause:

   | clause | rewrite (rename) | note |
   |---|---|---|
   | `where b <op> $1` | `(b <op> $1 or (b is null and a <op> $1))` | three-valued logic preserved: a row with both `NULL` is excluded either way; both indexes usable via BitmapOr |
   | `isNull`/`isNotNull b` | `(b is null and a is null)` / `(b is not null or a is not null)` | |
   | `order b`, `groupBy b`, `selectCountBy`/`selectSumBy` on `b` | `coalesce(b, a)` | an index on `b` alone does not serve the sort during the window; the plan header says so |
   | `innerJoin E on x.b Y.k` | `coalesce(x.b, x.a)` in the `ON` | |
   | `selectSum`/`Max`/`Min` over `b` | `coalesce(b, a)` | |
   | `unique index [b]`, `onConflict [b]` | **not rewritable** — a conflict target must be a real column | MIG008 stays; declare the unique index in the next version |
   | constant default (`Default c` on a new column) | the literal `c` stands in for the missing value: `coalesce(b, c)` | no old column exists; the rewrite is against the constant |

   Anything outside that table — a Go-computed column, an expression over several
   columns — is not SQL-expressible and is held to the rule that follows. The subset
   is a compiler-recognised list, extended deliberately, never a property inferred
   optimistically. Gating V8's readiness on the backfill
   (the first revision) deadlocks a normal roll: V7 keeps serving while V8 is unready,
   so V7 never drains, so the backfill is never final, so V8 is never ready — and even
   a "complete" scan is invalidated by the next V7 update. So: a V8 query that uses a
   V8-introduced non-`Maybe` column inside SQL is a **compile error** naming the query
   and offering the two ways out — declare it `Maybe` (the program owns the `NULL`
   semantics) or use it from V9. In V9 the column is authoritative because V7 was
   retired first and the final pass then ran; V9's readiness waits for that final
   pass (V8 serves meanwhile; no deadlock, because V8 does not need the column in SQL).
   This is the same expand/contract rhythm as everything else: the *meaning* of the
   column contracts one version after its *storage* expands.
4. **Readiness gates every new unique index**, not only the ones an `onConflict`
   targets (§7): uniqueness is entity semantics the Memory backend already enforces,
   and a V8 instance serving before the index is `VALID` could itself insert the
   duplicate that fails the build.
5. **Invalidation trigger** on every entity under migration for as long as V7 is
   admitted — until retirement, not until V7 looks absent (§2).
6. **Safety never rests on a lease; one lock order everywhere.** The only locks that
   guard correctness are the fence keys — transaction-scoped for everything that runs
   in a transaction, and (invariant 7) session-scoped on one dedicated connection for
   the DDL that cannot. Who *does*
   the work — expand, backfill, index builds, contract — is decided by a lease row in
   `tesl_schema_leases (name, holder, expires_at)` taken by compare-and-swap and
   renewed by heartbeat, and every one of those jobs is idempotent and safe under two
   holders (DDL uses `IF NOT EXISTS` forms and is re-checked against the catalog;
   backfill batches carry the conditional predicate; a second concurrent `CREATE INDEX
   CONCURRENTLY` fails harmlessly on the name). A lease that expires under a paused
   holder therefore costs duplicated work, never a wrong result. Every command that
   takes more than one lock takes them in this order: (1) the `boot` lease, (2) fence
   keys in ascending version order, (3) job leases (`backfill`, `index:<name>`). The
   offline path is the case that made this matter: the first draft had boot taking
   the boot lock and then fences, and offline taking every fence and then the boot
   lock.
7. **Nontransactional DDL is fenced too.** `CREATE INDEX CONCURRENTLY` and `DROP INDEX
   CONCURRENTLY` run in autocommit, so the transaction fence cannot cover them; a
   worker that took its lease in a fenced transaction, was paused, and resumed after
   its version was retired would otherwise issue DDL nobody admitted — recreating a
   unique index a later version dropped, for instance. So every such statement is
   issued on a **dedicated DDL connection** that holds `pg_advisory_lock_shared(fence(
   schema, n))` **session-level** for the instance's whole life, taken before the
   admission read like any fence. Retirement's exclusive lock therefore waits for it,
   paused process or not — **given** that the connection is session-affine. That is
   the one assumption in this design that the runtime cannot verify from inside, and
   it is stated as a **trusted deployment requirement**, not as something that fails
   closed on its own: a transaction pooler that resets session state between
   assignments releases the lock silently, and one that does not may still run the
   admission read and the later DDL on different backends, so "a leaked lock blocks
   retirement" holds for some misconfigurations and not others. Hence
   `PostgresConfig { ddlConnection: … }` — a DSN that must reach PostgreSQL directly
   or through a session-mode pooler, documented as such, distinct from the request
   pool's DSN when that goes through a transaction pooler. The clearest deployment is
   the **dedicated schema worker**: `./app --schema worker` runs the DDL and backfill
   jobs and nothing else, as a single-replica Deployment with a direct DSN, and
   request instances then skip those jobs entirely (they still expand at boot, which
   is transactional). Where no pooler is in the path, the default — every instance
   may take the jobs over its own `ddlConnection` — is fine. Two defences in depth
   remain, because a requirement is still a requirement: the objects
   such DDL creates carry the creating version in their name (`users_email_idx_v8`),
   so a straggler can never satisfy or collide with a later version's declaration and
   contract can drop `*_v<retired>` leftovers by name; and retirement additionally waits
   until `pg_stat_progress_create_index` shows no build in the schema — server-side
   truth about executing statements, which a paused client cannot fake.

**At V8 instance boot** (`OpenPostgres`), in this order:

1. Take the `boot` lease (compare-and-swap on `tesl_schema_leases`, renewed every
   5 s while the sequence runs). Not obtained: wait for it to change hands or expire,
   then re-read `tesl_schema` — another instance is doing the work below, and every
   step is idempotent if two ever overlap.
2. Register in `tesl_schema_instances` and start the heartbeat (every 15 s).
3. Read `tesl_schema`. Cases in §8. In the normal case the database is at `V7
   expanded`, `min_version = 6` or `7`.
4. Verify the recorded V7 snapshot hash matches this binary's embedded copy of
   `schema/V7.tesl`. Mismatch: refuse (someone edited history).
5. **Retire V6** if `min_version = 6`: in one transaction take
   `pg_advisory_xact_lock(fence(schema, 6))` exclusively with `lock_timeout`; held by
   any in-flight V6 transaction → a V8 is booting while
   V6 still runs, which the two-version rule forbids: **refuse** to start, naming the
   count from `pg_locks`. Acquired → `min_version = 7`, commit, release. From this
   point no V6 connection can ever be admitted.
6. **Finish V7's migration**, now that nothing can re-null its columns: hand the
   backfill leader (below) the *final* pass for every entity V7 migrated; when an
   entity's final pass finds no row with `_tesl_v < 7`, run its contract steps — `add
   constraint … check (col is not null) not valid`, `validate constraint`, `set not
   null` for each V7-introduced column, drop the V6→V7 invalidation trigger, `drop
   column` for the V6 columns V7 stopped using — each in its own short transaction
   with `lock_timeout`. Record `(7, 'contracted')` when every entity is done. Boot
   does not wait for this.
7. **Expand V7→V8**, if not yet expanded: each statement in its own short transaction
   with `SET lock_timeout = '2s'` and bounded retries with backoff, because a
   metadata-only `ALTER TABLE` still needs `ACCESS EXCLUSIVE` for a moment and must
   not queue behind a long report query while every other request piles up behind
   it. Install the V7→V8 invalidation triggers the same way. Record `(8, 'expanded',
   snapshot_hash, migration_hash)`.
8. Release the `boot` lease. Other V8 instances waiting at step 1 now see `V8
   expanded`, verify, and proceed.
9. Open the pool. From here every transaction begins with the fence statement
   (invariant 1); the first one doubles as the admission check for this instance.
9b. Open the **DDL connection** (invariant 7) unless this instance runs with a schema
    worker elsewhere: on `ddlConnection`, `select pg_advisory_lock_shared(fence(schema,
    8))` session-level, then — a separate statement — `select min_version from
    tesl_schema`; if not admitted, close and refuse. That exact backend session is kept
    for the instance's life; if it drops (failover, restart) every job on this
    instance pauses until it has been reopened with the same two steps. Readiness
    (step 11) requires it to be open and admitted.
10. **Index builds.** For each new index, on a timer, try the `index:<name>` lease;
    the holder builds. An `INVALID` index of that name may be a dead builder's remnant
    **or a build still running on the server** — `CREATE INDEX CONCURRENTLY` exposes
    the index as invalid for the whole build, and a builder whose lease expired under a
    long pause may still have the statement executing. So before dropping, the holder
    checks `pg_stat_progress_create_index` (PostgreSQL 12+, hence the floor) for an
    active build on that index; if one is running it waits and re-evaluates rather
    than dropping (a `DROP INDEX` would in any case block on the build's lock and then
    destroy a possibly *valid* result). Only an invalid index with no active build is
    dropped, then `CREATE INDEX CONCURRENTLY` runs — on the dedicated DDL connection
    that holds the instance's session-level fence (invariant 7), never on a pooled
    request connection. A failed unique build is
    dropped, logged with the offending keys, and the lease released so the next tick
    retries. Two builders racing on an expired lease is harmless: the second `CREATE`
    fails on the name. `tesl_schema_index (name, state, attempts, error)` is
    observability.
11. Report ready when: steps 1–9b are done (milliseconds); every **new unique index**
    is `VALID`; and every column this version uses inside SQL that was introduced in
    V7 has a **final** backfill. Only the last two can take long, and only when the
    plan header said they would.

**Many instances booting at once, or before the first migration has run.** Migrations
are strictly serialised: at most one expand or retirement is in progress per schema at
any moment, and everything an instance does at boot is safe to lose a race on.

- The `boot` lease admits one instance to steps 3–7; the others wait, then re-read
  `tesl_schema` and find the work done. No instance reports ready while waiting, so a
  fleet of ten booting into a V7 database has one expander and nine readers — the
  same for a fresh, empty database, where one instance creates everything and the
  others find it created.
- The lease is a liveness aid, not the guard: if it expires under a paused holder and
  a second instance runs the same steps, nothing goes wrong. Every DDL statement is an
  `IF NOT EXISTS` form re-checked against the catalog; every `tesl_schema` state row is
  inserted under a unique key `(version, step)` so a second recorder gets a duplicate
  and reads the first's row instead; `min_version` advances by compare-and-set
  (`update … set min_version = 7 where min_version = 6`) under the exclusive fence, so
  two retirers cannot both succeed; the trigger and marker rules are idempotent.
- Two **different** versions booting together (a V8 roll interrupted by a V9 roll): the
  lease serialises them in whichever order they arrive. V9 finds either a V7 or a V8
  expanded database; in the first case it waits for V8's expand, then refuses at step
  5 if any V7 transaction is still admitted and V8 rows are not final, otherwise
  proceeds. A V8 instance that boots *after* V9 expanded finds itself one version
  behind the database — the rollback row of §8 — and starts, because V9's expand is
  V8-compatible by the two-version rule.

**During V8's life:**

- **Lazy read.** Emitted queries on an entity under migration select `_tesl_v`, the
  old and the new columns; the decoder, when `_tesl_v` is below the entity's target
  generation, applies the row functions
  the row still owes, one version at a time (a `6` row goes through V7's function and
  then V8's — both are in the binary, §6 invariant 2), to the row's stored view. Optional write-back on read (a `WriteBackOnRead` rule) is off by
  default: it turns reads into writes and doubles lock contention under load.
- **Dual write.** Emitted inserts/updates write the V8 columns and every V7 column the
  plan requires (`Rename`: the same value; transform with `WriteBack g`: `g`; removed
  column with `LegacyWith f g`: `g`).
- **Backfill.** One instance holds the `backfill` lease; if it dies, another takes
  over, and two overlapping holders only duplicate work. Keyset pagination by primary
  key, batches of 1 000–5 000 rows, each batch its own transaction, `UPDATE … FROM
  (VALUES …)` with the conditional predicate of invariant 2, progress in
  `tesl_schema_backfill (entity, from_version, last_pk, rows_done, final_at)` — progress
  is **per entity**, because the marker is one statement about the whole row. Throttled
  (sleep between batches, configurable), because a backfill that saturates the write
  path is an outage by another name. Rows a V7 update re-nulled through the trigger,
  or whose predicate failed, are picked up by the next pass. While V7 is admitted the
  backfill can only ever be **provisional** ("no rows below the target generation at the last scan"
  — an observation `--schema status` shows, and nothing depends on). It becomes
  **final** only after V7 is retired (V9 boot, step 5), by an exhaustive keyset pass
  over rows below the target generation (`_tesl_v < 4` in the running example) that runs when no writer can re-mark anything; it terminates
  because the marker, unlike a `NULL` test, does not depend on the migrated value,
  and it is normally tiny because the provisional passes did the work. Recorded per
  entity (`final_at`); V9's readiness and contract depend on it.
- Monitoring: `--schema status` and an OTel gauge (`tesl_schema_backfill_rows_remaining`).

**At V9 boot:** steps 5–6 above retire V7 and finish V8's migration (final pass, `NOT
NULL`, trigger and column drops). Rollback V8 → V7 is possible until that moment;
rollback V9 → V8 for the whole life of V9, because V8 is retired only at V10's boot
and a V8 binary that starts before then passes the admission check. An operator who
wants the rollback window to V7 closed earlier — and V7's trigger gone earlier — runs
`--schema retire` on any V8 instance; it performs step 5 for V7 and starts step 6.

**OFFLINE class:** `--schema apply-offline` exists for the two cases that
cannot be decomposed. See "The downtime path" below for the procedure, the
guarantees, and the compiler error that leads the user to it.

### 7. Indexes: non-blocking to build, not always risk-free

Adding an index is the most common schema change in a running system. Building one
never blocks the running program — but "non-blocking" and "`ONLINE`" are not the same
word: a **unique** index over columns V7 still writes is `ROLL-WINDOW RISK` (below),
because it changes what V7's inserts are allowed to do. Plain indexes and unique
indexes over new columns are `ONLINE`. Two things have to be handled that the earlier
draft did not.

**How they are built.** Never inside a transaction and never with a plain `CREATE
INDEX` on a populated table (that holds a `SHARE` lock that blocks every write for the
whole build). Always `CREATE INDEX CONCURRENTLY` (two table scans, no write lock), on
the instance's dedicated, session-fenced DDL connection (§6 invariant 7), under a
version-suffixed name, tracked in `tesl_schema_index (name, state, error, attempts)`. Dropping an index at contract uses `DROP INDEX CONCURRENTLY`. A
build takes seconds to tens of minutes depending on table size; V7 and V8 both keep
serving throughout. On an empty table the plain form is used (instant). An index that
already exists with the same **columns and uniqueness** satisfies the declaration
regardless of its name, as §11.8 already specifies.

**Every new unique index gates readiness; plain indexes do not.** A plain index is a
performance hint: a V8 instance is ready before it exists and merely runs slower until
it does (the plan prints the estimate). A unique index is **entity semantics**: the
Memory backend enforces it from the first test, so a V8 instance that served before
the index is `VALID` would be running under weaker semantics than the tests it passed
— and could itself insert the duplicate that fails the build. On top of that, `upsert
… onConflict [cols]` compiles to `ON CONFLICT (cols)`, which PostgreSQL rejects with
"there is no unique or exclusion constraint matching the ON CONFLICT specification"
until the index exists. So every V8 instance polls `pg_index.indisvalid` for each new
unique index and reports **not ready** until the build has finished. The rolling
deploy simply takes as long as the build; V7 keeps serving the whole time. (The first
revision gated only `onConflict` targets; the re-review is right that uniqueness
matters whether or not a query names it.)

**Exactly one builder.** Every V8 instance passes the boot lock, so ownership of a
build cannot come from reading a state table — two instances reading `pending` at
once would both build. The builder is whoever holds the `index:<name>` lease; a dead
builder's lease expires, and the next instance's timer tick — after confirming via
`pg_stat_progress_create_index` that no build is still executing — drops the `INVALID`
remnant and starts again. Ownership here is about not wasting work, not about safety:
two builders racing is a harmless failure on the index name (§6 invariant 6).
`tesl_schema_index` records what happened; it decides nothing.

**A new unique index changes V7's behaviour, and the plan says so.** V7 was compiled
under a schema that permitted duplicates. The moment the index is `VALID`, a V7 insert
that duplicates an existing key fails with a constraint error the V7 code never
expected — a 500 on a request that succeeded yesterday, for the rest of the roll
window. There is no protocol that avoids this while both versions run (building only
after V7 is gone would make V8's readiness depend on V7's absence, which deadlocks a
rolling deploy). So the classification is honest: a unique index over columns **V7
declares** is `ROLL-WINDOW RISK` (any V7 insert writes every declared column, so the
frozen module alone says which indexes are at risk); a unique index over **new columns
only** is `ONLINE`, because V7 never writes them. The dry-run duplicate pre-check below is what makes the risk small in
practice: if the data has no duplicates today, V7 producing one during a roll window
is the same race the program already had.

**Duplicates during the build.** V7 keeps inserting during the build and does not know
about the constraint. If it inserts a duplicate, the concurrent build fails and leaves
an `INVALID` index behind. The builder drops it, logs the offending key values, and
retries with backoff for as long as V7 is admitted; a V7 that inserts duplicates at a
steady rate can keep the build failing, which keeps V8 unready, which keeps V7
serving — a livelock, not a deadlock, and exactly the `ROLL-WINDOW RISK` the plan
already labels a unique index over V7-written columns with. Once V7 is retired the
build either succeeds or the duplicates are real data the operator has to resolve,
and `--schema status` says which rows.
Before any of that, the binary's `--schema dry-run` runs the duplicate query for every new
unique index against the real data (`select cols, count(*) … group by cols having
count(*) > 1`) so pre-existing duplicates are found before the deploy, not during it.

**The Memory backend** enforces a new unique index from the first test run, exactly as
today. The parity gap during a live build (Memory enforces, Postgres does not yet) is
the roll window only, and the readiness gate is what keeps V8 code from observing it.

**Index on a column being added.** Built concurrently while the column is still
mostly `NULL`; `NULL`s do not collide in a unique index, and the index is maintained
by the backfill's writes like any other. No ordering constraint between backfill and
index build.

### 8. The boot gate

| `tesl_schema` state vs binary `V<n>` | Behaviour |
|---|---|
| no `tesl_schema` and no user tables | fresh database: create the `tesl_schema*` tables, the lease rows and the `tesl_admit` function, then everything at `V<n>`, record it, start (`tesl run` on an empty dev/CI database still just works) |
| no `tesl_schema`, user tables present | refuse: a pre-versioning database; print `--schema adopt`, which verifies the live columns against the snapshot and records the version |
| `min_version > n` | refuse: this version has been **retired** (a later version booted, or an operator ran `--schema retire`); redeploy the current version |
| `V<n>` expanded, `min_version ≤ n` | start; retire `V<n-2>` and finish `V<n-1>`'s migration if not yet done (steps 5–6) |
| `V<n-1>` expanded, `min_version ≤ n-1` | **expand `V<n>` automatically**, then start |
| `V<n+1>` expanded, `min_version ≤ n` | start — this is a **rollback**, and the two-version rule guarantees this binary still runs |
| `V<n-2>` connections still hold their fence key | refuse: a `V<n>` is booting while `V<n-2>` still runs; deploy versions in order |
| behind by two or more | refuse: deploy versions in order (each expand is verified against the *previous* schema module only) |
| some entity still has rows **two generations** behind the generation `V<n-1>` gave it (the previous migration is not final) | refuse: this binary carries only the `V<n-1>` and `V<n>` migration files and cannot bring those rows forward; let the running `V<n-1>` fleet finish (or run `--schema contract` there) first |
| hash differs at the same version | refuse: an applied snapshot or migration's behaviour was edited (§11) |
| `OFFLINE` plan pending | refuse with the exact `--schema apply-offline` command (see "The downtime path") |
| a new unique index is not yet `VALID`, or a column this version uses inside SQL has no final backfill | start, but report **not ready** until it is (§6 step 11) |

The Memory backend is always at `V<n>` (fresh per test). No environment variable
turns the gate off; a development database is the first row, a test database is the
Memory backend.

### 9. Behaviour under load

The earlier draft's "one transaction" design would have held `ACCESS EXCLUSIVE` on
the table for the entire backfill — minutes for a few million rows — during which
every read and write queues, the connection pool (shared program-wide, 10 s lease)
drains, and unrelated endpoints answer 503. That is an outage, not a migration. The
lifecycle above is shaped by that failure mode:

- **Locks are held for milliseconds.** Expand is metadata-only DDL (PostgreSQL 11+
  for constant defaults, 12+ for `NOT VALID` constraint validation without a full
  lock), one statement per transaction, `lock_timeout` + retry so a blocked ALTER
  fails fast instead of queueing everyone behind it.
- **No long transactions on user tables.** Backfill batches commit independently;
  `CREATE INDEX CONCURRENTLY` runs outside any transaction; `SET NOT NULL` at
  contract is preceded by `ADD CONSTRAINT … CHECK (col IS NOT NULL) NOT VALID` +
  `VALIDATE CONSTRAINT` (share lock only), then the constraint is promoted.
- **Bloat is bounded.** `UPDATE`-based backfill creates one dead tuple per row; the
  batch pause lets autovacuum keep up, and the plan prints the expected extra bytes
  (rows × new column width) so the operator can check free space. The shadow-table
  path (copy + swap) is used only by `--offline`, where writes are stopped.
- **Dry-run writes nothing.** A rolled-back `UPDATE` still leaves dead tuples and WAL;
  the read-only pass does not.
- **Lazy read costs one function call per unmigrated row**, in Go, on data already
  fetched — no extra round trip. Reads of migrated rows pay a `NULL` check. Dual
  writes cost one extra column per insert/update for the life of V8. The invalidation
  trigger costs tens of microseconds per `UPDATE` on the migrating table and exists
  until V7 is **retired** — by default at V9's boot, so for the life of V8, or until
  an operator runs `--schema retire`. It is cheap enough that tying its lifetime to
  the state transition rather than to observed absence costs nothing worth having.
- **The fence costs one extra statement per transaction, in the same round trip.**
  `pgx` pipeline mode batches `BEGIN`, the fence statement, the program's statement(s)
  and `COMMIT`; the server-side cost is a shared advisory lock in the lock table per
  transaction — tens of microseconds, and shared locks on one key do not contend with
  each other. At very high transaction rates the lock table itself becomes a hot spot,
  which is what the `fence: Session` opt-in is for on deployments that can guarantee
  direct connections; measuring where that threshold sits is a phase-1 task. No
  pooler detection is attempted: the default protocol does not need it, and the
  earlier `pg_backend_pid()` probe was both probabilistic and able to leave an
  orphaned session lock behind.
- **The pool is never the bottleneck of a migration.** Backfill uses one connection;
  boot expand uses one; neither holds a lease across a user request.

Rough expectations, single primary, no replication lag budget:

| Table | Earlier draft (one transaction) | This design |
|---|---|---|
| < 100 k rows | seconds of table outage; acceptable in dev | expand ms; backfill seconds |
| 1 M rows | 1–3 min table outage, pool starvation program-wide | expand ms; backfill ~1–5 min in background, serving throughout |
| 10 M+ rows | 10–30 min outage | expand ms; backfill tens of minutes to hours, throttled, resumable, serving throughout |

### 10. JSONB columns and the codec list

An ADT or record stored as JSONB does **not** need a row migration when only its JSON
shape changed: the existing `fromJson [current, legacy]` list reads both, and the
single encoder writes the new shape on the next write. The plan reports such a change
as `Task.result: JSONB shape changed — read via codec fallback, no rewrite` and the
snapshot keeps the old codec so the fallback decoder can be generated (or checked)
against it. Under the two-version rule the legacy decoder must stay in the program
until V9 at the earliest — the plan says when it may be removed. A rewrite-now
backfill is available for retiring a legacy decoder. Removing a constructor that
stored rows still use is lossy and is classified as such.

### 11. Command surface — one compiler flag, the rest in the binary

The compiler's CLI grows by **one entry**, in the flag style the existing surface
uses (`--fmt`, `--lint`, `--check`):

```
tesl --migrate <entry> [--suggest-online]
    diff the previous schema module against the one the `database` names; write the
    migration skeleton <Migrate>/V<n+1>.tesl (or refresh an unfinished one), its frozen
    stdlib slice; print the plan header. If no newer
    schema module exists yet, offer to copy V<n>.tesl to V<n+1>.tesl first. Idempotent.
    The LSP quickfix on the "schema module changed, no migration" diagnostic calls
    exactly this.
```

**Why a command at all, if the schema module is copied by hand?** Because the copy is
the trivial part. Every hand-written thing — `V9.tesl`, the row functions, the
acknowledgements — is yours; what `--migrate` produces is exactly what a person
*cannot* write reliably, and the compiler needs all of it:

- the **diff and its classification** (`ONLINE` / `ROLL-WINDOW RISK` / `OFFLINE`,
  expand/window/contract per entity, the plan header) — derived from two schema
  modules plus the whole-program query set;
- the **migration skeleton** with one entry per entity (most of them `Unchanged`) and
  a typed `todo` per hole that lists the old row's fields and the new field's proof —
  Lamdera's `Unimplemented`, the part users value most;
- the **frozen stdlib slice** the row functions reach (`V8.stdlib.tesl`) — a closure
  computation over the compiler's own library;
- the **frozen hashes** of both schema modules in the migration header, which is what
  makes editing `V7.tesl` a compile error from then on;
- and a **refresh** of all of the above when the schema module changes again before
  the migration ships, preserving what you edited.

A migration file could be written by hand and the compiler would still check it
(MIG002 completeness, types, proofs); the stdlib slice and the hashes could not. So the command is the generator of the mechanical artefacts, and copying
`V8.tesl` to `V9.tesl` when no newer module exists is a convenience it offers on the
side, not its purpose. Everything else the earlier list had is either already covered or belongs
somewhere else:

- **`check`** is redundant: `tesl --check` already type-checks the whole program, and
  the migration file, the `todo` holes, the compatibility check and the MIG-series
  errors are part of that. No separate verb.
- **Anything that touches a live database is not the compiler's job.** The compiler
  runs where the source is; the database is reachable from where the *program* runs,
  with the credentials the deployment hands it. So the DB-touching verbs are flags on
  the **compiled binary**, which already embeds the row functions, the snapshots and
  the connection configuration:

  ```
  ./app --schema status                       db version, expanded/backfilled/contracted, backfill progress,
                                              live instances by version, pending OFFLINE plan
  ./app --schema dry-run [--sample 1%]        run the row functions read-only over real data; duplicate
                                              pre-check for new unique indexes; time estimate
  ./app --schema contract                     finish the previous migration now (final pass, NOT NULL, drops) if its version is retired
  ./app --schema retire                       retire the previous version now (closes its rollback window; drops its trigger)
  ./app --schema worker                       run only the DDL and backfill jobs, over a direct DSN; request instances then skip them
  ./app --schema apply-offline [--wait-for-drain]   the OFFLINE path; needs every admitted version's fence key exclusively
  ./app --schema adopt                        record V<current> on a pre-versioning database after verifying columns
  ```

  The binary exits after the verb instead of serving. Today the emitted `main` takes
  no arguments at all, so this is a new, small, uniform surface — one flag, one verb.

- **There is no `apply` for the online path anywhere.** Expand happens at boot,
  backfill in the background, contract at the next boot.

**Responsibility split.** Worth stating because migrations are where a language
tooling and a deployment tool most often end up doing each other's job:

| Concern | Owner |
|---|---|
| detecting a schema change, writing the snapshot and the migration skeleton, checking it | Tesl compiler (`--migrate`, `--check`) |
| expand at boot, lazy read, backfill, invalidation trigger, contract, boot gate, readiness | the compiled binary, automatically |
| reporting readiness (schema gate, unique-index build) on the health endpoint | the compiled binary |
| offline apply, dry-run, adopt, retire, status, the optional single schema worker | the compiled binary, on demand via `--schema` |
| rolling strategy, surge/unavailable counts, probe timings, scaling to zero, maintenance page | Helm / Kubernetes / whatever deploys it |
| running `--schema apply-offline` at the right moment (a Job, a `pre-upgrade` hook) | Helm / the pipeline |
| deciding that downtime is acceptable | the person writing `Offline "…"` |

Tesl never orchestrates a roll, never scales anything, never talks to a cluster API.
It makes the binary correct under any roll order and tells the operator, in the boot
log and on the readiness endpoint, what it is waiting for.

`--migrate` prints the header Acadia prints, and the same header is written as the
first comment of `V<n+1>.tesl` so a pull request shows it in the diff:

```
migration V7 -> V8                                   ONLINE
  User      MIGRATE WITH migrateUser
            expand:   +fullName NULL, +bio NULL, +age NULL      (dual-write name→fullName)
            backfill: 3 columns, est. 2.4M rows
            contract: -name, age SET NOT NULL, CHECK NonNegative   (at V9 boot)
  Session   unchanged
  Legacy    DROP                                     (table dropped at V9 boot; 0 V8 readers)
  indexes   +users_email_idx (unique, concurrently; gates readiness; 1 onConflict depends on it)
```

Approval is the git commit that contains the file. What the boot-time hash check
proves is narrower and should be stated precisely, and the re-review found the first
statement of it insufficient: a hash of the migration *file* does not pin the
migration's *behaviour* if a row function may call a helper defined in the live
program — two V8 builds with identical migration files and a changed `defaultAgeFor`
would both pass and leave the table half-migrated under one interpretation and half
under another, with V9's final pass adding a third build to the mix. Two rules close
this:

- **Migration code is frozen.** A row function, and every function it reaches, must be
  declared in the migration file itself, in one of the two schema modules it bridges
  (qualified `ShopSchema.V7.*`/`ShopSchema.V8.*` — entities, facts, checks, codecs, pure helpers, all frozen with the
  module), or in the standard library (frozen with it, below). Calling a function from the live program is a compile error with a quickfix
  that copies the definition into `migrations/V8.tesl` (from where it never changes
  again — the live copy is free to evolve). This is the same rule Lamdera imposes by
  convention and Acadia by the `OLD.` namespace, made mechanical.
- **The migration's closure is committed, including its slice of the standard
  library.** The standard library is itself mostly Tesl (the lifted modules), and a
  reached stdlib function can change between the compiler that built V8 and the one
  that builds V9 — yet V9 must run V8's final pass *before it is ready*, so "write a V9
  migration" is no remedy there. So `tesl --migrate` copies every lifted-Tesl stdlib
  function the migration's **whole reachable closure** touches — row functions, the
  schema-module checks and helpers they call, transitively — into
  `migrations/notes/V8.stdlib.tesl`, committed next to the migration. The **linking
  rule** is at the typed-IR level, not the source level: when the compiler elaborates
  the migration closure it rewrites every stdlib reference inside that closure —
  including references *inside* `NotesSchema.V8.wordCountOf`'s body, which lexically
  imports the live `Tesl.String` — to the frozen symbols. No user file imports the
  slice; a source-level import of it would rebind nothing inside another module's
  function and is not part of the design. What remains uncopyable is the layer of
  primitive builtins implemented in the Go runtime; each of those carries a **semantic
  version tag** in the builtin registry, bumped only when its meaning changes, and a
  migration's identity includes the tags of the primitives it reaches — not the
  runtime's version as a whole, which would refuse unrelated upgrades. Detecting the
  change is not enough, because V9 must *run* V8's final pass before it is ready; so
  a primitive whose meaning changes ships as a **new tag with the old implementation
  retained** (`String.trim@1` stays callable when `@2` becomes the default) for as long
  as the runtime supports the two-migration window plus a documented deprecation
  horizon, and a frozen migration binds to the tag it was frozen with. If a runtime
  ever drops a tag, a program whose embedded migrations reach it fails **at build
  time** naming the migration — not at boot — and the path is: finish and finalise
  that migration on the current runtime (`--schema status`), prune it, then upgrade.
- **`migration_hash` covers behaviour, not text.** It is taken over the canonical
  typed IR of that committed closure — the `migration` form, every row function and
  frozen helper, the frozen stdlib slice, the two schema modules they are typed against
  — plus the reached primitives' tags. A comment or formatting change does not alter
  it; a semantic change to anything the migration can execute does. The database
  records the hash from the **first binary that expanded V8**, and every later binary
  that runs any step of V8's migration — including V9, which performs V8's final pass
  — must embed the same hash or is refused with the name of what changed. With the
  closure committed and primitive tags retained, two binaries built from the same
  migration cannot disagree, whatever compiler or runtime built them.

So two builds cannot disagree about what V8 means, and an edited history is refused. It does **not** prove that the binary was
built from the reviewed commit; that is provenance, and it belongs to the build system
(reproducible builds, signed images). A separate signing step (Acadia's `sign`) is
deliberately not proposed — listed under non-goals.

### 12. PostgreSQL topologies

The protocol assumes **one logical primary** for writes. Under that assumption:

- **HA with failover** (Patroni, cloud-managed primaries): every guard survives.
  Transaction-scoped fences vanish with their transactions, which abort; the
  session-fenced DDL connection drops and is reopened with the same two steps (step
  9b), pausing jobs meanwhile; leases and `tesl_schema` rows are ordinary replicated
  data; a retirement either committed and replicated or did not happen; a `CREATE
  INDEX CONCURRENTLY` in flight on the old primary is simply absent or `INVALID` on the
  new one, which the builder's recovery path already handles. Advisory locks are not
  replicated, which is correct: they only mean something alongside live transactions.
- **Read replicas** (streaming replication): Tesl does not route reads to replicas
  today; if it ever does, the lazy read path is replica-safe (it computes in Go from
  whatever the replica returns), and a read on a lagging replica by a retired version
  fails loudly on a dropped column rather than corrupting anything. Retirement on an
  asynchronous replica is **lagged**: the read admission (§13) reads the replicated
  `tesl_schema`, so a retired reader is refused only once the retirement has
  replicated. Strict retirement for replica reads would need admission against the
  primary or a bounded-lag mechanism; that is a stated limitation of any future
  replica support, not something v1 has to solve.
- **Sharding / multi-primary**: out of scope for v1, and split in two. Multi-primary
  (BDR-style) has no single lock manager for the fence to live in and is not planned.
  **Citus** is a different case: a coordinator in front of the shards *is* a single
  lock manager, and nothing in the protocol depends on single-node-only behaviour, so
  there is a credible **future path** as a "Citus profile" on top of v1 rather than a
  redesign (all of this from documentation as of the design date; verify before
  building):
  - unchanged: advisory fences and leases on the coordinator (a profile forbids
    Citus 11's query-from-any-node); Go row functions (shard-agnostic); `_tesl_v`;
    keyset backfill through the coordinator; coordinator-propagated `ADD COLUMN`,
    `NOT VALID`/`VALIDATE`, `CREATE INDEX CONCURRENTLY`; row triggers on distributed
    tables (Citus 10+), since ours touch only `NEW`/`OLD` and a GUC;
  - profile changes: the writer GUC is set with `SET LOCAL` under
    `citus.propagate_set_commands = 'local'` so the worker-side trigger sees it;
    retirement's index-progress wait runs `pg_stat_progress_create_index` via
    `run_command_on_workers`; `tesl_schema*` and the lease table become **reference
    tables** (which the server-side trigger-fence alternative may read);
  - the one language addition: Citus requires the distribution column in the primary
    key and in every unique index, so an entity gains `distributedBy <field>` (and
    `reference` for lookup tables), with compile-time checks that the key and every
    `unique index` include it and that `innerJoin` is co-located or against a
    reference table — a compile error where Citus would otherwise fail at runtime, and
    the same check that keeps `onConflict` valid there;
  - a Citus cluster in the compatibility-suite matrix.
  Queues and pub/sub (`tesl_jobs`, `LISTEN/NOTIFY`) have their own Citus questions,
  independent of this item.

Everything used is a PostgreSQL built-in: advisory locks, PL/pgSQL triggers,
`CREATE/DROP INDEX CONCURRENTLY`, `NOT VALID` + `VALIDATE CONSTRAINT`,
`pg_stat_progress_create_index`, GUCs via `set_config`. No extension, no external
tool, PostgreSQL 12 or later.

### 13. What the compiler removes from the runtime

The stance for every Tesl feature applies here: prove at compile time, pay nothing at
runtime for what is proven. Concretely:

- **Reads are admitted without a lock; writes and deletes take the fence.** Retirement
  means *this schema version may no longer run* — not merely "may no longer update
  derived columns": a retired, paused binary that resumes must not serve reads under a
  row policy the next schema version tightened (policies are declared on entities, so
  they live in the schema module and a policy change *is* a schema change), return
  rows under an obsolete invariant, or delete rows a later version repurposed. The
  guarantee is scoped precisely to that: two binaries built against the **same** schema
  module are indistinguishable to `min_version`, and a code change with no schema
  change (a handler, `main`, a request-time check) is not fenced by this mechanism —
  that is ordinary deployment, not migration. A distinct monotonically increasing
  deployment generation could fence it and is out of scope here (the ninth review pass caught an earlier revision
  exempting reads and deletes entirely). But the *lock* half of the fence exists only
  so that retirement waits for in-flight **writers** — the trigger drop must not race a
  write — and retirement never has to wait for a reader: the contract DDL already
  blocks behind a reader's `ACCESS SHARE` table lock. So the compiler emits two
  different admissions:
  - **write transactions** (`insert`, `update`, `upsert`, `delete` — a delete is a
    mutation): the two-statement fence of §6 invariant 1;
  - **read transactions**: no advisory lock, and an **ordering** that makes admission
    sound: the transaction runs its query (or queries) **first**, then `select
    tesl_admit(<program version>)` — one primary-key lookup on `tesl_schema` comparing
    the **binary's schema version** with `min_version`, raising if retired — then
    `COMMIT`, all pipelined in one round trip, and the runtime hands rows to the
    handler **only after the admission statement has returned**. Why this order and
    not admit-then-query: under READ COMMITTED every statement has its own snapshot,
    so an admission taken *before* the query proves nothing about the state the query
    then reads — a retirement (and even a contract) could commit in between, since the
    query holds no lock yet (the thirteenth review pass found exactly that in the
    previous revision). Query-first closes it with two facts PostgreSQL guarantees: the
    query's `ACCESS SHARE` lock on every table it touched is held until commit, so no
    contract DDL can run between the query and the admission; and the admission
    statement's snapshot is at least as new as the query's, so a retirement committed
    before the query is seen and aborts the transaction, and a retirement committed
    after the admission snapshot means the query read genuinely pre-retirement data.
    Nothing is delivered from an aborted transaction. The argument is the program
    version, never an entity generation: generations are the row dimension and do not
    move for an entity a release did not migrate, so they cannot say whether *the
    binary* has been retired. No lock-table traffic; a read-heavy service pays one
    index probe per transaction for "a retired binary cannot serve". The acceptance
    suite interposes a retirement between query and admission, and between admission
    and commit, and asserts the transaction aborts in the first case and delivers
    pre-retirement rows in the second; it also covers zero-row results, aggregates,
    `EXISTS`, prepared and constant-folded statements, since the admission statement's
    execution must not depend on the query's plan shape (an earlier target-list
    initplan form could be skipped on a zero-row scan and was dropped).
  - **Idle zombies** that receive no request still exit: every instance re-reads
    `min_version` every 15 s and shuts down when retired. That poll is a liveness aid;
    the per-statement admission is the guard.
- **Lazy decoding is emitted only for entities with a migration in flight in this
  binary** (the two embedded migration files). Every other query's decoder is exactly
  what it is today.
- **Read-modify-write rewriting applies only to statically identified statements**:
  updates and partial upserts that touch a migrating entity's closure. The plan header
  lists them with their cost; everything else is a plain statement.
- **Dual writes and trigger installation exist only for the versions and entities the
  plan names.** A release with no row-function migration installs no trigger and
  emits no dual write.
- **The compatibility check itself is free at runtime**: it is what lets expand run at
  boot without a runtime verifier, and it is why the boot gate needs only a version
  comparison and a hash.

**Alternative under evaluation — a server-side write fence with no lock at all.** If
*every* Tesl write statement carried a trusted **program-version** setting
(`tesl.version = 8`, a pipelined `set_config` statement, no extra round trip), a
permanent per-table trigger could reject any write whose program version is below
`tesl_schema.min_version` (one primary-key lookup per row), and retirement would stay
what it is: a `min_version` update. The setting must be the **program version**, not
`tesl.writer.<entity>`: that GUC carries the entity generation a read-modify-write
materialised, and an entity with no row-function migration between V7 and V8 has the
same generation in both binaries, so a generation minimum would either admit both or
reject both and can never retire a binary. The two GUCs stay separate — one for
admission, one for migration/dual-write semantics — and until that separation is in
the design of the alternative, it is not a benchmark-equivalent candidate at all. That replaces the per-write-transaction
advisory lock with a per-row trigger call, needs no client-side lock state for
admission at all, and makes the request pool's pooler question disappear entirely;
the DDL connection's fence would still be needed, and reads would keep the
query-then-`tesl_admit` ordering (the trigger says nothing about reads). It has one gap the lock does not: a
write whose snapshot predates retirement can still be in flight when the final pass
runs and the trigger is dropped. The fix is a **barrier** before the final pass — a
transaction that takes `LOCK TABLE … IN SHARE MODE` and commits immediately, which
waits for every in-flight writer and admits no new one (they are refused by admission
once retirement is committed). Costs: a trigger on every write forever (tens of
microseconds per row, comparable to the lock), and PL/pgSQL on the hot write path of
every table. The choice is a phase-1 benchmark decision (see
"Decisions before phase 1"); the rest of the protocol is unchanged either way.

## Worked example: `notes` from V7 to V9

Everything above, in code, for one small program. None of it compiles today; the
point is to see every moving part touch every other one. Where writing it exposed a
gap in the rules, the gap is marked **(gap)** and the rule above has been amended.

### Files, and which of them this feature version-controls

```
notes.tesl                             the application: imports, auth, handlers, api, server, main   ○ deployed
schema/notes/v7.tesl                   schema module NotesSchema.V7                                   ◆ versioned (frozen)
schema/notes/v8.tesl                   schema module NotesSchema.V8                                   ◆ versioned (current)
schema/notes/v9.tesl                   schema module NotesSchema.V9  (later)                          ◆
migrations/notes/v8.tesl               migration V7 -> V8: generated skeleton, edited by a person     ◆ generated + edited
migrations/notes/v8-compat.tesl        generated two-version test module (imports no application code)  ◆ generated
migrations/notes/v8-support.tesl       generated typed helpers for the compat module (insertOldNote…)   ◆ generated
migrations/notes/v8.stdlib.tesl        frozen stdlib slice the migration closure reaches              ◆ generated (linked, never imported)
```

Nothing records what a version's *handlers* did: the frozen schema module is a sound
over-approximation of that (§1), so the compatibility check needs no other input.

File names follow the existing PascalCase-to-kebab-case rule (§10.2). Only the
`schema/…` modules are the source of truth for "what the data looks like"; the
`migrations/…` files bridge two of them. `notes.tesl` is never migrated. Everything
below is intended to be current Tesl except where a form is explicitly proposed by
this document (`schema module`, module references as record values, entity names as
record fields, the `Tesl.Migration` and `Tesl.Check` stdlib modules, `todo`).

### The application (`notes.tesl`) at V7

```tesl
module Notes exposing [NoteDatabase, NoteServer]

import Tesl.Prelude exposing [Bool(..), Int, List, String, Unit]
import Tesl.App exposing [App]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Time exposing [PosixMillis, nowMillis, time]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Tesl.Env exposing [env, envInt, envRead]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Json exposing [stringCodec]
import Tesl.Id exposing [generatePrefixedId]
import Tesl.Random exposing [random]
import NotesSchema.V7 exposing [Note, Session]        # ◆ THE version this program is built against.
                                                      #   Every entity type traces to schema/notes/v7.tesl.
                                                      #   No import of the migration namespace: nothing
                                                      #   in the application refers to migration files.

fact Authenticated (user: String)                     # request-time proof — not a column, stays here

auth cookieAuth(request: HttpRequest) -> user: String ::: Authenticated user =
  case Dict.lookup "user" request.cookies of
    Nothing -> fail 401 "not logged in"
    Something userId -> ok userId ::: Authenticated user

capturer noteIdCapture: String using stringCodec

record NoteBody {
  title: String
  content: String
}

codec NoteBody {
  toJson_forbidden
  fromJson [
    {
      title   <- "title"   with_codec stringCodec
      content <- "content" with_codec stringCodec
    }
  ]
}

database NoteDatabase = Database {
  schema:     NotesSchema.V7                          # ◆ PROPOSED: a module reference, not a string
  migrations: NotesSchema.Migrate                     # ◆ PROPOSED, mandatory: the migration namespace
  backend: Postgres (PostgresConfig {                 # ○ deployment configuration, never versioned
    dbName: env "NOTES_DB_NAME"
    user: env "NOTES_DB_USER"
    password: env "NOTES_DB_PASSWORD"
    connection: TcpConnection { host: env "NOTES_DB_HOST", port: envInt "NOTES_DB_PORT" 5432 }
  })
}

handler get listNotes(user: String ::: Authenticated user) -> List Note requires [dbRead] =
  select note from Note where note.authorId == user order note.createdAt desc

handler post createNote(user: String ::: Authenticated user, body: NoteBody)
  -> Note requires [dbRead, dbWrite, time, random] =
  insert Note {
    id: generatePrefixedId "note",
    title: body.title,
    content: body.content,
    authorId: user,
    legacyRank: 0,
    createdAt: nowMillis()
  }

handler put updateContent(user: String ::: Authenticated user, noteId: String, body: NoteBody)
  -> Unit requires [dbRead, dbWrite] =
  update note in Note where note.id == noteId set note.content = body.content

api NoteApi {
  get "/notes"
    auth user: String ::: Authenticated user via cookieAuth
    -> List Note

  post "/notes"
    auth user: String ::: Authenticated user via cookieAuth
    body body: NoteBody
    -> Note

  put "/notes/:noteId/body"
    auth user: String ::: Authenticated user via cookieAuth
    capture noteId: String via noteIdCapture
    body body: NoteBody
    -> Unit
}

server NoteServer for NoteApi {
  listNotes
  createNote
  updateContent
}

main() -> App requires [dbRead, dbWrite, time, random, envRead] =
  App {
    database: NoteDatabase
    api: NoteServer
    port: envInt "PORT" 8080
  }
```

**What `main` configures: nothing.** `main` is identical at V7, V8 and V9. The schema
version is the module the `database` names; expand runs because the binary starts,
retirement and contract run because the next binary starts, and every operator verb is
a `--schema` flag on the same binary. Runtime knobs are environment variables in the
existing style (`TESL_BACKFILL_BATCH` 2000, `TESL_BACKFILL_PAUSE_MS` 50,
`TESL_SCHEMA_LOCK_TIMEOUT_MS` 2000, `TESL_SCHEMA_POLL_S` 15). (The cookie auth is a
placeholder for the example, not a recommendation.)

### `schema/notes/v7.tesl`

```tesl
schema module NotesSchema.V7 exposing [Note, Session]
# PROPOSED module kind: may contain entities, the types/facts/checks/codecs they need,
# and pure helpers — the compiler rejects handlers, effects, `database`, `main`,
# `requires`, capabilities.

import Tesl.Prelude exposing [Int, String]
import Tesl.Time exposing [PosixMillis]

entity Note table "notes" primaryKey id {
  id:         String
  title:      String
  content:    String
  authorId:   String
  legacyRank: Int
  createdAt:  PosixMillis
  index [authorId]
}

entity Session table "sessions" primaryKey token {
  token:     String
  userId:    String
  expiresAt: PosixMillis
}
```

Database state after the V7 deploy: `V7 expanded, contracted`, `min_version = 7`.
Per entity, `Note` is at **generation 3** (two earlier row-function migrations),
`Session` at **generation 1** (never migrated). Every `notes` row has `_tesl_v = 3`,
every `sessions` row `_tesl_v = 1`.

### `schema/notes/v8.tesl` — copied from V7 and edited by hand

```tesl
schema module NotesSchema.V8 exposing [Note, Session, Tag, ValidWordCount, checkWordCount, wordCountOf]

import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.Time exposing [PosixMillis]
import Tesl.String exposing [String.split]
import Tesl.List exposing [List.length, List.filter]

fact ValidWordCount (n: Int)                    # named by a column proof → lives with the entity

check checkWordCount(n: Int) -> n: Int ::: ValidWordCount n =     # ONE declaration, shared by
  if n >= 0 then ok n ::: ValidWordCount n else fail 400 "negative word count"   # handlers and the migration

fn wordCountOf(text: String) -> Int =                              # pure helper, same reason
  List.length (List.filter (fn (w) -> w != "") (String.split " " text))

entity Note table "notes" primaryKey id {
  id:         String
  title:      String
  content:    String
  ownerId:    String                            # renamed from authorId
  wordCount:  Int ::: ValidWordCount wordCount  # NEW, computed from content, with a proof
  createdAt:  PosixMillis
                                                # legacyRank REMOVED
  index [ownerId, createdAt]                    # replaces index [authorId]
}

entity Session table "sessions" primaryKey token {   # unchanged — generation stays 1
  token:     String
  userId:    String
  expiresAt: PosixMillis
}

entity Tag table "tags" primaryKey id {         # NEW entity
  id:     String
  noteId: String
  label:  String
  index [noteId]
}
```

### `schema/notes/v9.tesl` — one additive change

```tesl
schema module NotesSchema.V9 exposing [Note, Session, Tag, ValidWordCount, checkWordCount, wordCountOf]
# Identical to V8 except one line in Note: the compiler derives the adapter (`Nothing`),
# no row function exists, Note's generation stays 4. This is the phase-1 kind of change.

import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Time exposing [PosixMillis]
import Tesl.String exposing [String.split]
import Tesl.List exposing [List.length, List.filter]

fact ValidWordCount (n: Int)

check checkWordCount(n: Int) -> n: Int ::: ValidWordCount n =
  if n >= 0 then ok n ::: ValidWordCount n else fail 400 "negative word count"

fn wordCountOf(text: String) -> Int =
  List.length (List.filter (fn (w) -> w != "") (String.split " " text))

entity Note table "notes" primaryKey id {
  id:         String
  title:      String
  content:    String
  ownerId:    String
  wordCount:  Int ::: ValidWordCount wordCount
  archivedAt: Maybe PosixMillis                 # NEW, nullable — `Additive`
  createdAt:  PosixMillis
  index [ownerId, createdAt]
}

entity Session table "sessions" primaryKey token {
  token:     String
  userId:    String
  expiresAt: PosixMillis
}

entity Tag table "tags" primaryKey id {
  id:     String
  noteId: String
  label:  String
  index [noteId]
}
```

(A release that changes no entity needs no new schema module at all and keeps
`schema: NotesSchema.V8`.)

### What the application has to change, per migration

**V7 → V8.** Ordinary compile-driven edits — every site is a type error until fixed,
which is the "blast radius" promise the tour already makes. In a large application the
import bump is many files but one action: each stale import is MIG015 (fix-all
eligible), so nothing can be missed and one fix-all rewrites them all; a re-export
facade (§1) would reduce it to one line.

```tesl
# the ONE mechanical bump. Once the `database` line moves, any remaining
# `NotesSchema.V7` import is MIG015 with a fix-all-eligible rewrite.
import NotesSchema.V8 exposing [Note, Session, Tag, ValidWordCount, checkWordCount, wordCountOf]

database NoteDatabase = Database {
  schema:     NotesSchema.V8                    # was V7
  migrations: NotesSchema.Migrate
  backend: …                                    # untouched
}

# listNotes: the renamed column. Allowed inside SQL in V8 because `Rename` is in the
# SQL-expressible subset — the emitter rewrites the predicate for the window.
handler get listNotes(user: String ::: Authenticated user) -> List Note requires [dbRead] =
  select note from Note where note.ownerId == user order note.createdAt desc
  #                                ^^^^^^^ was authorId

# createNote: the literal must supply wordCount WITH its proof — only `checkWordCount`
# (imported from the schema module) can mint ValidWordCount, via the `check` expression.
handler post createNote(user: String ::: Authenticated user, body: NoteBody)
  -> Note requires [dbRead, dbWrite, time, random] =
  let words = check checkWordCount (wordCountOf body.content)
  insert Note {
    id: generatePrefixedId "note",
    title: body.title,
    content: body.content,
    ownerId: user,
    wordCount: words,
    createdAt: nowMillis()
  }

# updateContent: NO source change. `content` is a source of wordCount, so the EMITTER
# turns this into a read-modify-write during the window; the Tesl text is untouched.

# NOT allowed yet in V8 — wordCount is Go-computed, outside the SQL-expressible subset,
# so PostgreSQL would evaluate the predicate on NULL for unmigrated rows. MIG008 names
# this clause and offers `Maybe` or "use from V9":
# handler get longNotes(...) = select note from Note where note.wordCount > 500
```

**V8 → V9.** `schema: NotesSchema.V9` and the import bump; nothing else *required*.
Now *permitted*, because V9's boot retires V7 and makes V8's backfill final first:

```tesl
handler get longNotes(user: String ::: Authenticated user) -> List Note requires [dbRead] =
  select note from Note where note.ownerId == user && note.wordCount > 500
```

### What `tesl --migrate notes.tesl` prints and writes (V7 → V8)

```
migration NotesSchema.V7 -> NotesSchema.V8                       ONLINE
  Note      gen 3 -> 4     MIGRATE WITH migrateNote   (2 holes)
            expand:   +ownerId NULL, +wordCount NULL,
                      legacyRank SET DEFAULT ‹legacy›, _tesl_v SET DEFAULT 3,
                      trigger tesl_mig_notes_g4 (sources: content, authorId)
            window:   dual-write authorId←ownerId; RMW: updateContent (1 statement);
                      SQL rewrite: listNotes.where ownerId (OR form; index [authorId] kept and used)
            backfill: est. 2.4M rows
            contract: -authorId, -legacyRank, wordCount SET NOT NULL, ownerId SET NOT NULL,
                      CHECK ValidWordCount, -index notes_authorId_idx, -trigger   (at V9 boot)
  Session   gen 1         unchanged
  Tag       new           create table
  indexes   +notes_ownerId_createdAt_idx_v8 (plain, concurrently)
            +tags_noteId_idx_v8 (plain, concurrently)

froze  schema/notes/v7.tesl               (hash recorded in the migration header; edits are now MIG013)
wrote  migrations/notes/v8.tesl            (2 todo — the program will not compile until resolved)
wrote  migrations/notes/v8-compat.tesl
wrote  migrations/notes/v8-support.tesl    (insertOldNote and friends, typed from the migration)
wrote  migrations/notes/v8.stdlib.tesl     (frozen: String.split, List.length, List.filter — linked, not imported)
```

### The migration file as generated (`migrations/notes/v8.tesl`)

```tesl
# migration NotesSchema.V7 -> NotesSchema.V8  ONLINE   (header as above, kept in sync)
# frozen: NotesSchema.V7 = sha256:9c1e…   NotesSchema.V8 = sha256:41ab…
module NotesSchema.Migrate.V8 exposing [migration, migrateNote]

import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Migrated(..), Same(..)]
import Tesl.Check exposing [Check.attempt, Attempt(..)]
import Tesl.Maybe exposing [Maybe(..)]
import NotesSchema.V7                        # module imports; qualified names below
import NotesSchema.V8

migration = Migration {
  from: NotesSchema.V7
  to:   NotesSchema.V8
  same: []                                   # V7 declares no fact or type that V8 also declares
  entities: {
    Note:    Migrate migrateNote [           # gen 3 -> 4
               Rename authorId ownerId,      # compiler-owned identity
               Legacy legacyRank (todo "V7 decodes legacyRank as Int NOT NULL; V8 rows need a value")
             ]
    Session: Unchanged
    Tag:     New
  }
}

fn migrateNote(old: NotesSchema.V7.Note) -> Migrated NotesSchema.V8.Note =    # @tesl-gen a1f3 7c…
  let wordCount = todo "V8 added `wordCount: Int ::: ValidWordCount wordCount`; NotesSchema.V7.Note has id, title, content, authorId, legacyRank, createdAt"
  Row (NotesSchema.V8.Note {
    id:        old.id,                       # pass-through: must stay the exact projection (MIG018)
    title:     old.title,
    content:   old.content,
    ownerId:   old.authorId,                 # renamed: must stay this exact projection (MIG017)
    wordCount: wordCount,                    # new: the only free expression
    createdAt: old.createdAt
  })
```

The trailing `# @tesl-gen <id> <fingerprint>` marks generator-owned nodes; the moment
the developer edits the body, its canonical AST no longer matches the fingerprint and
the node becomes user-owned.

### The migration file as committed (after the developer resolved both holes)

```tesl
module NotesSchema.Migrate.V8 exposing [migration, migrateNote]

import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Migrated(..), Same(..)]
import Tesl.Check exposing [Check.attempt, Attempt(..)]
import Tesl.Maybe exposing [Maybe(..)]
import NotesSchema.V7
import NotesSchema.V8

migration = Migration {
  from: NotesSchema.V7
  to:   NotesSchema.V8
  same: []
  entities: {
    Note:    Migrate migrateNote [Rename authorId ownerId, Legacy legacyRank 0]
    Session: Unchanged
    Tag:     New
  }
}

# No helper copies here: NotesSchema.V8.checkWordCount and .wordCountOf ARE the
# declarations the handlers use. Their stdlib calls are linked to the frozen slice at
# the typed-IR level; nothing is imported from it. ValidWordCount is sealed: only
# checks declared in NotesSchema.V8 can mint it.
fn migrateNote(old: NotesSchema.V7.Note) -> Migrated NotesSchema.V8.Note =
  case Check.attempt NotesSchema.V8.checkWordCount (NotesSchema.V8.wordCountOf old.content) of
    Failed reason -> Reject "note {old.id}: {reason}"   # stops the backfill; 500 on the lazy path
    Passed words  ->
      Row (NotesSchema.V8.Note {
        id:        old.id,
        title:     old.title,
        content:   old.content,
        ownerId:   old.authorId,
        wordCount: words,
        createdAt: old.createdAt
      })

test "V8: word count is computed from content" {
  let old = NotesSchema.V7.Note { id: "n1", title: "t", content: "one two  three",
                                  authorId: "u1", legacyRank: 4, createdAt: 0 }
  case migrateNote old of
    Row note -> expect note.wordCount == 3 && note.ownerId == "u1"
    Reject _ -> expect False
}
```

### The generated compatibility module (`migrations/notes/v8-compat.tesl`)

Self-contained and frozen with the migration: it imports the two schema modules, the
migration module and its generated support module — never the application or its
`database`. It runs as unnamed tests against the automatic in-memory store, which
models `_tesl_v` and the lazy read path.

```tesl
module NotesSchema.Migrate.V8Compat exposing []

import Tesl.Migration exposing [Migrated(..)]
import Tesl.List exposing [List.length, List.head]
import NotesSchema.V7
import NotesSchema.V8 exposing [Note]
import NotesSchema.Migrate.V8 exposing [migrateNote]
import NotesSchema.Migrate.V8Support exposing [insertOldNote]   # generated: NotesSchema.V7.Note -> Unit,
                                                                 # stores the row at generation 3

# structural: a V7-shaped row is stored, found by the rewritten predicate, decoded
# through the lazy path. The fixture is the developer's — a generator cannot know
# which V7 rows the migration accepts, and migrateNote may legitimately Reject some.
test "V8 compat: a V7-shaped Note is readable through V8" {
  insertOldNote (NotesSchema.V7.Note { id: "n2", title: "t", content: "a b",
                                       authorId: "u2", legacyRank: 0, createdAt: 0 })
  let notes = select note from Note where note.ownerId == "u2"   # the OR rewrite finds the V7 row
  expect List.length notes == 1
  expect (List.head notes).wordCount == 2                        # lazy path ran migrateNote
}
```

### The V8 → V9 migration file (`migrations/notes/v9.tesl`, generated, needs no edit)

```tesl
module NotesSchema.Migrate.V9 exposing [migration]

import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Same(..)]
import NotesSchema.V8
import NotesSchema.V9

migration = Migration {
  from: NotesSchema.V8
  to:   NotesSchema.V9
  same: [ Same NotesSchema.V8.ValidWordCount NotesSchema.V9.ValidWordCount ]   # semantic closures identical
  entities: {
    Note:    Additive []                    # +archivedAt: Maybe → adapter Nothing; gen stays 4
    Session: Unchanged
    Tag:     Unchanged
  }
}
```

(`v9-compat.tesl` is generated too: it stores a V8-shaped `Note` and reads it back with
`archivedAt == Nothing`.) Had V9 instead **tightened** the check — `checkWordCount`
becoming `n > 0`, the fact renamed `PositiveWordCount` — the semantic closure differs,
no `Same` is written, and `Note` cannot be `Additive` or `Unchanged` (MIG016) even
though no column moved:

```tesl
  entities: {
    Note:    Migrate revalidateNote []      # gen 4 -> 5: the invariant changed, rows must prove it
    …
  }

fn revalidateNote(old: NotesSchema.V8.Note) -> Migrated NotesSchema.V9.Note =
  case Check.attempt NotesSchema.V9.checkWordCount old.wordCount of   # old proof is V8's fact; V9 wants its own
    Failed reason -> Reject "note {old.id}: {reason}"
    Passed words  -> Row (NotesSchema.V9.Note { id: old.id, title: old.title, content: old.content,
                                                  ownerId: old.ownerId, wordCount: words,
                                                  archivedAt: Nothing, createdAt: old.createdAt })
# --schema dry-run lists every zero-word note before the deploy.
```

That is the case the design would otherwise have missed: a stored invariant that
silently stopped being true because its check changed.

### What the V8 binary does at boot (SQL it runs, in order)

```sql
-- step 1: boot lease (compare-and-swap; the row exists from the first bootstrap)
update notes_app.tesl_schema_leases set holder = $1, expires_at = now() + interval '30 s'
  where name = 'boot' and (holder is null or expires_at < now());

-- step 3: state
select version, step, snapshot_hash, migration_hash, min_version from notes_app.tesl_schema …;

-- step 5: retire V6 (only if min_version = 6)
begin;
select pg_advisory_xact_lock(hashtext('notes_app:fence:6'));   -- waits for in-flight V6 writers
update notes_app.tesl_schema set min_version = 7 where min_version = 6;
commit;

-- step 7: expand V7 -> V8, one short transaction per statement, lock_timeout = 2s
alter table notes_app.notes add column if not exists "ownerId"   text;
alter table notes_app.notes add column if not exists "wordCount" numeric;
alter table notes_app.notes alter column "legacyRank" set default 0;     -- legacy legacyRank 0
alter table notes_app.notes alter column "_tesl_v"    set default 3;     -- V7 inserts arrive at gen 3
create table if not exists notes_app.tags ("id" text primary key, "noteId" text not null,
  "label" text not null, "_tesl_v" smallint not null default 1);

create or replace function notes_app.tesl_mig_notes_g4() returns trigger as $$
begin
  if coalesce(nullif(current_setting('tesl.writer.notes', true), '')::int, 0) < 4
     and (new."content"  is distinct from old."content"
       or new."authorId" is distinct from old."authorId") then
    new."_tesl_v" := least(old."_tesl_v", 3);
  end if;
  return new;
end $$ language plpgsql;
create trigger tesl_mig_notes_g4 before update on notes_app.notes
  for each row execute function notes_app.tesl_mig_notes_g4();

insert into notes_app.tesl_schema (version, step, snapshot_hash, migration_hash)
  values (8, 'expanded', $1, $2);                    -- unique (version, step)

-- step 9b: the dedicated DDL connection
select pg_advisory_lock_shared(hashtext('notes_app:fence:8'));   -- session-level, lives with the connection
select min_version from notes_app.tesl_schema;                    -- separate statement

-- step 10: index builds, from the DDL connection, one builder per index (lease)
create index concurrently if not exists notes_ownerId_createdAt_idx_v8
  on notes_app.notes ("ownerId", "createdAt");
create index concurrently if not exists tags_noteId_idx_v8 on notes_app.tags ("noteId");
```

Readiness: steps 1–9b done, no new **unique** index in this plan, no V7-introduced
column used inside SQL → **ready in milliseconds**. The two plain indexes build in the
background.

### What V8 request code runs during the window

```sql
-- listNotes: a READ. No fence lock. The query runs FIRST (its ACCESS SHARE lock is then
-- held to commit, so no contract DDL can interpose), admission on the PROGRAM VERSION (8)
-- runs AFTER it with a newer-or-equal snapshot, and the runtime releases rows to the
-- handler only once the admission statement has returned. One pipelined round trip.
-- `where note.ownerId == user` is rewritten because ownerId is a `Rename` of authorId:
begin;
select n."_tesl_v", n."id", n."title", n."content", n."authorId", n."ownerId",
       n."wordCount", n."createdAt"
  from notes_app.notes n
 where (n."ownerId" = $1 or (n."ownerId" is null and n."authorId" = $1))
 order by n."createdAt" desc;
select notes_app.tesl_admit(8);          -- raises if min_version > 8 → transaction aborts, rows discarded
commit;
-- Go decoder: if _tesl_v < 4 → migrateNote(V7 view of the row) → Note; else decode directly.

-- createNote: a WRITE. Two-statement fence, then the insert with the dual write and the stamp.
begin;
select pg_advisory_xact_lock_shared(hashtext('notes_app:fence:8'));
select min_version from notes_app.tesl_schema;                    -- must be <= 8
insert into notes_app.notes ("id","title","content","ownerId","authorId","wordCount",
                             "createdAt","legacyRank","_tesl_v")
  values ($1,$2,$3,$4,$4,$5,$6, default, 4);
commit;

-- updateContent: touches a SOURCE column → read-modify-write, identified at compile time.
begin;
select pg_advisory_xact_lock_shared(hashtext('notes_app:fence:8'));
select min_version from notes_app.tesl_schema;
select set_config('tesl.writer.notes', '4', true);               -- "I materialise gen 4"
select … from notes_app.notes where "id" = $1 for update;         -- read (lazy-migrate in Go if _tesl_v < 4)
update notes_app.notes
   set "content" = $2, "wordCount" = $3 /* recomputed in Go */, "ownerId" = $4, "authorId" = $4,
       "_tesl_v" = 4
 where "id" = $1;                                                  -- trigger: writer 4 >= 4, no demotion
commit;
```

Meanwhile a **V7 instance** still runs `update notes set content = $1 where id = $2`
with no setting: the trigger sees writer `0 < 4` and `content` changed → `_tesl_v :=
least(3, 3)`; a V7 insert lands with `_tesl_v = 3` (the default), `ownerId NULL`,
`legacyRank 0`. Both are picked up by the backfill.

### The backfill (leader instance, background)

```sql
-- one batch; rows selected by keyset, exactly one generation behind
select "id","content","authorId" from notes_app.notes
 where "_tesl_v" = 3 and "id" > $last order by "id" limit 2000;
-- Go: migrateNote per row (a failing check → stop, report id + reason)
update notes_app.notes n
   set "ownerId" = v.owner, "wordCount" = v.words, "_tesl_v" = 4
  from (values ($1,$2,$3,$4,$5), …) as v(id, owner, words, content_read, author_read)
 where n."id" = v.id
   and n."_tesl_v" = 3
   and n."content"  is not distinct from v.content_read      -- conditional on what was read
   and n."authorId" is not distinct from v.author_read;
-- rows whose predicate failed stay at 3 and are seen again next pass
```

`--schema status` after a while:

```
database notes_app   min_version 7   V8 expanded   instances: 6×V8, 0×V7 (last V7 seen 14 min ago)
  Note     gen 3→4   backfill provisional: 0 rows at gen 3 (last scan 12 s ago)   trigger installed
  Session  gen 1     unchanged
  Tag      gen 1     new
  indexes  notes_ownerId_createdAt_idx_v8 VALID   tags_noteId_idx_v8 VALID
  pending at V9 boot: retire V7, final pass Note, contract (2 columns, 1 index, 1 trigger)
```

### V9: retire, finish V8, expand the additive column

V9's boot runs, in this order:

```sql
-- step 5: retire V7
begin;  select pg_advisory_xact_lock(hashtext('notes_app:fence:7'));
        update notes_app.tesl_schema set min_version = 8 where min_version = 7;  commit;

-- step 6: finish V8's migration of Note (background, per entity)
--   final pass: `where _tesl_v = 3` … finds nothing (or finishes the stragglers), then:
alter table notes_app.notes add constraint notes_wordcount_nn check ("wordCount" is not null) not valid;
alter table notes_app.notes validate constraint notes_wordcount_nn;                 -- share lock only
alter table notes_app.notes alter column "wordCount" set not null;                  -- cheap: constraint proves it
alter table notes_app.notes drop constraint notes_wordcount_nn;
-- same for ownerId; the proof's CHECK where expressible: check ("wordCount" >= 0) not valid → validate
drop trigger tesl_mig_notes_g4 on notes_app.notes;  drop function notes_app.tesl_mig_notes_g4();
alter table notes_app.notes drop column "authorId";
alter table notes_app.notes drop column "legacyRank";
drop index concurrently if exists notes_app.notes_authorId_idx;                    -- DDL connection
insert into notes_app.tesl_schema (version, step) values (8, 'contracted');

-- step 7: expand V8 -> V9 — the `Additive` entry is one metadata-only statement
alter table notes_app.notes add column if not exists "archivedAt" bigint;          -- Maybe → NULL
insert into notes_app.tesl_schema (version, step, snapshot_hash, migration_hash) values (9, 'expanded', $1, $2);
```

V9's readiness waits for `Note`'s final pass because `longNotes` uses `wordCount`
inside SQL. A V8 binary that boots afterwards is admitted (`min_version = 8`) and
tolerates the extra nullable column; a V7 binary is refused at its first fence
statement or `tesl_admit(7)`.

### Gaps the example exposed, and the amendments made above

Writing the example, and having it reviewed as if it were a golden fixture, changed
the design in these places:

0. **Nothing lands in `main`**, which is the right answer. What the versioned
   declarations *are* changed twice under review: from live declarations plus a
   generated snapshot (hid where a type came from, string identity, a duplicated
   check) to hand-written `schema module`s the program imports explicitly, with module
   references in `database` (`schema:`, mandatory `migrations:`), one declaration of
   each check shared through imports, and MIG015 for a stale import.
1. **Additive changes needed their own entry.** `Unchanged` meant "identical" and the
   phase-1 changes are not identical; `Additive` (derived adapter, no row function, no
   generation bump) is now the entry phase 1 lives on.
2. **Row functions needed a stated semantics**, not "an ordinary check": `check`
   returning a record with no top-level proof is a language change, invoked and
   failing like every other check, with the runner mapping any failure to backfill
   stop / lazy 500 regardless of the inner HTTP status. The earlier drafts
   pattern-matched on `Ok`/`Fail`, which Tesl does not have.
3. **`Rename` had to be compiler-owned.** A freely editable `ownerId: old.authorId`
   initialiser could silently diverge from the identity the SQL rewrite, lazy decoder,
   backfill and dual write all assume; the literal now omits the column and MIG017
   guards it.
4. **The compatibility test could not live in the migration file** — it needs the
   application's database and both schemas — so it is its own generated module, with
   a generated, precisely typed `insertOld<Entity>` and fixtures from property
   generators or a `todo`.
5. **`NotesSchema.Migrate` is not a module**; it is a module *prefix* discovered by
   directory scan, and `schema:`/`migrations:` are a new module-reference expression
   kind, not values. No import alias was added: qualified names do the job.
6. **Freezing stdlib is a typed-IR linking rule**, not an import: a source-level
   import of the slice would not rebind calls inside a schema-module helper's body.
7. **The application had to be real Tesl** — `App`, `random`, `generatePrefixedId`
   imported; `api` routes with return types and a `capturer`; `server … for …`; the
   `check` expression — or it is not a fixture.
8. **No footprint at all.** A generated record of "what V7's handlers touched" was
   removed once the maintainer asked how a schema module could know what the
   application does: it cannot, and complete-record inserts plus whole-row selects make
   the frozen module a sound over-approximation on its own.
9. **`same` compares semantic closures**, not declaration text.
10. **"SQL-expressible" is a declared subset** with a per-clause translation table,
    not an inferred property.
11. **The retirement guarantee is scoped to schema versions**; two binaries on the same
    schema module are indistinguishable, and that is stated rather than implied.
12. **Schema modules must carry the facts and checks** their column proofs name, and
    **cross-version identity is declared** through `same` (a changed check forces
    re-validation).
13. **The Memory backend models generations** for the compatibility test to mean
    anything; `tesl_admit` and the schema tables are created at first bootstrap; the
    plan header reports index usability during the window.

## The downtime path

Two changes are `OFFLINE` in v1: changing an entity's primary key, and `Reset`
(discard every row and recreate). `Reset` is offline by definition. A primary-key
change is offline **by scope decision, not by necessity**: PostgreSQL can change a
primary key without a full rebuild in many cases (new column, dual write, concurrent
unique index, a brief constraint swap), but foreign keys, referenced data and the
`onConflict`/upsert sites that name the key make the general decomposition
complicated, and v1 does not attempt it. The compiler error below says exactly that
and offers the new-entity alternative, which *is* decomposable today. Both cases are
rare, and the design has to make the path through them as clear as the online one,
because a user who hits it has nowhere else to go.

**Where the user learns about it: at compile time, from `tesl --migrate`.** Not at
boot, not in production. The plan header carries `OFFLINE` in capitals, and the
generated migration file will not compile until it contains an explicit
acknowledgement. The error is a new code in the `error_codes.ml` registry, in the
house format (§14b.4), and it must carry all three things a person needs: what cannot
be done online and why, the online alternative if one exists, and the exact offline
procedure.

```
error[MIG007]: migration V7 -> V8 changes the primary key of `User` (id: String -> userId: UserId)
  --> migrations/V8.tesl:3
  entity: `User` (table "users", 2.4M rows)

  Tesl does not decompose a primary-key change into online expand/contract steps
  (v1 scope). Done in one step, a V7 instance (which still inserts with `id`) and a
  V8 instance cannot run against the same table — the two-version rule
  (`tesl help manual migrations#online`) is not satisfied, so this plan is OFFLINE.

  online alternative:
    Introduce a new entity with the new key and migrate over two versions:
      V8: declare `entity UserV2 … primaryKey userId`, add `User copyTo UserV2 with toUserV2`
          to the plan — V8 dual-writes both, the backfill copies, reads stay on `User`.
      V9: switch reads to `UserV2`; `User drop`.
    `tesl --migrate --suggest-online` writes this two-version plan for you.

  offline procedure (if downtime is acceptable):
    1. add `Offline "<why downtime is acceptable here>"` to the entity's rule list in migrations/notes/v8.tesl
    2. scale the V7 deployment to zero (or put the ingress in maintenance mode)
    3. run the built binary once, where the database is reachable (a Job or Helm pre-upgrade hook):
             ./app --schema apply-offline --wait-for-drain
             (waits until it holds every admitted version's fence key exclusively — i.e.
              no admitted transaction is in flight; idle connections may remain and
              their next transaction is refused — then applies V8 in one transaction;
              est. 4–12 min for 2.4M rows — see the binary's `--schema dry-run`)
    4. deploy V8; scale up
    V8 instances refuse to start until step 3 has completed, and V7 instances
    cannot start afterwards.

  see: tesl help manual migrations#offline
```

Everything in that message is derivable: the row count and estimate from the
database (when reachable) or from the last `dry-run`, the alternative from the change
class, the commands from the entry file. The `--suggest-online` flag is the compiler
doing the tedious part of the alternative — most primary-key changes are better done
as a new entity anyway, and a user who is told that with the plan already written
will usually take it.

**What the offline procedure guarantees.**

- `--schema apply-offline` takes the fence key of **every admitted version**
  (`min_version` through current) exclusively, and sets `min_version` to the new
  version while holding them — the same guard the online path uses, so an in-flight
  V7 transaction blocks it rather than slipping past it, and a V7 transaction that
  starts afterwards is refused by its own fence statement. Holding every key proves
  there is no admitted **transaction** in flight, not that no connection exists: idle
  V7 connections may well remain open, and that is fine. Without `--wait-for-drain` it
  fails fast and prints how many transactions hold which key; with it, it blocks until
  they finish. The heartbeat table is what the progress message is built from, not
  what authorises the operation. There is no `--force`, because a forced offline
  migration under a live V7 is exactly the corruption the whole design exists to
  prevent.
- It takes the `boot` lease first, then — inside the one transaction below — the
  fence key of every admitted version exclusively, in ascending order (the global lock
  order of §6 invariant 6), verifies the V7 hash, and runs the entire plan — expand,
  row functions through the shadow-table path (copy into `users__v8`, apply `f` per row
  streamed by primary key, swap by rename), contract, `min_version` advance — in
  **one transaction**, so a failure anywhere leaves V7 intact. A `fail` from any row
  aborts the whole thing with the primary key and reason.
- It records `(8, 'expanded'), (8, 'backfilled'), (8, 'contracted')` at once, so V8
  boots see a finished migration and V7 boots are refused ("rollback window closed").
- The plan header states the estimated duration from `dry-run`, so the maintenance
  window is sized from evidence, not a guess.

**Mixed plans.** A plan with one `OFFLINE` entity and nine `ONLINE` ones is an
`OFFLINE` plan: the whole version is applied offline, because a V8 binary is one
artefact and cannot be half-deployed. The plan header says which entity forced it, so
the usual reaction — split the offline change into its own version, or take the
online alternative — is obvious.

**`Reset`** is the same path with a simpler body: the table is truncated and recreated
at V8. It is the right tool for pre-production data and for a table that is
genuinely a cache; the acknowledgement string is the place to say which.

**Documentation.** The manual gets a `migrations` chapter with `#online`, `#offline`,
`#indexes` and `#rollback` anchors (registered in `manual/anchors.md` per
`docs-single-source-and-anchors`), and every migration diagnostic ends with a `see:`
line pointing at one of them, the way `tesl help manual best-practices#…` already
works for other codes.

## Diagnostics and editor workflow

The editor operation behind `--migrate` was one sentence in earlier revisions; it is
where users will actually meet this feature, and it needs the same rigour as the
protocol.

### The MIG diagnostic family

`compiler/lib/error_codes.ml` gains a `Migration` category (it has none today —
`Proof`, `Capability`, `Security`, … exist), with registry and anchor tests like every
other family. Every MIG diagnostic carries: a stable code; a primary span; **related
locations** for the old declaration (snapshot), the new declaration, and the affected
query/write sites; why the rule exists; the safe alternatives; a `see:` anchor under
`migrations#…`; and its **action class** — *mechanical* (safe to apply silently),
*suggested* (offered, never in `source.fixAll`), or *decision* (requires explicit
acknowledgement in source, never a quick fix).

| Code | Reported by | Condition | Primary span | Related | Action class |
|---|---|---|---|---|---|
| MIG001 | compiler (`--check`, LSP) | the `database` names a schema module newer than the last migration's `to:` and no migration file bridges them | the `database` declaration | the two schema modules | mechanical (not fix-all): run `tesl --migrate` (editor: *Generate migration*) |
| MIG002 | compiler | migration entry missing / extra / `Unchanged` on a changed entity | the `migration` block or the entry | old + new entity decls | mechanical **only** for a generator-owned, unedited entry (add/remove it); **decision** when the entry was hand-edited — never deleted automatically |
| MIG003 | compiler | unresolved `todo` | the `todo` | the new field/proof that caused it, the `V7.User` fields available | decision (see below) |
| MIG004 | compiler / generator | ambiguous rename (removed + added same type) | the new field | the removed field | suggested: `Rename a b`; alternative: separate add/drop |
| MIG005 | compiler | removed field V7 still decodes, no `Legacy` | the removed field in the snapshot | the V7 declaration (V7 decodes every column it declares) | decision: `Legacy c v` / `LegacyWith f g` |
| MIG006 | compiler | a column V8 computes into a new column while V7 still decodes the old one, and no `WriteBack old new g` | the `Migrate` entry | the V7 declaration of the old column | decision: add `WriteBack old new g` or acknowledge `ROLL-WINDOW RISK` |
| MIG007 | compiler / generator | primary-key change / `Reset` (OFFLINE) | the entity | the plan header | decision: `Offline "…"`; suggested: `--suggest-online` |
| MIG008 | compiler | V8-introduced non-`Maybe` column whose row function is **not SQL-expressible** used inside SQL in V8 (renames and constant defaults are rewritten instead) | the query clause | the column decl | suggested: declare `Maybe`; or defer use to V9 |
| MIG009 | compiler | row function writes an existing (V7-written) column | the field init in the row fn | the V7 declaration (any V7 insert writes it) | **suggested**: new column + `Rename` *or* `Drop` — creating the column skeleton is mechanical, choosing rename versus drop is semantic |
| MIG010 | compiler | row function reaches a live-program function | the call | the callee | mechanical: copy the closure into the migration file |
| MIG011 | compiler | new unique index over V7-written columns | the `unique index` | the V7 declaration of the indexed columns | decision: acknowledge `ROLL-WINDOW RISK` |
| MIG012 | compiler | required migration file (`V<n-1>`/`V<n>`) or its stdlib slice missing or pruned too early | the `database` decl | — | mechanical but **not fix-all eligible**: the message names the file to restore; the editor offers a command, never a silent VCS operation |
| MIG013 | compiler (hash recorded in the next migration's header) **and** the boot gate (hash the database recorded) | a frozen schema module or migration file was edited after a later version was written | the edited declaration | the migration header that froze it | decision: revert the edit |
| MIG016 | compiler / generator | a fact or type a column names changed between the two modules (no `Same` entry) and the entity is `Unchanged` or `Additive` | the entry | the two declarations, the changed check body | decision: accept the generated `Migrate` re-validation skeleton, or restore the declaration |
| MIG018 | compiler | a pass-through column is not initialised by the exact projection `f: old.f` | the field initialiser | the two declarations of `f` | suggested: restore the projection; a real change is a new column |
| MIG020 | compiler | `from:`/`to:` are not consecutive schema modules of the same family | the field | the two module headers | mechanical: fix the reference |
| MIG021 | compiler | a `Migrate` row function's type is not `From.E -> Migrated To.E` for its entity | the function reference | the two entity declarations | suggested: fix the signature |
| MIG022 | compiler | a rule names a column of the wrong version/side, or a value/function of the wrong type | the rule | the column declarations | suggested: fix the rule (the message states the expected type) |
| MIG023 | compiler | two rules govern the same column | the second rule | the first | suggested: remove one |
| MIG024 | compiler | `Same` pairs declarations of different kinds or from the wrong modules | the `Same` | the two declarations | mechanical: regenerate |
| MIG025 | compiler | a non-compat module imports a generated `…Support` module (`insertOld<E>`) | the import | the support module header | none: these helpers exist only for compatibility tests |
| MIG019 | compiler | a `check`/`auth`/`establish` outside the declaring schema module mints a sealed (column) fact | the `ok … ::: F` | the fact's declaration | suggested: move the check into the schema module, or consume an existing check |
| MIG017 | compiler | a renamed column is not initialised by the exact projection of its old name (`b: old.a`) | the field initialiser | the `Rename` rule | **suggested**: restore the projection, or replace `Rename` with a new column + row function — removing a transform changes meaning, so never silent |
| MIG015 | compiler | the program imports a type from a schema module other than the one its `database` names (stale import after a version bump) | the `import` line | the `database` declaration | mechanical, fix-all eligible: rewrite the import to the current module |
| MIG014 | compiler (the runtime's primitive registry is known at compile time) | primitive tag referenced by an embedded migration not provided by this runtime | the migration file | the primitive | none: finalise and prune on the current runtime first |

Only the rows reported by the compiler can appear in the editor's Problems panel
before a deploy. MIG013 is reported by both: the compile-time check against the hash
in the next migration's header catches an edited history before it is built; the boot
gate re-checks against what the database recorded, for the case where history was
rewritten and rebuilt.

The **hole diagnostic (MIG003)** must carry enough to act without opening three
files: the expected type and required proof of the new field; the fields available
on the old row (`V7.User`: `id: String, email: String, name: String`); which new field
or invariant created the hole; a mechanical default **only** where exactly one
semantics-preserving value exists — `Maybe T` → `Nothing`, which represents absence
without inventing data; a new `List T` does *not* qualify, because "empty" is a
domain claim, and it is offered as a suggestion; and actions *Generate check
skeleton* and *Open old / new declaration*. Independent holes report independently:
the record construction that contains three `todo`s produces three MIG003s and **no**
cascading type error on the record itself.

**Decisions are not quick fixes.** `ROLL-WINDOW RISK`, `Drop`, `Reset`, `Legacy`,
`Offline "…"` are semantic choices about data; the editor may offer *Open
migration plan* or *Insert acknowledgement…* behind an explicit confirmation dialog,
but none of them appears in `source.fixAll`, and "make this field `Maybe`" is a
suggestion, never auto-applied. Mechanical actions — generate a skeleton, add an
`Unchanged` entry, copy a helper closure — are preferred quick fixes.

### LSP requirements

The current server (`runtime/go/internal/lsp/server.go`) applies code-action edits to
the active document only, exposes `workspace/executeCommand` with a single
`tesl.applyFix`, and filters diagnostics to the active document's path. Migration
tooling needs four things it does not have:

1. **Multi-file generation as a command over a non-mutating compiler API.**
   `tesl.generateMigration` under `workspace/executeCommand` must not shell out to a
   `--migrate` that writes files — a preview would no longer be a preview, cancellation
   could leave partial changes, and `WorkspaceEdit` document versions would mean
   nothing. So the compiler gains `--migrate --manifest-json`: it takes the
   open-document overlays, performs **no writes**, and returns an edit manifest — the
   files to create and the edits to apply (`migrations/notes/v<n>.tesl`,
   `v<n>-compat.tesl`, `v<n>-support.tesl`, `v<n>.stdlib.tesl`), each with the
   expected hash of the current on-disk/overlay content. The LSP presents the
   preview and applies the manifest **atomically as far as the protocols allow**,
   which needs saying precisely, because standard LSP does not by itself give
   "fails the whole edit if any file changed":
   - it negotiates `workspace.workspaceEdit.documentChanges`, `resourceOperations`
     containing `create`, and `failureHandling`; with `transactional` (or
     `undo`) available, **open** documents go through one `workspace/applyEdit`
     with versioned `TextDocumentEdit`s, so a stale version fails the edit;
   - **closed** files have no version to guard with, so the LSP server writes them
     itself: verify the manifest hash, write to a temporary file, atomic rename —
     a filesystem-level guarantee that does not depend on the client — and then
     tells the client the files changed;
   - without transactional failure handling on the client, the server applies open
     documents one at a time with a pre-check each and, on a failure part-way,
     applies the inverse edits it computed from the manifest and reports which
     files were touched; "fails the whole edit" then means "restored", not
     "never started", and the preview says so.
   The plain `tesl --migrate` CLI is manifest-then-apply over the same code, with the
   same hash checks. Ownership is fixed: the compiler computes, the LSP previews and
   applies, the extension presents.
1b. **A versioned diagnostic protocol.** Today's `--check-json` diagnostic carries one
   file/range, a message, a code and one fix payload. MIG diagnostics need, as
   **machine-readable** fields in a new protocol version: `relatedInformation`
   (file/range/message triples); `actionClass` (`mechanical` / `suggested` /
   `decision`) so `source.fixAll` never infers safety from message text or a
   hard-coded code list; `codeDescription.href` to the manual anchor; command
   arguments for multi-file actions; `needsConfirmation` for anything that is a
   decision; and `fixAllEligible`, **separate from** `actionClass` — a fix can be
   mechanical (deterministic, one correct result) and still not belong in
   `source.fixAll`: restoring a file from version control (MIG012), generating three
   files (MIG001), or copying a closure across files (MIG010) run as explicit commands
   with a preview even though their result is deterministic. Fix-all is restricted to
   small, idempotent, single-document source edits.
2. **Cross-file diagnostics.** MIG diagnostics span the entry file, the snapshot, the
   migration file and affected queries; publishing them only to the active URI drops
   most of them. Publish grouped diagnostics to every affected URI (or implement
   workspace diagnostics), and use `relatedInformation` to connect migration entry ↔
   old/new entity declaration, early SQL use ↔ introduced column, roll risk ↔ V7 write
   sites, hole ↔ required proof.
3. **An unsaved-buffer policy.** The CLI reads disk; the diagnostic may come from an
   unsaved buffer. `tesl.generateMigration` passes the open-document overlays to the
   compiler; if that is not possible it prompts to save all dirty Tesl documents, and
   otherwise refuses with the list of unsaved files. Generating from stale disk state
   is never silent.
4. **AST-aware refresh with explicit ownership.** Re-running the generator on an
   unfinished migration works on the parsed form, never on text, and follows one rule
   set: every generated node carries a provenance marker (a stable id **and a
   canonical AST fingerprint of the generated baseline**, in a trailing comment the
   parser preserves — an id alone says which node this is, not whether its content
   changed); a generated node whose current canonical AST still matches its baseline
   fingerprint is *untouched* and may be replaced or removed; a node the user has **edited** is user-owned — it is never
   deleted or rewritten automatically, and if the new diff no longer wants it, it stays
   in the file with a MIG002 (decision class) pointing at the old and new declarations,
   and the editor offers a diff-based resolution. The same fingerprint is what lets
   MIG002 tell a generator-owned entry from a hand-edited one reliably. Row functions, `Legacy`/`WriteBack`
   clauses and acknowledgements are user-owned from the moment they are written.

### VSCodium extension

`editor/vscode-tesl/package.json` contributes no migration command today. Add:
*Tesl: Generate / Refresh Migration* (with progress and cancellation, a preview of the
files to be created or changed, opening `migrations/V<n>.tesl` afterwards with the
cursor on the first `todo`, and a diagnostics refresh); CodeLens on a `migration`
block for *Open previous snapshot*, *Run migration tests*, *Explain MIGnnn*; and a
plan-summary view showing `ONLINE` / `ROLL-WINDOW RISK` / `OFFLINE` per entity. Every
live-database operation (`--schema …`) stays a terminal or task command the user runs
deliberately; nothing in the editor talks to a database.

## Row-level security policies (companion, from Acadia)

Acadia's strongest idea is that a table **cannot be touched without a policy**, and
that the policy is a record of four predicates. Tesl already has the two halves a
policy needs: a proof-carrying actor (`user: User ::: Authenticated user`, `&& Admin
user`) arriving through the `auth … via` line, and entity-scoped capabilities
(`roadmap/next/entity_scoped_db_capabilities.md`) for the **table-level** question
"may this code touch `Note` at all". A policy is the **row-level** layer under that.

Sketch, deliberately close to Acadia's shape:

```tesl
entity Note table "notes" primaryKey id {
  id:      String
  ownerId: String
  body:    String

  policy for actor: User {
    read   actor row          = row.ownerId == actor.id
    insert actor row          = row.ownerId == actor.id
    update actor before after = before.ownerId == actor.id && after.ownerId == before.ownerId
    delete actor row          = row.ownerId == actor.id
  }
}
```

- Every query form on a policied entity names the actor
  (`select n from Note as actor where …`, `insert Note as actor { … }`; exact
  syntax open). Omitting it is a compile error: there is no way to write the query
  without going through the policy. `policy unrestricted` is the explicit opt-out
  and is what a `Session` table declares.
- **Erasure through proofs** is Tesl's version of Acadia's "static symbolic
  evaluation". A clause is discharged at compile time when the call site already
  holds a fact that implies it — `row ::: OwnedBy actor row`, or `actor ::: Admin
  actor` with an `Admin` arm in the policy — and no code is emitted for it. A clause
  not discharged is compiled into the `WHERE` (for `read`/`update`/`delete`) or a
  pre-write check (for `insert` and the `after` side of `update`) that aborts the
  transaction. Fail closed, like every other checker judgment.
- `update` seeing **before and after** gives immutable columns for free
  (`after.ownerId == before.ownerId`), which is the most common policy in practice
  and the one people forget in hand-written `WHERE` clauses.
- Policies live in the snapshot. A policy change appears in the plan header as
  `Note POLICY CHANGED (update: ownerId no longer immutable)`, so a security
  relaxation is reviewed in the same place as a dropped column. A policy change is
  itself subject to the two-version rule only trivially (it is code, not schema), but
  a **tightening** means V7 instances still accept what V8 rejects for the roll
  window; the header says so.
- Backfill and the lazy read path run as the system, not as an actor; policies do
  not apply to them, and the plan header says so when a policied entity is migrated.
- Whether a policy is **mandatory** on every entity (Acadia) or only once the program
  declares any `auth` line is the main question for the row-policy roadmap file. Acadia's answer is right for a
  database language; for Tesl, a lint that becomes an error one release later is the
  likely path.

This deserves its own roadmap file once the migration snapshot exists, because the
snapshot is what makes a policy change auditable. It is included here so the two are
designed together rather than retrofitted.

## Review 2026-09-02 and what it changed

**Current mechanisms (authoritative — read this, not the history below, as the
requirements summary):**

| Concern | Mechanism now |
|---|---|
| admission | two dimensions, never mixed: **program version** for admission, **entity generation** for rows. `tesl_schema.min_version`; **writes and deletes**: `pg_advisory_xact_lock_shared(fence(v))`, then a separate `select min_version` (READ COMMITTED); **reads**: query first, then `select tesl_admit(v)` in the same pipelined transaction, rows released only after it returns — the query's table lock and the later snapshot are the ordering guard, no advisory lock (§13); server-side trigger fence for writes under evaluation, and only with a separate program-version GUC |
| retirement | one transaction: exclusive xact lock on the retiring version's fence, `min_version = v+1`; also waits for `pg_stat_progress_create_index` to be empty |
| nontransactional DDL | dedicated DDL connection (`ddlConnection`, a **trusted** direct/session-mode DSN) holding a session-level shared fence, opened at boot step 9b; or a single `--schema worker`; version-suffixed object names |
| "not yet migrated" | permanent per-row `_tesl_v smallint` holding the **entity generation** (increments only on row-function migrations, so unchanged entities never need touching); atomic per entity; only inserts, backfill, read-modify-write may stamp; trigger only lowers |
| V7 writes during the window | invalidation trigger, `least(old, target-1)` unless `tesl.writer >= target`; lives until the version is retired |
| V8 writes touching the closure | read-modify-write with `set_config('tesl.writer.<entity>', <generation>, true)`; partial upserts likewise unless provably outside the closure; the GUC is trusted because Tesl owns all writes |
| backfill | `_tesl_v = g-1` exactly (per-entity generation); conditional on source values read; provisional until retirement, final after |
| topology | one logical primary; HA failover survives every guard; asynchronous read replicas (future) give only **lagged** retirement for reads — strict retirement needs admission against the primary or a bounded-lag mechanism; sharding a non-goal; PostgreSQL 12+ built-ins only (§12) |
| concurrent boots | `boot` lease serialises expand/retire; every step idempotent (`IF NOT EXISTS`, unique `(version, step)` rows, compare-and-set `min_version`); waiting instances are not ready |
| who does the work | `tesl_schema_leases` (boot, backfill, index:<name>); leases never guard safety; lock order boot → fences ascending → leases |
| SQL use of a new column | compile error in the introducing version unless `Maybe`; from the next version, readiness waits for the final pass |
| unique indexes | every new one gates readiness; over V7-written columns = `ROLL-WINDOW RISK` |
| cross-version identity | generated `same { V9.T = V8.T }` block from equality of the **semantic closure** (checks, helpers, codecs, frozen stdlib, primitive tags), honoured inside the migration file only; a changed closure forces re-validation |
| compatibility-check input | the frozen previous schema module only — complete-record inserts and whole-row selects make it a sound over-approximation of the previous program; no record of handler usage exists |
| migration file | one folded record `Migration { from, to, same, entities: { E: Entity … } }` with the `Tesl.Migration` ADTs `Entity` (`Unchanged`/`Additive`/`Derived`/`Migrate`/`New`/`Drop`/`Reset`) and `Rule` (`Rename`/`Default`/`Legacy`/`LegacyWith`/`WriteBack`/`Offline`); no keywords |
| row function | ordinary `fn (Old.E) -> Migrated New.E` (`Row`/`Reject`); checks applied via `Check.attempt` (Maybe-returning); pass-through and renamed columns must be exact projections (MIG018/MIG017); runner maps `Reject` to backfill stop / lazy 500 |
| sealed facts | a column fact may be minted only by checks in its declaring schema module (MIG019), so `same` and derived `CHECK`s see every minter |
| compatibility tests | generated `…V<n>Compat` + `…V<n>Support` modules, self-contained, Memory-backed as unnamed tests, importing no application code; structural only, fixtures are the developer's |
| versioning unit | hand-written `schema module NotesSchema.V<n>` (entities, facts, checks, codecs, pure helpers; nothing else, compiler-enforced); imported explicitly by the program; `database { schema: NotesSchema.V<n>, migrations: NotesSchema.Migrate }` — module references, no strings; one version per database (MIG015) |
| migration identity | frozen closure (migration file + both schema modules + stdlib slice) + primitive tags with retained implementations; hash of typed IR; older modules frozen at compile time by the hash in the next migration's header (MIG013) |

**History.** Each pass below is recorded as it was resolved at the time; a row marked
*→ superseded* was later replaced by the mechanism in the table above.

An independent review of the first two-version draft found eight issues; all are
folded in above, and the four that were protocol-level are worth recording because
each one turned a "by construction" claim into a specific mechanism:

| Finding | Resolution |
|---|---|
| backfill lost-update race: read `a=x`, V7 writes `a=y`, write `b=f(x)` under `IS NULL` only, never revisited | backfill predicate includes every source column `IS NOT DISTINCT FROM` the value read (§6 invariant 2) |
| heartbeat TTL is not a fence: a paused V7 resumes after contract | shared advisory lock held by every V7 connection *→ superseded (pass 4): per transaction, two statements (pass 5)*; heartbeat is observability only (§6 invariant 1) |
| lazy read fixes decoding, not SQL: a new column in `where`/`order`/`groupBy`/join/aggregate is evaluated on `NULL` by PostgreSQL | readiness gate: V8 is not ready until such columns are backfilled; `Maybe` is the escape (§6 invariant 3) |
| column removal is not online: V7 decodes the column as non-null, V8 inserts leave it `NULL` | `legacy c` (database default) or `legacy with g` (dual write) required unless the snapshot proves V7 never decodes it (§2) |
| a new unique index makes V7 duplicate inserts fail once `VALID` | `ROLL-WINDOW RISK` unless the index covers only new columns; frozen V7 module names the columns (§7) |
| `pg_advisory_xact_lock` cannot span per-statement transactions | session-level lock on a dedicated boot connection *→ superseded (pass 4): the `boot` lease* (§6) |
| "total" row functions with a hidden abort | row functions are `check` functions: `ok`/`fail` in the type; `Positive age` with default `0` corrected to `NonNegative` (§4, §5) |
| commit ≠ applied artefact | hash check binds the database to the embedded files; provenance is the build system's (§11) |

A **re-review** of that revision found six more, all centred on one boundary the
draft had left implicit — *V7 is absent right now* versus *V7 can never return* — and
the fix was to make that boundary a stored, irreversible state (`min_version`,
advanced only under V7's exclusive fence) and sequence everything after it:

| Finding | Resolution |
|---|---|
| fence check-then-lock race: contract could commit between the admission check and the shared lock | lock first, then check while holding it; retirement writes `min_version` under the exclusive lock (§6 invariant 1) *— per connection then; per transaction since pass 4* |
| trigger dropped on "fence currently free"; a V7 rollback then re-nulls a source column with no trigger | trigger lives until V7 is **retired**; backfill is provisional until then, final only after (§2, §6) |
| SQL-use readiness gate deadlocks a normal roll (V8 unready → V7 never drains → backfill never final) and a "complete" scan is invalidated by the next V7 write | compile error: a V8-introduced non-`Maybe` column may not be used inside SQL in V8; use it from V9, whose readiness waits for the final pass after V7's retirement (§6 invariant 3) |
| offline path waited on heartbeat expiry | takes every admitted version's fence exclusively and advances `min_version` while holding them; heartbeats are diagnostics (downtime path) |
| only `onConflict`-targeted unique indexes gated readiness | every new unique index gates readiness (§7) |
| concurrent index builds had no single owner | per-index session advisory lock *→ superseded (pass 4): `index:<name>` lease, and (pass 6) the build itself runs on the session-fenced DDL connection*; state table is observability (§6 step 10, §7) |

A **third pass** confirmed the state machine and found five consistency and scope
issues, folded in above: migration behaviour is now pinned by freezing helper code
into the migration file and hashing the typed IR of its closure rather than the file
text (§11); the summary and load sections say "until V7 is retired" rather than "until
no V7 is alive"; every remaining "`onConflict`-only" readiness wording was aligned with
the rule that every new unique index gates readiness; primary-key changes are stated
as unsupported online in v1, not as a PostgreSQL impossibility; and the fence's
dependence on session-affine connections was made a detected precondition (§9) — a fix the fourth pass then replaced, see below.

A **fourth pass** found five more; two changed mechanisms. The `pg_backend_pid()`
pooler probe was both probabilistic (a transaction pooler can hand the same backend
back by chance) and hazardous (a session lock taken before the probe fails stays on a
backend the pooler keeps, blocking retirement) — so the fence became
**transaction-scoped** by default, which needs no session affinity and no detection,
with session-level as an opt-in for direct-connection deployments; and `new_col IS
NULL` cannot mean "unmigrated" when the migrated value is legitimately `NULL`
(renamed `Maybe`, transform into `Maybe`, a row function returning `Nothing`), so the
marker is now a permanent per-row `_tesl_v` column, which also removed the trigger's
coincidence case. The other three: hashing current stdlib behaviour detects drift but
cannot *run* the old behaviour when V9 must finish V8's pass, so `--migrate` now
freezes the reached stdlib slice into a committed file and primitives carry semantic
tags; a single global lock order (boot lease, fence keys ascending, job leases) with
the rule that leases never guard safety; and the snapshot/function-call rules were
made consistent (snapshots hold codecs and nothing else executable).

A **fifth pass** found six, two of them protocol-level. The one-statement fence read
its `min_version` from a snapshot taken *before* blocking on the lock, so it could
admit a retired version; the fence is now two statements (lock, then read), which is
sufficient at the READ COMMITTED level Tesl actually uses, with the `for share`
variant specified should a stronger level ever be offered. And "every V8 write stamps
8" could mark a row complete after an update to an unrelated field: `_tesl_v` is now an
atomic per-entity statement, only inserts, backfill and read-modify-write updates may
stamp it, the trigger only lowers it (`least(old, 7)`), V8 read-modify-writes identify
themselves with a transaction-local `set_config`, and backfills chain strictly one
version at a time (`= g-1`, never `< g`), which fixed the binary's contents at the two
most recent migrations and added a boot refusal when the prior migration is not
final. The rest: retained primitive implementations behind version tags so a frozen
migration can still execute after a runtime upgrade, with a build-time failure rather
than a boot refusal when a tag is gone; progress recorded per entity, not per column;
"transactions", not "connections", in the offline procedure; and an
`pg_stat_progress_create_index` check before dropping an invalid index, since a
concurrent build looks invalid while it runs.

A **sixth pass** found five. The trigger's writer test was equality (`= '8'`), so a
coexisting older trigger (V6→V7, awaiting removal) would demote a V8 read-modify-write
that had in fact chained the row through both closures — the test is now ordered
(`writer < target` demotes). Nontransactional DDL ran in autocommit with no fence at
all, so a worker paused across a retirement could resume and recreate a dropped
unique index — it now runs on a dedicated session-fenced DDL connection (the one place
a session lock survived the fourth pass, with its session-affinity precondition
documented and failing closed), objects carry the creating version in their names,
and retirement waits out server-visible builds. Partial `upsert … doUpdate` was a
writer the read-modify-write rule had not classified — it now is. The index heading
said `ONLINE` for every index; it says non-blocking, with the unique-over-V7-columns
risk kept. And the history tables gained an authoritative current-mechanism table
above them, with superseded rows marked.

A **seventh pass** found five, one architectural. The marker held the global schema
version, so an entity unchanged in V8 kept rows at `7` that a V9 migration selecting
`= 8` would never see, and advancing every unchanged entity per release would be a
whole-database rewrite; `_tesl_v` is now the **entity's generation**, incremented only
by a row-function migration, with the snapshot mapping versions to generations. The
DDL connection's fail-closed claim was too strong — some poolers reset session state
and release the lock silently — so `ddlConnection` is stated as a trusted
direct/session-mode requirement, with a single `--schema worker` as the clearest
deployment. The DDL connection is now an explicit boot step (9b) that readiness
depends on. `_tesl_v` is described as a materialisation audit, not a writer audit. And
the one-round-trip pipelined transaction is a tested pooler-compatibility condition.
The maintainer's question in the same round — many instances booting at once, or
before the first migration — is answered in §6 "Many instances booting at once":
serialised by the `boot` lease, idempotent in every step, nobody ready while waiting.

An **eighth pass** moved from protocol to product. The SQL examples still used schema
versions where the mechanism now requires entity generations (fixed: `User` gen 3→4
throughout, `tesl.writer.users`); the DDL precondition's "fails closed" wording was
still overstated in one place (fixed under "Decisions before phase 1"); the writer
GUC's trust model was unstated (now: Tesl owns all writes, external writers
unsupported during a migration); and tooling had one sentence. It now has a section:
a MIG001–MIG014 taxonomy with action classes, the hole diagnostic's contents, the rule
that decisions are never quick fixes, and the LSP/extension requirements (multi-file
generation as a `workspace/executeCommand`, cross-file diagnostics with
`relatedInformation`, an unsaved-buffer policy, AST-aware refresh). The open
questions were split into decisions, non-goals, acceptance criteria and genuinely
open items. The same round added §12 (topologies) and §13 (what the compiler removes
from the runtime, including the read-only-no-fence rule and the server-side write
fence alternative) from the maintainer's questions.

A **ninth pass** caught a regression and finished the tooling cut. Exempting reads and
deletes from admission (§13, previous pass) was wrong: retirement means the version may
not *run*, and a resumed zombie must not read under a weakened policy or delete after
a contract. The fix keeps the performance goal — reads are admitted by a lock-free
`tesl_admit` initplan inside the query itself, deletes take the write fence — and adds
a 15-second liveness poll for idle zombies. The rest: the last schema-version literal
in the rename row; a *reported by* column in the taxonomy (MIG013 is a boot-time
diagnostic, never a compile-time promise); MIG002 and MIG009 downgraded from
mechanical, `List → []` no longer a mechanical default; a non-mutating
`--migrate --manifest-json` API with a versioned diagnostic protocol carrying
machine-readable `actionClass`; an explicit ownership rule for refresh; editor-journey
acceptance tests; a phase-1/phase-2 tooling cut; and the last open questions turned
into decision gates or moved to their own items.

A **tenth pass** found the read guard and the trigger alternative both using the
entity generation where admission needs the **program version** — the two dimensions
are now stated as separate everywhere (generation for rows and dual writes, version
for admission), and the trigger alternative is a candidate only with its own
`tesl.version` GUC. Tooling: LSP capability negotiation and what "atomic" means with
and without `transactional` failure handling (closed files are written by the server
with hash-check + atomic rename); provenance carries a canonical baseline fingerprint,
since an id cannot tell whether a node was edited; `fixAllEligible` separated from
`actionClass`; phase-1 acceptance no longer tests phase-2 behaviour; "read path at
zero" replaced by a measured admission budget; replica retirement stated as lagged;
two stale open-question references fixed.

A **worked example** (`notes` V7→V9, above) was then written end to end — program,
snapshots, generated and committed migration file, plan header, every SQL statement
the binary runs at boot, in the window, in the backfill and at contract — and exposed
six gaps, all folded in: snapshots carry facts; a `new` entry word; MIG008 exempts
SQL-expressible row functions (renames, constants) by rewriting the SQL use in the
window; the Memory backend models generations for the compatibility test; the
`tesl_admit` function and schema tables are created at first bootstrap; the plan
header reports index usability during the window.

After the worked example, the maintainer changed the **versioning unit**: from "live
entity declarations plus a generated snapshot" to a **hand-written `schema module` per
version that the application imports explicitly**, with the `database` declaration
naming the schema module and a mandatory `migrations:` namespace as module references
rather than strings. Consequences folded in: no generated copy of the current version;
checks and codecs declared once in the schema module and shared by handlers and the
migration through imports; the migration file bridges `Old`/`New` modules (Acadia's
`OLD.`); a stale import is a compile-time MIG015 with a mechanical fix; frozen versions
are checked at compile time by the hash in the next migration's header (MIG013 gained a
compile-time half); a per-version "footprint" of V7's handler usage was briefly the
only other generated artefact and was then dropped (next entry).

A **source-language review** of the worked example (the eleventh pass) found the
proposed Tesl surface less coherent than the protocol beneath it, and the example was
rewritten as an intended-to-compile golden fixture: an `additive` entry distinct from
`unchanged`; one row-function model (`check` returning a record, stated as a language
change, invoked and failing like every check, no `Ok`/`Fail` matching); compiler-owned
`rename`; the compatibility test in its own generated module with typed
`insertOld<Entity>` helpers and generator- or hole-based fixtures; module references as
a new expression kind and `migrations:` as a scanned prefix, with qualified names
instead of an import alias; a typed-IR linking rule for the frozen stdlib slice; a
valid-Tesl application; `same` over semantic closures; a per-clause SQL-expressible subset; the
retirement guarantee scoped to schema versions; and the last schema-version literals
in the lazy-read and summary text replaced. Gaps 1–13 above record each.

The maintainer then asked whether the entity declaration alone was not enough, and how
a schema module could know what the application reads and writes. It cannot, and it
does not need to: the **footprint artefact was removed**. The frozen module is a sound
over-approximation because inserts are complete record literals and selects decode
whole rows; the precision a footprint offered is noted as a possible later refinement.

The maintainer then asked for **records and ordinary functions instead of keywords**,
and a twelfth review pass landed at the same time; the two were folded together. The
migration file is now one `Migration { … }` record with `Tesl.Migration` ADTs
(`Entity`, `Rule`, `Migrated`, `Same`), row functions are plain `fn`s returning
`Row`/`Reject` with checks applied through a Maybe-returning `Check.attempt` (no
`check` extension, no proofless `ok`, no ignored HTTP status), pass-through and
renamed columns are exact projections (no injected fields), pure renames and constant
defaults have entries (`Derived`, `Additive [Default …]`), column facts are **sealed**
to their schema module (MIG019), the compatibility module is self-contained and
Memory-backed with typed generated helpers and no universal success property, the read
admission is a separate pipelined statement rather than a target-list initplan, the
manifest lists every generated file, the phase texts and MIG list match the final
model, the `v9` schema block is complete, and the last `< 8` literals are gone.

A **thirteenth pass** found two blockers in the new source design and four gaps. The
`Migration` record's constructors were presented as ordinary ADTs but are typed
contextually — `Migration { … }` is now stated as a compiler-known folded declaration
like `Database`/`App`, with an elaboration table and MIG020–MIG024. The
admit-then-query read order proved nothing under READ COMMITTED (separate snapshots,
no lock yet held): reads now run **query first, then admission**, so the query's table
lock and the later snapshot form the guard, with rows released only after admission
returns. `WriteBack` names both endpoints; `Check.attempt` is a compiler intrinsic
returning `Attempt` with the validator's reason; the support module has a privilege
boundary (`schemaTest`, test-only, MIG025); `Derived`'s description, the phase-2 text
and the acceptance criterion were aligned; and "Open questions: none" was replaced by
the four items genuinely still open.

The title was softened from "by construction" to "rolling deploys" in the same pass:
the `ONLINE` class is zero-downtime under the stated protocol, and the two
`ROLL-WINDOW RISK` cases and the `OFFLINE` class are named rather than claimed away.

## Phases

1. **Versions, snapshots, gate, expand-at-boot for additive changes.** `tesl_schema`,
   `tesl_schema_instances` + heartbeat, `schema module`s with the one-version rule (MIG015) and compile-time freezing (MIG013),
   `min_version` + retirement + the transaction-scoped fence + the session-fenced DDL connection + `_tesl_v`, the lease table and lock order, `--migrate`, `--schema status|adopt|retire`, classification, the compatibility check, expand DDL with
   `lock_timeout`, `CREATE INDEX CONCURRENTLY` in the background with single-builder
   ownership, the readiness gate for every new unique index, and the duplicate
   pre-check in `dry-run`. Every non-additive diff is a `todo`; `OFFLINE` changes get the
   MIG-series error with the procedure. **Tooling cut for phase 1:** MIG001, MIG002,
   the additive part of MIG004, MIG007 classification, MIG008, MIG011, MIG012, MIG013,
   MIG014, MIG015, MIG016 for `Additive`/`Unchanged`; the non-mutating manifest API, the versioned diagnostic protocol, the
   `tesl.generateMigration` command with preview and versioned apply, cross-file
   diagnostics, the unsaved-buffer policy. "Every non-additive diff is a `todo`" in
   phase 1 means the generator emits a rejected placeholder for it; the functional
   typed-hole workflow is phase 2. Fixes the stale tour/spec text. This alone
   closes the "column added, dies at request time" hole and restores plain-index
   creation — the most common production change, made zero-downtime.
2. **Row functions and the online lifecycle.** The `Migrate`/`Derived` entries and the
   `Rename`/`Legacy`/`LegacyWith`/`WriteBack` rules, `todo`, ordinary `fn` row functions
   returning `Migrated`, `Check.attempt`, dual writes, lazy read, conditional batched backfill, the fence,
   with leader election, retirement + contract at next boot behind the fence, `dry-run`,
   the generated compatibility and support modules, Memory-backend execution in `tesl
   test` — including a generation marker and lazy read path in the Memory store and the
   generated typed `insertOld<Entity>` helpers so the compatibility test is a real
   two-version test — `Check.attempt`, sealed facts (MIG019), and frozen schema modules
   as frozen record types in the checker. **Tooling for phase 2:** MIG003 (with the
   hole contents), MIG005, MIG006, MIG009, MIG010, MIG017, MIG018, MIG019, MIG021–MIG023, MIG025, the row-function actions
   (*Generate check skeleton*, copy-closure), the AST-aware refresh with ownership.
3. **OFFLINE path and `reset`.** `--schema apply-offline --wait-for-drain`, shadow-table
   copy, the all-fences-exclusive check, `--migrate --suggest-online` for primary-key changes,
   the manual chapter and its anchors.
4. **JSONB integration.** Plan awareness of codec fallback lists; generate or verify
   the legacy decoder from the snapshot codec; "may be removed at V<n>" tracking.
5. **Row-level policies.** Own roadmap file; depends on 1 for the snapshot and on
   entity-scoped capabilities for the table layer.
6. **Later:** cross-entity reads inside row functions; write-back on read as an
   option; api/wire shape in the snapshot so a breaking endpoint change shows in the
   same plan header (Acadia's `endpoints` section — Tesl's generated clients make
   this cheap to detect); compiling simple row functions to SQL expressions so the
   backfill runs server-side.

## Decisions before phase 1

These are decision gates, not research; each has a leaning and a reason, and phase 1
should not start until they are closed.

- **Retirement timing default.** Leaning: at the next version's boot, with `--schema
  retire` for closing the rollback window earlier. Alternative: automatic after the
  roll completes plus a grace period — faster cleanup, but it closes rollback while
  the new version is newest, which is when rollback is most likely. Product policy.
- **Granularity is per `database`, keyed by module references.** Each `database`
  names its schema module (`schema: NotesSchema.V8`) and its migration namespace
  (`migrations: NotesSchema.Migrate`, mandatory), and has its own `tesl_schema`. What
  remains to decide is the small language addition this needs — a module reference as
  a `Database` field value, which Tesl does not have today — and the file layout
  convention the module names imply (`schema/notes/V8.tesl`,
  `migrations/notes/V8.tesl`). The optional `ddlConnection:` and `fence:` fields and
  their defaults are decided with it.
- **DDL topology.** The DDL connection's session affinity is a **trusted deployment
  requirement** that the runtime cannot verify and that does *not* universally fail
  closed (a proxy that resets session state releases the lock silently). Decide:
  `--schema worker` with a direct DSN *required* when a transaction pooler is in the
  path, *recommended* otherwise; or optional everywhere. Leaning required-under-pooler.
- **Admission mechanism: transaction-scoped advisory fence (current) versus the
  server-side write-fence trigger (§13 alternative).** The trigger is a candidate only
  once it carries a separate trusted program-version GUC (`tesl.version`) checked
  against `min_version` and the pre-final-pass barrier; with those in its design,
  benchmark both on the write path at target throughput and pick the lower p99 cost —
  the trigger wins on moving parts, the lock wins on keeping PL/pgSQL off every table.
  Correctness first, then performance.
- **`_tesl_v` permanent versus per-migration marker.** Leaning permanent (two bytes a
  row; dropped columns leave `pg_attribute` tombstones against the 1600-column limit).
  Foundational: decide before any table is created with it.
- **Entity-generation representation.** `smallint` allows 32 767 row-function
  migrations of one entity — unreachable in practice, but the overflow policy must be
  stated (refuse at `--migrate`, suggest a `reset`-free re-baseline) rather than
  discovered.
- **Diagnostic protocol and edit ownership.** The compiler emits a non-mutating edit
  manifest and structured diagnostics (`relatedInformation`, `actionClass`,
  `codeDescription`, command arguments, `needsConfirmation`) under a new protocol
  version; the LSP owns preview and atomic versioned application; the extension owns
  presentation only; edited generated nodes are user-owned until explicitly resolved.
  Decide the protocol version and field names before any MIG code ships.
- **Entry-file and database discovery in the editor** for a workspace with several
  programs or several `database` declarations: a workspace setting, a `tesl.json`, or
  inference from the open file's import graph. Leaning inference with a setting as
  override; blocks `tesl.generateMigration`.
- **Refresh conflict rule.** Adopt the ownership rule of the LSP section (provenance
  ids; untouched generated nodes replaceable; edited nodes never auto-deleted; stale
  edited nodes stay with MIG002 and a diff resolution). Decide the provenance marker's
  concrete syntax.
- **Module re-export for a schema facade.** Whether to add `module X exposing […]
  reexporting Y` (or an equivalent) so that large applications can import an
  unversioned `NotesSchema` facade and bump one line per schema change. General
  language feature, small; the migration design works without it (MIG015 + fix-all),
  so it is a convenience gate, not a blocker.
- **Reserved names.** `_tesl_v`, `tesl_schema*`, `tesl_mig_v*` triggers/functions,
  `*_v<n>` index suffixes and the `tesl.writer.*` GUC prefix are reserved; a user
  entity field or table name that collides is a compile error. Decide the exact
  prefix set once.

## Non-goals (v1)

- Down migrations. Rollback is redeploying the previous binary, or a new forward
  migration.
- Online decomposition of primary-key changes (OFFLINE; `--suggest-online` offers the
  new-entity alternative).
- Skipping versions: a binary two versions ahead of the database is refused.
- A signing step for plans (the commit is the approval; the hash binds the database
  to the embedded artefact; provenance is the build system's).
- External writers to entity tables during a migration.
- Sharded / multi-primary PostgreSQL (Citus has a stated future path, §12; multi-primary does not).
- PostgreSQL below 12.
- Snapshot as JSON: snapshots are Tesl source; the hash is over the elaborated
  catalog.

## Acceptance criteria (phase 1)

- Fence overhead on a write transaction: measured, and below an agreed budget (the
  proposal is ≤ 5% p99 latency at the reference load). Read admission: **no advisory
  lock and no extra round trip** — the one admission statement per read transaction is
  measured against its own budget (proposal ≤ 1% p99); "zero" is not a supportable
  claim and is not made. Ordering tests: a retirement interposed between query and
  admission aborts the transaction; between admission and commit, pre-retirement rows
  are delivered; a contract DDL interposed anywhere blocks until commit.
- Rolling deploy V7→V8 on a 10M-row table with continuous writes: no failed request
  attributable to the migration in the `ONLINE` class; a documented, bounded failure
  count in the `ROLL-WINDOW RISK` class.
- (Phase 1) additive generation: snapshot + migration files created for an additive
  diff, `unchanged` entries and the plan header correct; every non-additive diff
  produces a placeholder entry the compiler rejects with a phase-1 diagnostic naming
  the change — the typed-hole *workflow* (MIG003 contents, skeleton actions) is phase 2.
- (Phase 2) the generated compatibility test and the two-version Memory-backend test
  pass for every row in the decomposition table.
- Concurrent boot of ten instances against an empty database, a V7 database and a
  half-expanded database: exactly one expander, no duplicate state rows, nobody ready
  early.
- Pooler compatibility suite: the pipelined fenced transaction against PgBouncer
  (session and transaction mode) and direct connections.
- The phase-1 MIG codes (below) registered, with anchor tests; `source.fixAll`
  contains no decision-class action, verified from the machine-readable `actionClass`.
- Editor journey, each as an automated test against the LSP. Phase 1: a dirty buffer
  cannot produce a stale migration (overlays are used, or the command refuses naming
  the files); the preview lists all generated files; cancellation changes nothing on
  disk; diagnostics appear on affected files that are not open; a decision-class action
  never applies without confirmation; nothing with `fixAllEligible = false` runs from
  `source.fixAll`; a file changed between generation and apply is not overwritten (the
  edit fails, or is restored, per the negotiated capabilities). Phase 2: an edited row
  function survives a refresh (fingerprint-based); the created migration opens with the
  first MIG003 selected.

## Open questions

Four items are decided in direction but not yet specified to implementation depth,
and are listed here rather than claimed closed:

- **The exact elaboration rules of `Migration { … }`** — the table in §4 states what
  each position must be; the formal typing judgments (how `entities:` derives its record
  type from two modules, how `Migrate f` is checked against the specific pair) belong
  in LANGUAGE-SPEC before implementation.
- **The read-admission ordering proof** — the argument in §13 rests on `ACCESS SHARE`
  being held to commit and on READ COMMITTED snapshot ordering; it must be written up
  against the PostgreSQL manual's lock and snapshot rules and pinned by the interposed-
  retirement tests before phase 1 ships reads.
- **`Check.attempt`'s typing and evaluation** as a compiler intrinsic, and whether a
  general `Attempt` result type belongs in `Tesl.Check` for handlers too.
- **The `schemaTest` capability and test-only module kind** for the generated support
  module: how a test build grants it and how the production build excludes the module.

Two items were moved out — typed holes (`todo`) anywhere in the language belong to
their own compiler/LSP roadmap item, and whether row-level policies are mandatory
belongs to the row-policy roadmap file.
