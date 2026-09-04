# Schema evolution: schema modules, typed migrations, and zero-downtime rolling deploys

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

This file is the **normative** design. Its review history — sixteen passes, the
mechanisms tried and withdrawn, and why — is in
[`database-migrations-history.md`](database-migrations-history.md) and is not
normative; where the two disagree, this file and its "Current mechanisms" table win.

The bar (maintainer, 2026-09-02): migrations must ship as a solved problem, not a
toy. That rules out "run the migration, then deploy" as the story, because with a
rolling deploy that ordering does not exist.

## Summary of the proposal

1. **The schema is a hand-written module the program imports — `NotesSchema.VCurrent`
   — plus generator-frozen snapshots of every previous version.** Entities (and the
   facts, checks/establishes and codecs their columns need) live in the ordinary module
   `NotesSchema.VCurrent`; the application says `import NotesSchema.VCurrent exposing
   [Note, …]` once, and the `database` declaration names the module — not a string.
   Changing the schema is: the generator **copies** `VCurrent` to `V8.tesl` (frozen,
   compiler-checked hash), *then* you edit `VCurrent` in place — so the PR diff shows
   only the change and no import ever moves. Frozen versions stay in the repo so the
   migration can name `NotesSchema.V8.User` and be type-checked against it. This is
   Lamdera's `Evergreen/V<n>/Types.elm` with a hand-owned live module (maintainer,
   2026-09-04: Tesl is explicit about where every type comes from, and it has no
   re-exports).
2. **`tesl migrate generate` diffs the previous schema module against the current one** and
   writes the migration record (`migrations/notes/v8.tesl`, a `Migration { … }` with an
   entry **only for entities that changed** — an absent entity is compiler-verified
   `Unchanged`) plus the frozen stdlib slice it reaches; compatibility and support
   modules are deterministic build artefacts, not committed. Additive, loss-free
   changes are filled in by the compiler. Anything else is a typed hole (`todo "…"`)
   that is a compile error until a human replaces it. This is Lamdera's
   `Unimplemented` and Acadia's `.plan` file at once.
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
5. **Expand runs when V8 arrives** — at boot of the first V8 instance in development,
   and from a dedicated **schema worker** (the same binary, `--schema worker`, with a
   DDL-owning role) in production, where request processes hold an entity-DML role
   and no DDL authority. It is metadata-only DDL under a lease with `lock_timeout`
   retries, and V7 instances tolerate it by construction, so no hand-run migration step
   sits between build and deploy. This is the auto-migration the earlier draft wanted
   to remove, made safe by the rule and scoped by the privilege model (§11).
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
   `tesl_schema_state.min_version` names the oldest admitted version. Every **write**
   transaction a V7 instance runs first takes a shared **transaction-scoped** advisory
   lock on V7's fence key and reads that state under it — unconditionally, in every
   mode. Reads carry no admission by default in v1 (`admission: Trusted`): before a
   contract a post-retirement read still returns correct data, and after one it fails on
   the dropped column before any admission could run, so `Strict` — the query first, then
   `tesl_admit` in the same transaction, lock-free, rows released after commit — buys
   nothing until row-level policies exist; it ships as the opt-in and becomes the default
   with them (reopened by the 2026-09-03 review, §13 and "Decisions"). **Retiring** V7 (advancing `min_version` to 8) happens
   only while holding V7's key exclusively and only after every remaining V7-shaped
   row has been carried forward — so no V7 write is in flight at the moment of
   retirement, none can start after it, paused process or not, and no row is stranded.
   Nothing depends on which backend session a statement lands on, so transaction-mode
   poolers are fine for the request pool (the schema worker's DDL connection is the
   one exception, §6 invariant 7). **When** retirement runs is a product setting:
   the v1 default is an explicit `--schema contract` that the deployment pipeline runs
   once the old fleet is drained (the fence still makes it safe against a straggling
   writer); `contract: WhenDrained` or `NextVersion` makes it automatic. Only
   after it are V7's trigger dropped, `NOT NULL` set, and V7's columns dropped. Rolling
   back V8 → V7 is possible until retirement; V9 → V8 for the whole life of V9. The
   heartbeat table is observability, never a guard.
8. **The database records its state and its history** — one `tesl_schema_state`
   row for admission, append-only `tesl_schema_versions` rows for every expand,
   contract and repair, per-entity generation state — and the compiled program embeds
   the version it was built against. The boot gate admits any distance **inside a
   monotonic additive epoch** (only epoch-preserving changes since the epoch began) and
   refuses a binary more than one version away once the epoch has been closed to the
   two-version window. **Nothing is ever `ALTER`ed in
   a database that has data except the expand and contract steps a committed plan
   describes.**
9. **No down migrations.** A migration is a forward function. Rolling back is
   redeploying the previous binary, which the two-version rule guarantees still runs;
   undoing a schema change is a new forward migration.
10. **Row-level security policies** (Acadia's `Security.policy`) are the natural
    companion and are sketched in their own section; they become part of the
    snapshot so a policy change shows up in the plan for review.

## Everyday workflow (read this first)

Everything below this section is the machinery. This is what a developer does, in
order of how often they do it. Vocabulary needed for the 90% case: *schema module*,
*migration record*, *plan*, *hole*. Not needed: generations, fences, admission, leases,
contracts, repairs — those appear only in advanced diagnostics and operations.

1. **Change the schema.** Editor: *Tesl: Change Schema* (or `tesl migrate generate`).
   It resolves the target (asks if ambiguous) and **freezes** the current schema module —
   copies `v-current.tesl` to `v<n>.tesl` as `NotesSchema.V<n>` — and bumps nothing else.
   You then edit `v-current.tesl` like any other Tesl file. That is the whole "version
   history" management.
2. **Save; the plan appears.** The compiler diffs the two revisions and shows the plan
   header (`ONLINE` / `ROLL-WINDOW RISK` / `OFFLINE`, per changed entity) and a sparse
   migration record naming only what changed. For a nullable column, a constant-default
   column, a new entity or a plain index that is the end: nothing to write. A **unique**
   index over a column old code writes is the one "additive" change that is not
   harmless — the plan says so and suggests declaring it `staging unique index` first
   and promoting it next release (step 3).
3. **Resolve holes.** Where a value or a decision is needed — a computed column, a
   renamed field, a removed column old code still reads — the record carries a typed
   `todo` with the old row's fields and the required proof, and the editor opens at the
   first one. You write an ordinary function or pick a rule from completion.
4. **Test and deploy.** `tesl test` runs your unit tests and the generated two-version
   tests (`tesl test` is a CLI route this feature adds — `compiler/bin/main.ml` mentions
   it in an error message but does not route it; today tests run through the emitted Go
   test binary and `tesl --mutate`). Deploying the new version expands the database automatically (worker in
   production, boot in development) and backfills in the background. Old and new
   instances run together for the whole roll. One exception worth knowing about: after
   a run of additive releases, the first migration that *transforms* data asks the
   pipeline to close the additive epoch first — one previewed command
   (`app --schema close-epoch`) that touches no user table.
5. **Finalise.** When every hole is resolved, *Tesl: Finalise Migration* (or `tesl
   migrate contract V<n>`) previews and writes the `v<n>-contract.tesl` — a short,
   reviewed list of exactly what will be dropped later — so migration and contract
   authorisation **ship in the same build**. A purely additive change has no contract
   file and skips this step.
6. **Later, contract.** When the old version is gone, the pipeline runs `app --schema
   contract V<n>` — or it runs automatically, if you configured `contract: WhenDrained`.
   Nothing is rebuilt or redeployed for it.

Everything else in this document — repairs, offline changes, rebasing a branch,
pruning old revisions — is a first-class command with a preview, reached from a
diagnostic or from `--schema status`, and none of it is on the everyday path. The
generator refreshes an already-written contract file whenever the migration record
changes before it ships, so the two never drift.

## The developer-facing surface (spec): what a Tesl developer actually writes

(Added 2026-09-04 at the maintainer's request: one place that shows the code, counts
every new construct, and says what was deliberately *not* added. Shown in the
**`VCurrent` layout** — the maintainer's own formulation (2026-09-04) of the reopened
live-module decision: the generator copies the current module to `V<n>` *first*, then
the developer edits `VCurrent`, so at V9 the repository holds `VCurrent`, `V8`, `V7`; the
PR diff highlights only the change, and no import ever moves because they all name
`VCurrent`. Recommended; since Tesl has no re-exports it is the only layout that bumps no
application import. Under §1's hand-versioned layout only file names and import lines
differ.)

**New constructs — five, no new keywords.**

| construct | where | precedent / why not something existing |
|---|---|---|
| a **module reference** as the value of `schema:` and `migrations:` in `Database { … }` | the `database` declaration | `Database` fields are already typed contextually (`entities: [Note]`, `env "X"`); a string would not be checked |
| `todo "reason"` | generated migration skeletons | a well-typed expression that is always a compile error; Lamdera's `Unimplemented`; nothing existing can be "typed and refuse to build" |
| the `Migration { … }` / `Contract { … }` / `Repair { … }` records with entity names as fields and bare column names in rules | `migrations/…/v<n>.tesl` | same shape as `Database { … }` and `App { … }`; bare column identifiers already appear in `index [authorId]` and `onConflict [id]`; the constructors come from the stdlib module `Tesl.Migration` and are greppable |
| `@column("name")` on an entity field | schema module, written by the generator for `Retype` | `@db(type)` already annotates a field's storage type; this annotates its storage name |
| `staging unique index [cols]` | entity body | a declaration the two-release uniqueness recipe needs; `unique index` is the precedent |

**Deliberately not added.** No `schema module` / `entity module` / `shared module`
header kinds: the module `database … schema:` names *is* the schema module, and the
content rule ("only entities, their types, facts, `check`/`establish`, codecs and pure
helpers") is a diagnostic on that module and everything it imports, not a keyword. No
`entities { … }` / `shared { … }` root map and no `R<k>` entity revisions: a large schema
is a live module that **imports** one plain module per entity (`schema/notes/note.tesl`
is `module NotesSchema.Note`); the freeze copies the import closure into
`schema/notes/v7/…`. No `reexporting`. No `Check.attempt` / `Attempt` — `establish`
already is the non-propagating proof boundary. No `version N` header — the live module's
version is one more than the highest frozen snapshot beside it (`v7.tesl` present ⇒ live
is 8), which the generator maintains and the database hash verifies; a wrong guess is a
refused boot, not a corrupted table. Everything else below is Tesl as it is today:
`module`, `import`, `entity`, `fact`, `check`, `establish`, `fn`, `test`, records, ADTs.

**The whole thing, end to end.** Files for the `notes` database:

```
schema/notes/v-current.tesl          the LIVE schema, module NotesSchema.VCurrent — hand-owned, edited in place   committed
schema/notes/v7.tesl                 frozen snapshot of the previous version, module NotesSchema.V7 — written by the
                                     generator, byte-identical to the old live file but for the header      committed
migrations/notes/v8.tesl             migration V7 -> live: generated skeleton, holes filled by hand           committed
migrations/notes/v8-contract.tesl    what may be dropped once V7 is gone: generated, reviewed                 committed
notes.tesl                           the application — unchanged by a schema bump                             deployed
```

The live schema module — an ordinary module:

```tesl
module NotesSchema.VCurrent exposing [Note, Session, Tag, ValidWordCount, tryWordCount, checkWordCount, wordCountOf]

import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Time exposing [PosixMillis]
import Tesl.String exposing [String.split]
import Tesl.List exposing [List.length, List.filter]

fact ValidWordCount (n: Int)

establish tryWordCount(n: Int) -> Maybe (v: Int ::: ValidWordCount v) =   # the one minting boundary
  if n >= 0 then Something (n ::: ValidWordCount n) else Nothing

check checkWordCount(n: Int) -> n: Int ::: ValidWordCount n =               # handlers: same boundary, HTTP failure
  case tryWordCount n of
    Nothing -> fail 400 "negative word count"
    Something valid ->
      let (v ::: p) = valid
      ok v ::: p

fn wordCountOf(text: String) -> Int =
  List.length (List.filter (fn (w) -> w != "") (String.split " " text))

entity Note table "notes" primaryKey id {
  id:        String
  title:     String
  content:   String
  ownerId:   String                            # V7 called this authorId
  wordCount: Int ::: ValidWordCount wordCount  # new in V8
  createdAt: PosixMillis
  index [ownerId, createdAt]
}

entity Session table "sessions" primaryKey token {
  token:     String
  userId:    String
  expiresAt: PosixMillis
}

entity Tag table "tags" primaryKey id {         # new in V8
  id:     String
  noteId: String
  label:  String
  index [noteId]
}
```

The application names it once and never changes for a schema bump:

```tesl
import NotesSchema.VCurrent exposing [Note, Session, Tag, checkWordCount, wordCountOf]

database NoteDatabase = Database {
  schema:     NotesSchema.VCurrent             # module reference: the live schema module   ← new
  migrations: NotesSchema.Migrate              # module prefix: migrations/notes/v*.tesl     ← new
  backend:    Postgres (PostgresConfig { … })
}
```

The developer runs *Tesl: Change Schema* **first**: the generator copies
`v-current.tesl` to `schema/notes/v7.tesl` with the header rewritten to `module
NotesSchema.V7 …` (otherwise identical — `git diff -C` shows a 100 % copy) and records
V7's hash. *Then* the developer edits `v-current.tesl` (renames `authorId`, adds
`wordCount` and `Tag`, removes `legacyRank`); on save the generator writes or refreshes
`migrations/notes/v8.tesl`:

```tesl
module NotesSchema.Migrate.V8 exposing [migration, migrateNote]

import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Migrated(..)]
import Tesl.Maybe exposing [Maybe(..)]
import NotesSchema.V7                       # the frozen previous version
import NotesSchema.VCurrent                 # the live one

migration = Migration {
  from: NotesSchema.V7
  to:   NotesSchema.VCurrent
  same: []                                  # generated: V7 declares no type V8 also declares
  fixtures: [oldNote]                       # generated hole (MIG003) until you write oldNote
  entities: {                               # only what changed; Session absent = verified Unchanged
    Note: Migrate migrateNote [Rename authorId ownerId,
                               Legacy legacyRank (todo "V7 reads legacyRank as Int NOT NULL; V8 rows need a value")]
    Tag:  New
  }
}

fn migrateNote(old: NotesSchema.V7.Note) -> Migrated NotesSchema.VCurrent.Note =
  let wordCount = todo "V8 added `wordCount: Int ::: ValidWordCount wordCount`; V7.Note has id, title, content, authorId, legacyRank, createdAt"
  Row (NotesSchema.VCurrent.Note { id: old.id, title: old.title, content: old.content,
                          ownerId: old.authorId, wordCount: wordCount, createdAt: old.createdAt })
```

Two `todo`s; the program does not compile until they are gone. The developer replaces
them — ordinary Tesl, nothing migration-specific in the bodies:

```tesl
    Note: Migrate migrateNote [Rename authorId ownerId, Legacy legacyRank 0]

fn migrateNote(old: NotesSchema.V7.Note) -> Migrated NotesSchema.VCurrent.Note =
  case NotesSchema.VCurrent.tryWordCount (NotesSchema.VCurrent.wordCountOf old.content) of
    Nothing         -> Reject "note ${old.id}: negative word count"
    Something words ->
      Row (NotesSchema.VCurrent.Note { id: old.id, title: old.title, content: old.content,
                              ownerId: old.authorId, wordCount: words, createdAt: old.createdAt })

fn oldNote() -> NotesSchema.V7.Note =
  NotesSchema.V7.Note { id: "n1", title: "t", content: "one two", authorId: "u1", legacyRank: 0, createdAt: 0 }

test "V8: word count is computed from content" {
  case migrateNote (oldNote ()) of
    Row note -> expect note.wordCount == 2 && note.ownerId == "u1"
    Reject _ -> expect False
}
```

Handlers change only where the *types* changed — the rename and the new proof-carrying
field — and the compiler points at each site:

```tesl
handler post createNote(user: String ::: Authenticated user, body: NoteBody)
  -> Note requires [dbRead, dbWrite, time, random] =
  let words = check checkWordCount (wordCountOf body.content)
  insert Note { id: generatePrefixedId "note", title: body.title, content: body.content,
                ownerId: user, wordCount: words, createdAt: nowMillis() }
```

Deploy. Expand and backfill are automatic. Later, `tesl migrate contract V8` writes the
reviewed list of what may go once V7 is gone, and `app --schema contract V8` executes it
when `await contractable` says so:

```tesl
module NotesSchema.Migrate.V8Contract exposing [contract]

import Tesl.Migration exposing [Contract, Drop(..), Tighten(..)]
import NotesSchema.Migrate.V8

contract = Contract {
  of:      NotesSchema.Migrate.V8
  drops:   [Column Note authorId, Column Note legacyRank, Index Note notes_authorId_idx, Trigger Note tesl_mig_notes_g4]
  tighten: [NotNull Note ownerId, NotNull Note wordCount, Check Note wordCount]
}
```

When V9 comes, the generator copies `VCurrent` to `v8.tesl` (`NotesSchema.V8`) and, in
`migrations/notes/v8.tesl`, rewrites `to: NotesSchema.VCurrent` to `to: NotesSchema.V8`
and `NotesSchema.VCurrent.Note` to `NotesSchema.V8.Note` — a mechanical rename of
references to a byte-identical module, so the migration's semantic hash does not move
and MIG013 is not triggered. The repository then holds `VCurrent`, `V8`, `V7`, … — every
frozen version stays by default, because a backup or a curated test snapshot taken at
V3 is brought forward by replaying V4 … VCurrent (catch-up, §8); `prune` removes old
ones only with a recorded statement of the oldest snapshot that can still be restored.

**What if the copy fails?** (Maintainer's question.) The generator writes through the
same manifest as every other edit — expected-hash check, write to a temporary file,
atomic rename — so a *partial* frozen file cannot exist. The remaining failures and how
each is caught:
- **The copy was never made** and the developer edited `VCurrent` anyway. The last
  migration file records the hash of its `to:` module at generation time; a `VCurrent`
  whose hash differs is MIG001 at the next compile — "schema changed since migration V8
  was generated: refresh V8 (not yet deployed) or start V9 (freeze first)" — and the
  editor asks which. The compiler cannot know on its own whether V8 has shipped (it never
  sees a database), so that one question is the developer's; the answer is remembered.
- **The developer answered wrong** — refreshed V8 although V8 was already deployed
  somewhere. Compile time cannot see that; the **boot gate** does: the database recorded
  V8's `snapshot_hash` at expand, the rebuilt binary embeds a different one, refused as
  edited history (§8). Exactly the backstop the hand-versioned layout has for an edited
  `V8.tesl`, so the risk is the one the maintainer named: the same as today, no worse,
  and never a corrupted table.
- **The frozen copy is corrupt or hand-edited later.** Its hash is recorded in the
  migration that names it (`from: NotesSchema.V7`); any difference is MIG013 at compile
  time, as for every frozen module.
- **Two developers freeze concurrently** on branches: both create `v8.tesl` and
  `migrations/notes/v8.tesl` — the add/add conflict §1 already describes; `tesl migrate
  rebase` resolves it. A **purely additive** change (a `Maybe` column, an index, a new entity) is the
schema edit plus a generated record with one `Additive` line and no function, no fixture,
no contract file, nothing to fill in.

**What the same example looks like for a large schema.** `v-current.tesl` becomes a
thin root whose only job is to name the entity modules that make up the database
(imports are membership; the root exposes nothing, because Tesl has no re-exports):

```tesl
module NotesSchema.VCurrent exposing []
import NotesSchema.VCurrent.Note
import NotesSchema.VCurrent.Session
import NotesSchema.VCurrent.Tag
```

with `schema/notes/v-current/note.tesl` holding `module NotesSchema.VCurrent.Note exposing
[Note, ValidWordCount, tryWordCount, …]` and the entity's own facts and helpers, shared
types in an ordinary `module NotesSchema.VCurrent.Shared`. The application imports the
entity modules **directly** — `import NotesSchema.VCurrent.Note exposing [Note,
checkWordCount]` — one greppable hop, and still never a moving import. The freeze copies
the closure into `schema/notes/v7/` with each module renamed `NotesSchema.V7.Note`; the
PR diff shows the one entity file that changed. No new syntax is involved in scaling up.

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
    record-level proofs. Only `check` and `establish` functions mint them.

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
- **A migration is an ordinary function, checked by the proof kernel.** Not a script.
  `fn (Old.E) -> Migrated New.E` is total over its declared result — the new row, or a
  typed rejection — and the new row type's proofs are the acceptance criterion for
  every migrated row.
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
- **Every race argument holds at READ COMMITTED.** The runtime sets no isolation level
  (`runtime/go/teslrt/database.go`, `WithTransaction`), so each statement has its own
  snapshot; every proof in this document — fence, admission, plan switch, backfill
  conditionality, retirement — is written for that level and must not assume
  `REPEATABLE READ` or `SERIALIZABLE`. The normative SQL and each concurrency scenario
  ship as executable integration tests against every supported PostgreSQL major.
- **This is a new subsystem, not a bootstrap enhancement.** Today's bootstrap creates
  absent tables and unique indexes and reconciles nothing; the phases below build a
  protocol with its own control schema, and the plan is sized as such.
- **Reuse what exists.** JSONB shape changes keep using the `fromJson` list. The
  catalog shape in `ir.ml` is the snapshot's skeleton. The whole-program query set
  judges a diff's blast radius and decides compatibility.

## The design

### 1. Versions: `VCurrent` plus frozen snapshots — DECIDED (maintainer, 2026-09-04)

- The program's schema version is an integer, `V1, V2, …`, linear. Two branches that
  both freeze `V8` collide in git, which is the desired outcome: the same schema cannot
  have two eighth versions. (Timestamps and semver were considered; both let
  incompatible histories merge silently.)
- **The unit of versioning is the module the `database` names — `NotesSchema.VCurrent`
  (`schema/notes/v-current.tesl`), an ordinary Tesl module, hand-owned and edited in
  place.** There is no `schema module` keyword: being named by `schema:` is what makes a
  module the schema module, and the **content rule** is a diagnostic on it and on every
  module it imports: `entity` declarations with indexes and field proofs (proofs are part
  of the invariant history — a V7 row was **not** required to satisfy a proof added in
  V8, and the migration must reflect that); the types, newtypes, ADTs and **facts** those
  entities name; the `check`/`establish` functions that mint those facts; the **codecs**
  JSONB columns need; pure helper functions; **nothing else** — no handlers, `api`,
  `server`, `main`, capabilities, `requires`, `database` declarations or effects.
- **Membership is declaration, not export.** Every `entity` declared in `VCurrent` or in
  a module it (transitively) imports is a table of that database. Exporting controls only
  what the *application* may name: facts, checks, codecs and helpers are exported freely
  and are not tables; an unexported entity still has a table (reachable only from the
  migration file, which imports the module wholesale). One schema module belongs to
  exactly one `database` (naming it from two is MIG-class error), and an `entity`
  declared outside a schema module's import closure is a compile error. A program with
  several databases has several `VCurrent` families.
- **The version number is derived, not written.** `VCurrent` is one more than the highest
  frozen snapshot beside it: `schema/notes/v7.tesl` present ⇒ the current version is 8.
  The generator maintains the snapshots and the database's recorded hash verifies the
  result at boot, so a wrong number is a refused boot, never a mismatched table. No
  `version N` header syntax exists.
- **Freezing happens first, by copy.** *Tesl: Change Schema* (or `tesl migrate generate`)
  copies `v-current.tesl` to `schema/notes/v<n>.tesl` with one change — the header becomes
  `module NotesSchema.V<n>` — records that module's elaborated-catalog hash in the new
  migration file's header, and only *then* does the developer edit `VCurrent`. `git diff
  -C` shows the frozen file as a 100 % copy and the live file's diff is exactly the
  change. From the freeze on, any edit to `v<n>.tesl` is MIG013 at compile time, and the
  boot gate re-checks the same hash against what the database recorded when `V<n>`
  expanded. A frozen module's entities are **frozen record types with a column
  mapping**: they cannot be queried, inserted or named in a `database`; their only
  consumers are the migration file, the lazy read path and the backfill. When the next
  freeze happens, the generator rewrites the finished migration's `to: NotesSchema.VCurrent`
  and its `NotesSchema.VCurrent.*` references to the frozen name — references to a
  byte-identical module, so the migration's semantic hash does not move. **The rules
  that make this deterministic** (re-review, 2026-09-04), to be specified in
  LANGUAGE-SPEC before implementation: (a) *closure boundary* — schema-owned is every
  module whose name starts with the family prefix and the version segment
  (`NotesSchema.VCurrent`, `NotesSchema.VCurrent.*`) reachable by import from the root;
  the only external imports a schema module may have are `Tesl.*` (importing an
  application module from a schema module is a content-rule error), and those are not
  copied; (b) *rewrite* — in every copied file and in the finished migration file, the
  module header and every qualified reference whose path begins with the family's
  version segment get that segment replaced (`VCurrent` → `V8`); nothing else in the
  text changes; (c) *hashing* — the canonical typed IR used for every hash in this
  document (`snapshot_hash`, `migration_hash`, the `Same` closures) **alpha-renames the
  version segment to a placeholder** before serialisation, so nominal identities are
  `(family, ·, Name)` and the hash of `VCurrent`'s content equals the hash of its frozen
  copy by construction — which is also why the rewrite of a finished migration's
  references does not move its hash; (d) the canonical IR serialisation itself is a
  specification item (field order, name mangling, literal normal forms) that two
  compiler implementations must share, and its golden tests ship with phase 1.
- **Imports never move.** The application says `import NotesSchema.VCurrent exposing
  [Note, …]` once, and a schema bump touches no application file. Every type is still
  traceable to one hand-owned file in one greppable hop, which is the property the
  2026-09-02 decision asked for; there is no generated copy of the *current* version
  anywhere, and no re-export (Tesl has none, by design — the earlier facade is
  withdrawn). Importing `NotesSchema.V7.Note` from a handler is MIG015 — now a plain
  mistake rather than a bump mechanism — with the mechanical rewrite as its fix.
- **Identity across versions is declared, not assumed.** `NotesSchema.V8.ValidWordCount`
  and `NotesSchema.VCurrent.ValidWordCount` are two nominal facts, as `V8.UserId` and
  `VCurrent.UserId` are two newtypes; without more, every proof-carrying or newtype
  column would need re-establishing in every migration and `Unchanged` would be a lie
  for proofs (maintainer, 2026-09-02). So the generator writes the **`same:` list** of
  the migration record (`Same NotesSchema.V8.ValidWordCount NotesSchema.VCurrent.ValidWordCount`,
  §4) naming every type, newtype, ADT, fact and codec whose canonical **semantic
  closure** is identical in the two modules — for a fact, the transitive typed IR of
  every `check`/`establish` that can mint it, the pure helpers they call, the codecs
  involved, the frozen stdlib functions reached and the primitive tags, not merely the
  declaration's own text (a helper that changed under an unchanged check changes the
  invariant); the compiler treats the two as one **inside the migration file only**. A
  declaration that changed gets no `same` line: it is a new type, and every entity with a
  column naming it is classified *needs re-validation* even if no column moved — the row
  function runs the new `establish` over old rows, and `--schema dry-run` reports the rows
  that fail before the deploy. A person may delete a generated `same` line to force
  re-validation deliberately. Facts that no column names — `Authenticated` — stay in the
  application and are never versioned.
- **Scaling to a large schema needs no new syntax.** `v-current.tesl` becomes a thin
  root that only imports one plain module per entity (`import NotesSchema.VCurrent.Note`,
  file `schema/notes/v-current/note.tesl`), exposing nothing itself; shared types live in
  an ordinary `NotesSchema.VCurrent.Shared`; the application imports the entity modules
  directly (`import NotesSchema.VCurrent.Note exposing [Note, checkWordCount]`). The
  freeze copies the import closure into `schema/notes/v<n>/…` with each module renamed
  `NotesSchema.V<n>.…`; the PR diff shows the one entity file that changed. There are no
  entity revisions (`R<k>`), no root map and no shared-revision bookkeeping — the
  earlier draft's three numbers collapse to **two**: the database **schema version**
  `V<n>` (moves on any change to any entity) and the per-entity **row generation** `gen`
  (internal; moves only when a row function migrates that entity; shown by `--schema
  status`).
- **Branches: a coordination cost, stated honestly.** Two branches that change
  *different* entities still both create `schema/notes/v8.tesl` and
  `migrations/notes/v8.tesl` — add/add conflicts on the frozen snapshot and the record.
  Their entity files under `v-current/` do not conflict, and the resolution is
  mechanical: `tesl migrate rebase` regenerates snapshot and record against the new
  predecessor and keeps every user-owned function whose types still apply. The rules a
  team needs: schema changes for one database are **linear** (one version at a time,
  deployed in order — a V21 binary refuses a V19 database, so V20 and V21 may ship in one
  release train only if V20 is deployed first or the two are combined); two
  merged-but-undeployed changes **may be combined** into one version (`rebase --combine`),
  which is safe because a version already recorded in any database with a different hash
  is MIG013 at the next boot, so combination cannot rewrite deployed history; CI runs
  `--check` and the compat tests on the rebased result before merge; a merge queue may
  run `rebase` itself, since it is deterministic given the preserved semantic edits.
  Linear history per database is the trade the two-version rule buys.
- **Review and source diffs proportional to the change.** The migration record names
  only the entities that changed: an absent entity is **compiler-verified `Unchanged`**
  (its shape and `Same` closure must be identical, else MIG002 "entity changed but has
  no entry"), so `Unchanged` is never written by hand. The plan header shows the
  changed entities and one line — `297 entities unchanged` — for the rest; `--all`
  expands it.
- **What exists per change, and who owns it** — one canonical inventory, so a nullable
  field does not surprise anyone with a directory of machinery:

  | artefact | class | committed? |
  |---|---|---|
  | `v-current.tesl` (and the entity modules it imports) | hand-written source, edited in place | yes |
  | `v<n>.tesl` frozen snapshot of the previous version | generated **copy** of the previous `VCurrent`, header rewritten | yes |
  | `v<n>.tesl` migration record + row functions | generated skeleton, hand-edited | yes |
  | `v<n>-repair-<k>.tesl`, `v<n>-contract.tesl` | generated skeleton, hand-reviewed | yes |
  | `v<n>.stdlib.tesl` frozen slice | generated, frozen | yes — it is what later compilers cannot recreate |
  | `…Compat`, `…Support` modules | deterministic from frozen sources | **no** — regenerated by the build into `.tesl-stuff/`, run by `tesl test`, never reviewed |
  | plan header, preview, `--schema status` output | reports | no |

  For an additive change the committed footprint is therefore: the schema edit, a
  migration record of a few lines, and possibly nothing else (no row function reaches
  the stdlib, so no slice). **Nor is there a contract step**: a version whose contract
  would list no physical operation and no generation change (only additive columns,
  indexes, new entities) needs no `v<n>-contract.tesl` at all. Its physical work is
  **finalised automatically** the moment expand completes — there is nothing to wait
  for. Its *admission* is a different matter: the previous version stays admitted
  (rollback possible) for the whole life of the current one, and is **retired only when
  the next schema version needs the slot** — by the next version's own contract, under
  the exclusive fence, as for any version. No timer closes a rollback window; no
  exception to `contract: Explicit` exists; an empty `Contract { drops: [], tighten: [] }`
  is never generated. `--prune` reports an additive revision as a candidate once every
  environment it is deployed to has moved two versions past it. The earlier text that listed the compatibility module as a
  committed file was wrong on its own terms: a deterministic artefact of frozen inputs
  is a build product. Nothing about the *previous program's
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
  kind admitted only as the value of these two `Database` fields. `schema:` names the
  live module (`NotesSchema.VCurrent`); the integer schema version is derived from the
  frozen snapshots beside it, as above. `migrations:` names a module *prefix* that need
  not exist as a module: the compiler discovers `NotesSchema.Migrate.V<n>` children by
  scanning the directory the prefix resolves to under the existing
  PascalCase-to-kebab-case file rule, orders them by `n`, and requires them to be
  contiguous. Nothing imports the prefix; the application never mentions the migration
  files at all (they are compiled because the `database` names their prefix).
- **No import alias is added.** A migration file bridges two schema modules with two
  plain module imports and qualified names — `import NotesSchema.V7`, `import
  NotesSchema.VCurrent`, then `NotesSchema.V7.Note` and `NotesSchema.VCurrent.Note` —
  which is how Tesl already disambiguates same-named types from two modules (§10.2,
  §10.3). Verbose, and exactly as explicit as the rest of the language; the generator
  writes the qualified names, and a person rarely types them.

  The principle (maintainer, 2026-09-02): **only schema modules define historical
  data shape.** Migration records, repairs, contracts and frozen stdlib slices are
  committed alongside them; handlers, `main`, and `PostgresConfig` are deployed, not
  migrated, and the feature keeps nothing of a handler at all.
- The compiled program embeds `SchemaVersion` (derived as above) and the SHA-256 of
  `VCurrent`'s elaborated catalog.

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
| field proof **removed** from an existing column | — | V7 — and every admitted older version — still **trusts** the proof; V8 writes values it no longer checks, and nothing re-validates a row on decode (the checker is the sole enforcement) | `drop constraint` where one was expressible | ROLL-WINDOW RISK, and **window-narrowing** inside an additive epoch (§3) — the earlier draft listed this as additive, which was fail-open |
| `Rename a b` | `add column b null`; **V8 writes both** `a` and `b`; invalidation trigger on `a` | lazy read: `_tesl_v` below the target generation → take `a`; backfill | `drop column a`; drop trigger | ONLINE |
| type change / transform a new column with a row function | as rename, V8 writes `b` and, if `WriteBack g` given, `a`; trigger on `a` | lazy read via `f`; backfill | `drop column a`; drop trigger | ONLINE with `WriteBack`; otherwise ROLL-WINDOW RISK |
| column removed | V8 stops writing it, but V7 still **reads** it as non-null, so rows V8 inserts must carry a value: `Legacy c v` (constant → `set default c`, metadata-only) or `LegacyWith f g` (V8 dual-writes `g(row)`); `drop not null` alone only when the V7 snapshot proves V7 never decodes the column | — | `drop column` | ONLINE with `Legacy`; compile error without |
| entity removed | — (V7 still uses it) | — | `drop table` | ONLINE |
| new plain index | `create index concurrently` (outside transaction, background) | ready before it exists; slower until then | — | ONLINE |
| new unique index | `create unique index concurrently`; **readiness waits until it is `VALID`** (every new unique index; an `onConflict` on it is an additional hard dependency, not the criterion) | V7 may insert duplicates → build fails → drop `INVALID`, log keys, retry while V7 alive; once VALID, a V7 duplicate insert **fails** | — | ONLINE only if **every** indexed column is new in this version, nullable, default-free and not filled by a row function while older versions are admitted (so every old-version insert writes `NULL`, which `NULLS DISTINCT` never collides); otherwise ROLL-WINDOW RISK (§7) |
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
-- [illustrative] the shape of an invalidation trigger; the normative form is in the worked example
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
  only for entities with a migration in flight; the plan header lists them with their
  **true cost — proportional to the rows the `where` matches**, not one round trip:
  every matched row is fetched through Go, locked and written back. The emitter declares
  **one server-side cursor** — `declare rmw cursor for select … for update` — so the
  target set is chosen by a **single statement snapshot**, exactly as a native `UPDATE`
  chooses it (a row inserted after that snapshot is not a target; a row another
  transaction updates meanwhile is re-checked against the predicate on its new version,
  PostgreSQL's ordinary READ COMMITTED behaviour for both forms), and `fetch`es it in
  batches of `TESL_RMW_BATCH` (default 2 000) inside the one transaction so client
  memory stays bounded. Re-issuing the `select` per primary-key range was the first
  draft and would have given every page its own snapshot, admitting rows a native
  `UPDATE` would never have touched; a rewritten `update` whose
  `where` is not a primary-key equality gets MIG031 (suggested class: "this statement
  fetches every matched row through Go during the window; key it by primary key, or
  accept"), and `--schema dry-run` prints the matched-row count from the live table. A
  set-based update over a million rows must never become a silent million-row round
  trip because a *different* field of the entity gained a migration;
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
-- [illustrative]
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
through `check` rejects them. The mirror image — a proof *removed* — is not additive
either: V8 writes what V7 still trusts, and since a row is never re-validated on decode
(the checker is the sole enforcement of a stored proof) V7 runs with a broken invariant
until it is retired. Both directions are `ROLL-WINDOW RISK`. The plan labels this `ROLL-WINDOW RISK`, steers to the
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

`tesl migrate generate <entry.tesl>` loads the previous schema module, elaborates the current
program, and computes per entity one of:

| Class | Examples | Plan output |
|---|---|---|
| **unchanged** | identical columns, indexes, proofs, `Same` closure | **no entry** in the record — absence is compiler-verified `Unchanged`; the plan header lists it folded |
| **additive, epoch-preserving** | new `Maybe` column; constant-default column; new entity; plain index; a unique index whose **every** column is new in this version, nullable, default-free and not filled by a row function (every old-version insert writes `NULL`; Tesl's `unique index` is `NULLS DISTINCT`) | `User: Additive [Default rank 0]` — the compiler derives the adapter (`Nothing` / the constant), emits the expand DDL, bumps no generation; a new entity is `Tag: New`. Compatible with **every** version admitted since the epoch began, so it never narrows the window |
| **window-narrowing** | a unique index over a column **any admitted version writes** (the compiler checks against every schema revision in the current epoch, not the predecessor alone) — **and** any other new unique index that fails the additive test: over a defaulted new column (every old insert writes the same constant and collides), a composite mixing new and old-written columns, or a column a row function fills while old writers exist (backfilled values can collide independently of who wrote the source); a **proof removed** from a column any admitted version reads (the old binary keeps trusting an invariant nothing enforces any more, and a row is never re-validated on decode); anything else additive in storage but not in behaviour | still `Additive`, but the plan header says `WINDOW-NARROWING`: before this version can expand, the epoch must be closed to the two-version window (`close-epoch`), because once the index is `VALID` an old writer meets constraint failures its schema never predicted — bounded for one predecessor, unbounded across an epoch |
| **needs a value** | new non-`Maybe` computed column; new field proof (`Revalidate`); `Maybe T` narrowed or type changed under the same name (`Retype`); a removed column V7 still decodes (needs `Legacy`); **a fact or type a column names changed** (its closure differs, so no `Same`) — re-validation of every row through the new check | `User: Migrate migrateUser […]` with a generated function whose body has one `todo` per problem |
| **lossy** | column removed; entity removed; ADT constructor removed on a JSONB column | listed with what will be dropped at V9 contract and how many queries/handlers touched it — never silent |
| **ambiguous** | column removed and another of the same type added | proposed as `Rename name fullName` in a comment; the hole asks |
| **offline** | primary key change; `Reset` | `OFFLINE` in the header; the entity's rule list must contain `Offline "reason"` |

Classification uses the whole-program query set: a removed column that no query
reads and no handler writes is still lossy for the data, but the plan says so
("no query reads `User.legacyScore`; 0 handlers write it"), which is the information a
reviewer needs. `Money`/`MoneyRate` fields, which expand to several derived columns,
diff as one field.

**Multi-column fields (`Money`, `MoneyRate`, future compound types) work because the
unit of every mechanism is the logical field, and the emitter already owns the
field-to-columns mapping.** (Maintainer's question, 2026-09-04.) A `Money` field is stored
as two physical columns — minor units and currency — by `entity_columns` in the emitter,
and every rule here is stated over a field's **column set**, never over one column:
expand adds every column of the set (all nullable during the window); `Rename` renames
the set and the dual write copies each member; `Retype amount` gives the whole set new
storage names from the version (`amount__v9_minor`, `amount__v9_cur`) and `Storage`
drops the old set; the invalidation trigger's source list contains every physical
column of every source field; the marker-aware rewrite `w(b, a)` is emitted per physical
column, and a comparison on a `Money` field in the window compares both; `Default` and
`Legacy` take a `Money` literal (`Money.sek 0`) that the emitter splits as it does for an
insert; a `unique index [amount]` is an index over both columns; `_tesl_v` is per row, so
a half-written set cannot exist — the row function produces the whole value or `Reject`s.
The generated compatibility test stores an old-shaped row through `insertOld<E>` and
reads the `Money` back as one value. What is *not* SQL-expressible for `Money` is any
window aggregate: `selectSum` over a migrating `Money` column needs the currency rule
across rows, so it is MIG008 in the introducing version, like any Go-computed column.
Anything the emitter later adds as a compound storage type inherits this for free, as
long as it registers its column set in the same one place.

### 4. The migration file: one record, ordinary functions

The migration file is a **folded record**, in the style Tesl already uses for
`Database { … }` and `App { … }`, plus ordinary functions. There are no contextual
keywords: every operation is a constructor of an ADT exported by a new stdlib module
`Tesl.Migration`. (Maintainer, 2026-09-02: the earlier keyword form — `Migrate`,
`Unchanged`, `Rename`, `Legacy`, `WriteBack`, `same`, `offline` — was a second little
language; this is one record.)

```tesl
# migrations/shop/v8.tesl — generated by `tesl migrate generate`, edited by a person
module ShopSchema.Migrate.V8 exposing [migration, migrateUser]

import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Migrated(..), Same(..)]
import Tesl.Maybe exposing [Maybe(..)]
import ShopSchema.V7
import ShopSchema.V8

migration = Migration {
  from: ShopSchema.V7                       # module references (§1)
  to:   ShopSchema.V8
  same: []                                  # cross-version identities, generated (§1)
  fixtures: []                              # user-owned old-row functions for the compat module (§4b)
  entities: {                               # only the entities that changed; Session is absent = verified Unchanged
    User:    Migrate migrateUser [Rename name fullName]
    Archive: Drop                           # table dropped at V9 contract; V7 keeps using it
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
  | Revalidate field (establish)    # the column keeps its name and VALUE; only its proof (or the
                                    #   check/establish behind it) changed. The row function may initialise
                                    #   it only from the `Something` binder of the schema module's
                                    #   `establish` for that fact applied to `old.field`; generation +1;
                                    #   a database CHECK at contract ONLY when the check is in the
                                    #   SQL-expressible subset, otherwise the proof is runtime-only
                                    #   (sound because external writers are a non-goal); ROLL-WINDOW
                                    #   RISK (old writers can still store values the new check rejects)
  | Retype    field                 # same logical name, new type. A new storage column; the row
                                    #   function's initialiser for `field` is a free expression (like a
                                    #   new column); `WriteBack field field g` (same name both sides is
                                    #   legal only under Retype) dual-writes the old storage column
  | WriteBack field field (fn)      # WriteBack oldField newField g: for a column V8 computes into
                                    #   `newField`, V8 also writes `g(new) : oldType` into the OLD
                                    #   column so V7 readers stay whole. Both endpoints named, for
                                    #   the same reason Rename names both: removed+added is ambiguous
  | Offline   String                # `Reset` / primary-key change acknowledgement

type Migrated a = Row a | Reject String

type Contract = Contract { of: migrationRef, drops: List Drop, tighten: List Tighten }
type Drop     = Column entity field | Storage entity columnName | Index entity name | Trigger entity name | Table entity
                                    # Storage names a PHYSICAL column that no longer has a logical field —
                                    # the old storage of a Retype'd field — so a contract never shows two `amount`s
type Tighten  = NotNull entity field | Check entity field        # Check only where SQL-expressible
type Repair   = Repair { of: migrationRef, entity: entity, with: rowFn }

type Same = Same typeRef typeRef    # `Same ShopSchema.V8.NonNegative ShopSchema.V9.NonNegative`
```

**Elaboration rules** (the contextual typing that makes the record checkable; each
violation is a MIG diagnostic in the table under "Diagnostics"):

| position | type it must have | diagnostic |
|---|---|---|
| `from:` / `to:` | module references to schema modules — a frozen `V<n>` and either the next frozen one or `VCurrent`; `to`'s version = `from`'s + 1 | MIG020 |
| `entities:` | a record whose fields are a **subset** of the union of the two modules' entity names; every entity absent from it must be identical in both modules (shape, indexes, `Same` closure) — verified `Unchanged`; a changed entity with no entry is MIG002 | MIG002 |
| `Migrate f rules` for entity `E` | `f : From.E -> Migrated To.E` — the specific pair, not a polymorphic shape | MIG021 |
| `Rename a b` | `a` a column of `From.E` absent from `To.E`; `b` a column of `To.E` absent from `From.E`; same column type | MIG022 |
| `Default b v` | `b` a new non-`Maybe` column of `To.E`; `v` a literal of `b`'s type | MIG022 |
| `Legacy a v` / `LegacyWith a g` | `a` a column of `From.E` absent from `To.E`; `v : a`'s type / `g : To.E -> a`'s type | MIG022 |
| `WriteBack a b g` | `a` old-only, `b` new-only, `g : To.E -> a`'s type | MIG022 |
| `Retype f` | `f` present in both versions with **different** column types; the generator writes `f: T @column("f__v<n>")` (storage name from the introducing schema version) into `VCurrent` — user edits to that annotation are MIG027; the row function's initialiser of `f` is a free expression typed `T`; `WriteBack f f g` with `g : To.E -> old type` is the only WriteBack whose endpoints share a name; contract emits `Storage E "f"` for the old physical column; window SQL uses the marker-aware form only if the conversion is in the SQL-expressible subset (a cast), else MIG008 applies | MIG022 / MIG027 |
| `Rename a b` + `Retype b` on one column | allowed together: logical rename and type change in one migration; storage name from the new revision | — |
| `Revalidate f c` | `f` present in both versions with the same column type; `c` an `establish` of `To`'s module returning `Maybe (v: T ::: P v)` for the fact `To.E.f` names; the initialiser of `f` is the `Something` binder of `c old.f`; a database `CHECK` is emitted only if `c`'s body is in the SQL-expressible subset, else the plan marks the invariant runtime-only | MIG022 / MIG018 |
| duplicate or conflicting rules on one column (e.g. `Rename a b` and `Legacy a v`) | — | MIG023 |
| `Same T U` | type references to same-kind declarations in `From` and `To` **whose canonical semantic-closure hashes are equal** (declaration, minting checks, helpers, codecs, frozen stdlib, primitive tags); `Same` is verified, never an assertion — a hand-written `Same` over differing closures is MIG024, which names the first differing node | MIG024 |
| `Additive rules` | every change to `E` has a single derivable adapter given the rules | MIG016 |

What is genuinely new *syntax* is small and listed in §1: module references as record
values, entity names as record fields, bare column identifiers as values inside a
`Rule` (which `index [orgId]` and `onConflict [id]` already do inside an entity
context), and type references as `Same` arguments. What is new *machinery* is the
elaboration above — one contextual typing pass over a folded declaration, which the
compiler already has for `Database` and `App`.

**Row functions are ordinary `fn`s**, total by type: they return `Migrated New.E`,
`Row` with the new row or `Reject` with a reason. No `check` declaration kind is
extended, no proofless `ok` exists, no HTTP status is written to be ignored, **and no
new intrinsic is needed**: the language already has the non-propagating proof boundary
a row function wants — `establish`, in its optional form `-> Maybe (v: T ::: P v)`
(LANGUAGE-SPEC §7, D7: canonical for an optional proof-carrying return). An earlier
draft invented a `Check.attempt` intrinsic and an `Attempt` type for this; the
maintainer pointed at `establish` (2026-09-04) and the intrinsic is withdrawn. The
schema module declares the fact's minting boundary **once**, as an `establish`, and the
handler-facing `check` delegates to it, so there is one predicate expression:

```tesl
# in schema module ShopSchema.V8 — the ONE place NonNegative can be minted (sealed, §5)
fact NonNegative (n: Int)

establish tryNonNegative(n: Int) -> Maybe (v: Int ::: NonNegative v) =
  if n >= 0 then Something (n ::: NonNegative n) else Nothing

check checkNonNegative(n: Int) -> n: Int ::: NonNegative n =        # handlers: HTTP failure
  case tryNonNegative n of
    Nothing -> fail 400 "negative"
    Something valid ->
      let (v ::: p) = valid
      ok v ::: p

# in the migration file
fn migrateUser(old: ShopSchema.V7.User) -> Migrated ShopSchema.V8.User =
  case ShopSchema.V8.tryNonNegative (defaultAgeFor old) of
    Nothing      -> Reject "user ${old.id}: age would be negative"
    Something age -> Row (ShopSchema.V8.User { id: old.id, email: old.email, fullName: old.name, age: age })
```

`Nothing` carries no reason — `establish` is a boundary, not an HTTP validator — so the
**row function supplies the reason** in its `Reject` string, and that string is what
`--schema dry-run`, the backfill log, the quarantine row and the lazy-path 500 show.
`establish` is unconditional trust by design (the spec compares it to `unsafeCoerce`),
which is exactly why the seal matters: only an `establish` **declared in the schema
module** may name a column fact (MIG019), so "every function that can mint this fact"
stays the finite, hashed set the `Same` closure is computed over. The runner maps
`Reject` to: stop the backfill with the primary key and reason; a 500 with the same
reason in the log on the lazy path. Invocation in a test is a plain call: `case
migrateUser old of Row u -> … | Reject r -> …`.

**Rules the compiler enforces on a row function**, all syntactic, none semantic:

- One entry per **changed** entity; an entity absent from the record is verified
  `Unchanged` by the compiler (writing `Unchanged` explicitly is allowed and means the
  same). A changed entity with no entry, `Unchanged` on an entity whose shape changed,
  or `Additive` where a rule has no single adapter, is MIG002/MIG016.
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
- A **revalidated** column (rule `Revalidate f check`) is the one exception to the
  pass-through rule, and a narrow one: its initialiser must be the variable bound by
  `Something` from the schema module's `establish` for the fact, applied to `old.f` —
  the same physical column, the same value, a new proof. No shadow column exists; the trigger watches the column itself, so a V7
  write lowers the marker and the row is re-validated; a database `CHECK` is
  installed `NOT VALID` and validated at contract **only when the check's body is in
  the SQL-expressible subset** (a comparison against a literal, say) — otherwise the
  invariant is enforced by the Tesl proof alone, which is sound because external
  writers are a stated non-goal, and the plan header says "runtime-only"; and the
  change is `ROLL-WINDOW
  RISK`, because a V7 writer can store a value the new check rejects until it is
  retired (§2 already labelled proof tightening so). This is how "the invariant
  changed, no column moved" (MIG016) is *resolved*; the earlier example did it with a
  bare initialiser, which MIG018 would have rejected.
- A **same-named type change** (`Maybe T` → `T`, `Int` → `Int32`, a newtype introduced
  over an existing column) keeps its **logical name**: rule `Retype amount`, with the
  row function initialising `amount` freely and, if V7 still reads the old column,
  `WriteBack amount amount g`. An earlier revision forced a new Tesl name (`amountV2`) and a later
  rename back — two application-wide edits for one storage change, paid by every user
  of every type-changing migration; the ergonomics review (2026-09-03) rightly called
  that a storage mechanic leaking into the domain API. Instead the generator gives the
  field a **storage name** distinct from its Tesl name — `amount: Money
  @column("amount__v9")`, from the schema version that introduces it, written into
  `VCurrent` — the old physical
  column keeps the old storage name during the window, dual-written through `g` if V7
  still reads it, and is dropped at contract. The Tesl name never moves; the physical
  name is an annotation nobody else reads. The emitter already maps fields to column
  names (the index-name derivation uses "real column names"), so `@column` is an
  indirection it half has, paid once, centrally. `Rename` remains for changing the
  logical name; `Retype` for changing the type under it; MIG009 still forbids rewriting
  an existing physical column in place. Worked, for `amount: Int` becoming `amount:
  Money` in `ShopSchema.Order` at V9:

  ```tesl
  # in ShopSchema.VCurrent (frozen later as ShopSchema.V9) — the generator wrote the annotation
  entity Order table "orders" primaryKey id {
    id:     String
    amount: Money @column("amount__v9")       # logical name unchanged; new storage column
  }

  # migrations/shop/v9.tesl
  entities: {
    Order: Migrate migrateOrder [Retype amount, WriteBack amount amount Money.toMinorUnits]
  }
  fn migrateOrder(old: ShopSchema.V8.Order) -> Migrated ShopSchema.V9.Order =
    Row (ShopSchema.V9.Order { id: old.id, amount: Money.sek old.amount })   # `amount` is free here

  # migrations/shop/v9-contract.tesl (generated later)
  drops: [ Storage Order "amount" ]           # the old physical column; the field `amount` lives on
  ```

  During the window the application reads and writes `order.amount` as `Money`; the
  emitter reads `amount__v9` for rows at the new generation and converts `amount` for
  older rows through the row function, writes both columns (the old via `WriteBack`),
  and `where order.amount > x` is MIG008 unless the conversion is a SQL cast.
- A **new** column is the only place an arbitrary expression is allowed, and it is
  where the generator writes the `todo`.
- A row function **fills** a derived column for old rows; it does not **maintain** it.
  There is no `New.E -> New.E` function, so the emitter never recomputes a derived value
  when the application later updates one of its sources — that is the application's job,
  exactly as for any stored derived value it writes today. The plan header lists, per
  derived column, the handlers that update a source of it and whether they set it
  (`DERIVED wordCount ← content: updateContent sets wordCount`), as information; a stored
  derived value that must stay consistent forever is a denormalisation concern (§13b),
  not a migration one. The worked example's first draft got this wrong (its handler left
  `wordCount` alone and its SQL claimed a recomputation that nothing could perform).
- The function may call functions of either schema module, functions declared in the
  migration file, and the standard library (frozen with it, §11) — never the
  application. It sees **one old row and nothing else**: no joins, no lookups in other
  entities. Cross-entity transformations — denormalising a value from a parent,
  deriving ownership through a foreign key, populating a field from a reference table
  — are common and are **not expressible as a v1 row function**, deliberately: a lookup
  makes the function's result depend on the state of another table at backfill time,
  which the two-version protocol cannot keep consistent under concurrent old writers.
  The supported routes, which the plan header names when it detects a hole that
  mentions another entity: (1) a **staged** change — introduce the field as `Maybe`,
  fill it from the application (an ordinary handler or worker with the whole program
  available), then tighten it in a later version with `Revalidate`; (2) a **new
  entity** populated by the application; (3) the **offline** path when the derivation
  must be atomic with the schema change. A restricted, read-only lookup context for
  row functions (a frozen view of specific other entities at their old generation) is
  a later item, listed under non-goals for v1. Schema-module facts are **sealed** (§5), so "every check that can mint
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

What is generated is **structural**, in both directions the window needs: an
old-shaped row is inserted at its generation, read back through the new decoder and
found by a rewritten predicate (**old → new**); and a new-shaped row is inserted by the
new code path and read back through the **old** decoder via a generated
`readOld<Entity> : key -> Maybe Old.E` (**new → old**), which checks that `Rename`
dual-wrote the old column, that `Legacy`/`LegacyWith` supplied every removed non-null
column, and that `WriteBack` produced a decodable old value. The support module
therefore holds both `insertOld<E>` and `readOld<E>`, under the same test-only
privilege boundary. What is **not** generated is a
universal "every valid old row migrates successfully" property: a row function is
allowed to `Reject` old rows the new invariant excludes, so such a property would fail
legitimately. **Fixture rows live in committed source, never in the generated
module**: the generator synthesises them where every field of the old row is
constructible from its type (the additive and `Derived` cases, and any `Migrate` whose
old shape carries no proof-bearing, opaque or codec-only field — so "nothing to write"
for an additive change stays true); where it cannot, the migration record's
`fixtures:` field names user-owned functions in the migration file
(`fixtures: [oldNoteWithWords]`, `fn oldNoteWithWords() -> NotesSchema.V7.Note = …`),
and the generated compatibility module **consumes** them. Synthesis is narrow,
deterministic, and **structural only**: for `Additive` and `Derived` migrations — where
values are merely transported — the generator builds the fixture from canonical
inhabitants (`Nothing`, the empty list, a single-constructor wrapper of canonical
contents) and, for the plain primitives, values that are obviously placeholders
(`"fixture-1"`, `1`, `True`, a fixed instant) on fields that carry no proof and belong to
no unique index. For any **`Migrate`** function at least one user fixture is required,
because no synthesised primitive is a *representative* input to arbitrary code — an
empty string on an unconstrained email field is type-correct and would push the only
compatibility test down the row function's rejection branch. A hole is better than a
plausible-looking test of nothing; property generators over user-declared generators
are the later refinement. A missing fixture is a
`todo`-class hole in the migration file (MIG003), with the old row's fields in the
message. A `property` over generated rows is emitted only when the row function is
syntactically total (no `Reject`, no `case` on a `Maybe`-returning `establish`). Developers never edit a
build artefact.

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
**sealed**: only `check` and `establish` functions declared in that same schema module may mint it
(`ok x ::: NonNegative x` anywhere else — an application `check`, `auth` or `establish`
— is MIG019). Consumption is unrestricted. Without this, "every check that can mint
the fact", which `same` hashes and from which a PostgreSQL `CHECK` may be derived, is
not a finite set, and a stored invariant could be established by a validator the
schema never saw. Facts not named by a column (`Authenticated`) are unaffected.

`User` in V8 declares `age: Int ::: NonNegative age`. The generator cannot invent a
`NonNegative` fact, so the hole is left. The developer writes:

```tesl
fn migrateUser(old: ShopSchema.V7.User) -> Migrated ShopSchema.V8.User =
  case ShopSchema.V8.tryNonNegative (defaultAgeFor old) of
    Nothing       -> Reject "user ${old.id}: age would be negative"
    Something age -> Row (ShopSchema.V8.User { id: old.id, email: old.email, fullName: old.name, age: age })
```

`Reject` is the row function's one way out, and it is in its return type. During
backfill it stops the backfill and reports the primary key and reason; on the lazy read
path it is a 500 for that row with the same reason in the log — the row is unreadable
under the new invariant, which is the truth. The alternative — silently
coercing — is unavailable by construction, because only the schema module's `check`/`establish` mint
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

0. **Admission is a stored state, `tesl_schema_state.min_version`**, the oldest version
   allowed to hold a connection. It only ever increases, and only inside the
   *retire* transition below. Everything that must never happen while V7 could still
   write — dropping its trigger, calling its backfill final, setting `NOT NULL`,
   dropping its columns, using a new column inside SQL — is sequenced **after**
   `min_version` passes 7, never after an observation that V7 seems absent.
1. **Fence — transaction-scoped, two statements, on writes, the second of which
   raises.** Every **write** transaction a `V<n>` instance runs (reads run the
   lock-free, query-first admission of §13 only under `admission: Strict`; the DDL
   connection holds the session-level form of invariant 7) begins with `select pg_advisory_xact_lock_shared(fence(schema,
   n))` and **then, as a separate statement**, `select tesl_admit(n)` — the same
   function reads use, which **raises** when `min_version > n`. It must raise, not
   return a value: the whole transaction is pipelined (`BEGIN`, lock, admit, the
   program's statements, `COMMIT`, one round trip), and PostgreSQL executes queued
   statements in order regardless of what the client has seen — a returned
   `min_version` the client inspects later is no barrier at all, and the program's
   write would already have run (an earlier draft claimed "rolls back before any
   program statement runs" on exactly that basis; the eighteenth review pass caught
   it). An error inside a pipeline aborts the rest of the pipeline up to its sync
   point, so the raising statement is a **server-side execution barrier**: the
   program's statements are never executed, not merely rolled back — which matters for
   volatile SQL functions and for anything a statement might do outside transactional
   table state. The instance then shuts down. The acceptance suite pins the stronger
   property: with retirement winning the lock ahead of an already-pipelined
   transaction, the program's statement is shown never to have executed (a
   side-effecting marker function in the statement never fires). Two statements, not
   one: under READ COMMITTED each
   statement takes its own snapshot at *its* start, so the read sees whatever
   committed before the lock was granted — whereas a single `select lock(), min_version
   …` takes its snapshot before blocking on the lock and can return the pre-retirement
   value after retirement has committed. Tesl transactions run at PostgreSQL's default
   READ COMMITTED (the runtime sets no isolation level; verified 2026-09-02), which is
   what makes the two-statement form sufficient. Should a stronger level ever be
   offered, the admission read must become `select min_version from tesl_schema for
   share` on the singleton row — under READ COMMITTED it re-evaluates to the updated
   row, under REPEATABLE READ/SERIALIZABLE it raises a serialization failure, both of
   which are refusals — at the cost of row-lock (multixact) traffic on the one
   `tesl_schema_state` tuple;
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
   this pass picks it up. A **serving** binary needs only the two most recent
   migration files (`V<n-1>.tesl` and `V<n>.tesl`): the boot gate (§8) refuses to serve
   while any entity still has rows two generations behind — a state the previous
   version's fleet was responsible for finishing. The binary nevertheless **embeds every
   committed migration, repair and contract** in the `migrations:` namespace (small Tesl
   functions — plus their frozen stdlib slices under the frozen-execution model, or a
   recorded `compiler_abi` under the alternative; see Decisions), because the same binary is
   what brings a restored snapshot forward through **catch-up** (§8), one version at a
   time. The compiler requires at least the two most recent to be present; older ones
   may be pruned only with the acknowledgement `prune` records (§11). The update
   predicate is `_tesl_v = g-1 AND xmin = <the xmin read>` — the row's system column,
   four bytes, exact: any committed write to the row since the read (a V7 update, a
   delete and re-insert) gives the tuple a new `xmin`, so the predicate fails without
   shipping every source value back to the server for an `IS NOT DISTINCT FROM`
   comparison (the first draft did that; a `content` text column would have doubled
   every batch's payload). A freeze by `VACUUM` keeps the visible `xmin` since
   PostgreSQL 9.4, and were it ever to change, the row is merely re-selected by the
   next pass. The write sets every derived column and `_tesl_v = g` together. A V7 update between
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

   The window value of a renamed column is chosen by the **generation marker**, never
   by `b IS NULL`: for a nullable (`Maybe`) column a physical `NULL` in `b` is
   ambiguous — an unmigrated row, or a migrated row whose value is `Nothing` — and
   `_tesl_v` already says which. Writing `w(b, a)` for
   `case when _tesl_v < g then a else b end`:

   | clause | rewrite (rename) | note |
   |---|---|---|
   | `where b <op> $1` | `((_tesl_v >= g and b <op> $1) or (_tesl_v < g and a <op> $1))` | three-valued logic preserved per branch; both indexes usable via BitmapOr with the marker as filter |
   | `isNull`/`isNotNull b` | `w(b, a) is null` / `w(b, a) is not null` | on an old row with `a = Something x`, `b == Nothing` is **false**, as it must be |
   | `order b`, `groupBy b`, `selectCountBy`/`selectSumBy` on `b` | `w(b, a)` | an index on `b` alone does not serve the sort during the window; the plan header says so |
   | `innerJoin E on x.b Y.k` | `w(x.b, x.a)` in the `ON` | |
   | `selectSum`/`Max`/`Min` over `b` | `w(b, a)` | |
   | `unique index [b]`, `onConflict [b]` | **not rewritable** — a conflict target must be a real column | MIG008 stays; declare the unique index in the next version |
   | constant default (`Default c` on a new column) | `case when _tesl_v < g then c else b end` | no old column exists; the rewrite is against the constant, again by marker, not by `NULL` |
   | `where <pred on b>`, `b` Go-computed — **proposed refinement (review 2026-09-03), decide before phase 3** | `((_tesl_v >= g and <pred on b>) or _tesl_v < g)`; the lazy path migrates the `< g` rows and re-applies the predicate in Go | an **over-approximation** that is exact after the Go filter. Legal only for a `where` with no `limit`, no `order`/`groupBy`/aggregate/join on `b`; cost = every unmigrated row the rest of the `where` admits, printed by the plan header. Removes the empty release for the commonest case (filter on a new column) |

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
   takes more than one lock takes them in this order: (1) the boot lock (session-level
   advisory, key `2147483647`), (2) fence keys in ascending version order, (3) job leases
   (`backfill`, `index:<name>`). The boot lock is the one lease-shaped thing that *is* a
   guard, which is why it is a lock and not a row. The
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
   request instances then skip those jobs entirely — including expand, for which a
   `tesl_app` process has no DDL privilege; they wait for the executor's expand to
   appear. Where no pooler is in the path, the default — every instance
   may take the jobs over its own `ddlConnection` — is fine. Two defences in depth
   remain, because a requirement is still a requirement: the objects
   such DDL creates carry the creating version in their name (`users_email_idx_v8`),
   so a straggler can never satisfy or collide with a later version's declaration and
   contract can drop `*_v<retired>` leftovers by name; and retirement additionally waits
   until `pg_stat_progress_create_index` shows no build in the schema — server-side
   truth about executing statements, which a paused client cannot fake.

**Modes, stated once so the steps below can name them.** *Default* (decided
2026-09-03): expand and backfill automatic; contract (retirement inside it) only when
the `contract:` setting executes the committed `v<n>-contract.tesl` — `Explicit`
(default, `app --schema contract`), `WhenDrained`, or `NextVersion`; read admission
`Trusted` (none; the 15 s poll exits retired idle processes). *`admission: Strict`*: the
query-first admission of §13 on every read — the opt-in until row-level policies land,
then the default.
Steps marked **[executor]** are performed by whichever process holds DDL authority:
the schema worker under `topology: Worker`, the application process itself under
`topology: Embedded` (development, and small production services). Steps marked
**[request-check]** apply only under `Worker`: a request process under `tesl_app`
reads control state, writes nothing but its own heartbeat row, and waits for the
executor's expand to appear. One lifecycle, two topologies.

**At V8 instance boot** (`OpenPostgres`), in this order:

1. **[executor]** Take the **boot lock**: `pg_advisory_lock(:fence_ns, 2147483647)`,
   **session-level, on the executor's dedicated DDL connection** (invariant 7 already
   requires that connection to be direct, so the lock lives exactly as long as the
   session that holds it and vanishes with it). The `boot` lease row stays as
   observability and as the handoff signal (who is expanding, since when), **never as the
   guard**: the review of 2026-09-03 showed why an expiring lease cannot be one — a V8
   executor paused past the expiry mid-install, a V9 taking the lease and installing V9,
   and the V8 resuming would both reach `tesl_record_expanded`, and "every step is
   idempotent" is false across *different* versions (`create table if not exists` at V9
   silently adopts the V8-shaped table). A session lock has no expiry to race: the
   second executor blocks (with `lock_timeout` and a status line) until the first
   commits or its connection dies. Not obtained: wait, then re-read the control state —
   another executor is doing the work below. Request processes never take it.
2. **[request-check]** Register in `tesl_schema_instances` (the one control table `tesl_app`
   may write, its own row only) and start the heartbeat (every 15 s).
3. Read `tesl_schema_state` and `tesl_schema_versions`. Cases in §8. In the normal case the database is at `V7
   expanded`, `min_version = 6` or `7`.
4. Verify the recorded V7 snapshot hash matches this binary's embedded copy of
   `schema/V7.tesl`. Mismatch: refuse (someone edited history).
5. **[executor, as the first step of the contract of V7 — when the `contract:` setting
   executes it] Retire V6 — but only once every V6-shaped row has been carried forward.**
   In one transaction take `pg_advisory_xact_lock(fence(schema, 6))` exclusively with
   `lock_timeout`; held by any in-flight **fenced** V6 transaction (a write, or the DDL
   connection — reads hold no fence) → a V8 is booting while V6 still runs, which the
   two-version rule forbids: **refuse** to start, naming the count from `pg_locks`.
   Acquired — so no V6 write can start or be in flight — run V7's **final pass** for
   every entity V7 migrated *while holding the fence*: every row still below the
   entity's V7 target generation goes through the frozen V7 row function (the pass
   itself runs in batched transactions on other connections; the fence only has to
   keep V6 writers out, and it does). If **every** row is accepted, the outer
   transaction — after **re-checking** that no row is below the target generation —
   atomically writes `min_version = 7`, each affected entity's `generation` /
   `target_generation` / `final_at`, and the `(7, 'retired')` lifecycle row, then
   commits and releases. The assertion "this entity is final" commits **with**
   retirement and never independently: a worker that marked an entity final on some
   batch connection and then crashed before advancing `min_version` would have released
   the fence and let an old writer demote a row under a false `final_at`. From this
   point no V6 connection can ever be admitted, and the final pass is *final* because
   nothing that could have re-marked a row was admitted while it ran. If **any** row is `Reject`ed: **abort the retirement** — the outer
   transaction rolls back, the fence is released, V6 stays admitted, `min_version` and
   every lifecycle row are unchanged. What is *not* undone, and must be said plainly:
   the final-pass batches that already committed on other connections stay committed.
   That is safe — they moved rows to the new generation inside a schema that still
   carries every old column, exactly what the provisional backfill does all day — and
   it means the retry does not redo them. The rejected rows are recorded in
   `tesl_schema_quarantine` in a **separate** transaction after the abort (a rolled-back
   transaction cannot record anything) — and that transaction **re-runs the row
   function** on the row as it is *now*, because the application may have repaired or
   deleted it in between; a row that now passes, or no longer exists, is not
   quarantined, and stale entries are cleared the same way on every pass. The worker
   reports the list (a request process is unaffected), and the next attempt resumes from the remaining rows below the target
   generation, re-reading rather than trusting a cursor. A crash of the booting process
   mid-retirement is the same as an abort: the xact lock vanishes with the connection
   and nothing was committed. An earlier revision — retire first,
   finish later — could strand the database: V7 kept writing until the moment of
   retirement, a row written after the dry-run could be one the frozen function
   rejects, and once V6 was retired nothing admitted could repair it. Validating
   before advancing `min_version` keeps the old version available for exactly that
   repair.
6. **[executor, same trigger as step 5] Contract V7**, exactly as the committed
   `v7-contract.tesl` lists it — never inferred from the catalog: for every entity, run the
   contract steps — `add constraint … check (col is not null) not valid`, `validate
   constraint`, `set not null` for each V7-introduced column, the `CHECK` of each
   `Revalidate`d column, drop the V6→V7 invalidation trigger, `drop column` for the V6
   columns V7 stopped using — each in its own short transaction with `lock_timeout`.
   Record `(7, 'contracted')` when every entity is done. Boot does not wait for this.
7. **Expand V7→V8**, if not yet expanded: each statement in its own short transaction
   with `SET lock_timeout = '2s'` and bounded retries with backoff, because a
   metadata-only `ALTER TABLE` still needs `ACCESS EXCLUSIVE` for a moment and must
   not queue behind a long report query while every other request piles up behind
   it. Install the V7→V8 invalidation triggers the same way. Record `(8, 'expanded',
   snapshot_hash, migration_hash)`.
8. Release the boot lock (`pg_advisory_unlock`) and clear the lease row. Other V8
   executors waiting at step 1 now see `V8 expanded`, verify, and proceed.
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
    checks `pg_stat_progress_create_index` (PostgreSQL 12+; the floor is **14**, set by
    `CREATE OR REPLACE TRIGGER`) for an
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

- The **session-level boot lock** admits one executor to steps 3–7; the others block on
  it, then re-read the control state and find the work done. No instance reports ready
  while waiting, so a fleet of ten booting into a V7 database has one expander and nine
  readers — the same for a fresh, empty database, where one instance creates everything
  and the others find it created. The `boot` *lease row* beside it is observability
  only.
- Idempotence is defence in depth, **not** the serialiser: a second executor of the
  *same* version repeating a step does no harm — every DDL statement is an `IF NOT
  EXISTS` form re-checked against the catalog; every lifecycle row goes through the
  recorder, which treats an equal-hash duplicate as a retry — but two executors of
  *different* versions expanding concurrently would not be harmless (`create table if
  not exists` at V9 adopts a V8-shaped table), which is exactly why the guard is a lock
  with no expiry rather than a lease; `min_version` advances by compare-and-set
  (inside `tesl_advance_floor`, which is the only writer of the floor) under the exclusive fence, so
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
- **Two plans per statement, because the window ends before V8 does.** V7's
  compatibility objects — the columns V8 dual-writes, the columns lazy reads select,
  the invalidation trigger — are dropped by `contract V8`, which runs while V8 is still
  admitted and serving (it retires V7, not V8). A V8 binary with only its window SQL
  would then fail every insert with `column "authorId" does not exist`. So for every
  statement on an entity with a migration in flight in this binary the compiler emits
  **two** plans: the **window plan** (dual writes, lazy read of `_tesl_v` + old + new
  columns, marker-aware rewrites) and the **settled plan** — exactly the SQL a program
  that never had the migration would emit. Selection is **per bound database and
  monotonic** (one process may bind several databases with different floors; "process-wide"
  below means per database identity): window until the process learns that `tesl_schema_state.compat_floor`
  has reached 8 ("the V7→V8 compatibility objects are being or have been removed;
  every admitted binary runs settled plans for that window"), settled forever after.
  The process learns it from three sources, none an extra round trip: **`tesl_admit`
  returns it** — the one admission statement every write — and, under `Strict`, every read — already runs
  raises when retired and otherwise returns `compat_floor`, so each transaction's
  result updates the process mode for the next one — the 15 s poll, and a
  schema-change SQLSTATE raised by a window-plan statement, which re-reads the state
  and **retries the whole transaction** on the settled plan (nothing was observable).
  The runtime has **one retry decision table**, used by reads and writes alike: on any
  SQL error first re-read `min_version`; retired → log and exit (never retry);
  otherwise `40001`/`40P01` → retry the same plan (bounded, jittered, §13); otherwise
  the *schema-change set* — `42703 undefined_column`, `42P01 undefined_table`,
  `42704 undefined_object`, `42883 undefined_function`, and `0A000` with the
  "cached plan must not change result type" message — → if the statement ran a window
  plan, **roll back the failed transaction**, re-read `compat_floor`, and switch **only
  if the floor has reached that plan's contract version** (`compat_floor >= 8` for the
  V7→V8 window) — an unrelated missing column or function before the contract is the
  handler's error, never a switch — then retry once; otherwise the error is the
  handler's, as today. `0A000` is matched on SQLSTATE and the fact that the statement
  was prepared, not on message text (which is localised). An ambiguous failure around
  `COMMIT` (connection lost after the commit was sent) is **never** retried
  automatically — the outcome is unknown — and surfaces as a 500 with an OTel event. Switching plans also **drops the pgx statement cache** for the
  affected statements (the two plans are registered under distinct statement names, so
  a settled plan never reuses a window plan's prepared statement, and a leftover
  window preparation is deallocated on switch). Correctness rests on the
  retry and the monotone switch alone; `contract` merely makes the error path rare:
  it sets `compat_floor = 8` **before the first drop**, in its own transaction, then
  waits until every heartbeating instance's `tesl_schema_instances` row reports `compat_floor_seen >= 8`
  or two poll intervals have passed, and only then drops. Settled plans are correct
  because retirement validated every row final before the floor moved, so no row
  still needs the old columns or the lazy path; the `_tesl_v` stamp stays. The
  reviewer of the earlier draft was right that "request binaries are unaffected by
  the contract" was false as stated; they are unaffected in **behaviour**, and they
  switch SQL plan to make that true.
- **Backfill — who, how parallel, how long.** (Maintainer's question, 2026-09-04.) The
  executor that holds the `backfill:<entity>` lease runs it — the schema worker under
  `Worker`, the boot instance under `Embedded` — as goroutines in that process, never on a
  request path; if it dies another executor takes over, and two overlapping holders only
  duplicate work. Expand itself is metadata-only and takes milliseconds; the backfill
  and index builds are the long part, and **a slow backfill delays the contract, not
  correctness**: the lazy read path makes every V8 instance correct from the first
  request, and only `contract V8` (and a V9 query that needs the column inside SQL) waits
  for it. Inside the executor the work is **sharded**: `TESL_BACKFILL_CONCURRENCY`
  (default 4) goroutines each own a primary-key range taken from the table's
  `pg_stats` histogram bounds at start (or hash ranges when the key has no useful
  histogram), each with its own keyset cursor in `tesl_schema_backfill_shards`, all under
  **one** throttle controller — the throttle reads database-wide signals (replica lag,
  WAL rate), and one decision-maker is what keeps it from oscillating. Sharding across
  *instances* (several worker replicas, or the request pods, which hold the entity-DML
  role and could do it) is deliberately **not** the default: the bottleneck is the
  primary's write path — WAL, index maintenance, replica replay — which every instance
  would share, so extra processes buy little once the executor's goroutines overlap the
  round-trip latency, and they would need a distributed throttle. It stays available as
  `worker` replicas taking `backfill:<entity>:<shard>` leases for the rare table where the
  row function itself is CPU-bound. Two things cut the row-by-row cost where it can be
  cut: a **`Derived` migration whose rules are all SQL-expressible** (`Rename`, `Default`)
  backfills in **pure SQL** — `update … set b = a, _tesl_v = g where pk in (select pk …
  where _tesl_v = g-1 order by pk limit N)`, no row crosses to Go, typically ten times the
  throughput of the `VALUES` form — and the reopened `OnRead` tier (Decisions) removes the
  backfill entirely for a derived column the application never writes. Honest
  expectations for the Go path, one primary, throttled to keep replicas within budget:
  5 000–20 000 rows/s depending on row width and index count, so 10 M rows is minutes to
  an hour, 100 M rows is hours, 1 B rows is days — during which the application serves
  normally and `--schema status` shows the ETA from the measured rate. For the last
  class the plan header says so before the deploy, and the choices are: `OnRead`, the
  pure-SQL form, a staged `Maybe` column filled by the application over weeks, or
  accepting the wait. Keyset pagination by primary
  key over a **partial marker index** (`on (pk) where _tesl_v < g`, built concurrently at
  expand and dropped at contract, so no pass scans already-migrated rows and the
  retirement postcondition `count(*) where _tesl_v < g` is an index probe, not a table
  scan), batches of 1 000–5 000 rows, each batch its own transaction, `UPDATE … FROM
  (VALUES …)` with the `xmin` predicate of invariant 2, progress in
  `tesl_schema_backfill_shards (entity, shard, lo_pk, hi_pk, last_pk, rows_done, state)`,
  aggregated per entity in `tesl_schema_entities` — the entity is still the unit of
  *finality*, because the marker is one statement about the whole row; the shard is only
  a unit of *work*. Throttled
  **adaptively**, because a backfill that saturates the write path or a replica is an
  outage by another name: the leader measures, between batches, replication replay
  lag (`pg_stat_replication`), WAL generation rate, lock waits and statement timeouts
  on its own batches, dead-tuple pressure on the table — all observable from the
  database by the executor itself — and, **only when configured**, the application's
  fleet-wide request p99 and error rate, read from a metrics provider the operator
  names (`TESL_BACKFILL_SLO_SOURCE`: a Prometheus-compatible query endpoint, or the
  runtime's own OTLP-exported aggregates); a single executor's local request metrics are
  not representative of a fleet and are never used for this. Without a provider,
  `--schema status` says "application SLO throttling: not configured" and the
  database-observed limits stand alone. It slows or pauses against configured
  thresholds (`TESL_BACKFILL_MAX_REPLICA_LAG_MS`, `…_MAX_WAL_MBPS`,
  `…_MAX_P99_MS`, per-entity batch size and concurrency); `app --schema backfill
  pause|resume [<Entity>]` is the operator's hand on it; `--schema status` and an OTel
  event say *why* it is throttled right now. A resumable backfill that overwhelms the
  replicas is not zero downtime. Rows a V7 update re-nulled through the trigger,
  or whose predicate failed, are picked up by the next pass. While V7 is admitted the
  backfill can only ever be **provisional** ("no rows below the target generation at the last scan"
  — an observation `--schema status` shows, and nothing depends on). It becomes
  **final** only after V7 is retired (V9 boot, step 5), by an exhaustive keyset pass
  over rows below the target generation (`_tesl_v < 4` in the running example) that runs when no writer can re-mark anything; it terminates
  because the marker, unlike a `NULL` test, does not depend on the migrated value,
  and it is normally tiny because the provisional passes did the work. Recorded per
  entity (`final_at`); V9's readiness and contract depend on it.
- **Knowing when to contract** (maintainer's question, 2026-09-04: "how does the
  developer know the migration is done and the next deploy may contract?"). "Done" has
  a precise meaning — *contractable*: every entity of the migration has no rows below its
  target generation at the last scan (provisional complete), every new index is `VALID`,
  no fenced transaction of the old version exists and no old-version heartbeat has been
  seen for the grace period. It is exposed four ways, all derived from the same control
  rows, none of them a new mechanism:
  - **OpenTelemetry**, like everything else: the gauge
    `tesl_schema_backfill_rows_remaining{database,entity}` (already listed), a gauge
    `tesl_schema_contractable{database,version}` (0/1), `tesl_schema_old_instances{version}`
    (heartbeats seen in the grace window), and one **event** `tesl.schema.contractable`
    emitted when the condition first becomes true — the thing an alert or a pipeline
    trigger subscribes to. Throttle state and ETA are attributes on the gauge.
  - **`app --schema status`**: one line per version — `V8: contractable (backfill
    provisional complete 14 min ago; 0 V7 instances since 22 min; indexes VALID) → run
    app --schema contract V8` — or the reason it is not, with the ETA from the measured
    rate.
  - **`app --schema await contractable V<n> [--timeout 2h]`**, for pipelines: blocks until
    the condition holds (exit 0), or times out (exit 2) printing what is still missing;
    the natural step between "deploy V8" and "contract V8" in a CD job.
  - **`contract` itself refuses** while rows remain or old heartbeats are recent, naming
    the count — so a pipeline that simply runs `contract` after the roll gets a correct
    answer either way; `await` only makes the wait explicit.
  `contract: WhenDrained` is the same condition acted on automatically; `Explicit` is
  the developer reading one of the four. Nothing here is a *promise* that the backfill is
  final — that is decided under the fence by the contract's own final pass — which is why
  the word is *contractable*, not *done*.

**Crash and resume — the first executor of a new version may die at any point, and
another picks up where it stopped.** (Maintainer's requirement, 2026-09-04: on a table
of hundreds of millions of rows a restart from the top is not acceptable.) The rule is
that **every long-running job persists its progress in the database at every commit, and
takeover means reading that progress, never recomputing it**; the one job PostgreSQL
itself cannot resume is named as such. Per job:

| job | what a crash loses | how the next executor resumes | guard against two executors |
|---|---|---|---|
| **expand** (DDL, trigger, control rows) | nothing committed — each statement is its own transaction | the boot lock vanishes with the dead session; the next holder re-runs the same `IF NOT EXISTS` / catalog-checked statements (no-ops for what exists) and `tesl_record_expanded` (idempotent on equal hashes) | the session-level boot lock |
| **initial install** on an empty database | same | same; `install_schema` verifies every existing table against the module before recording | same |
| **backfill** (provisional) | at most **one uncommitted batch per shard** (`TESL_BACKFILL_BATCH` rows) | the `backfill:<entity>` lease expires (`TESL_LEASE_TTL_S`, default 30 s; renewed every 5 s by a live holder); the next executor reads every shard's `last_pk`/`state` from `tesl_schema_backfill_shards` and continues each shard from its cursor. **The marker makes even a lost cursor cheap**: eligible rows are exactly `_tesl_v = g-1`, served by the partial marker index, so a shard restarted from `lo_pk` re-reads only rows that were not yet migrated — a restart from the top costs a scan of the *remaining* rows, never a rewrite of finished ones. `--schema status` prints `resumed from shard cursors (k of n shards complete)` | the lease, plus the `xmin` predicate: an expired-but-alive holder and its successor can only duplicate a batch, never disagree |
| **backfill by a newer binary** | nothing | a V9 executor embeds V8's migration (§6 invariant 2) and resumes V8's shard cursors exactly as a V8 executor would — a version roll *during* a long backfill is the normal case, not an exception | same |
| **index build** (`CREATE INDEX CONCURRENTLY`) | **the whole build** — PostgreSQL has no resumable index build; an interrupted one is left `INVALID` | the next `index:<name>` lease holder confirms via `pg_stat_progress_create_index` that no build is running, drops the `INVALID` remnant, starts again. This is the one job that starts over, and on a 100 M-row table that is tens of minutes: hence the worker is a long-lived process with a generous `terminationGracePeriodSeconds` in `deploy-recipe`, and an operator pausing the backfill does not stop an index build | the lease; a second `CREATE` fails harmlessly on the name |
| **final pass** (under the exclusive fence at contract) | the coordinator transaction — the fence and the floor advance; **not** the batches already committed on other connections | rerun `contract V<n>`: it retakes the fence and processes only rows still below the target generation, which the committed batches already removed from the set | the fence; the CAS in `tesl_advance_floor` |
| **contract DDL** | the statement in flight | rerun `contract V<n>`: resumes statement by statement from the catalog (§13b) | `tesl_record_contracted`; the next version's expand waits for `contracted` |
| **queue restamp / repair passes** | one batch | own progress rows (`tesl_schema_queue_restamps`, the repair's quarantine keys); resume from the cursor | the fence |

**How the successor knows it should resume rather than keep waiting.** (Maintainer's
question, 2026-09-04.) Correctness never depends on the answer — a wrong guess in either
direction costs one duplicated batch, because batches are conditional on `xmin` and the
marker; only *liveness* depends on it. So the question is "how fast and how surely is a
dead or stuck executor detected", and the answer differs by guard:

- **The boot lock is not polled at all.** The successor is *blocked inside*
  `pg_advisory_lock`; PostgreSQL wakes it the instant the holder's session ends, whether
  by `pg_advisory_unlock`, a clean exit, a crash, or a killed pod (the kernel closes the
  socket, the backend exits, the lock is released). No TTL, no guess. The one gap is a
  **half-open connection** — a node that vanished without a FIN, a partition — where the
  server does not learn the client is gone until TCP keepalive gives up, and the Linux
  default is two hours. So the executor sets, on its DDL/lease connection, the
  per-session GUCs `tcp_keepalives_idle = 10`, `tcp_keepalives_interval = 5`,
  `tcp_keepalives_count = 3` (user-settable, no server configuration needed): the server
  declares the client dead within about 25 s and the blocked successor proceeds.
- **Leases carry server-side identity, not only a clock — for every backend the
  executor owns, not just the lease connection.** An executor uses several connections:
  the lease/renewal connection, the dedicated DDL connection with its session fence and
  any `CREATE INDEX CONCURRENTLY`, and one connection per backfill shard. Terminating the
  lease connection alone (the first draft) would leave a batch transaction, an index
  build and the DDL session fence alive. So every connection an executor opens sets
  `application_name = 'tesl-exec:<instance id>'`, the lease row records that instance
  id, and the successor reasons about **the set** of backends with that tag in
  `pg_stat_activity`. Renewal (every 5 s) runs on a dedicated goroutine over the lease
  connection, **never inside a batch transaction**, so a batch that takes longer than
  the TTL because the throttle slowed it never looks like a death. A candidate
  successor, polling every 5 s, decides in this order:
  1. **no** backend carries the holder's tag → the holder is dead; take the lease
     **now**, without waiting for `expires_at` — the common crash case resumes in
     seconds, not a TTL;
  2. backends are present and the lease is **not** expired → alive and renewing; wait;
  3. backends are present but the lease **is** expired → stuck (paused process, frozen
     VM, a renewal goroutine that will never run); its sessions may hold row locks, a
     half-finished `CREATE INDEX CONCURRENTLY` and the session fence. The successor
     terminates **every** backend with the tag — `pg_terminate_backend` on each, which a
     role may do to its own role's backends without superuser — and then **polls
     `pg_stat_activity` until none remains** (`TESL_TAKEOVER_WAIT_S`, default 30; a
     backend that outlives it is reported, and the lease is *not* taken): a `true` from
     `pg_terminate_backend` means the signal was sent, not that the backend has exited.
     Only when the set is empty is the lease taken, so there is never a moment with two
     *live* holders. Termination is decisive and safe: open batch transactions roll
     back (one batch per shard), an index build aborts to `INVALID` (the builder path
     already handles that), and the session fence is released with its session — which
     is exactly what retirement needs too.
  The takeover writes the lease with its own pid/`backend_start`, emits
  `tesl.schema.job.resumed` with the cursors and the reason (`holder-absent`,
  `holder-expired-terminated`), and `--schema status` shows the previous holder and why
  it was replaced. `TESL_LEASE_TTL_S` therefore bounds detection of a *stuck* holder; a
  *dead* one is detected by `pg_stat_activity` at the next 5 s poll.
- **Why not terminate the boot-lock holder the same way?** Boot uses a lock rather than
  a lease precisely so that a slow expand is never mistaken for a dead one; but the same
  rule applies as a last resort: if `pg_advisory_lock` has timed out for longer than
  `TESL_LEASE_TTL_S` **and** the lock holder (from `pg_locks`) has an expired `boot`
  lease row, it is a stuck holder and the successor terminates it and proceeds. A holder
  that is merely slow keeps renewing its lease row and is left alone indefinitely.

Two properties fall out and are acceptance criteria: the total work of a backfill
interrupted `k` times is the row count plus at most `k × shards × TESL_BACKFILL_BATCH`
rows, and no committed row is ever processed twice by a resumed pass (the marker says
so). The partial marker index is itself built `CONCURRENTLY`; if it is `INVALID` after
a crash the backfill does **not** wait for it — the keyset scan falls back to the primary
key with a filter, slower but correct — while the index lease holder rebuilds it.

**Progress, not only completion, on OpenTelemetry.** (Maintainer, 2026-09-04.) A
multi-hour job whose only signals are "started" and "done" is unobservable, so every
long job exports its progress continuously from the same control rows `--schema status`
reads, all with `database`, `version` and `entity` attributes:

- `tesl_schema_backfill_rows_done` / `_rows_remaining` (counters and gauge, per
  entity and per shard), `tesl_schema_backfill_rows_per_second` (measured over the last
  minute), `tesl_schema_backfill_eta_seconds`, `tesl_schema_backfill_batch_ms`
  (histogram), `tesl_schema_backfill_shards{state}` (pending/running/provisional/final),
  `tesl_schema_backfill_throttle{reason}` (0/1 with the active reason: replica lag, WAL
  rate, lock waits, dead tuples, application p99, operator pause);
- `tesl_schema_index_build_progress` — `blocks_done`/`blocks_total` and `tuples_done`
  straight from `pg_stat_progress_create_index`, per index, plus `attempts`;
- `tesl_schema_final_pass_rows_remaining`, `tesl_schema_quarantine_rows`,
  `tesl_schema_contract_statements_remaining`, `tesl_schema_queue_restamp_rows_done`;
- `tesl_schema_executor{instance,job}` — which executor currently holds which lease, so a
  takeover is visible as the label changing; an event `tesl.schema.job.resumed` with the
  shard cursors it resumed from, and `tesl.schema.job.throttled` / `.paused` / `.resumed`
  with the reason.

Together with the `contractable` gauge and event above, a dashboard shows the whole life
of a migration; a pipeline can wait on `await`, an operator can alert on ETA growth or
on `throttle{reason}` staying set, and a takeover after a crash is a visible fact, not
an inference from a gap in the graph.

**Retiring V7 and contracting V8's leftovers** is one operation, *contract*, with
retirement as its internal first step; the committed `v8-contract.tesl` **authorises**
it, and the `contract:` lifecycle setting says when it **executes** — `Explicit` (the
default; `app --schema contract V8` on the executor), `WhenDrained` (the executor runs
it once no fenced V7 transaction exists and no V7 heartbeat has been seen for the
grace period), or `NextVersion` (at V9's boot). **The admission window is strictly
two versions once the additive epoch is closed, in every mode** (inside an epoch any
number of additive versions is admitted — §3, §8's algorithm). A V9 executor that boots and finds V7 still admitted
does **not** expand V9 — three admitted versions would need V7↔V9 compatibility, which
nothing has checked (dual writes, SQL rewrites and generation chains are all derived
from the immediate predecessor only). Under `Explicit` it stays **unready** and prints
the exact command — `app --schema contract V8` (migration V7→V8; retires V7) — in the
boot log and in `--schema status`; the V8 fleet keeps serving, so this is not
downtime, it is the operator's step in the order it has to happen. Under `NextVersion`
that boot runs the contract itself and then expands; under `WhenDrained` the executor
runs it as soon as the conditions hold, then expands. Boot never executes a contract
under `Explicit`. An earlier draft had V9 expand and become ready with V7 still
admitted, which contradicted the rule the whole protocol rests on. In every case the executor performs steps 5–6 for V7 — final pass
under V7's exclusive fence, retirement only if every row is accepted, then exactly the
listed `NOT NULL`s, trigger and column drops. There is no separate user-facing "retire"
operation for destructive versions.

**Slot retirement — the additive case, named.** A version with nothing to drop
(additive only) has no contract artefact, but its predecessor still occupies an
admission slot: the two-version rule admits at most two schema versions, so before a
third can be expanded the oldest must be retired. That is *slot retirement*: the
retirement step alone — exclusive fence, final pass (trivially empty), `min_version`
advance, lifecycle row `(n, 'retired')` — with no DDL. It is initiated by the next
version's expand when it finds two versions already admitted: under `Explicit` the
executor reports "V7 must be retired before V9 can expand: `app --schema contract V8`
(migration V7→V8; retires V7; nothing to drop)" and stays **unready** (not refusing —
an operator can still reach it); `contract V8` of an additive V8 *is* slot retirement,
allowed without an artefact because nothing destructive is listed; under
`WhenDrained`/`NextVersion` it happens automatically. **Naming, once:** `contract
V<n>` always means "execute migration `V<n-1>`→`V<n>`'s contract, which retires
`V<n-1>`"; every status line and error prints all three (`Contract V8 · migration
V7→V8 · retires V7`), because "retire V7" is how people think and "V8" is what the
artefact is named after. A version expanded under a pre-fence protocol level can be
retired only after the protocol activation ceremony below.

**When a row is rejected at retirement.** The database is left admitting what it
admitted before: V8 expanded, V7 admitted, rollback to V7 possible, with the
already-accepted final-pass batches committed (harmlessly, as above) and the rejected
rows quarantined. `--schema status` and the refusing V9
boot both print the quarantine (entity, key, reason — the row function's `Reject`
string). Three repair paths, none of which edits the frozen migration:

- fix or delete the rows through the still-admitted V7 or V8 application (the ordinary
  case: a handful of rows written during the window that violate a new rule);
- commit a **repair amendment** (specified below), which the final pass applies
  **only to rows the frozen function rejects**;
- `--schema quarantine Note --delete <keys>`, for rows that should not exist, with the
  same acknowledgement discipline as `Offline`.

A row function that *can* reject — syntactically: `Reject` in its body — is not fully
`ONLINE`, and the plan says so: it is labelled **MAY BLOCK
RETIREMENT** (the final pass may quarantine rows) **and MAY FAIL REQUESTS** — a lazy
read of a row the function rejects has no value to hand to the handler, so that
request fails with a typed `MigrationRejected` error (a 500 with the row key and
reason in the log, counted in `--schema status`), for exactly the rows that will be
quarantined. `ONLINE` without qualification is reserved for a **total** transform —
no `Reject` (and therefore no optional `establish`) — and the compiler's class table keeps the two apart;
the expected count of failing rows is what `--schema dry-run` reports before the roll,
and a nonzero count is the signal to fix the data or the function first.

**Why Repair exists at all** (maintainer's question, 2026-09-04). Because V8's row
function is **immutable the moment V8 expands**: its hash is recorded in the database,
every V8 binary anywhere may be running it on the lazy path, and half the table may
already carry rows it produced. A bug in it — or a real row it wrongly rejects — is
discovered only when production data hits it, at backfill or at the final pass. At that
point every other channel is closed: editing `v8.tesl` is MIG013 (the hash no longer
matches what the database recorded, and a rebuilt V8 with a different `migration_hash`
is refused at boot as edited history); rolling back to V7 and shipping a corrected V8 is
the same refusal, because V8 *has* expanded and its identity is fixed; and pushing the
fix into V9's migration deadlocks — V9 cannot expand until V7 is retired, and V7 cannot
be retired while rows are rejected. Fixing the *data* through the still-admitted
application (or deleting it, acknowledged) covers the "a few bad rows" case and needs no
Repair. Repair is the **forward channel for a code-level fix** that respects immutability:
an append-only amendment, hashed and frozen like the migration, applied only to rows the
frozen function rejects, so what V8 already did is never reinterpreted. It ships in phase
4 with the destructive contract, and if the "few bad rows" path turns out to cover
practice it is the first thing to cut.

**Repair amendments, specified.** A repair is a migration-shaped artefact with a
narrower job, and it is frozen, hashed, embedded and tested exactly like one:

```tesl
# migrations/notes/v8-repair-1.tesl — generated skeleton by `tesl migrate repair --entity Note`
module NotesSchema.Migrate.V8Repair1 exposing [repair, repairNote]

import Tesl.Migration exposing [Repair, Migrated(..)]
import NotesSchema.V7
import NotesSchema.V8

repair = Repair {
  of:     NotesSchema.Migrate.V8        # the migration it amends (module reference)
  entity: Note
  with:   repairNote                    # applied only where migrateNote returns Reject
}

fn repairNote(old: NotesSchema.V7.Note) -> Migrated NotesSchema.V8.Note = …
```

- **Scope and retention.** (Maintainer's question, 2026-09-04; revised the same day
  after the catch-up section.) A *serving* binary applies repairs only for the two
  migrations whose final pass can still be pending — `V<n-1> → VCurrent` and
  `V<n-2> → V<n-1>` (§6 invariant 2). But repairs, like migrations, are **retained and
  embedded for every committed version**, because catch-up (§8b) replays old
  migrations and can meet a rejecting row in any of them — a curated snapshot from V3
  may hold data no live database ever had. So a `Repair` may be **added for any
  committed migration**: for a live one it runs at the next final pass; for an older one
  it runs only inside a catch-up, and that is the supported remediation for "an old
  snapshot reveals a row V4's function rejects" — add `V4Repair<k>`, commit, rerun
  catch-up; the alternative is the acknowledged `quarantine --delete`. Neither rewrites
  frozen history (a repair is append-only by construction) and neither is raw SQL. The
  retention horizon is exactly the committed history: a binary can catch up any
  snapshot at or above the oldest version whose migration it embeds, and `prune`'s
  recorded statement names that cutoff; there is no separate archival bundle — the
  serving binary is the catch-up binary. An earlier draft made a new repair of an old
  migration MIG026 on the grounds that nothing could apply it; catch-up can. The "one version back" intuition
  is right in spirit and off by one in the window: the repair for `V7 → V8` is still
  legal while `VCurrent` is V9, because V9's contract is what runs V8's final pass. The
  worry about "an empty or very old database all the way to `VCurrent`" resolves as
  follows: an **empty** database is installed directly at `VCurrent`'s shape and runs no
  migration and no repair at all; a **very old** database is refused *for serving* and
  brought forward by catch-up (§8b), which replays every migration and every committed
  repair in order — which is why they are retained (previous bullet) rather than pruned
  as "never needed again", as an earlier draft of this paragraph said.
- **Identity and order.** Repairs of one migration are numbered (`V8Repair1`,
  `V8Repair2`, …) and applied in order to a rejected row until one returns `Row`; a
  repair may itself `Reject`, in which case the row stays quarantined with the last
  reason. The control row is `(8, 'repair', 1, hash)` — `tesl_schema_versions` is keyed
  by `(version, step, seq)` for this reason. The repair chain is **not** part of V8's
  identity: V8's `migration_hash` never changes once recorded, so the original V8
  image, and a V9 built before the repair existed, remain admitted for the whole
  window — including the V9 → V8 rollback of §8. Repairs form their own **append-only,
  prefix-compatible** chain: a binary embedding repairs `1..k` is admitted when the
  database holds `1..j` and one chain is a prefix of the other; two different hashes
  at the same `seq` refuse the binary (MIG013-class — someone edited a recorded
  repair). What a binary that lacks a recorded repair cannot do is **execute the final
  pass** for that migration: the pass requires the whole recorded chain, and
  `--schema status` says which binary can run it. So a repair is never a mutation of a
  deployed version's meaning; it is a later artefact that only the executor of the
  final pass must carry. An earlier draft made the chain part of V8's frozen history,
  which would have refused the very V8 image the rollback promises.
- **Typing and freezing.** `Repair { of, entity, with }` is contextually typed like
  `Migration` (MIG021 for the function's pair, MIG022 for a wrong entity); its reachable
  closure and stdlib slice are frozen with it; `Same` is inherited from the migration it
  amends; it becomes immutable the moment its hash is recorded **anywhere** — in the
  database's `tesl_schema_versions` or in a later artefact's header — whichever comes
  first. A generated `V8Repair1Compat` module exercises it on a quarantined-shaped
  fixture. The manifest, preview and LSP command treat it as any other generated set.
- **Who applies it.** Any binary that embeds V8's chain — a rebuilt V8, or V9+ — may
  run the final pass with it; the quarantine row is cleared by the pass that accepts
  the row, and by the application when it updates or deletes the row (the trigger
  lowers the marker, the pass re-reads it, and an accepted row deletes its quarantine
  entry). Rollback V8 → V7 is possible until that moment;
rollback V9 → V8 for the whole life of V9, because V8 is retired only at V10's boot
and a V8 binary that starts before then passes the admission check. An operator who
wants the rollback window to V7 closed earlier — and V7's trigger gone earlier — runs
`app --schema contract V8` on the worker as soon as the roll is done (or sets
`contract: WhenDrained`); there is no separate retire command.

**OFFLINE class:** `--schema apply-offline` exists for the two cases that
cannot be decomposed. See "The downtime path" below for the procedure, the
guarantees, and the compiler error that leads the user to it.

### 7. Indexes: non-blocking to build, not always risk-free

Adding an index is the most common schema change in a running system. Building one
never blocks the running program — but "non-blocking" and "`ONLINE`" are not the same
word: a **unique** index over columns V7 still writes is `ROLL-WINDOW RISK` (below),
because it changes what V7's inserts are allowed to do. Plain indexes are `ONLINE`; a
unique index is `ONLINE` only under the full additive test of §3 — every column new,
nullable, default-free, not row-function-filled — because "V7 does not name the column"
is not enough: a constant default makes every V7 insert write the same value, a
composite key may include an old column, and backfilled values can collide on their
own. Two things have to be handled that the earlier draft did not.

**How they are built.** Never inside a transaction and never with a plain `CREATE
INDEX` on a populated table (that holds a `SHARE` lock that blocks every write for the
whole build). Always `CREATE INDEX CONCURRENTLY` (two table scans, no write lock), on
the instance's dedicated, session-fenced DDL connection (§6 invariant 7), under a
version-suffixed name, tracked in `tesl_schema_index (name, state, error, attempts)`. Dropping an index at contract uses `DROP INDEX CONCURRENTLY`. A
build takes seconds to tens of minutes depending on table size; V7 and V8 both keep
serving throughout. The plain form is used only for a table **created in the same
expand** (never yet writable), not for one merely observed empty — an empty table
can receive its first write between the check and the build. An index that already
exists satisfies the declaration regardless of its name when it is **equivalent**:
same columns in order, uniqueness, `NULLS [NOT] DISTINCT` semantics
(`indnullsnotdistinct`), access method, expressions, predicate, operator classes,
collations, sort/null ordering, `INCLUDE` columns, deferrability (`indimmediate`, and
`condeferrable`/`condeferred` when constraint-owned) and constraint ownership — compared
**semantically** on `pg_index`/`pg_attribute`/`pg_opclass`/`pg_constraint` columns,
with `pg_get_indexdef` used only for the expression and predicate trees, never as a
text identity (its formatting differs across majors) — **and** it is
`indisvalid`, `indisready` and `indislive`; an invalid or half-built index of the right
shape is dropped and rebuilt, and a differently shaped index of the same name is
drift (above). §11.8's "same columns and uniqueness" is superseded.

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
frozen module alone says which indexes are at risk); a unique index is `ONLINE` only
when every column passes the additive test of §3 (new, nullable, default-free, not
filled by a row function) — then V7's inserts write `NULL`s that never collide. The
dry-run duplicate pre-check below is what makes the risk small in
practice: if the data has no duplicates today, V7 producing one during a roll window
is the same race the program already had.

**Duplicates during the build, and the livelock it can cause.** V7 keeps inserting
during the build and does not know about the constraint. A steady rate of V7
duplicates keeps the build failing, which keeps V8 unready, which keeps V7 serving —
a livelock with no natural bound. The plan therefore makes the operator choose one of
three resolutions when it labels the index `ROLL-WINDOW RISK`, and the choice is made
**in the schema module**, never at runtime — staging changes what V8 *compiles to*
(whether its type promises uniqueness, whether `onConflict [cols]` is legal, whether the
Memory backend enforces it, what the executor installs), and the migration record is
derived from the schema diff, so the only honest place for the decision is the desired
state itself:

(a) **Stage** it — the default suggestion. V8's entity declares

```tesl
  staging unique index [email]      # preparation, not a promise: no uniqueness is exposed yet
```

and V9 changes that line to `unique index [email]`. A `staging unique index` is a
**preparatory declaration**: the compiler derives it from the V7→V8 diff like any other
change (so the sparse record needs no special rule and the entity is not "unchanged"),
exposes **no** uniqueness to the program — V8's `User` type makes no promise,
`onConflict [email]` does not compile in V8, tests do not assume one row, the Memory
backend does not enforce it — and records an **obligation**: every later revision must
carry the line forward until it is *promoted* to `unique index` or *cancelled* by
deleting it, and either is an ordinary reviewed schema diff. **Promotion, honestly.**
An earlier draft built the index "once V7 is retired" and claimed the livelock was gone;
the re-review of 2026-09-04 is right that it had only moved: during the V9 roll **V8 is
still admitted and exposes no uniqueness**, so V8 keeps inserting duplicates while the
build runs, and a steady rate fails it forever. Without the reservation-table guard,
promotion therefore needs a writer that cannot create duplicates *and* a moment at which
no other writer exists. The recipe is three releases, and the compiler enforces every
step:
- **V8 stages** (`staging unique index [email]`): no promise, no guard, as above.
- **V9 declares** `unique index [email]` and, because the index does not exist yet,
  its writes carry a **per-key guard**, compiled in and emitted only in the window
  plan: an `insert` or `update` that sets a staged key first takes
  `pg_advisory_xact_lock(:fence_ns_stage, hashtext(key…))` and then probes for an
  existing row with that key — so two V9 writers of the same key serialise and the
  second fails with the same typed uniqueness error the index will raise later. V9
  therefore never creates a duplicate against another **V9** writer. It cannot stop V8,
  so **the build starts inside `contract V9`** — after V8 is retired under its exclusive
  fence — when the only admitted writers are V9's, which the guard covers. Pre-existing
  duplicates (V7's, V8's) fail the build once, are reported as `blocked_duplicates` with
  their keys, and block the contract until the data is fixed; `--schema dry-run` lists
  them beforehand. V9 code may **not** rely on the index (`onConflict [email]` does not
  compile in V9), because it does not exist for most of V9's life.
- **V10 relies** on it: `onConflict [email]` compiles, the guard is gone from the plan,
  readiness gates on `VALID` as for any unique index.
The guard is a per-key advisory lock plus one index probe per write of a staged key,
in V9 only — the same primitive the fence uses, not the reservation subsystem the
companion describes (that one is about *V8's* window, when the staging version itself
must not create duplicates against V7; it remains withdrawn from v1). What staging buys,
stated precisely: the build never races an unguarded writer, so the livelock cannot
occur; the cost is one extra release before the constraint can be relied on. A team
that wants two releases instead has the **bounded maintenance step** — hold the
exclusive fences of every admitted version for the duration of the build, a write stall
of minutes on a large table — chosen explicitly and never by default.

A **runtime guard** for the window — a reservation table with a real unique index, kept
in step by V8's writes so that even V8 cannot create duplicates while V7 is admitted —
was designed and **withdrawn from v1** after review: an initially empty reservation table
enforces nothing against pre-existing rows; a table trigger fires for V7's writes too,
and a staging change bumps no generation, so nothing distinguishes the two writers;
populating the table under concurrent V7 and V8 writes is a backfill with its own
provisional/final states, dirty-key tracking and reconciliation at retirement; and the
reservation invariant (every non-null key has exactly one reservation owned by its row,
every reservation points at one live row, no two rows share a key) needs the same
machinery `_tesl_v` already provides for columns. That is a subsystem, not a
convenience, and shipping it "approximately safe" would weaken a core that is otherwise
rigorous. It is recorded, with those requirements, as the dependent item
`roadmap/later/staged-uniqueness-guard.md`; until it lands, the honest statement is: a
staged unique index is enforced from V9, and duplicates V8 creates in the window are
found and reported, not prevented.

Control state mirrors the obligation: `tesl_schema_stages` (DDL below) with states
`pending` (declared, no index) → `promoting` (index build running after the predecessor
retired) → `enforced` | `blocked_duplicates` (build failed on real duplicates; keys in
`--schema status`) | `cancelled`; a stage is matched across revisions by a **stable
semantic identity** (entity, typed key columns, collation, null semantics, deferrability
— Tesl's `unique index` is immediate and `NULLS DISTINCT`, the stage records exactly
that, and any future deferrable or `NULLS NOT DISTINCT` form is part of the identity),
never by index name or text. Compiler diagnostics (MIG030 family): changing a staged key's
columns, collation or null semantics without cancelling the old stage; renaming a
staged field or dropping its entity without cancelling; declaring a conflicting
`unique index` while a stage is pending; carrying a stage beyond
`TESL_STAGE_MAX_VERSIONS` (default 3) without promotion or cancellation; promoting while
control state is not `pending` for that database (a boot-time check, MIG013-class);
pruning source that still defines an outstanding stage. **Cancellation** — deleting the
line — is a decision-class plan entry (`CANCEL STAGED UNIQUE User[email] — no unique index
will be created`) that the reviewer must acknowledge; it needs no migration constructor,
the two schema revisions already carry the intent.

(b) A **bounded window** — the index is declared in V8 as usual, V8 reports unready for
at most `TESL_INDEX_BUILD_WINDOW` (default 30 min), then surfaces the offending keys in
`--schema status` and waits for an operator; what the operator may change at runtime is
only *how long to wait* (`app --schema index-wait`), never the strategy. (c) The
**offline** path. A "ready with an `INVALID` index, refusing violating writes"
option was considered and removed: it contradicts the readiness rule that a unique
index is entity semantics, and `onConflict` cannot use an invalid index. There is no
default bound on failures during the window; a bound exists only where one of these
policies supplies it. If it inserts a duplicate, the concurrent build fails and leaves
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
| no control schema, user tables present | refuse: a pre-versioning database; print `--schema adopt`, which — in **one transaction** — creates the control schema, verifies every live table's columns against the schema module (refusing on any mismatch or on a pre-existing `_tesl_v`/`tesl_*` name), adds `_tesl_v smallint not null default <g>` to every entity table (metadata-only, PostgreSQL 11+), where `g` is the entity's generation in the module lineage the repo holds (1 for an entity with no migration history), writes the `tesl_schema_entities` rows and records `V<n> expanded, contracted`. All or nothing: a failure on the fifth table leaves the first four untouched |
| `min_version > n` | refuse: this version has been **retired** (a contract of a later version ran); redeploy the current version |
| binary embeds a `v<n>-contract.tesl` and `V<n-1>` is not yet contracted | start; the artefact authorises — execution is `app --schema contract V<n>` on the worker (`contract: Explicit`, default) or automatic under `WhenDrained` / `NextVersion`: final pass under `V<n-1>`'s exclusive fence, retire if every row is accepted, exactly the listed drops, record `(n, 'contracted', hash)` — or report the rejected rows and do nothing |
| binary embeds no `V<n-1>` module/migration (cleanup after contract) and the database records `(n, 'contracted')` | start |
| same, but the database does **not** record the contraction | refuse: this binary lacks history the database still needs; deploy the binary that has it (the compiler only allowed the deletion because a contract file exists, so this is a deploy-order mistake, not a lost history) |
| `V<n>` expanded, `min_version ≤ n` | start |
| `V<n-1>` expanded, `min_version = n-1` (exactly one admitted version) | **expand `V<n>` automatically**, then start |
| `V<n-1>` expanded, `min_version = n-2` (two admitted; `V<n-2>` occupies the oldest slot) | do **not** expand: under `Explicit` stay unready and print `app --schema contract V<n-1>` (migration `V<n-2>`→`V<n-1>`; retires `V<n-2>`); under `NextVersion` run that contract, then expand; under `WhenDrained` run it when its conditions hold, then expand |
| `V<n+1>` expanded, `min_version ≤ n` | start — this is a **rollback**, and the two-version rule guarantees this binary still runs |
| `V<n-2>` connections still hold their fence key | refuse: a `V<n>` is booting while `V<n-2>` still runs; deploy versions in order |
| behind by two or more | refuse **to serve**: deploy versions in order (each expand is verified against the *previous* schema module only). The message names the way forward for a database that has **no fleet** — a restored backup, a curated test snapshot: `app --schema catch-up` (below), which replays the missing versions one at a time under exclusive fences |
| some entity still has rows **two generations** behind the generation `V<n-1>` gave it (the previous migration is not final) | refuse: this binary carries only the `V<n-1>` and `V<n>` migration files and cannot bring those rows forward; let the running `V<n-1>` fleet finish (or run `--schema contract` there) first |
| hash differs at the same version | refuse: an applied snapshot or migration's behaviour was edited (§11) |
| `OFFLINE` plan pending | refuse with the exact `--schema apply-offline` command (see "The downtime path") |
| a new unique index is not yet `VALID`, or a column this version uses inside SQL has no final backfill | start, but report **not ready** until it is (§6 step 11) |

**The decision, as one algorithm** (the table above is its explanation; this is what
the executor runs, and the re-review of 2026-09-04 asked for it because the table and
the additive-epoch prose read as two models). Inputs: the binary's version `v`, the
state row (`min_version`, `current`), the `expanded` rows with their per-version
`epoch_preserving` flag (recorded at expand from the plan's classification), the
`retired`/`contracted` rows, the fence keys held.

```
admit(v):
  if min_version = 0                     -> fresh database: initial install at v (§ bootstrap)
  if v < min_version                     -> REFUSE retired
  if v <= current:
     if all expanded rows in (v, current] are epoch_preserving
                                         -> ADMIT (any distance inside an additive epoch)
     elif v = current - 1                -> ADMIT (rollback row)
     else                                -> REFUSE "deploy in order" + offer catch-up
  if v = current + 1:
     if exists ('contracting' in progress for current)   -> UNREADY "contract V<current> incomplete"
     if not epoch_preserving(v) and min_version < current and not all expanded rows in [min_version, current] epoch_preserving
                                         -> UNREADY "retire V<min_version> first" (contract / close-epoch per lifecycle mode)
     if fence(v-2) held by anyone        -> REFUSE "V<v-2> still runs"
     if hash(v-1 expanded) <> embedded   -> REFUSE edited history
     if some entity two generations behind -> REFUSE "previous migration not final"
     else                                -> EXPAND v, then ADMIT
  if v > current + 1                     -> REFUSE "deploy in order" + offer catch-up
  readiness: after ADMIT, not ready until every new unique index is VALID and every
             column used inside SQL has a final backfill
```

The Memory backend is always at `V<n>` (fresh per test). No environment variable
turns the gate off; a development database is the first row, a test database is the
Memory backend.

### 8b. Catch-up: bringing a restored snapshot to `VCurrent`

(Maintainer, 2026-09-04.) A backup of production restored for a drill, a point-in-time
restore after an incident, or a large curated test database is at some V50 while the
code is at V57. Working out "which versions did we ship between, in what order, with
nothing interleaved" is not a task a team that deploys thirty times a day should ever
have to do by hand — and it does not have to, because schema versions are **linear
integers per database**: the chain is `V51, V52, …, V57`, nothing else can be in it, and
code deploys that changed no schema created no version. What the two-version rule
forbids is *serving* two versions apart, and it forbids it because of the concurrent old
fleet it cannot see. A restored snapshot has **no fleet**. So:

```
./app --schema catch-up [--to V<n>] [--dry-run] [--no-throttle]
```

replays every missing version **sequentially**, and it begins by proving it is alone.
**Barrier first.** The exclusive fence keys exclude every *writer*, but under the v1
default `admission: Trusted` a read takes no fence and no admission statement, and an
idle old connection can start one at any moment — so "a restored snapshot has no fleet"
is an operational expectation, not something the database proves (re-review,
2026-09-04). Catch-up (and `apply-offline`, which had the same gap) therefore runs a
**connection barrier** before its first step, and refuses without one: as `tesl_schema`
— which `--schema grants` makes the database's owner and a member of `tesl_app` — it
executes `revoke connect on database … from tesl_app`, terminates every `tesl_app`
backend, and polls `pg_stat_activity` until none remains; then it takes, **session-level
on its own DDL connection**, the exclusive fence key of every version from the
database's `min_version` to the target (the coordinator holds them for the whole run
while the batches commit in short transactions on other connections — holding them in
one transaction would contradict §13b's short-transaction rule), and only then works.
At the end it `grant connect`s back (`--keep-barrier` leaves it revoked for the
operator). Where the executor lacks those privileges it refuses unless `--barrier
platform:<ref>` names an external barrier, recorded like the activation ceremony's
`platform-barrier` evidence. **Then normalisation, not "next version first".** The
chain is a state-machine normalisation (§13b): (1) **finish the partially applied
transition at `current`** — a restored "V53 expanded, backfill provisional" resumes
V53's backfill to final, applies V53's repairs, quarantines what still rejects (a
quarantined row stops the chain with version, key and reason, as at a live retirement);
(2) **retire and contract as the state requires** — retire V52 through
`tesl_advance_floor`, execute V53's committed contract or slot-retire, resume a partial
contract statement by statement; (3) **only then expand V54**, and repeat (1)–(3) for
each version up to the target: expand `k`, run `k`'s migration to final in one go (no
writers, so provisional and final collapse; the backfill engine runs with its shards
and, with `--no-throttle`, without replica-lag limits since nothing is serving), apply
`k`'s repairs, retire `k-1`, contract `k`, record the lifecycle rows. It prints the
chain, the estimated duration per version from row counts, and the quarantine before
doing anything under `--dry-run`. Guarantees are **not weakened**: no step runs that a live deployment would
not have run, in the order it would have run it, with the barrier and the fences proving
the precondition a live deployment gets from its predecessor's retirement. What catch-up
does not do: run while anything is connected as `tesl_app` (the barrier refuses and
names the backends rather than waiting silently, unless `--wait-for-drain`); skip a
version; or run in a request process — it is an executor verb like `contract` and `apply-offline`. Development under
`topology: Embedded` may set `catchUp: Auto` so a local database restored from a
snapshot is brought forward at boot; the production default is the explicit command in
the restore runbook, because an unattended multi-hour replay on a production restore is
a decision, not a default. Two consequences for the rest of the design: every committed
migration, repair and contract is **embedded** in the binary (invariant 2), and `prune`
becomes a decision with a stated cost — "snapshots older than V<k> can no longer be
caught up by this binary" — rather than housekeeping.

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
  `VALIDATE CONSTRAINT` (`SHARE UPDATE EXCLUSIVE` — blocks other DDL and `VACUUM`,
  never reads or writes), then the constraint is promoted.
- **Bloat is bounded.** `UPDATE`-based backfill creates one dead tuple per row; the
  batch pause lets autovacuum keep up, and the plan prints the expected cost honestly:
  every updated row is a **new heap tuple** (rows × average tuple width, not new-column
  width); when the update changes **any** indexed column — the normal case, since the
  new column is usually indexed and the partial marker index keys on `_tesl_v` — the
  update is not HOT and **every** index on the table gets a new entry, not only the one
  whose key changed (HOT applies only when no indexed column changes at all); plus
  roughly the same again in WAL and hence
  replica traffic; `--schema dry-run` prints heap, index and WAL estimates and the
  free-space and replica-lag thresholds the backfill pauses at (`backfill pause` is
  automatic below the free-space threshold or above the lag threshold, resuming when
  clear). The shadow-table
  path (copy + swap) is used only by `--offline`, where writes are stopped.
- **Dry-run writes nothing.** A rolled-back `UPDATE` still leaves dead tuples and WAL;
  the read-only pass does not.
- **Lazy read costs one function call per unmigrated row**, in Go, on data already
  fetched — no extra round trip. Reads of migrated rows pay a `NULL` check. Dual
  writes cost one extra column per insert/update for the life of V8. The invalidation
  trigger costs tens of microseconds per `UPDATE` on the migrating table and exists
  until V7 is **retired** as the first step of the contract — whenever the `contract:`
  setting executes it (command, when drained, or at V9's boot), so typically for part
  of V8's life. It is cheap enough that tying its lifetime to the state transition rather
  than to observed absence costs nothing worth having.
- **The fence costs one extra statement per transaction, in the same round trip.**
  `pgx` pipeline mode batches `BEGIN`, the fence statement, the program's statement(s)
  and `COMMIT`; the server-side cost is a shared advisory lock in the lock table per
  transaction — tens of microseconds, and shared locks on one key do not *conflict*
  with each other. They do **contend**: PostgreSQL's fast-path locking, which keeps
  relation locks on hot tables out of the shared lock manager, does not cover advisory
  locks, so every fenced write in the fleet takes the same lock-manager partition
  LWLock for the same lock object — exactly the `LWLock:LockManager` wait the fast path
  exists to avoid. At high write rates on many cores that is a real hot spot, not a
  theoretical one; it is the strongest argument for the server-side trigger alternative
  (§13) or for **striping** the shared key (`fence(v, pid mod k)`, retirement taking all
  `k` exclusively), and the phase-1 benchmark must include both. The `fence: Session`
  opt-in removes the per-transaction acquisition on deployments that can guarantee
  direct connections; finding the saturation point is a phase-1 release gate. No
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
| 10 M rows | 10–30 min outage | expand ms; Go backfill tens of minutes to an hour (4 shards, throttled, resumable), pure-SQL `Derived` minutes; serving throughout |
| 100 M rows | hours of outage | expand ms; Go backfill hours, pure-SQL tens of minutes; serving throughout; `--schema status` shows the ETA |
| 1 B rows | not attempted | expand ms; Go backfill **days** — the plan header says so; prefer `OnRead`, a pure-SQL `Derived`, or a staged `Maybe` filled by the application; serving throughout either way |

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

### 11. Command surface — a `tesl migrate` family, the rest in the binary

The compiler's CLI grows by **one entry**, in the flag style the existing surface
uses (`--fmt`, `--lint`, `--check`):

```
tesl migrate generate  <entry> [--database D] [--suggest-online]   # the everyday verb; creates the next revision if none exists
tesl migrate rebase    <entry> [--database D] [--combine]
tesl migrate repair    <entry> [--database D] --entity <E> [--fixture <path>]
tesl migrate contract  <entry> [--database D] V<n>                   # writes v<n>-contract.tesl (authorisation)
tesl migrate prune     <entry> [--database D]
# `tesl migrate` is a subcommand family like `tesl doc`; verbs are mutually exclusive by construction.
# `--database` selects the target when the workspace has several; otherwise the single target is inferred.
    diff the previous schema module against the one the `database` names; write the
    migration skeleton <Migrate>/V<n+1>.tesl (or refresh an unfinished one), its frozen
    stdlib slice; print the plan header. If no newer
    schema module exists yet, offer to copy V<n>.tesl to V<n+1>.tesl first. Idempotent.
    The LSP quickfix on the "schema module changed, no migration" diagnostic calls
    exactly this.
```

**Team workflows the command owns.** Three routine situations get first-class,
previewable operations rather than instructions:

- `tesl migrate rebase`: branch A landed V9; branch B also has a hand-edited V9 and must
  become V10. The command renumbers headers, filenames, module names, provenance
  markers and the compat/support outputs, regenerates the record against the new
  predecessor, keeps every user-owned row function whose types still apply, and leaves a
  MIG003-class hole with a focused message where one does not. "The collision is
  desired" describes correctness; this is the recovery.
- `tesl migrate prune`: **decision-class, off by default.** Pruning trades repository and
  binary size for the ability to catch up (§8b) a snapshot older than the pruned
  versions, and its output says so in one line: "after this prune, a database or backup
  at V<k> or older cannot be brought to `VCurrent` by this binary". The compiler can
  only compute **source candidates** — files no future binary would need *if* every
  database has finalised the versions behind them; it cannot know that, because it never sees a database, and a build is deployed
  to many. So `prune` takes **runtime evidence per database, not per environment**: `app
  --schema status --json` emits a hash-bound report for one database carrying a stable
  database identity (the `tesl_schema_meta` id), the schema target, current and minimum
  versions, the migration hashes, the observation time and the deployment identity; the
  repository declares the **expected target inventory** — statically (`tesl.json`
  `deployTargets`) for ordinary deployments, or through an **inventory provider** for
  dynamic fleets (`deployTargets: { provider: "<command or URL>" }`) that returns a
  signed snapshot "these were all active targets at time T", with dormant or
  customer-controlled installations listed as such so that prune treats them as
  *unknown*, never as *finalised*; a database-per-tenant system does not maintain a
  ten-thousand-line list by hand; CI collects one report per target; `tesl migrate prune --status reports/*.json` lists what is
  removable given all of them, names any expected target that is **missing or stale**
  and refuses to call anything removable while one is, says why each retained file is
  still needed, and removes nothing until confirmed. Without evidence it prints candidates only, labelled
  as such. The boot refusal remains the last line: a binary that lacks history a
  database still needs refuses, so premature pruning is a failed deploy, never lost
  data — but the point of the evidence is not to get there.
- `tesl migrate repair --entity <E>`: the journey from a quarantined production row to a
  reviewed fix. The scaffold carries the rejection reason, the target and sequence
  preselected, and a **failing compatibility test** built from a fixture obtained by
  `./app --schema quarantine export <Entity> <key> --redact` — the only live-database
  step, run in the terminal. Its rules, since it is a privacy boundary and not a
  convenience: the export is a **typed fixture skeleton**, written to
  `.tesl-stuff/quarantine/` (git-ignored, mode 0600) and never into a source directory;
  every column marked `@pii` in the entity module and every `Secret`-typed column is
  replaced by a correctly typed `todo`. The states are distinct and the tool names
  them: (1) the export is a **non-compiling skeleton**; (2) the developer supplies
  synthetic values for the holes; (3) it compiles; (4) only then can the scaffolded
  test reproduce the rejection — or fail to, which the tool states up front when the
  **rejected** column is itself sensitive, since redaction then necessarily destroys the
  reproduction and the case must be built by hand. `@pii` is a small general annotation
  with consequences beyond migrations (logging, telemetry redaction, codec output); its
  typing, propagation through newtypes and records, and redaction semantics are
  specified in their own bounded subsection of the manual, not here; without `--redact` the command refuses unless the database is marked
  non-production in the target. A fixture promoted into a committed test is a deliberate
  copy, reviewed like any other test data. `--schema dry-run` then states exactly which
  quarantined keys the repair would accept. The scaffold's header says in one sentence when to fix
  data through the application instead of changing migration semantics.

Small services get the operational pieces generated, not assembled: `./app --schema
deploy-recipe kubernetes|compose` emits the worker Deployment/Job, the grants job, the
contract job, a **pre-expand `close-epoch` job** (gated on the drain check, with the
exact `--through` target, a no-op when another deployment already closed the epoch) and
the readiness ordering that keeps the current request pods serving throughout, as
templates under `templates/`, in the style of the existing `templates/docker`. Tesl still orchestrates nothing; it hands
the operator a correct starting point.

**Why a command at all, if the schema module is copied by hand?** Because the copy is
the trivial part. Every hand-written thing — `V9.tesl`, the row functions, the
acknowledgements — is yours; what `tesl migrate generate` produces is exactly what a person
*cannot* write reliably, and the compiler needs all of it:

- the **diff and its classification** (`ONLINE` / `ROLL-WINDOW RISK` / `OFFLINE`,
  expand/window/contract per entity, the plan header) — derived from two schema
  modules plus the whole-program query set;
- the **migration skeleton** with one entry per changed entity (absence is verified
  `Unchanged`, so the record is as long as the change) and
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
  # every verb takes [--database D] when the program declares several databases
  ./app --schema status                       versions, generations, backfill progress, live instances, quarantine, pending contract
  ./app --schema dry-run [--sample 1%]        row functions read-only over real data; duplicate pre-check; time estimate; which
                                              quarantined keys a repair would accept
  ./app --schema contract V<n>                execute the committed v<n>-contract.tesl: final pass under the old fence, retire
                                              (internal first step), exactly the listed drops/tightenings. Refuses while old
                                              heartbeats are recent unless --force
  ./app --schema worker                       the production executor: expand, DDL, backfill, index builds and contract run here
                                              under the DDL-owning role; request processes do none of it
  ./app --schema grants                       print the GRANT script for the two roles (tesl_app, tesl_schema)
  ./app --schema quarantine list|export|delete <E> [<key>] [--redact] [--acknowledge "…"]
  ./app --schema backfill pause|resume [<E>]   the operator's hand on the adaptive backfill
  ./app --schema await contractable V<n> [--timeout D]   block until V<n> may be contracted (exit 0), or time out (exit 2)
                                              naming what is missing — the pipeline step between deploy and contract
  ./app --schema activate-protocol plan|verify <nonce>   the split ceremony: `plan` emits the DBA statements + nonce,
                                              an administrative job runs them, `verify` checks and records; no soft evidence
  ./app --schema close-epoch --through V<n>   atomic epoch closure: retire every admitted version below V<n> in one
                                              transaction (all fence keys ascending, one CAS), preview first
  ./app --schema index-wait <index> <duration>|forever   how long an unready build may wait (the strategy itself
                                              — `staging unique index`, window, offline — is declared in the schema, never chosen at runtime)
  ./app --schema deploy-recipe kubernetes|compose   emit worker/grants/contract templates under templates/
  ./app --schema catch-up [--to V<n>] [--dry-run] [--no-throttle]   replay every missing version in order under exclusive
                                              fences — for a restored backup or a curated test snapshot with no fleet (§8b)
  ./app --schema apply-offline [--wait-for-drain]   the OFFLINE path; needs every admitted version's fence key exclusively
  ./app --schema adopt                        record V<current> on a pre-versioning database after verifying columns
  ```

  The binary exits after the verb instead of serving. Today the emitted `main` takes
  no arguments at all, so this is a new, small, uniform surface — one flag, one verb.

- **There is no `apply` for the online path anywhere.** Expand happens when the new
  version arrives (worker in production, boot in development), backfill in the
  background, contract when the `contract:` setting executes the committed artefact
  (`Explicit`: the command; `WhenDrained`; `NextVersion`).

**Responsibility split.** Worth stating because migrations are where a language
tooling and a deployment tool most often end up doing each other's job:

| Concern | Owner |
|---|---|
| detecting a schema change, writing the next revision and the migration skeleton, checking it | Tesl compiler (`tesl migrate generate`, `--check`) |
| expand, lazy read, backfill, invalidation trigger, boot gate, readiness | the compiled binary, automatically (expand and backfill in the schema worker in production) |
| contract (retirement is its first step) | the schema worker, authorised by the committed `v<n>-contract.tesl`, executed per `contract: Explicit | WhenDrained | NextVersion` |
| reporting readiness (schema gate, unique-index build) on the health endpoint | the compiled binary |
| offline apply, dry-run, adopt, contract, status; the schema worker as the production executor | the compiled binary, via `--schema` |
| rolling strategy, surge/unavailable counts, probe timings, scaling to zero, maintenance page | Helm / Kubernetes / whatever deploys it |
| running `--schema apply-offline` at the right moment (a Job, a `pre-upgrade` hook) | Helm / the pipeline |
| deciding that downtime is acceptable | the person writing `Offline "…"` |

Tesl never orchestrates a roll, never scales anything, never talks to a cluster API.
It makes the binary correct under any roll order and tells the operator, in the boot
log and on the readiness endpoint, what it is waiting for.

`tesl migrate generate` prints the header Acadia prints, and the same header is written as the
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
  library** *(frozen-execution model — the one execution-model decision still open; the
  alternative, "record `compiler_abi`, do not freeze", is in Decisions, and catch-up
  makes the choice urgent because it runs the oldest migrations under the newest
  compiler)*.** The standard library is itself mostly Tesl (the lifted modules), and a
  reached stdlib function can change between the compiler that built V8 and the one
  that builds V9 — yet V9 must run V8's final pass *before it is ready*, so "write a V9
  migration" is no remedy there. So `tesl migrate generate` copies every lifted-Tesl stdlib
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
  — must embed the same hash or is refused with the name of what changed.
- **A hash of compiler IR is not a frozen semantics; an execution ABI is.** Two
  compiler versions can lower identical typed IR differently, fix a code-generation
  bug, or change pattern-match, integer or proof-erasure behaviour, and a refactor of
  the IR representation would change the hash while preserving behaviour. So the
  migration closure is written in — and the compiler checks it stays within — the
  **Migration Core** subset of Tesl (records, ADTs, `case`, `let`, arithmetic and
  string primitives, calls to frozen functions and to the schema modules' `establish`/`check`; no effects, no
  capabilities), whose lowering carries a **migration ABI version** (`tesl-migration-abi
  v1`) with pinned, golden-tested semantics across compiler releases. The ABI version is
  written in every migration, repair and contract header and is part of the hash. A
  compiler that changes the meaning of anything in the subset bumps the ABI and must
  either **retain the previous lowering** for embedded migrations frozen under the old
  ABI or refuse to build them (MIG014's rule, extended from primitives to the subset),
  with the path "finalise and contract on the old compiler, then upgrade". With that,
  "two binaries built from the same migration cannot disagree" is a property of a
  versioned, tested execution contract rather than of an internal data structure.

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
tool, on every PostgreSQL major supported upstream at release time. The **floor is
14**: `CREATE OR REPLACE TRIGGER` (14) and `gen_random_uuid()` (13) are the newest
mechanisms used; unsupported majors are not promised or tested.

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
  deployment generation could fence it and is out of scope here (an earlier revision exempted reads and deletes entirely). But the *lock* half of the fence exists only
  so that retirement waits for in-flight **writers** — the trigger drop must not race a
  write — and retirement never has to wait for a reader: the contract DDL already
  blocks behind a reader's `ACCESS SHARE` table lock. So the compiler emits two
  different admissions:
  - **write transactions** (`insert`, `update`, `upsert`, `delete` — a delete is a
    mutation): the two-statement fence of §6 invariant 1;
  - **read transactions** (under `admission: Strict`; the v1 default `Trusted` emits a
    plain read — see the product defaults for why): no advisory lock, and an
    **ordering** that makes admission sound: the query runs **first**, then `select tesl_admit(<program version>)` — one
    primary-key lookup on `tesl_schema_state` comparing the **binary's schema
    version** with `min_version`, raising if retired — then `COMMIT`; the runtime hands
    rows to the handler **only after `COMMIT` has succeeded** (not merely after the
    admission statement returns: a transaction can still fail at commit, and a future
    streaming API must not observe rows the transaction later discards). Three shapes,
    all statically known to the compiler:
    - a **single read** outside any `transaction { }`: wrapped as `BEGIN`, query,
      admit, `COMMIT`, pipelined, one round trip, rows released after commit;
    - a **statically pipelineable batch** — several reads with no data dependency,
      which the emitter can send in one pipeline: `BEGIN`, queries, one admit, `COMMIT`;
    - a **data-dependent read-only `transaction { }`**, where query B is built from
      A's rows: A's rows *must* reach the handler code before B exists, so admission
      runs **after every read statement** (each one holds its tables' locks from then
      on) and the handler's *response* is released only after `COMMIT`. A retirement
      between A and B is caught by B's admission and aborts the whole transaction,
      whose response is then never sent. Retirement adds a new abort point after
      handler code has run, so **external effects inside a `transaction { }` body are
      a compile error** (decided 2026-09-03): a capability that leaves the process —
      `httpClient`, direct sends, anything not transactional — may not be required by
      code reachable from a transaction body. The transactional primitives are
      unaffected and are the sanctioned route: `enqueue` and `email` already write to
      outboxes inside the same transaction, `publish` goes through `tesl_pubsub_outbox`,
      so "do it after commit" is spelled "enqueue it". This is a language rule, not a
      documented exclusion; it belongs in LANGUAGE-SPEC alongside the capability rules
      and lands with the fence.
    - transactions containing **writes** take the write fence first and need no read
      admission. Why this order and
    not admit-then-query: under READ COMMITTED every statement has its own snapshot,
    so an admission taken *before* the query proves nothing about the state the query
    then reads — a retirement (and even a contract) could commit in between, since the
    query holds no lock yet (an earlier revision had exactly that race). Query-first closes it with two facts PostgreSQL guarantees: the
    query's `ACCESS SHARE` lock on every table it touched is held until commit, so no
    contract DDL can run between the query and the admission; and the admission
    statement's snapshot is at least as new as the query's, so a retirement committed
    before the query is seen and aborts the transaction, and a retirement committed
    after the admission snapshot means the query read genuinely pre-retirement data.
    Nothing is delivered from an aborted transaction. **The guarantee, stated
    exactly:** every delivered response of version V is derived from a snapshot taken
    while `min_version <= V` — reads linearise before the retirement even if their
    bytes leave the process after it; no read whose snapshot is after the retirement
    is ever delivered; no write of a retired version commits (the fence). This is
    *not* "no SQL of a retired binary is ever executed": a process paused before its
    query and resumed after retirement — even after a contract — executes a query that
    may fail with `undefined_column`, and the runtime runs the **one retry decision
    table** of §6 on it: re-read `min_version`; retired means the process logs the
    retirement and exits (the same path as the poll); an admitted binary on a window
    plan switches to the settled plan and retries once; anything else is the handler's
    error as today. That failure is controlled, contains no data, and is the
    price of reads carrying no lock; a strict "no old SQL after retirement" would need
    every read to take the fence, which is `Trusted`'s inverse and is not offered.
    Buffering cost: Tesl has no streaming read API — a read transaction is one
    pipeline whose rows arrive with the `COMMIT` result — so "release after commit"
    adds no buffer, connection time or transaction lifetime beyond what one round trip
    already has; a future streaming API must re-derive this. The argument is the program
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
`tesl_schema_state.min_version` (one primary-key lookup per row), and retirement would stay
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

**Transaction retry, as a general rule.** A PostgreSQL deadlock (`40P01`) or
serialization failure (`40001`) — possible under any unique index, not only staged ones
— is retried by the runtime as a **whole transaction**, never a single statement:
bounded attempts (default 3) with exponential jitter, the body re-executed so
`nowMillis`/`generateId` are re-evaluated (nothing from the failed attempt was
observable, so fresh values are correct), an OTel event and a 500 with the last error
when attempts are exhausted, and **no** automatic retry for a transaction whose body
requires a capability the language does not mark replayable — which, with external
effects already forbidden inside transaction bodies, is none in practice. Stated
plainly: `WithTransaction` (`runtime/go/teslrt/database.go:136`) has **no** retry and
sets no isolation level today, so this — and the external-effects rule above — is new
language semantics, not a description of the runtime. Both are justified on their own:
a transaction can already abort at `COMMIT` on `40001`/`40P01`, so an effect inside a
body was never atomic with it. They belong in LANGUAGE-SPEC as their own item, which
this design depends on and does not decide.

### 13b. The lifecycle as one state machine

Most of the confusion in earlier drafts came from describing the same transitions from
V7's, V8's and V9's points of view. Named once, per **version**:

```
   Expanded ──(backfill provisional)──▶ Backfilling ──(no rows below target)──▶ Awaiting contract
                                                                                        │
                        tesl_advance_floor: exclusive fence on predecessor,          │ contract V<n>
                        final pass with every row accepted, re-check, CAS min_version   │ (Explicit: command;
                                                                                        │  WhenDrained / NextVersion: automatic)
                                                                                        ▼
                                                    Predecessor retired ──(listed drops/tightenings)──▶ Contracted
```

- **Expanded**: the version's DDL is in the catalog; inside an additive epoch any
  number of versions may be in this state, after it at most two (the window).
  Additive-only versions have nothing to backfill or drop and sit in *Expanded* until
  **slot retirement** (`close-epoch`, or the next contract) retires their predecessor.
- **Backfilling**: provisional only; the predecessor may still re-mark rows.
- **Awaiting contract**: a transforming version whose `v<n>-contract.tesl` is committed
  and not yet executed; the next version cannot expand until this one's predecessor is
  retired.
- **Staged unique index** (a per-declaration lifecycle that spans versions, tracked in
  `tesl_schema_stages`): *pending* (declared in V<n>, no index) → *promoting* (V<n+1>
  declares `unique index`, predecessor retired, build running) → *enforced* (index
  `VALID`) | *blocked_duplicates* (build failed on real duplicates; keys reported) |
  *cancelled* (the `staging` line was deleted; a decision-class plan entry). Two pictures, because one name for both confused readers: the **additive
  epoch** is `Expand → Expand → … → close-epoch`; a **transforming migration** is
  `Expand → Backfill → Contract (retire + drop) → Contracted`.
- **Predecessor retired** is written atomically with the floor advance and the
  final-generation records — one transaction. Retirement is irreversible by design and
  is the only irreversible step.
- **Contracting** (explicit, because it can be observed for minutes or, after a
  failure, indefinitely): `compat_floor` is set first, every admitted binary is on
  settled plans, and the listed drops and tightenings run as separate short
  transactions with `lock_timeout`. A failure — lock timeout, a `NOT NULL` that finds a
  row the final pass did not (impossible by construction, handled anyway), a lost
  connection — stops the command, leaves the database in a state **no admitted binary
  depends on** (settled plans reference none of the objects being removed), keeps
  readiness untouched, and is reported by `--schema status` as `contracting: k of n
  statements remaining`. The legal recovery is to run `contract V<n>` again: it
  resumes from the catalog, statement by statement, idempotently (`IF EXISTS`,
  constraint presence checked before `VALIDATE`). The `contracted` lifecycle row is
  written last. Nothing else — no manual DDL — is a supported recovery. **The next
  version's expand waits for `contracted`**: a later schema may legitimately reuse a
  physical column, index, trigger or function name that a pending drop still holds, and
  `IF NOT EXISTS` would then adopt the leftover as the new declaration, or a stale
  trigger could fire on the new schema's writes — so the executor treats *Contracting*
  like an admitted third version: the V<n+1> boot prints "contract V<n> incomplete: k
  statements remaining; run `app --schema contract V<n>`" and stays unready. Blocking
  costs nothing here (the remaining statements are seconds of work and the rerun is
  trivial); a dependency proof that would allow expanding over a partial contract was
  considered and rejected as complexity without a use case.

A version can also be **Quarantined** (a `Reject` at the final pass; the transition
aborts and the predecessor stays admitted) and **Refused** (a binary the gate will not
start). The everyday developer sees only *Expanded* and *Contracted*.

**A staged cross-entity change, worked briefly.** `Note.orgId` should be derived from
`Note.ownerId` through `User.orgId`. V8: add `orgId: Maybe OrgId` to `Note`
(`Additive`, nothing to write); ship a `worker` in the *application* that fills it with
an ordinary `update … set note.orgId = …` joined through `User`, using the whole
program — and that worker is **generated**, not hand-rolled: `tesl migrate generate
--backfill-worker Note.orgId` scaffolds a `worker` that uses the runtime's own backfill
engine as a library (keyset pagination, conditional updates, resumable progress in its
**own** `tesl_schema_backfill_jobs` row — never in `tesl_schema_entities`, whose one
cursor per entity belongs to the generation migration — adaptive throttling,
`--schema status` reporting, and a final pass after the old writers drain). What the
scaffold is honest about: it is a **fill**, not a maintained derived column. The
single-row invalidation trigger cannot see a change in *another* entity, so a
`User.orgId` that changes after a note was filled, a `Note.ownerId` reassignment, a
deleted `User`, or a `Note` inserted during the fill are the application's to handle —
the scaffold names them and offers two routes: **dual-write** in the handlers that
change either side (the compiler lists them), or a **durable dirty-key queue** the
worker drains (a `queue` of `Note` keys enqueued by those handlers). A derived column
maintained across entities forever is a different feature (denormalisation) and is
not what a migration provides; only the per-row expression — the join — is the
developer's. V9, once the worker reports done: `Migrate migrateNote [Retype orgId]` —
`Maybe OrgId` → `OrgId` is a type change under the same logical name, so it is
`Retype`, not `Revalidate` (which re-proves the same type) — with a row function that
unwraps `Something` and `Reject`s `Nothing` with the note's key (or defaults it,
deliberately); the new non-null storage column gets its `@column` name, dry-run lists
the remaining `Nothing` rows before deploy, and V9's contract drops the nullable storage
after V8 is retired. No row function ever joined anything.

### 14. Queues, caches and outboxes — the same problem, smaller

Entities are not the only typed data that outlives a deploy (maintainer's question,
2026-09-03). Verified against the Go runtime:

- **Queue jobs** (`tesl_jobs`): `payload jsonb`, `job_type` names the codec, any instance
  claims any row with `FOR UPDATE SKIP LOCKED`. A row whose payload cannot be decoded
  goes to the dead letter with `next_attempt_at = infinity` and is never retried. During
  a roll that is **silent loss of work in both directions**: a V8 worker claims a
  V7-shaped `EmailJob` it cannot decode; a V7 worker claims a V8-shaped job for a type it
  has never heard of. This is Lamdera's in-flight `Msg` problem exactly.
- **Cache** (`tesl_cache`, `UNLOGGED`): §19.4 already deletes an undecodable value and
  answers `Nothing`. Losing cache is acceptable by design; the only cost is that V7 and
  V8 delete each other's entries for the whole roll.
- **Runtime-owned tables** (`tesl_jobs`, `tesl_cache`, `tesl_email_outbox`,
  `tesl_pubsub_outbox`): the spec calls `tesl_jobs` "unversioned". Their shape can
  change between Tesl releases with no protocol at all — the control schema's own
  "table exists, column does not" problem, again.

The answers reuse the machinery above rather than adding new kinds:

1. **A `schema_version` column on every job and outbox row**, stamped by the writer.
   A worker claims rows with `schema_version` in `[min_version, its own]` — every
   **admitted** version, read from the same singleton the fence reads. An earlier
   revision said `[mine − 1, mine]`, which is wrong inside an **additive epoch**: V1–V10
   may all be admitted, a delayed V1 job is legal while a V10 worker runs, and no V1
   worker may be left to claim it. What makes the wider predicate sound is the epoch
   rule itself: **a change to an existing job type's shape is window-narrowing** (it
   closes the epoch, like a unique index over an old-written column), so inside one
   epoch every job type that exists in two versions has the *same* frozen shape, and a
   V10 worker decodes a V1 row directly — the `Same` closure proves the types equal.
   Only *adding* a job type is additive, and older versions never enqueue it. Across an
   epoch boundary at most two versions are admitted and the V<n> worker decodes V<n−1>
   rows through the `jobs:` migration it embeds. The row's `schema_version` names the
   frozen schema module in which its `job_type` is resolved, so renames, removals and
   shape changes are expressed in the migration record, never inferred from the name. A
   V7 worker never touches a V8 job. The companion item is **split in two**, because the
   claim predicate needs the first half: (i) the **prerequisite**, which ships with the
   predicate in the production-hardening phase — job record types declared in the
   schema module, frozen, hashed and diffed across versions like entities, covered by
   `Same`, and MIG028 as a compile **error** on any shape change to an existing job
   type ("in-flight jobs of this type would dead-letter across the roll; the migration
   surface for jobs is not available yet — add a new job type, or keep the shape");
   without that frozen history the compiler has no authoritative previous shape to
   compare against, so cross-version claiming **may not ship before it**; (ii) the
   **migration surface** — `jobs:`, `Migrate`, `Rename`, `IgnoreOld`, fixtures, the
   transforming retirement pass — which lands later. With (i) in place cross-version
   claiming never claims a row it cannot decode: the *only* undecodable rows are
   pre-feature rows and corrupt payloads, which remain typed, visible dead letters. Visible loss
   was the earlier interim and was rejected: it is still loss. There is no "no
   cross-version claim" interim either, because that orphans delayed jobs of any
   version whose workers have left. Making job record types **part of the versioned schema** —
   declared in a schema-kind module, checked by the same `Same`/closure rule, with a
   `jobs:` section of the migration record (`Migrate`, or an explicit `IgnoreOld` for
   in-flight old jobs, Lamdera's `MsgOldValueIgnored`) and a compile error when a
   changed job type has neither a decoder for the previous shape nor `IgnoreOld` — is a
   second, smaller migration surface that this document does **not** specify: it is
   its own dependent roadmap item, `roadmap/later/queue-payload-migrations.md`, with
   the hard requirement recorded there that this feature may not claim "all durable
   typed data is safe across a roll" until it lands. Until then the runtime pieces
   below hold: the admitted-window claim predicate, and an undecodable job is a
   *typed, visible* dead letter rather than a silent one.
2. **Retirement migrates the queue in place; it does not wait for it.** Jobs are
   rows. The final pass under V7's exclusive fence rewrites every `pending` (including
   delayed and retry-scheduled) row with `schema_version = 7` through the embedded
   `jobs:` migration and stamps it `8`; a job type marked `IgnoreOld` deletes those rows
   — data loss by decision, so `--schema dry-run` prints the count per job type, the
   contract plan header carries a decision-class entry, and the deletion is audited
   with the reason; a `Reject` quarantines the job like a row and blocks retirement.
   `processing` rows follow the one claimant rule of item 6 below — a retiring
   claimant's row is restamped once its lease lapses (at most one lease period of
   waiting), a surviving claimant's row is restamped in place at once and never waited
   for. Nothing waits for long retry schedules, delayed jobs or poison jobs —
   dead rows are migrated too, or deleted under `IgnoreOld`. Pub/sub outbox rows are
   transient: default `IgnoreOld` **with the same preview count and acknowledgement**;
   the email outbox stores the rendered message and has no payload shape to evolve.
3. **The dead letter stops being silent**: an undecodable payload goes dead with a
   typed reason the dead-letter handler receives, and `--schema status` counts them.
4. **Cache keys carry a short hash of the value type's semantic closure.** Old and new
   binaries never read each other's entries, so there is no cross-version decoding at
   all and no thrash; the cache is "lost" exactly for the value types that changed,
   and kept for everything else — the behaviour asked for.
5. **Runtime-owned tables join the control-schema format protocol** (§6's
   `tesl_schema_meta.format_version`): `tesl_jobs` and both outboxes get transactional,
   tested upgrades and are never truncated; `tesl_cache` may be truncated on a format
   change, since losing it is acceptable.
6. **Claims carry an attempt token — a prerequisite bug fix, not a migration
   feature.** Today (`runtime/go/teslrt/pgstores.go`) a `processing` job is reclaimed
   after the visibility timeout, and `complete`/`fail` are keyed by job id alone: attempt
   A stalls, B claims and runs, A resumes and deletes or re-schedules B's row. The fix
   is a monotone `claim_seq` per row, returned with the claim, stored with
   `claimed_by_version` and `lease_until`; **lease renewal** (every third of the lease,
   default lease 60 s) keeps a legitimately long handler's claim alive so it is not
   duplicated; renewal, completion, retry, dead-letter and cancellation are
   compare-and-set on `(id, claim_seq)`, and a stale attempt's result is dropped and
   logged. **Retirement and running handlers, exactly — by claimant, not by payload:**
   a `processing` row of the retiring version is either (a) claimed by a **retiring**
   worker (`claimed_by_version = 7`): advancing the floor makes its every renewal fail
   (the renewal is a fenced write), so it expires within **one lease period**, after
   which the pass restamps or migrates it and a V8 worker may claim it; or (b) claimed
   by a **surviving** worker (`claimed_by_version = 8`, which legally claimed a V7
   payload): it does **not** block retirement and may run past one lease — the
   retirement pass **restamps the processing row in place**, preserving `status`,
   `claim_seq`, `claimed_by_version` and `lease_until` and rewriting only
   `schema_version` (and the payload, re-encoded through the embedded `jobs:` migration
   when the boundary is transforming; untouched when `Same` holds). This is safe
   against the running claimant without extra rules: the restamp does not change
   `claim_seq`, so the claimant's completion (`delete … where id and claim_seq`) and
   failure/requeue (`update … where id and claim_seq`) commute with it, and the
   claimant already holds its decoded payload. Requeue after restamp stamps the
   claimant's version anyway. The one-lease bound therefore holds for what retirement
   *waits* for (retiring claimants); surviving claimants are not waited for. The
   postcondition after any retirement or epoch closure is the clean invariant, true
   **at the floor's commit**, not eventually: **no non-quarantined job row has
   `schema_version < min_version`**, whatever its status. A V7 handler still executing
   after its lease lapsed cannot touch queue state (`claim_seq`), and its
   *transactional* effects — `enqueue`, `email`, `publish`, entity writes — all go
   through fenced write transactions that fail admission, so they never land. What can
   land late is an **unfenced external effect**, `httpClient` from a job handler: the
   language does **not** guarantee idempotent effects, so the retirement guarantee is
   stated weaker for exactly that case — *a job whose V7 attempt outlived its lease may
   have its external HTTP effect performed twice, once by V7 and once by V8* — which is
   the same at-least-once duplicate the queue has today after a visibility timeout,
   neither introduced nor removed here. Deployments that cannot accept it have two
   routes the plan names: drain V7 workers before `contract` (`WhenDrained` does this
   for the worker role), or give the external system an idempotency key that is
   **stable across attempts and across versions** — `(job id, effect name, key)`, where
   the effect name is an **explicit annotation** on the call site, `@effect "charge"`,
   and `key` is an optional payload-derived expression (`@effect "notify" key:
   recipient.id`) for a site that fires more than once per job. Explicit because the
   handler may legitimately change between V7 and V8: a compiler-assigned id from
   source position or AST hash would change when the call moves, and V7's attempt A and
   V8's attempt B would again send different keys. Without `key:` a site that fires more
   than once per job is a compile error (MIG032: "effect fires in a loop; give it a
   key"), so there is no ordinal to define under filtering or reordering. A job-handler
   `httpClient` call **without** `@effect` is legal and is listed in the plan header as
   `AT-LEAST-ONCE (no effect id): <site>` — the runtime supplies no key and the
   duplicate is possible; the annotation is how the developer says they care. The
   runtime hands the external call a **canonical, domain-separated, fixed-length**
   key — `Idempotency-Key: tesl1-<base64url(sha256(preimage))>`, 49 characters, where
   `preimage` is `"tesl-effect-v1"` followed by each component as **`len(bytes)` as a
   4-byte big-endian length, then the bytes**: `job id` (UTF-8), `name` (UTF-8),
   `canonical(key)`. Length-prefixing, not a delimiter: a separator byte cannot make
   `(a‖0x1F‖b, c)` and `(a, b‖0x1F‖c)` collide only if it can never occur in a component,
   which nothing guaranteed (the previous form used `0x1F` and hashing does not remove the
   ambiguity). `canonical(key)` is a **frozen scalar encoding**, not JSON: `key:` must be
   a `String`, `Int`, `Bool` or a newtype over one (MIG032 otherwise) — no records, no
   floats, no ADTs, so there is no object-key order or numeric rendering to drift between
   versions — encoded as one type byte (`s`/`i`/`b`) then the UTF-8 text, the decimal
   integer, or `0`/`1`. The length is bounded whatever the key, and a `key: recipient.id`
   never leaves the process in clear (a raw `<job id>/<name>/<key>` would have put payload
   data on the wire); the handler receives the job id. An earlier draft said `(job id, claim_seq)`, which is
   precisely wrong: attempt A and attempt B have different `claim_seq` values and the
   external system would see two keys. `claim_seq` fences *queue state*; it never
   identifies an effect.

**What job identity protects — a decision.** `(schema_version, job_type)` fixes the
*payload type*, not the handler: a job enqueued under V7 is executed by whichever
admitted worker claims it, with **that worker's** handler. This is deliberate and is how
every rolling queue deployment already behaves — a bug fix in a handler *should* apply
to jobs enqueued before it shipped — so handler closures are not frozen and carry no
identity. The job type is the only versioned contract: a handler change that older
jobs must **not** receive is expressed by changing the type (a new job type, or
`IgnoreOld` on the old one), which the compiler then forces to be decided. The plan
header lists job types whose handler closure hash changed between the two versions as
information (`HANDLER CHANGED: EmailJob — old jobs run the new handler`), not as an
error.

Placement: the claim predicate (1), typed dead letters (3) and the format protocol (5)
are runtime-only and belong to the **production hardening** phase; the cache key hash
(4) is independent and cheap and goes with it; queue drain at retirement (2) goes with
validate-before-retire; the job-payload *language* surface is the dependent item.

## Worked example: `notes` from V7 to V9

Everything above, in code, for one small program. None of it compiles today; the
point is to see every moving part touch every other one. Where writing it exposed a
gap in the rules, the gap is marked **(gap)** and the rule above has been amended.

### Files, and which of them this feature version-controls

```
notes.tesl                             the application: imports, auth, handlers, api, server, main   ○ deployed
schema/notes/v7.tesl                   module NotesSchema.V7 — frozen snapshot                        ◆ versioned (frozen)
schema/notes/v8.tesl                   module NotesSchema.V8 — frozen snapshot                        ◆ versioned (frozen)
schema/notes/v-current.tesl            module NotesSchema.VCurrent — shown below as it reads at V9    ◆ live, edited in place
                                       (all three are shown in FROZEN form, as they read once V10 has frozen V9;
                                        while a version is current its module is `NotesSchema.VCurrent`)
migrations/notes/v8.tesl               migration V7 -> V8: generated skeleton, edited by a person     ◆ generated + edited
.tesl-stuff/migrate/notes/v8-compat.tesl   two-version test module, deterministic from frozen sources     ○ build artefact, not committed
.tesl-stuff/migrate/notes/v8-support.tesl  typed helpers for it (insertOldNote, readOldNote)               ○ build artefact, not committed
migrations/notes/v8.stdlib.tesl        frozen stdlib slice the migration closure reaches              ◆ generated (linked, never imported)
```

Nothing records what a version's *handlers* did: the frozen schema module is a sound
over-approximation of that (§1), so the compatibility check needs no other input.

File names follow the existing PascalCase-to-kebab-case rule (§10.2). Only the
`schema/…` modules are the source of truth for "what the data looks like"; the
`migrations/…` files bridge two of them. `notes.tesl` is never migrated. Everything
below is intended to be current Tesl except where a form is explicitly proposed by
this document (module references as record values, entity names as record fields, the
`Tesl.Migration` stdlib module, `todo`).

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
existing style (`TESL_BACKFILL_BATCH` 2000, `TESL_BACKFILL_CONCURRENCY` 4, `TESL_BACKFILL_PAUSE_MS` 50, `TESL_LEASE_TTL_S` 30,
`TESL_SCHEMA_LOCK_TIMEOUT_MS` 2000, `TESL_SCHEMA_POLL_S` 15). (The cookie auth is a
placeholder for the example, not a recommendation.)

### `schema/notes/v7.tesl`

```tesl
module NotesSchema.V7 exposing [Note, Session]              # frozen snapshot; was NotesSchema.VCurrent while current
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
module NotesSchema.V8 exposing [Note, Session, Tag, ValidWordCount, tryWordCount, checkWordCount, wordCountOf]   # frozen

import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.Time exposing [PosixMillis]
import Tesl.String exposing [String.split]
import Tesl.List exposing [List.length, List.filter]

fact ValidWordCount (n: Int)                    # named by a column proof → lives with the entity

establish tryWordCount(n: Int) -> Maybe (v: Int ::: ValidWordCount v) =   # THE minting boundary: one
  if n >= 0 then Something (n ::: ValidWordCount n) else Nothing              # predicate expression, used by
                                                                             # the migration directly
check checkWordCount(n: Int) -> n: Int ::: ValidWordCount n =               # handlers: same boundary, HTTP
  case tryWordCount n of                                                    # failure on the way out
    Nothing -> fail 400 "negative word count"
    Something valid ->
      let (v ::: p) = valid
      ok v ::: p

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
module NotesSchema.V9 exposing [Note, Session, Tag, ValidWordCount, tryWordCount, checkWordCount, wordCountOf]   # frozen (VCurrent at the time)
# Identical to V8 except one line in Note: the compiler derives the adapter (`Nothing`),
# no row function exists, Note's generation stays 4. This is the phase-1 kind of change.

import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Time exposing [PosixMillis]
import Tesl.String exposing [String.split]
import Tesl.List exposing [List.length, List.filter]

fact ValidWordCount (n: Int)

establish tryWordCount(n: Int) -> Maybe (v: Int ::: ValidWordCount v) =
  if n >= 0 then Something (n ::: ValidWordCount n) else Nothing

check checkWordCount(n: Int) -> n: Int ::: ValidWordCount n =
  case tryWordCount n of
    Nothing -> fail 400 "negative word count"
    Something valid ->
      let (v ::: p) = valid
      ok v ::: p

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

# updateContent: MUST change. wordCount is a stored derived column: the migration fills
# it for OLD rows, the application maintains it from then on. The compiler has no
# V8 -> V8 function and never recomputes a derived column when a source changes. (The
# first draft left this handler untouched and its SQL snapshot claimed the value was
# "recomputed in Go" — impossible; wordCount would have gone stale on every V8 edit while
# V7's edits stayed correct through the trigger.) `content` is also a SOURCE of the
# migration, so during the window the emitter turns the statement into a
# read-modify-write: materialise ownerId etc. for an unmigrated row first, then apply.
handler put updateContent(user: String ::: Authenticated user, noteId: String, body: NoteBody)
  -> Unit requires [dbRead, dbWrite] =
  let words = check checkWordCount (wordCountOf body.content)
  update note in Note
    where note.id == noteId
    set note.content = body.content
    set note.wordCount = words

# NOT allowed yet in V8 — wordCount is Go-computed, outside the SQL-expressible subset,
# so PostgreSQL would evaluate the predicate on NULL for unmigrated rows. MIG008 names
# this clause and offers `Maybe` or "use from V9" (or, if the `where` over-approximation
# of §6 invariant 3 is adopted, allows it at the cost of fetching every unmigrated note):
# handler get longNotes(...) = select note from Note where note.wordCount > 500
```

**V8 → V9.** `schema: NotesSchema.V9` and the import bump; nothing else *required*.
The same PR may add the generated **`migrations/notes/v8-contract.tesl`** (`tesl
migrate contract V8`): the reviewed request to retire V7 and drop exactly
`authorId`, `legacyRank`, the old index and the trigger. The schema worker honours it
once the V8 backfill is final and no V7 writer remains (the usual case after a completed
roll) and reports the rows otherwise; `v7.tesl` and `v8*.tesl` may be deleted in a later
cleanup PR once the database records the contraction. Now *permitted*, because V7 is
retired and V8's backfill is final:

```tesl
handler get longNotes(user: String ::: Authenticated user) -> List Note requires [dbRead] =
  select note from Note where note.ownerId == user && note.wordCount > 500
```

### What `tesl migrate generate notes.tesl` prints and writes (V7 → V8)

```
migration NotesSchema.V7 -> NotesSchema.V8                       ONLINE
  Note      gen 3 -> 4     MIGRATE WITH migrateNote   (2 holes)
            expand:   +ownerId NULL, +wordCount NULL,
                      legacyRank SET DEFAULT ‹legacy›, _tesl_v SET DEFAULT 3,
                      trigger tesl_mig_notes_g4 (sources: content, authorId)
            window:   dual-write authorId←ownerId; RMW: updateContent (1 statement, keyed by primary key);
                      SQL rewrite: listNotes.where ownerId (OR form; index [authorId] kept and used)
            derived:  wordCount ← content via migrateNote — FILLED for old rows only; maintained by the
                      application (handlers that update content: updateContent — sets wordCount: yes)
            backfill: est. 2.4M rows
            contract: -authorId, -legacyRank, wordCount SET NOT NULL, ownerId SET NOT NULL,
                      CHECK ValidWordCount, -index notes_authorId_idx, -index notes_tesl_v_g4_idx, -trigger   (at V9 boot)
  Session   gen 1         unchanged
  Tag       new           create table
  indexes   +notes_ownerId_createdAt_idx_v8 (plain, concurrently)
            +tags_noteId_idx_v8 (plain, concurrently)
            +notes_tesl_v_g4_idx (partial marker index on _tesl_v < 4, concurrently; dropped at contract)

froze  schema/notes/v7.tesl               (hash recorded in the migration header; edits are now MIG013)
wrote  migrations/notes/v8.tesl            (2 todo — the program will not compile until resolved)
built  .tesl-stuff/migrate/notes/v8-compat.tesl, v8-support.tesl   (deterministic; regenerated by every build, not committed)
wrote  migrations/notes/v8.stdlib.tesl     (frozen: String.split, List.length, List.filter — linked, not imported)
```

### The migration file as generated (`migrations/notes/v8.tesl`)

```tesl
# migration NotesSchema.V7 -> NotesSchema.V8  ONLINE   (header as above, kept in sync)
# frozen: NotesSchema.V7 = sha256:9c1e…   NotesSchema.V8 = sha256:41ab…
module NotesSchema.Migrate.V8 exposing [migration, migrateNote]

import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Migrated(..), Same(..)]
import Tesl.Maybe exposing [Maybe(..)]
import NotesSchema.V7                        # module imports; qualified names below
import NotesSchema.V8

migration = Migration {
  from: NotesSchema.V7
  to:   NotesSchema.V8
  same: []                                   # V7 declares no fact or type that V8 also declares
  entities: {                                # only what changed; Session is absent = verified Unchanged
    Note:    Migrate migrateNote [           # gen 3 -> 4
               Rename authorId ownerId,      # compiler-owned identity
               Legacy legacyRank (todo "V7 decodes legacyRank as Int NOT NULL; V8 rows need a value")
             ]
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
import Tesl.Maybe exposing [Maybe(..)]
import NotesSchema.V7
import NotesSchema.V8

migration = Migration {
  from: NotesSchema.V7
  to:   NotesSchema.V8
  same: []
  entities: {
    Note:    Migrate migrateNote [Rename authorId ownerId, Legacy legacyRank 0]
    Tag:     New
  }
}

# No helper copies here: NotesSchema.V8.tryWordCount and .wordCountOf ARE the
# declarations the handlers use (through checkWordCount). Their stdlib calls are linked
# to the frozen slice at the typed-IR level; nothing is imported from it. ValidWordCount
# is sealed: only the check/establish declared in NotesSchema.V8 can mint it.
fn migrateNote(old: NotesSchema.V7.Note) -> Migrated NotesSchema.V8.Note =
  case NotesSchema.V8.tryWordCount (NotesSchema.V8.wordCountOf old.content) of
    Nothing         -> Reject "note ${old.id}: negative word count"   # stops the backfill; 500 on the lazy path
    Something words ->
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

### The generated compatibility module (`.tesl-stuff/migrate/notes/v8-compat.tesl`, a build artefact)

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
  let notes = select note from Note where note.ownerId == "u2"   # the marker-aware rewrite finds the V7 row
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
  }                                         # Session, Tag absent = verified Unchanged
}
```

(`v9-compat.tesl` is generated too: it stores a V8-shaped `Note` and reads it back with
`archivedAt == Nothing`.) Had V9 instead **tightened** the check — `checkWordCount`
becoming `n > 0`, the fact renamed `PositiveWordCount` — the semantic closure differs,
no `Same` is written, and `Note` cannot be `Additive` or `Unchanged` (MIG016) even
though no column moved:

```tesl
  entities: {
    Note:    Migrate revalidateNote [Revalidate wordCount NotesSchema.V9.tryWordCount]   # gen 4 -> 5
    …
  }

fn revalidateNote(old: NotesSchema.V8.Note) -> Migrated NotesSchema.V9.Note =
  case NotesSchema.V9.tryWordCount old.wordCount of                    # the ONLY legal initialiser for a
    Nothing         -> Reject "note ${old.id}: word count must be positive"   # Revalidate'd column (MIG018 otherwise)
    Something words -> Row (NotesSchema.V9.Note { id: old.id, title: old.title, content: old.content,
                                                    ownerId: old.ownerId, wordCount: words,
                                                    archivedAt: Nothing, createdAt: old.createdAt })
# Same physical column, same value, new proof; a database CHECK at contract only because `n > 0`
# is SQL-expressible (otherwise runtime-only, and the plan says so); ROLL-WINDOW RISK
# while V8 can still write zero-word notes. --schema dry-run lists every such note before the
# deploy — and because this function can Reject, the plan header also says MAY BLOCK RETIREMENT.
```

That is the case the design would otherwise have missed: a stored invariant that
silently stopped being true because its check changed.

### What the V8 binary does at boot (SQL it runs, in order)

**How to read the SQL in this document.** Every block is one of three classes, and only
the first is executed by the test suite: **normative templates** (`-- [normative-template]`) — the control schema,
`tesl_admit`, the fence and admission statements, the trigger, retirement, contract and
index statements — written with **named bind parameters** (`:snapshot_hash`, `:v`) and
run by a harness that supplies them, and *generated* into this document from the same
fixture the integration tests use, so the text cannot drift from what runs;
**illustrative** fragments — a comment standing in for a final pass, a statement that
needs a separate connection, prose in a code fence — marked `-- [illustrative]`; and
**generated-SQL snapshots** — what the compiler emits for a request, compared against
the emitter's snapshot tests, marked `-- [generated-snapshot]`. A `-- HARNESS STEP` line
inside a normative template names a step the harness performs in Go between the
statements (a batched pass, a catalog check, a wait); the template is executable with
those steps supplied. The earlier "every block runs
verbatim" acceptance line was not satisfiable and is replaced below.

```sql
-- [normative-template] the control schema, created once at the first bootstrap (or by --schema adopt), never by a version.
-- The lease table does not exist yet, so the guard is a database-scoped advisory lock in Tesl's fixed bootstrap
-- namespace with key2 = 0 (reserved: no version is 0), taken BEFORE the first CREATE. This is the ONE fixed-namespace
-- lock: it only serialises bootstraps, so sharing it across schema families in one database is harmless. Every fence
-- below uses the database's own :fence_ns instead.
begin;
select pg_advisory_xact_lock(32341, 0);
create schema if not exists notes_app;            -- a genuinely empty database has no namespace yet (today's bootstrap
                                                  -- creates it too, postgres.go:228); the empty-database test must NOT
                                                  -- pre-create it in fixture setup
-- HARNESS STEP assert_schema_owner('notes_app'): pg_namespace.nspowner is the executor role (or a role it is a member
--   of); a namespace owned by someone else is drift, refused with the owner named
create table if not exists notes_app.tesl_schema_meta (        -- the CONTROL SCHEMA's own version — see below
  id smallint primary key check (id = 1), format_version int not null,
  database_uuid uuid not null unique,      -- the ONE stable identity of this logical database: minted at bootstrap or
                                           -- adopt, preserved across control-schema upgrades and physical restores,
                                           -- carried in every status report, activation plan, audit row and prune
                                           -- artefact. A clone promoted to an independent environment must run
                                           -- `app --schema reidentify` (new uuid, audited); prune rejects two target
                                           -- reports with one uuid and different deployment identities unless the
                                           -- inventory declares them replicas of one logical database.
  -- three protocol facts, deliberately separate:
  max_observed_protocol    int not null,   -- informational, monotonic: the highest protocol any binary reported;
                                           -- takes part in NO admission or retirement decision
  retirement_protocol_floor int not null,  -- the protocol proven safe to RETIRE against (advanced only by activation)
  fence_ns                 int not null,   -- key1 of every fence lock of THIS logical database: the low 31 bits of
                                           -- database_uuid, minted once at bootstrap and read by every binary before its
                                           -- first fence. Advisory locks are per PostgreSQL database, not per schema, so a
                                           -- fixed namespace would make two Tesl schema families (or two Tesl programs
                                           -- sharing one database) at the same version block and mis-refuse each other
  fence_domain             text not null); -- identifies the lock-key algorithm ('tesl-1' = pg_advisory_*(fence_ns, version),
                                           -- never hashtext); retirement requires every admitted
                                           -- version to share it — an integer ordering alone cannot say "compatible"
create table if not exists notes_app.tesl_schema_activation_plans (       -- what a pending ceremony is AUTHORISED to do
  nonce text primary key, database_id text not null, created_at timestamptz not null default now(),
  expires_at timestamptz not null, from_protocol int not null, to_protocol int not null,
  from_fence_domain text not null, to_fence_domain text not null,
  old_role_generation text not null, new_role_generation text not null,
  expected_grants jsonb not null,
  plan_hash text not null,                 -- binds database_uuid, cluster system identifier, database name, schema
                                           -- target, role generations, protocols, fence domains, expiry and grants,
                                           -- so a script generated for one database cannot be applied to another
  status text not null check (status in ('pending','consumed','expired','failed')),
  verified_at timestamptz, consumed_at timestamptz,
  failure_code text, failure_detail text); -- 'failed' is TERMINAL for a mismatch (a new plan is needed) and
                                           -- RETRYABLE only for 'old-backend-still-present'; the code says which
create table if not exists notes_app.tesl_schema_stages (      -- staged unique indexes (a multi-version obligation)
  stage_id text primary key,               -- stable semantic identity: entity + typed key columns + collation + null rule
  entity text not null, key_columns jsonb not null, declaration_hash text not null,
  created_version int not null, last_carried_version int not null,
  state text not null check (state in ('pending','promoting','enforced','blocked_duplicates','cancelled')),
  target_index text, duplicate_keys jsonb, last_error text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table if not exists notes_app.tesl_schema_queue_restamps ( -- queue restamp/migration progress for ONE retirement
  plan_hash text primary key, from_versions int[] not null, to_version int not null,  -- plan: the retirement-plan hash
  cursor text, rows_done bigint not null default 0,
  state text not null check (state in ('running','complete','failed')), last_error text,
  started_at timestamptz not null default now(), completed_at timestamptz);
create table if not exists notes_app.tesl_schema_backfill_jobs ( -- application-level fills (generated workers), NOT the
  job_id text primary key, entity text not null,                  -- migration engine's per-entity generation cursor
  from_version int not null, to_version int not null, worker_hash text not null,
  cursor jsonb, rows_done bigint not null default 0,
  state text not null check (state in ('running','paused','provisional','final','failed','cancelled')),
  throttle jsonb, last_error text, created_at timestamptz not null default now(), completed_at timestamptz);
create table if not exists notes_app.tesl_schema_protocol_activations (   -- append-only audit of the ceremony
  seq bigserial primary key, activated_at timestamptz not null default now(),
  from_protocol int not null, to_protocol int not null, fence_domain text not null,
  old_role_generation text not null, new_role_generation text not null,
  operator text not null, evidence_kind text not null check (evidence_kind in ('role-termination','platform-barrier')),
  evidence_ref text not null, nonce text not null unique);
create table if not exists notes_app.tesl_schema_state (       -- ONE row: the database's admission state
  id            smallint primary key check (id = 1),
  min_version   int not null,                                  -- oldest admitted schema version
  current       int not null,                                  -- highest expanded version
  compat_floor  int not null default 0);                       -- highest version whose predecessor's compatibility
                                                               -- objects are being/have been dropped: admitted
                                                               -- binaries at or below it run SETTLED plans for
                                                               -- that window; set BEFORE the first drop; monotonic
create table if not exists notes_app.tesl_schema_versions (    -- append-only lifecycle rows
  version int not null,
  step text not null check (step in ('expanded', 'retired', 'contracted', 'repair')),  -- the COMPLETE enum
  seq smallint not null default 0,                             -- repair amendments are numbered
  snapshot_hash text,                                          -- the schema module's hash (expanded rows only)
  artefact_hash text not null,                                 -- expanded: migration hash; contracted: contract hash;
                                                               -- repair: repair hash; retired: the RETIREMENT PLAN hash
                                                               -- (versions retired, entities/generations finalised, jobs
                                                               -- restamped, executor command) — additive versions have no
                                                               -- contract artefact, so this is what a retirement is accountable to
  applied_at timestamptz not null default now(),
  protocol_level int not null, fence_domain text not null,     -- of the binary that PERFORMED this step (for 'expanded' the
                                                               -- expander, whose values retirement compatibility is judged on;
                                                               -- for 'retired'/'contracted' the executor, for audit)
  executed_by text,                                            -- instance id of the executor (audit)
  primary key (version, step, seq));
create table if not exists notes_app.tesl_schema_entities (    -- per-entity generation + backfill state
  entity text primary key, generation smallint not null, target_generation smallint not null,
  last_pk jsonb,                                               -- the primary key as a JSON array of column values,
                                                               -- compared by the emitted typed keyset predicate, never as text
  rows_done bigint not null default 0, final_at timestamptz);
  -- ONE job per entity is an invariant, not a hope: an entity's generations advance strictly one at a
  -- time (invariant 2), the next version's expand cannot start a new row-function migration for an
  -- entity whose previous one is not final (boot gate row "two generations behind"), and contract
  -- touches no cursor. last_pk/rows_done here are the AGGREGATE of the shards below.
create table if not exists notes_app.tesl_schema_backfill_shards (   -- parallel work units of ONE entity's job
  entity text not null, shard smallint not null, target_generation smallint not null,
  lo_pk jsonb, hi_pk jsonb,                                   -- [lo, hi) primary-key range from pg_stats histogram bounds
  last_pk jsonb, rows_done bigint not null default 0,
  state text not null check (state in ('pending','running','provisional','final')),
  holder text, updated_at timestamptz not null default now(),
  primary key (entity, shard, target_generation));           -- the entity stays the unit of FINALITY; a shard is work
create table if not exists notes_app.tesl_schema_leases (
  name text primary key, holder text, expires_at timestamptz,
  holder_instance text);                                       -- every connection of that executor carries
                                                               -- application_name = 'tesl-exec:<holder_instance>'; the successor
                                                               -- reasons about the SET of such backends in pg_stat_activity:
                                                               -- none → dead, take over now; some + expired → terminate all,
                                                               -- wait until none, take over; some + live → wait
create table if not exists notes_app.tesl_schema_instances (   -- heartbeats: observability, never a guard
  instance text primary key, version int not null, protocol_level int not null, last_seen timestamptz not null,
  compat_floor_seen int not null default 0);   -- the plan mode this instance has switched to; contract's grace wait reads it
create table if not exists notes_app.tesl_schema_index (name text primary key, state text not null, attempts int not null default 0, error text);
create table if not exists notes_app.tesl_schema_quarantine (
  entity text, pk jsonb, target_generation smallint, attempt int,  -- V8's failures and V9's are different rows
  reason text, seen_at timestamptz, primary key (entity, pk, target_generation, attempt));
create or replace function notes_app.tesl_admit(v int) returns int language plpgsql stable as $$
declare m int; f int;
begin
  select min_version, compat_floor into m, f from notes_app.tesl_schema_state where id = 1;  -- the one lookup
  if m > v then raise exception 'tesl: schema version % is retired (min_version %)', v, m; end if;
  return f;      -- the ONE admission API: raises if retired, otherwise returns compat_floor, so every fenced
end $$;          -- write and every admitted read learns the plan mode without an extra statement

-- The lifecycle is a state machine, and the database enforces its edges (re-review, 2026-09-04: a recorder that
-- validated only 'expanded' would have accepted a 'contracted' without expansion, a repair gap, or a 'retired' written
-- outside tesl_advance_floor). Design: one PRIVATE core that owns the insert — it never leaves the transaction aborted
-- on a duplicate (a raw INSERT would: a unique violation aborts the whole transaction) and refuses a duplicate with a
-- different hash (immutable history) — and one PUBLIC function per transition that validates that transition's
-- preconditions and calls the core. The core's EXECUTE is revoked from everyone; the public functions are SECURITY
-- DEFINER and owned by `tesl_control`, a NOLOGIN role that owns the control schema's functions, so neither tesl_schema
-- nor tesl_app can write a lifecycle row except through a validated edge. 'retired' has no public function at all:
-- only tesl_advance_floor (also owned by tesl_control) reaches the core for it.
create or replace function notes_app.tesl_lifecycle_core__(
    v int, s text, q int, snap text, art text, proto int, dom text, who text) returns void
language plpgsql as $$
declare r notes_app.tesl_schema_versions%rowtype;
begin
  if q < 0 or q > 32767 then raise exception 'tesl: lifecycle seq % out of range', q; end if;   -- column is smallint
  insert into notes_app.tesl_schema_versions
      (version, step, seq, snapshot_hash, artefact_hash, protocol_level, fence_domain, executed_by)
    values (v, s, q::smallint, snap, art, proto, dom, who)
    on conflict (version, step, seq) do nothing;                       -- a duplicate is not an error yet …
  select * into r from notes_app.tesl_schema_versions where version = v and step = s and seq = q;
  if r.artefact_hash is distinct from art or r.snapshot_hash is distinct from snap
     or r.protocol_level <> proto or r.fence_domain <> dom then         -- … a duplicate with a DIFFERENT hash is
    raise exception 'tesl: immutable history: (%, %, %) is already recorded with a different hash', v, s, q;
  end if;                                                              -- equal hashes: idempotent retry, continue
end $$;
revoke execute on function notes_app.tesl_lifecycle_core__(int, text, int, text, text, int, text, text) from public;
alter function notes_app.tesl_lifecycle_core__(int, text, int, text, text, int, text, text) owner to tesl_control;

create or replace function notes_app.tesl_record_expanded(v int, snap text, art text, proto int, dom text, who text)
returns void language plpgsql security definer set search_path = notes_app as $$
declare c int;
begin
  select current into c from tesl_schema_state where id = 1 for update;
  if c <> 0 and c <> v - 1 and c <> v then
    raise exception 'tesl: cannot record V% expanded while current = % (deploy versions in order)', v, c;
  end if;
  if exists (select 1 from tesl_schema_versions where version = v and step = 'retired') then
    raise exception 'tesl: V% is already retired', v;
  end if;
  perform tesl_lifecycle_core__(v, 'expanded', 0, snap, art, proto, dom, who);
  update tesl_schema_state                                             -- row and singleton in ONE statement's transaction
     set current = v, min_version = case when min_version = 0 then v else min_version end
   where id = 1 and current < v;                                       -- idempotent on a retry that already moved it
end $$;
alter function notes_app.tesl_record_expanded(int, text, text, int, text, text) owner to tesl_control;

create or replace function notes_app.tesl_record_contracted(v int, art text, proto int, dom text, who text)
returns void language plpgsql security definer set search_path = notes_app as $$
begin
  if not exists (select 1 from tesl_schema_versions where version = v and step = 'expanded') then
    raise exception 'tesl: V% was never expanded', v; end if;
  if exists (select 1 from tesl_schema_versions where version = v - 1 and step = 'expanded')
     and not exists (select 1 from tesl_schema_versions where version = v - 1 and step = 'retired') then
    raise exception 'tesl: V% cannot be contracted before V% is retired', v, v - 1; end if;
  if (select compat_floor from tesl_schema_state where id = 1) < v then
    raise exception 'tesl: compat_floor must reach V% before its contract is recorded', v; end if;
  perform tesl_lifecycle_core__(v, 'contracted', 0, null, art, proto, dom, who);
end $$;
alter function notes_app.tesl_record_contracted(int, text, int, text, text) owner to tesl_control;

create or replace function notes_app.tesl_record_repair(v int, q int, art text, proto int, dom text, who text)
returns void language plpgsql security definer set search_path = notes_app as $$
declare last_seq int;
begin
  if not exists (select 1 from tesl_schema_versions where version = v and step = 'expanded') then
    raise exception 'tesl: V% was never expanded', v; end if;
  select coalesce(max(seq), 0) into last_seq from tesl_schema_versions where version = v and step = 'repair';
  if q <> last_seq + 1 and not exists (select 1 from tesl_schema_versions where version = v and step = 'repair' and seq = q) then
    raise exception 'tesl: repair % of V% would leave a gap (last recorded %)', q, v, last_seq; end if;
  perform tesl_lifecycle_core__(v, 'repair', q, null, art, proto, dom, who);
end $$;
alter function notes_app.tesl_record_repair(int, int, text, int, text, text) owner to tesl_control;
-- Every illegal edge is a negative acceptance test: contracted before expanded, contracted before the predecessor's
-- retirement, contracted before compat_floor, a repair gap, a repair of an unexpanded version, expanded out of order,
-- expanded after retired, and a direct call to the core or a direct INSERT as tesl_schema (privilege refusal).

-- tesl_advance_floor is the ONLY writer of min_version (the `tesl_advance_floor` transition of the prose). Every
-- caller — destructive contract, additive slot retirement, close-epoch, apply-offline, any future recovery — calls it;
-- no template and no generated code may `update … set min_version`. It verifies, inside the caller's transaction,
-- with server-side truth where one exists:
create or replace function notes_app.tesl_advance_floor(
    expected int, next int, plan_hash text, proto int, dom text, who text) returns void
language plpgsql as $$
declare m notes_app.tesl_schema_meta%rowtype; st notes_app.tesl_schema_state%rowtype; r record; v int; n int;
begin
  select * into m from notes_app.tesl_schema_meta where id = 1;
  if m.fence_domain <> dom then
    raise exception 'tesl: executor fence domain % differs from the database''s %', dom, m.fence_domain;
  end if;
  -- (0) the range itself, before any other work: strictly increasing, not beyond what is expanded, exactly one
  --     'expanded' row per version in it (contiguous, no gaps — a missing row must not be silently skipped and then
  --     given a synthetic 'retired' row), none of them already retired, and `expected` is the current floor
  select * into st from notes_app.tesl_schema_state where id = 1 for update;
  if next <= expected then raise exception 'tesl: floor range % -> % is not increasing', expected, next; end if;
  if next > st.current then raise exception 'tesl: cannot retire up to V% while only V% is expanded', next - 1, st.current; end if;
  if st.min_version <> expected then raise exception 'tesl: min_version is %, not %', st.min_version, expected; end if;
  select count(*) into n from notes_app.tesl_schema_versions
   where step = 'expanded' and version between expected and next - 1;
  if n <> next - expected then
    raise exception 'tesl: % of % versions in [%, %] have an expanded row; history is not contiguous', n, next - expected, expected, next - 1;
  end if;
  if exists (select 1 from notes_app.tesl_schema_versions where step = 'retired' and version between expected and next - 1) then
    raise exception 'tesl: a version in [%, %] is already retired', expected, next - 1;
  end if;
  -- (1) the retirement protocol is active for every version being retired, and each was expanded in THIS fence
  --     domain — a version expanded under another lock-key algorithm cannot be excluded by this one
  for r in select version, protocol_level, fence_domain from notes_app.tesl_schema_versions
            where step = 'expanded' and version between expected and next - 1 loop
    if r.protocol_level > m.retirement_protocol_floor or r.fence_domain <> dom then
      raise exception 'tesl: V% was expanded at protocol % in domain %; retirement is activated only up to protocol % in %',
        r.version, r.protocol_level, r.fence_domain, m.retirement_protocol_floor, m.fence_domain;
    end if;
  end loop;
  -- (2) this transaction holds every retired version's fence key EXCLUSIVELY — read from pg_locks, not asserted
  for v in expected .. next - 1 loop
    if not exists (select 1 from pg_locks
                    where locktype = 'advisory' and pid = pg_backend_pid() and granted
                      and classid = m.fence_ns and objid = v and objsubid = 2 and mode = 'ExclusiveLock') then
      raise exception 'tesl: fence key for V% is not held exclusively by this transaction', v;
    end if;
  end loop;
  -- (3) final-generation condition: no entity still owes rows to a migration (the harness sets generation =
  --     target_generation only after its own `count(*) where _tesl_v < g` postcondition held under the fence)
  select count(*) into n from notes_app.tesl_schema_entities where generation < target_generation;
  if n > 0 then raise exception 'tesl: % entities are not final; the final pass must complete first', n; end if;
  -- (4) queue postcondition: no non-quarantined job row below the new floor
  if exists (select 1 from notes_app.tesl_jobs where schema_version < next and status <> 'quarantined') then
    raise exception 'tesl: job rows below V% remain; restamp/migrate them first', next;
  end if;
  -- (5) compare-and-set on the expected floor
  update notes_app.tesl_schema_state set min_version = next where id = 1 and min_version = expected;
  if not found then raise exception 'tesl: min_version is not % (concurrent retirement?)', expected; end if;
  -- (6) one 'retired' lifecycle row per retired version, through the same recorder, same transaction
  for v in expected .. next - 1 loop
    perform notes_app.tesl_lifecycle_core__(v, 'retired', 0, null, plan_hash, proto, dom, who);   -- the ONLY path to 'retired'
  end loop;
end $$;
-- bootstrap seed, still inside the transaction that took the bootstrap lock and created the tables above:
insert into notes_app.tesl_schema_meta (id, format_version, database_uuid, max_observed_protocol, retirement_protocol_floor, fence_ns, fence_domain)
  select 1, :format_version, u, :protocol_level, :protocol_level,
         (('x' || substr(replace(u::text, '-', ''), 1, 8))::bit(32)::int & 2147483647),   -- fence_ns from the uuid
         :fence_domain
    from (select gen_random_uuid() as u) g
  on conflict (id) do nothing;                    -- the UUID is minted by the database, never by a client
insert into notes_app.tesl_schema_state (id, min_version, current, compat_floor) values (1, 0, 0, 0)
  on conflict do nothing;                         -- current = 0: NOTHING is expanded yet. min_version = 0: NO floor yet —
                                                  -- `tesl_admit` passes every version until the initial expansion below
                                                  -- sets both to :v in one statement. Seeding min_version = :v (the first
                                                  -- draft) would have let a V9 seeder refuse a V8 that then won the lease.
insert into notes_app.tesl_schema_leases (name) values ('boot'), ('backfill') on conflict do nothing;
commit;

-- initial expansion (fresh database): the ONLY transition out of current = 0, run under the session-level boot LOCK by
-- whichever version holds it (the seed is version-neutral, so the seeder and the expander may differ):
-- HARNESS STEP install_schema(:v): every `create table if not exists` / `create unique index if not exists` of the
--   application schema at V<v>, each its own short transaction, idempotent — a crash anywhere here is redone by the
--   next lock holder and creates nothing twice
select notes_app.tesl_record_expanded(:v, :snapshot_hash, :migration_hash, :protocol_level, :fence_domain, :holder);
--   one statement, one transaction: inserts the (v, 'expanded') row AND sets current = v AND min_version = v (from 0), so
--   the lifecycle row and the singleton are never observed disagreeing. Recovery is total: crash before it → the catalog
--   has tables, the state says nothing is expanded, the next holder redoes install_schema (no-op) and records; crash after
--   it → done; a second recorder gets the idempotent path inside the function (equal hashes) or the immutable-history
--   error (different hashes).
-- Two versions racing the first bootstrap: both seed identical state; the lease admits one to install_schema; the other
-- re-reads. If the loser is LOWER (a V8 lost to a V9): current = 9, min_version = 9 > 8 → it is refused with "database
-- initialised at V9 with no V8 history; deploy V9" — a deploy-order message, because a database born at V9 never
-- admitted V8 and has no V8 lifecycle row to roll back to. If the loser is HIGHER (a V9 lost to a V8): it finds the
-- ordinary `V<n-1> expanded, min_version = n-1` row and expands V9 after the lease. The end state therefore depends on
-- who wins; the acceptance test asserts each outcome, not "the same state" (the earlier criterion claimed that).
select database_uuid, format_version, fence_ns, fence_domain from notes_app.tesl_schema_meta where id = 1;   -- what everyone then uses;
                                                  -- :fence_ns below is this value, never a constant

-- The control schema has its own, separate migration protocol. `tesl_schema_meta.format_version`
-- names the shape of the tesl_schema_* tables; the runtime carries hand-written, tested upgrade
-- steps k → k+1 (`ALTER TABLE tesl_schema_versions ADD COLUMN seq …`, adding `_tesl_v` with the
-- current generation default to every entity table when online compatibility is first enabled in
-- phase 3, …), each one transaction, run by the worker under the boot lease before anything else;
-- a binary whose maximum format is below the database's refuses to start; `CREATE TABLE IF NOT
-- EXISTS` creates, it never upgrades — the same problem this whole feature exists to solve, and
-- the control schema is not exempt from it.

-- Protocol level. Fenced retirement is sound only if EVERY binary that may still be running takes
-- the fence. So the fence and admission ship in the very first phase, dormant (min_version never
-- advances until retirement exists), and every expanded version records the protocol level of the
-- binary that expanded it. A database that ever ran a PRE-fence binary (adopted from today's
-- runtime, or any future protocol bump) cannot retire anything until the operator has run the
-- **protocol activation ceremony**, which is a database-level, durable, audited transition — not
-- a flag on one contract — because no in-database mechanism can exclude a paused process that never
-- took a lock, and a password rotation does NOT disconnect already-authenticated sessions. It is
-- SPLIT, because the powers it needs (ALTER ROLE, pg_terminate_backend) must never belong to the
-- long-running schema worker:
--   1. `app --schema activate-protocol plan` (worker role) writes a `tesl_schema_activation_plans` row
--      — nonce, database identity, source and target protocol and fence domain, old and new role
--      generations, the exact expected grants, a plan hash, an expiry — and only then emits the
--      administrative statements and the nonce: create the NEW role generation (`tesl_app_g2`,
--      `tesl_schema_g2`) with the grants `--schema grants` prints; point the new deployment at it.
--      The row is what `verify` later checks against; a nonce with no pending row, an expired row,
--      or a row for another database identity is refused, and a consumed row can never be replayed.
--   2. A short-lived ADMINISTRATIVE job — a DBA, or a managed-service adapter (RDS/Cloud SQL expose
--      role administration through their own APIs; the adapter is explicit, not assumed) — runs:
--        alter role tesl_app_g1 nologin; alter role tesl_schema_g1 nologin;
--        select pg_terminate_backend(pid) from pg_stat_activity where usename in ('tesl_app_g1','tesl_schema_g1');
--      No new session can authenticate as the old generation, and every existing one is gone,
--      paused clients included — their next statement fails on a dead connection.
--   3. `app --schema activate-protocol verify <nonce>` (worker role, ordinary SELECT privileges)
--      locks the pending plan row and confirms against it: the old roles are NOLOGIN;
--      `pg_stat_activity` shows no old-generation backend; the new roles hold exactly the expected
--      grants; the database identity matches; the plan has not expired.
--   4. Only on success does it write `retirement_protocol_floor`, the audit row, and the plan row's
--      `consumed` status in one transaction; a failed check marks the plan `failed` and records why.
-- There is NO soft-evidence option. "The fleet is stopped" is accepted only as `evidence_kind =
-- 'platform-barrier'` with a reference the operator names, and only when the database has no other
-- route than the terminated roles; a heartbeat table or an empty pod list is not evidence, and an
-- earlier `--unsafe-assert-stopped` flag was removed for the same reason the offline path has no
-- `--force`: recording that an operation was unsafe helps forensics, not correctness. An operator
-- who bypasses this with hand-run SQL is outside the guarantee, not using a supported command.
--
-- ONE transition advances the floor: `tesl_advance_floor(expected, next, …)` above (the prose's
-- `advanceAdmissionFloor`). No template, generated statement or operator command writes `min_version`
-- any other way, and no caller implements a subset of its checks.

-- step 1: the boot LOCK — session-level, on the DDL connection, held until step 8; this is the mutual exclusion.
select pg_advisory_lock(:fence_ns, 2147483647);          -- key2 = 2^31-1 is reserved for the boot lock, as 0 is for bootstrap
-- the lease row is a handoff/observability record only (renewable by its holder; never consulted for safety):
update notes_app.tesl_schema_leases set holder = :holder, expires_at = now() + interval '30 s'
  where name = 'boot' and (holder is null or holder = :holder or expires_at < now());

-- step 3: state
select min_version, current from notes_app.tesl_schema_state where id = 1;
select version, step, seq, snapshot_hash, artefact_hash, protocol_level, fence_domain
  from notes_app.tesl_schema_versions order by version, step, seq;   -- protocol + domain: what retirement compatibility is judged on

-- step 5: retire V6 (only if min_version = 6), validating first
begin;
select pg_advisory_xact_lock(:fence_ns, 6);   -- two-int32 form: key1 = this database's fence_ns (fence_domain 'tesl-1'),
                                              -- key2 = the version; no hashing, no cross-family collision; waits for fenced V6 transactions
-- HARNESS STEP final_pass('Note', 3): V7's final pass, in batches on other connections; any Reject → rollback + quarantine + refuse
-- HARNESS STEP assert_final: `count(*) where _tesl_v < 3` is 0, then `update tesl_schema_entities set generation = target_generation`
select notes_app.tesl_advance_floor(6, 7, :retirement_plan_hash, :protocol_level, :fence_domain, :holder);   -- every check, the CAS, the 'retired' rows
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
create or replace trigger tesl_mig_notes_g4 before update on notes_app.notes   -- ONE statement (PostgreSQL 14+,
  for each row execute function notes_app.tesl_mig_notes_g4();                  -- our floor): no committed instant
-- without a trigger. A drop+create pair in separate transactions would leave a window in which a V7 update
-- silently keeps a stale derived value — idempotence must never introduce an intermediate state that violates
-- the data invariant. The function is CREATE OR REPLACE for the same reason; the trigger is installed before
-- V8 becomes ready and before the backfill's first batch, so no gen-4 row ever exists unprotected.

select notes_app.tesl_record_expanded(8, :snapshot_hash, :migration_hash, :protocol_level, :fence_domain, :holder);
  -- one statement: the (8, 'expanded') row and `current = 8` together; a second expander takes the idempotent path
  -- (equal hashes) or is refused (different hashes) without ever aborting on a duplicate key
-- Authoritative state after a crash: the catalog plus tesl_schema_versions. DDL is idempotent
-- (`IF NOT EXISTS`, re-checked against the catalog), so "DDL done, no lifecycle row" simply
-- redoes nothing and writes the row; "row without DDL" cannot occur because the row is written
-- last; the singleton's `current` is derived from the highest 'expanded' row and repaired on boot
-- if it disagrees; a partially applied contract resumes statement by statement from the catalog;
-- a repair hash recorded with batches incomplete resumes like any final pass.

-- step 9b: the dedicated DDL connection
select pg_advisory_lock_shared(:fence_ns, 8);   -- session-level, lives with the connection
select min_version, compat_floor from notes_app.tesl_schema_state where id = 1;   -- separate statement

-- step 10: index builds, from the DDL connection, one builder per index (lease)
create index concurrently if not exists notes_ownerId_createdAt_idx_v8
  on notes_app.notes ("ownerId", "createdAt");
create index concurrently if not exists tags_noteId_idx_v8 on notes_app.tags ("noteId");
create index concurrently if not exists notes_tesl_v_g4_idx on notes_app.notes ("id") where "_tesl_v" < 4;
  -- partial marker index: backfill, final pass and the retirement postcondition touch only unmigrated rows;
  -- shrinks as the backfill proceeds; dropped at contract
```

Readiness: steps 1–9b done, no new **unique** index in this plan, no V7-introduced
column used inside SQL → **ready in milliseconds**. The two plain indexes build in the
background.

### What V8 request code runs during the window

```sql
-- [generated-snapshot] compiler output for the window plan; compared against emitter snapshots, not executed by the harness
-- listNotes: a READ. No fence lock. The query runs FIRST (its ACCESS SHARE lock is then
-- held to commit, so no contract DDL can interpose), admission on the PROGRAM VERSION (8)
-- runs AFTER it with a newer-or-equal snapshot, and the runtime releases rows to the
-- handler only once COMMIT has succeeded. One pipelined round trip.
-- `where note.ownerId == user` is rewritten because ownerId is a `Rename` of authorId:
begin;
select n."_tesl_v", n."id", n."title", n."content", n."authorId", n."ownerId",
       n."wordCount", n."createdAt"
  from notes_app.notes n
 where ((n."_tesl_v" >= 4 and n."ownerId" = $1) or (n."_tesl_v" < 4 and n."authorId" = $1))
 order by n."createdAt" desc;
select notes_app.tesl_admit(8);          -- raises if min_version > 8 → transaction aborts, rows discarded
commit;
-- Go decoder: if _tesl_v < 4 → migrateNote(V7 view of the row) → Note; else decode directly.

-- createNote: a WRITE. Two-statement fence, then the insert with the dual write and the stamp.
begin;
select pg_advisory_xact_lock_shared(:fence_ns, 8);
select notes_app.tesl_admit(8);                                   -- RAISES if retired: the pipeline aborts here
insert into notes_app.notes ("id","title","content","ownerId","authorId","wordCount",
                             "createdAt","legacyRank","_tesl_v")
  values ($1,$2,$3,$4,$4,$5,$6, default, 4);
commit;

-- updateContent: touches a SOURCE column (content) and a DERIVED one (wordCount) → read-modify-write, identified
-- at compile time. The handler supplies wordCount; the RMW supplies the rest of the closure (ownerId, authorId).
begin;
select pg_advisory_xact_lock_shared(:fence_ns, 8);
select notes_app.tesl_admit(8);                                   -- raises if retired
select set_config('tesl.writer.notes', '4', true);               -- "I materialise gen 4"
select … from notes_app.notes where "id" = $1 for update;         -- read (lazy-migrate in Go if _tesl_v < 4)
update notes_app.notes
   set "content" = $2, "wordCount" = $3 /* the handler's checked value */, "ownerId" = $4, "authorId" = $4,
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
-- [generated-snapshot] the runtime's backfill statement for this migration
-- one batch; rows selected by keyset, exactly one generation behind
select xmin, "id","content","authorId" from notes_app.notes
 where "_tesl_v" = 3 and "id" > $last order by "id" limit 2000;   -- served by the partial marker index
-- Go: migrateNote per row (a failing check → stop, report id + reason)
update notes_app.notes n
   set "ownerId" = v.owner, "wordCount" = v.words, "_tesl_v" = 4
  from (values ($1,$2,$3,$4::xid), …) as v(id, owner, words, xmin_read)
 where n."id" = v.id
   and n."_tesl_v" = 3
   and n.xmin = v.xmin_read;                                  -- conditional on the tuple version read (invariant 2)
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
-- [normative-template] `contract V8` as the harness runs it; :binds supplied by the executor.
-- step 5: retire V7 = tesl_advance_floor(7 -> 8), the ONLY path that moves min_version (also used by
-- close-epoch and apply-offline). One transaction; the final pass is a harness step, not a comment:
begin;                                                        -- the COORDINATOR transaction: holds the fence throughout
select pg_advisory_xact_lock(:fence_ns, 7);                   -- no V7 write can now start; in-flight ones drain
-- HARNESS STEP final_pass('Note', 4): bounded transactions on OTHER connections, each `update … where _tesl_v = 3`
-- through the frozen migrateNote (V7 writers are fenced out, V8 writers write gen 4, so the set only shrinks);
-- a Reject → quarantine row, ROLLBACK of this coordinator, command refused
select count(*) from notes_app.notes where "_tesl_v" < 4;    -- postcondition: the harness asserts 0, else ROLLBACK
-- HARNESS STEP jobs_retire(from = [7], to = 8): bounded transactions on other connections, progress in
-- tesl_schema_queue_restamps(:retirement_plan_hash); pending/dead/processing V7 rows restamped in place (payload
-- re-encoded through the embedded V7→V8 jobs: migration; untouched when Same); retiring claimants' renewals already
-- fail under this fence, so their rows expire within one lease and are restamped in a later batch
select count(*) from notes_app.tesl_jobs where schema_version < 8 and status <> 'quarantined';  -- harness asserts 0
update notes_app.tesl_schema_entities set generation = 4 where entity = 'Note' and target_generation = 4;
select notes_app.tesl_advance_floor(7, 8, :retirement_plan_hash, :protocol_level, :fence_domain, :holder);
  -- protocol coverage, fence domain, exclusive key held (pg_locks), entities final, no job below 8, CAS 7 → 8, and the
  -- (7, 'retired') row via the private lifecycle core — all or nothing, and never a raw `update … min_version`
commit;

-- step 6a: announce the plan switch BEFORE any drop (V8 binaries are still admitted and dual-writing)
update notes_app.tesl_schema_state set compat_floor = 8 where id = 1 and compat_floor < 8;
-- HARNESS STEP wait_plan_switch(8): until every row of tesl_schema_instances with version <= 8 reports
-- compat_floor_seen >= 8, or 2 poll intervals (30 s) have passed — a grace, not a guard; the retry table is the guard

-- step 6b: contract V8's migration of Note, one short transaction per statement, lock_timeout = 2s;
-- every statement is idempotent or catalog-checked, so a rerun after a crash resumes here:
-- HARNESS STEP ensure_check_constraint('notes', 'notes_wordcount_nn', '("wordCount" IS NOT NULL)'): pg_constraint
--   has no IF NOT EXISTS, so the ADD lives INSIDE this step, which reads pg_constraint and then does exactly one of:
--   absent → `alter table notes_app.notes add constraint notes_wordcount_nn check ("wordCount" is not null) not valid`;
--   present and SEMANTICALLY equal (the canonical comparator of the acceptance criteria: both expressions deparsed by
--   THIS server with an empty search_path and compared as deparsed text; convalidated either way) → nothing;
--   present with a different definition → drift, refuse with the object named
-- HARNESS STEP validate_if_needed('notes_wordcount_nn'): `alter table … validate constraint` unless convalidated
--   (SHARE UPDATE EXCLUSIVE); a crash after the ADD and before validation resumes here
alter table notes_app.notes alter column "wordCount" set not null;           -- cheap: the constraint proves it; idempotent
alter table notes_app.notes drop constraint if exists notes_wordcount_nn;
-- same for ownerId; the proof's CHECK where expressible: check ("wordCount" >= 0) not valid → validate
drop trigger if exists tesl_mig_notes_g4 on notes_app.notes;
drop function if exists notes_app.tesl_mig_notes_g4();
alter table notes_app.notes drop column if exists "authorId";
alter table notes_app.notes drop column if exists "legacyRank";
drop index concurrently if exists notes_app.notes_authorId_idx;              -- DDL connection, outside a transaction
drop index concurrently if exists notes_app.notes_tesl_v_g4_idx;             -- the partial marker index; every row is at gen 4
select notes_app.tesl_record_contracted(8, :contract_hash, :protocol_level, :fence_domain, :holder);

-- step 7: expand V8 -> V9 (a later boot; waits for the row above) — the `Additive` entry is one metadata-only statement
alter table notes_app.notes add column if not exists "archivedAt" bigint;          -- Maybe → NULL
select notes_app.tesl_record_expanded(9, :snapshot_hash, :migration_hash, :protocol_level, :fence_domain, :holder);
  -- row + `current = 9` in one statement
```

V9's readiness waits for `Note`'s final pass because `longNotes` uses `wordCount`
inside SQL. A V8 binary that boots afterwards is admitted (`min_version = 8`) and
tolerates the extra nullable column; a V7 binary is refused at its first fence
statement or `tesl_admit(7)`.

### Where the example changed the design

Writing this example as a golden fixture and having it reviewed changed the design in
fourteen places (facts in schema modules, the `New` entry, SQL-expressible rewrites,
the Memory store's generation model, the contract artefact, `Retype`, …). Each is now
simply part of the rules above; the list of what changed and why is in
[`database-migrations-history.md`](database-migrations-history.md).

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

**Where the user learns about it: at compile time, from `tesl migrate generate`.** Not at
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

  online alternative (existing mechanisms only — no cross-entity migration rule exists):
    Introduce a new entity with the new key and migrate over two versions:
      V8: declare `entity UserV2 … primaryKey userId` (`UserV2: New`); dual-write it from
          the handlers that write `User` (the compiler lists them: 4 sites); fill existing
          rows with a generated application worker (`--backfill-worker UserV2`, its own
          `tesl_schema_backfill_jobs` row, final pass after the roll); reads stay on `User`.
      V9: switch reads to `UserV2`; `User: Drop`.
    `tesl migrate generate --suggest-online` writes the V8/V9 schema edits, the
    migration records and the worker scaffold; the dual writes are yours.

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

- `--schema apply-offline` runs the same **connection barrier** as catch-up (§8b) —
  `Trusted` readers take no fence, so the fences alone do not prove the fleet is gone —
  then takes the fence key of **every admitted version** (`min_version` through current)
  exclusively, and sets `min_version` to the new version while holding them — through the same `tesl_advance_floor` transition
  every other path uses, so it is subject to the same protocol check: a database that
  ran a pre-fence binary must have completed the activation ceremony first, or the
  offline apply refuses, because a pre-fence zombie takes none of the keys it is
  waiting for. An in-flight V7 transaction blocks it rather than slipping past it, and a
  V7 transaction that starts afterwards is refused by its own fence statement. Holding every key proves
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
- It records `(8, 'expanded'), (7, 'retired'), (8, 'contracted')` at once, so V8
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

The editor operation behind `tesl migrate generate` was one sentence in earlier revisions; it is
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
| MIG001 | compiler (`--check`, LSP) | the `database` names a schema module newer than the last migration's `to:` and no migration file bridges them | the `database` declaration | the two schema modules | mechanical (not fix-all): run `tesl migrate generate` (editor: *Tesl: Change Schema*) |
| MIG002 | compiler | migration entry missing / extra / `Unchanged` on a changed entity | the `migration` block or the entry | old + new entity decls | mechanical **only** for a generator-owned, unedited entry (add/remove it); **decision** when the entry was hand-edited — never deleted automatically |
| MIG003 | compiler | unresolved `todo` | the `todo` | the new field/proof that caused it, the `V7.User` fields available | decision (see below) |
| MIG004 | compiler / generator | ambiguous rename (removed + added same type) | the new field | the removed field | suggested: `Rename a b`; alternative: separate add/drop |
| MIG005 | compiler | removed field V7 still decodes, no `Legacy` | the removed field in the snapshot | the V7 declaration (V7 decodes every column it declares) | decision: `Legacy c v` / `LegacyWith f g` |
| MIG006 | compiler | a column V8 computes into a new column while V7 still decodes the old one, and no `WriteBack old new g` | the `Migrate` entry | the V7 declaration of the old column | decision: add `WriteBack old new g` or acknowledge `ROLL-WINDOW RISK` |
| MIG007 | compiler / generator | primary-key change / `Reset` (OFFLINE) | the entity | the plan header | decision: `Offline "…"`; suggested: `--suggest-online` |
| MIG008 | compiler | V8-introduced non-`Maybe` column whose row function is **not SQL-expressible** used inside SQL in V8 (renames and constant defaults are rewritten instead) | the query clause | the column decl | suggested: **Prepare the unlock** — an action that generates the minimal next schema root and migration record (all verified-unchanged) so the query is legal there, and prints when that version may deploy and when this one may contract; `Maybe` is offered only with the caveat that nullability is a domain claim, not a deployment shortcut |
| MIG009 | compiler | row function writes an existing (V7-written) column | the field init in the row fn | the V7 declaration (any V7 insert writes it) | **suggested**: new column + `Rename` *or* `Drop` — creating the column skeleton is mechanical, choosing rename versus drop is semantic |
| MIG010 | compiler | row function reaches a live-program function | the call | the callee | mechanical: copy the closure into the migration file |
| MIG011 | compiler | new unique index over V7-written columns | the `unique index` | the V7 declaration of the indexed columns | decision: acknowledge `ROLL-WINDOW RISK` |
| MIG012 | compiler | a required migration, repair or contract file (`V<n-1>`/`V<n>` and their amendments) or a stdlib slice is missing — the previous version's files may be absent only when `prune` removed them with evidence (a contract executed, or an additive version two versions past, in every environment) | the `database` decl | — | mechanical but **not fix-all eligible**: the message names the file to restore; the editor offers a command, never a silent VCS operation |
| MIG013 | compiler (hash recorded in the next migration's header) **and** the boot gate (hash the database recorded) | a frozen schema module or migration file was edited after a later version was written | the edited declaration | the migration header that froze it | decision: revert the edit |
| MIG016 | compiler / generator | a fact or type a column names changed between the two modules (no `Same` entry) and the entity is `Unchanged` or `Additive` | the entry | the two declarations, the changed check body | decision: accept the generated `Migrate` re-validation skeleton, or restore the declaration |
| MIG018 | compiler | a pass-through column is not initialised by the exact projection `f: old.f` | the field initialiser | the two declarations of `f` | suggested: restore the projection; a real change is a new column |
| MIG020 | compiler | `from:`/`to:` are not consecutive schema modules of the same family | the field | the two module headers | mechanical: fix the reference |
| MIG021 | compiler | a `Migrate` row function's type is not `From.E -> Migrated To.E` for its entity | the function reference | the two entity declarations | suggested: fix the signature |
| MIG022 | compiler | a rule names a column of the wrong version/side, or a value/function of the wrong type | the rule | the column declarations | suggested: fix the rule (the message states the expected type) |
| MIG023 | compiler | two rules govern the same column | the second rule | the first | suggested: remove one |
| MIG024 | compiler | `Same` pairs declarations of different kinds, from the wrong modules, or whose semantic closures differ (the message names the first differing check/helper/codec) | the `Same` | the two declarations and the differing node | mechanical: regenerate (which removes the `Same` and forces MIG016's re-validation path) |
| MIG026 | compiler | repair chain malformed: a sequence gap or duplicate (`V8Repair1`, `V8Repair3`), a repair whose `of:` does not name a committed migration, or a repair of a migration whose files were pruned | the repair module header | the chain | mechanical: renumber / none |
| MIG027 | compiler | a hand edit of a generator-owned `@column` storage annotation, or `Retype` on a column whose type did not change | the annotation / the rule | the two declarations | mechanical: regenerate |
| MIG029 | — | **retired 2026-09-04**: shared-module *revision* mismatch; the `VCurrent` layout has no revisions. The number is not reused | — | — | — |
| MIG030 | compiler (family) | staged-uniqueness obligations: a staged key's columns, collation, null semantics or deferrability changed without cancelling the stage; a staged field renamed or its entity dropped without cancelling; a conflicting `unique index` declared while the stage is pending; a stage carried beyond `TESL_STAGE_MAX_VERSIONS` without promotion or cancellation; a staged key written in the promoting version without the per-key guard (emitter invariant); source pruned while a stage is outstanding | the `staging unique index` line | the previous revision's line, the control state | decision: promote, cancel, or extend |
| MIG028 | compiler | the shape of an existing job record type changed between two schema versions while the `jobs:` migration surface is unavailable (in-flight jobs would dead-letter across the roll) | the job type declaration | the previous revision's declaration | decision: add a new job type, or keep the shape |
| MIG032 | compiler | an `@effect "name"` call site that can fire more than once per job (in a loop or a fold) carries no `key:` | the call site | the enclosing loop | suggested: add `key: <payload expr>` |
| MIG025 | compiler | a non-compat module imports a generated `…Support` module (`insertOld<E>`) | the import | the support module header | none: these helpers exist only for compatibility tests |
| MIG019 | compiler | a `check`/`auth`/`establish` outside the declaring schema module mints a sealed (column) fact | the `ok … ::: F` | the fact's declaration | suggested: move the check into the schema module, or consume an existing check |
| MIG017 | compiler | a renamed column is not initialised by the exact projection of its old name (`b: old.a`) | the field initialiser | the `Rename` rule | **suggested**: restore the projection, or replace `Rename` with a new column + row function — removing a transform changes meaning, so never silent |
| MIG015 | compiler | the program imports a type from a schema module other than the one its `database` names (stale import after a version bump) | the `import` line | the `database` declaration | mechanical, fix-all eligible: rewrite the import to the current module |
| MIG014 | compiler (the runtime's primitive registry is known at compile time) | primitive tag referenced by an embedded migration not provided by this runtime | the migration file | the primitive | none: finalise and prune on the current runtime first |
| MIG031 | compiler | an `update`/`upsert` rewritten to read-modify-write for the window whose `where` is not a primary-key equality (its window cost is proportional to the matched rows) | the statement | the migration entry whose closure it touches | suggested: key by primary key, or acknowledge the O(rows) window cost |

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
   `tesl migrate generate` that writes files — a preview would no longer be a preview, cancellation
   could leave partial changes, and `WorkspaceEdit` document versions would mean
   nothing. So the compiler gains `tesl migrate generate --manifest-json`: it takes the
   open-document overlays, performs **no writes**, and returns an edit manifest — the
   files to create and the edits to apply (`migrations/notes/v<n>.tesl`,
   `v<n>.stdlib.tesl`; the compat/support modules are build artefacts and never part of
   the edit), each with the
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
   The plain `tesl migrate generate` CLI is manifest-then-apply over the same code, with the
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

### Completion and hover for the contextual forms

`Migration { … }`, `Repair { … }` and `Contract { … }` look like ordinary records and are
typed by elaboration, so the editor must give **positive** guidance, not only errors:
completion of the valid entity entries at the cursor (and why each is `Additive`,
`Derived` or needs `Migrate`), the valid old/new columns for `Rename`/`Retype`, the
expected type for `Default`/`Legacy`, the exact row-function signature for `Migrate`
(insertable as a stub), and the valid drops and tightenings for a `Contract`; hover on
an entry explains the classification in the plan header's words. Without this the
syntax looks familiar while behaving unlike a normal value, which reads as arbitrary.

### VSCodium extension

`editor/vscode-tesl/package.json` contributes no migration command today. Add:
*Tesl: Change Schema* — creates the next revision (or freezes the previous one), bumps `database` where the layout needs it, then
generates/refreshes the migration (with progress and cancellation, a preview of the
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

## Current mechanisms (authoritative summary)

This table is the requirements summary an implementer should read first. It was
rewritten in full on 2026-09-03 after a review found the previous one stale. The
review-by-review history of how each row came to be — including the mechanisms that
were tried and withdrawn — lives in
[`database-migrations-history.md`](database-migrations-history.md) and is not
normative.

| Concern | Mechanism now |
|---|---|
| versioning unit | the ordinary module `NotesSchema.VCurrent`, hand-owned and edited in place (large schemas: a root importing one plain module per entity); the generator **copies** it to `NotesSchema.V<n>` before each change, so imports never move and the diff shows only the change; `database { schema: <module ref>, migrations: <module prefix> }`; the version is derived from the frozen snapshots; frozen snapshots immutable by hash (MIG013) |
| two numbers, kept distinct | database schema version `V<n>`; row generation `gen` per entity (internal, status/diagnostics only) |
| migration record | one `Migration { from, to, same, fixtures, entities }` naming **only changed entities** (the schema-level `staging unique index` declaration is not a `Rule`; it is diffed like any declaration) (absence = verified `Unchanged`); `Entity` = `Additive`/`Derived`/`Migrate`/`New`/`Drop`/`Reset`; `Rule` = `Rename`/`Retype`/`Default`/`Legacy`/`LegacyWith`/`WriteBack`/`Revalidate`/`Offline`; a compiler-known folded declaration typed by elaboration (MIG020–MIG024, MIG027) |
| row function | ordinary `fn (Old.E) -> Migrated New.E` (`Row`/`Reject`); proofs via the schema module's `establish` in its `Maybe (v: T ::: P v)` form — an existing construct, no new intrinsic; the `Reject` string carries the reason; pass-through and renamed columns are exact projections (MIG018/MIG017); `Retype` and new columns are free expressions; `Revalidate` re-establishes a proof in place; written in the **Migration Core** subset under a versioned execution **ABI** |
| identity across versions | `Same` list generated from equality of semantic closures and **verified** (MIG024); a changed closure forces `Revalidate`/`Migrate` (MIG016); column facts **sealed** to their schema module (MIG019) |
| compatibility-check input | the frozen previous schema module only (complete-record inserts + whole-row selects make it a sound over-approximation) |
| artefacts | committed: `v-current.tesl` (and its entity modules), frozen `v<n>.tesl` snapshots, migration `v<n>.tesl`, `v<n>-repair-<k>.tesl`, `v<n>-contract.tesl`, `v<n>.stdlib.tesl`; build artefacts (not committed): `…Compat`/`…Support` modules; reports: plan header, previews, status |
| admission | two dimensions never mixed: **program version** for admission, **generation** for rows. `tesl_schema_state.min_version`. **Writes and deletes**: `pg_advisory_xact_lock_shared(fence(v))` then a separate **raising** `select tesl_admit(v)` — a pipeline barrier, unconditional in every mode. **Reads**: `Trusted` by default in v1 (no admission; the poll exits retired processes); `Strict` opt-in — the query first, then `tesl_admit(v)` in the same transaction, rows released after `COMMIT`; becomes the default with row-level policies |
| contract (retirement inside it) | authorised by the committed `v<n>-contract.tesl` (exact drops/tightenings; none generated for additive-only versions, which finish automatically); executed per `contract: Explicit` (default, `app --schema contract V<n>`) / `WhenDrained` / `NextVersion`; execution = final pass under the old version's exclusive fence with every row accepted, re-check, atomic `min_version` + per-entity final state + lifecycle row, then exactly the listed operations; a `Reject` aborts, quarantines (re-running the function first), and reports — repair via the admitted versions, an ordered `Repair` amendment, or acknowledged deletion |
| "not yet migrated" | permanent per-row `_tesl_v smallint` holding the **entity generation**; atomic per entity; only inserts, backfill and read-modify-write stamp it; the trigger only lowers it |
| V7 writes during the window | invalidation trigger, `least(old, target-1)` unless `tesl.writer.<entity> >= target`; lives until the version is retired |
| V8 writes touching the closure | read-modify-write with `set_config('tesl.writer.<entity>', <gen>, true)`; partial upserts likewise unless provably outside the closure; trusted because Tesl owns all writes |
| backfill | `_tesl_v = g-1` exactly, over a partial marker index; conditional on the tuple `xmin` read; provisional until retirement, final after; marker-aware SQL rewrites for `Rename`/`Default` (never `IS NULL`) |
| SQL use of a new column | compile error in the introducing version unless SQL-expressible or `Maybe`, with a "prepare the unlock" action; usable from the next version, whose readiness waits for the final pass |
| unique indexes | every new one gates readiness; over columns any admitted version writes = `ROLL-WINDOW RISK` **and window-narrowing** (closes an additive epoch); the resolution is declared **in the schema**: `staging unique index [cols]` in V<n> (no uniqueness exposed, **no runtime guard in v1**, a tracked promote-or-cancel obligation, MIG030 family; the index is built at promotion in V<n+1> after the predecessor retires) — or a bounded wait, or offline; built `CONCURRENTLY` on the worker's session-fenced DDL connection, one builder per index; duplicates V<n> created in the window are reported, not prevented (the reservation guard is the dependent item `staged-uniqueness-guard.md`) |
| nontransactional DDL | the worker's dedicated DDL connection holding a session-level shared fence (trusted direct DSN); version-suffixed object names; retirement waits out `pg_stat_progress_create_index` |
| who does the work | `topology: Worker` (default; roles `tesl_app` / `tesl_schema`, `--schema grants`) or `Embedded` (one process, one role, same guards); leases never guard safety; lock order boot → fences ascending → job leases; the control schema has its own `format_version` and upgrade protocol |
| concurrent boots | the **session-level boot lock** on the DDL connection serialises expand (the lease row is observability); every step idempotent as defence in depth; waiting instances not ready |
| queues, caches, outboxes | job/outbox rows carry `schema_version` and are claimed only within the two-version window; retirement migrates pending/dead jobs in place through the embedded `jobs:` migration (`IgnoreOld` = acknowledged, counted deletion); claims carry a `claim_seq` token (CAS on complete/fail); undecodable jobs are typed, visible dead letters; the language surface for migrating job payloads (`jobs:`, `IgnoreOld`) is the dependent item `queue-payload-migrations.md`; cache keys include the value type's closure hash; runtime-owned tables are under the control-schema format protocol, `tesl_cache` truncatable |
| topology (PostgreSQL) | one logical primary; HA failover survives every guard; async replicas give lagged retirement for reads; sharding a non-goal; built-ins only, on the PostgreSQL majors **supported upstream at release time** (14–18 today; the floor is 14 — `CREATE OR REPLACE TRIGGER` — and unsupported majors get no CI and no promise) |
| commands | compiler: `tesl migrate generate|rebase|repair|contract|prune [--database D]`; binary: `app --schema <verb> [--database D]` with verbs `status`, `dry-run`, `contract V<n>`, `worker`, `grants`, `quarantine (list|export|delete)`, `backfill (pause|resume)`, `activate-protocol (plan|verify <nonce>)`, `close-epoch --through V<n>`, `index-wait`, `deploy-recipe`, `apply-offline`, `catch-up`, `await contractable`, `adopt`, `reidentify`; editor: *Tesl: Change Schema* over a non-mutating manifest with preview |

## Product layers, defaults, and what ships first

A strategic review (2026-09-03) made a point this document had drifted away from: the
design had become one feature made of six systems — a schema compiler, an online
migration engine, a deployment-version admission system, a distributed job
coordinator, a historical linker and a multi-file editor workflow — and phase 1 was
carrying most of the control plane to ship an additive column. The core that is
Tesl-specific and worth building first is smaller: versioned schema modules, a
compiler-generated diff and compatibility classification, typed row functions with
proofs, a reviewable plan, and generated compatibility tests. Everything else is
layered on that, each layer useful without the next:

| layer | what it is | ships in |
|---|---|---|
| 1. Schema history and planning | the `VCurrent` schema module and its frozen snapshots, module references, MIG015, compile-time freezing (MIG013), the diff and `ONLINE`/`ROLL-WINDOW RISK`/`OFFLINE` classification, the plan header, the sparse `Migration` record with `Additive`/`New`/`Drop` (unchanged entities by absence), MIG001–MIG002, MIG011–MIG016, MIG020, MIG024, the non-mutating manifest and the editor command | phase 1 |
| 2. Typed transformation | `Migrate`/`Derived`, `Rename`/`Retype`/`Legacy`/`WriteBack`/`Revalidate`, row functions over `establish`, sealed facts, `Same`, frozen stdlib slices, `fixtures:`, `todo`, MIG003–MIG010, MIG017–MIG019, MIG021–MIG023, MIG025–MIG027, generated compatibility and support modules, `--schema dry-run` | phase 3 |
| 3. Migration executor | the control schema, expand DDL with `lock_timeout`, `CREATE INDEX CONCURRENTLY` with single ownership, catalog verification, `--schema status`/`adopt`/`contract`, the schema worker and the privilege model, the OFFLINE path | phase 1 (additive, Embedded), phase 2 (worker, indexes, runtime tables), phase 4 (contract, offline) |
| 4. Online compatibility | `_tesl_v` generations, invalidation triggers, dual writes, read-modify-write, marker-aware SQL rewrites, lazy reads, batched conditional backfill | phase 3 |
| 5. Deployment coordination | **mechanism** — the write fence, read admission, protocol level, pooler compatibility suite — ships dormant in **phase 1** as the safety kernel; **use** — `min_version` retirement, `contract: WhenDrained | NextVersion`, the activation ceremony, prune — ships in phase 4 | phase 1 (kernel), phase 4 (retirement) |

**Defaults, decided as product choices rather than assumed.** One of them is about
what phase 1 *is*. Two coherent strategies existed: (A) admission is a permanent
**safety kernel** that ships in phase 1 and executes on every transaction from day one,
dormant only in that nothing is ever retired yet; (B) phase 1 is genuinely
lightweight, and enabling coordination later requires the one-time activation ceremony
for every database. **Strategy A is chosen** (2026-09-03): the kernel's cost is one
shared advisory lock plus one raising statement per write transaction and one
statement per read transaction, pipelined, measured in phase 1 against the reference
workload; the cost of B is a second protocol epoch that every database has to be
walked through with a role-generation ceremony, forever. So layer 5's *mechanism* is
phase 1 and only its *use* — retirement — is phase 3/4; the earlier claim that ordinary
teams "pay none of layer 5's cost" was strategy B's claim and is withdrawn. Because
every later binary depends on this kernel, its performance budget is a **release
gate for phase 1**, not an acceptance measurement to revisit later, and the fallback is
decided now: if the budget is missed, the kernel is optimised **within the same fence
domain** (statement shape, lock-key partitioning), or the server-side trigger
alternative is chosen **before any binary ships**; a kernel is never replaced
incompatibly after release, since that would invoke the very activation ceremony the
kernel exists to avoid. What the
defaults still buy a team with ordinary orchestration is that nothing destructive
happens without an explicit, reviewed step:

- **Expand** is automatic (boot in development, the schema worker in production).
  Backfill is automatic and background. Both are metadata-only or throttled; neither
  changes a request's cost.
- **Contract is explicit by default, and its request is a committed, hashed artifact.**
  A previous revision made *deleting* the old schema module the contract request; the
  review showed why that fails: with the files gone the binary cannot
  tell a reviewed contract from catalog drift (fatal on an adopted database), cannot
  name the exact objects it is authorised to drop, and cannot distinguish destructive
  intent from a packaging omission — and "make the catalog match V8" contradicts the
  principle that nothing is altered except what a committed plan describes. So the
  request is a small generated file, `migrations/notes/v8-contract.tesl`:

  ```tesl
  module NotesSchema.Migrate.V8Contract exposing [contract]
  import Tesl.Migration exposing [Contract, Drop(..)]
  import NotesSchema.Migrate.V8

  contract = Contract {
    of:    NotesSchema.Migrate.V8            # the applied migration; its hash is recorded in the header
    drops: [ Column Note authorId, Column Note legacyRank,
             Index Note notes_authorId_idx, Trigger Note tesl_mig_notes_g4 ]   # the exact objects, nothing else
    tighten: [ NotNull Note ownerId, NotNull Note wordCount, Check Note wordCount ]
  }
  ```

  `tesl migrate contract V8` writes it while both schema modules are still present
  (the list is derived from V7 vs V8, never from the catalog), a person reviews and
  commits it, and it is hashed and frozen like every other migration artefact. The
  artefact **authorises**; it does not by itself **execute** — the two are separate so
  that the default has one obvious irreversible button: `--schema contract V8`, run by
  the worker (or the pipeline against it), performs the final pass with every row
  accepted under the old version's exclusive fence, retires, applies *exactly* the
  listed drops and tightenings, and records `(8, 'contracted', hash)`. Rows still
  rejected block the command, which reports them; request readiness is never
  involved. "The artefact's presence in the deployed binary schedules its execution
  once the old fleet is gone" is `contract: WhenDrained` in the single lifecycle
  setting below. Request binaries are unaffected in behaviour by whether the contract
  has run: they switch from window to settled SQL plans as §6 describes (a process-wide
  monotone switch driven by `compat_floor`, with whole-transaction retry as the
  backstop), and nothing they return changes. Only **after** the database records the contraction may the
  old source be deleted, as cleanup: the compiler permits `V7.tesl` and `v8*.tesl` to be
  absent **only when `v8-contract.tesl` exists** (otherwise MIG012 — a missing file is
  an error, never a request), and a binary built without them refuses to boot against a
  database that has not recorded the contraction. `--schema contract` is the command
  form of the same request for pipelines that prefer one; it is the moment pgroll's
  `complete` runs. Both are guarded by the write fence, so "explicit" is not "unsafe";
  it is "not autonomous". **One lifecycle setting**, `PostgresConfig { contract:
  Explicit | WhenDrained | NextVersion }`, says when an authorised contract executes:
  `Explicit` (default) by command; `WhenDrained` when no fenced old-version transaction
  exists and no old-version heartbeat has been seen for a grace period (the fence is
  still the safety, the heartbeat only the trigger); `NextVersion` at the next version's
  boot. Retirement is the contract's internal first step and has no separate setting or
  command. A normal team keeps `Explicit` and runs the command from its pipeline after
  the roll; a team that wants no step picks `WhenDrained`. The rule also answers "when
  may old modules be deleted": after the contract has run, and never while the database
  still needs them — the gate makes a premature deletion a refused boot, not a lost
  history.
- **The write fence is always on.** It is what makes contract safe against an
  in-flight old writer, it costs one shared advisory lock on writes only, and it is
  not optional in any mode: corruption must be impossible regardless of settings.
- **Read admission is off by default in v1** (`admission: Trusted`; REOPENED by the
  2026-09-03 review, reversing the same-day `Strict` decision — maintainer to confirm).
  What `Strict` would buy in v1, checked case by case: a retired process that resumes
  *before* the contract reads a schema that is still compatible with it and returns
  correct rows — `Strict` turns that correct response into a 500 and gains nothing; one
  that resumes *after* the contract fails on the dropped column **before** the admission
  statement runs, because the query runs first (§13) — `Strict` prevents nothing there
  either (the earlier text claimed it did). Its real payload is row-level policies — a
  stale reader serving under a retired policy — which are not in v1. So the mechanism
  ships in phase 1 as the opt-in, its budget (≤ 1 % p99) is measured there, and it
  becomes the default in the release that ships policies: a configuration default, not a
  protocol change. Failure behaviour under `Trusted`, stated plainly: writes are always
  fenced; an old process the platform failed to terminate serves correct reads until the
  contract and fails loudly after it; the 15-second poll exits it either way.
- **Production topology: the schema worker by default, an embedded option for tiny
  services.** Request processes run as a role with entity DML and read-only control
  access; DDL, control-state transitions, backfill and index builds run in `--schema
  worker` under the DDL-owning role. `PostgresConfig { topology: Embedded }` lets a
  one-process service with one credential expand at boot itself: every correctness
  guard is unchanged, only the least-privilege isolation is given up, and the boot log
  says so in one line. A service with no Kubernetes and no long-running worker facility
  should not need one to add a column. Development is `Embedded` by default.

**Privilege model.** Two PostgreSQL roles, created by the operator (the compiler emits
the grant script with `--schema grants`):

| role | may | may not |
|---|---|---|
| `tesl_app` (request processes) | `SELECT/INSERT/UPDATE/DELETE` on entity tables; `SELECT` on every `tesl_schema_*` table; `INSERT/UPDATE` of its **own row** in `tesl_schema_instances` (the heartbeat, via a row-level policy on `instance_id`); `EXECUTE tesl_admit`; `set_config('tesl.writer.*')`; take advisory locks (they are not privileged) | any DDL; any other write to `tesl_schema_*`; the boot lease; `min_version` |
| `tesl_control` (NOLOGIN) | owns the control schema's functions (`tesl_admit`, the lifecycle recorders, `tesl_advance_floor`); nothing logs in as it — it exists so the private lifecycle core is reachable only through the validated SECURITY DEFINER transitions | — |
| `tesl_schema` (the worker) | everything `tesl_app` may, plus DDL on the schema, ownership of the `tesl_mig_*` functions and triggers, `tesl_schema_*` writes **through the transition functions** (never a direct lifecycle insert), membership of `tesl_app` and ownership of the database (for the catch-up/offline connection barrier), `pg_stat_progress_*` and `pg_stat_activity` reads, `pg_terminate_backend` on **its own role's** backends (PostgreSQL grants that to every role without superuser; it is how a successor fences a stuck predecessor) | `pg_terminate_backend` on any other role's backend |

Trigger functions are `SECURITY INVOKER` with a fixed `search_path`; the control
tables are owned by `tesl_schema`; `min_version` is advanced only by the worker's
retirement transaction. Where the worker role is absent from request pods by design,
request pods cannot expand — which is the point — and the worker is the single
process that can, so it is also where boot-time expand happens in production.

**The two-release rhythm is a cost to measure, not assume away.** A Go-computed
column is usable inside SQL one release after it is introduced; a rename or constant
default is not subject to that, but a derived value is. Teams may ship otherwise-empty
releases to use a column. The acceptance criteria therefore include **user journeys**
with measured outcomes — source churn, number of releases, elapsed deploy time — for:
adding and querying a derived column; changing a field's type under the same API name;
tightening a proof; renaming a nullable field; adding a unique constraint; recovering
from a rejected row.

## Phases

Four **delivery phases**, each independently useful, each smaller than the earlier
three-phase cut — the previous phase 1 had grown to carry most of the control plane —
followed by two **dependent follow-ups** that are roadmap groups, not phases.

1. **Foundation — "adding a column works."** The `VCurrent` schema module and its
   generator-frozen snapshots (§1), module references, the
   one-version rule (MIG015), semantic freezing (MIG013), explicit target resolution,
   the diff and classification, the plan header, the sparse `Migration` record with
   `Additive`/`New`/`Drop`, the control schema and its format version, additive expand
   DDL with `lock_timeout`, catalog verification, **`topology: Embedded` only**
   (development and small production), `app --schema status|adopt`, `tesl migrate
   generate` with the non-mutating manifest, the versioned diagnostic protocol, the
   *Tesl: Change Schema* command with preview, dirty-buffer policy and cross-file
   diagnostics. **Tooling cut:** MIG001, MIG002, MIG011–MIG016, MIG020, MIG024.
   Non-additive diffs produce a rejected placeholder. Indexes in phase 1: plain indexes,
   and unique indexes **only when epoch-preserving** (over columns no admitted version
   writes — in practice, over newly introduced columns); a unique index over an existing
   written column is diagnosed as "requires phase 3 (`staging unique index` or
   `close-epoch`)". **The write fence and read admission ship here, dormant**: every binary from phase 1 on takes the shared fence
   on writes and runs `tesl_admit` (which never fails while `min_version` never
   advances), and records its protocol level — so that when phase 3 introduces
   retirement, every binary that could still be running already participates, and no
   later "protocol upgrade barrier" is needed for databases that started here (see the
   control-schema DDL for the barrier a pre-fence database needs). No `_tesl_v`,
   triggers, retirement or prune: versions accumulate, additively, and nothing is ever
   retired. **This is an explicit rule, not a loophole in the two-version rule**: while
   every migration in a database's history is additive, compatibility is
   **monotonic** — every column any admitted version writes still exists and is
   nullable or defaulted for every later version, and every column any version reads
   still exists — so an *additive epoch* admits any number of versions: a V1 binary may
   restart against a V10 database and V10 may expand while V1 runs, and the boot gate's
   "behind by two" refusal is suspended for versions inside the epoch. The epoch ends
   with the first non-additive migration (phase 3+): from then on the two-version window
   applies, and before that migration can expand, every admitted version older than its
   predecessor is retired — **in one atomic operation**, `app --schema close-epoch
   --through V<n-1>`, not one `contract` per version: it previews the versions to be
   retired, live instances and last heartbeats by version, the rollback capability being
   closed and any missing activation; executes by taking every relevant fence key in
   ascending order, running the (trivially empty) row final passes, **restamping the
   queue** — every `pending`, `dead` and `processing` job row with `schema_version` in
   `[old min_version, n-2]` is rewritten to `n-1` *without decoding*, because inside the
   epoch `Same` proved the job types identical (a plain `UPDATE … SET schema_version =
   n-1` preserving every other column, batched on other connections while the
   coordinator holds the fences, resumable from its own `tesl_schema_queue_restamps` row
   keyed by the retirement-plan hash — never the application fills' table — and
   finished before the floor moves); `processing` rows follow the **one claimant rule of
   §14**: a row claimed by a *retiring* version's worker cannot renew under the fence, so
   the pass waits out its lease (at most one lease period) and restamps it; a row claimed
   by a *surviving* version's worker is restamped **in place, immediately**, preserving
   `status`, `claim_seq`, `claimed_by_version` and `lease_until`, and is never waited for
   (its later completion or requeue commutes with the restamp) — so the postcondition
   holds at the floor's commit even with that claimant paused — and only then jumping
   `min_version` from the epoch's first version to `n-1` with one compare-and-set,
   writing each version's `retired` lifecycle row in the same transaction. The
   postcondition is checked before commit: **no non-quarantined job row has
   `schema_version < min_version`**. No DDL is involved. Per lifecycle mode: under **`Explicit`** the first transforming executor
   prints exactly that command and stays unready while the current fleet serves; under
   **`WhenDrained`** the executor runs it once every version below the target has no
   fenced transaction and no heartbeat for the grace period; under **`NextVersion`** the
   first transforming executor *attempts* it during its deployment but **refuses while
   any retiring version still has recent heartbeats** — forcing the exclusive keys
   through a live old fleet is data-safe (the fence holds) and traffic-unsafe (every
   queued old request then fails admission), and no mode does that silently. The
   preview therefore reports two verdicts, **data-safe** (fences) and **traffic-safe**
   (no live old instances), refuses by default on the second, and has the same
   deliberate override as `contract` (`--force`, recorded), whose output is severe and
   factual: corruption remains impossible; transactions already in flight drain or
   block; every newly queued old-version transaction then fails admission; load-balancer
   propagation can therefore produce request errors until routing catches up. That is a
   legitimate availability override, unlike an unsafe protocol activation, which does
   not exist. It takes every key with a
   bounded `lock_timeout` and gives up with a report rather than hanging the deployment
   behind one forgotten long-running transaction. Each admitted version took the fence,
   so no ceremony is needed for versions born in phase 1.
2. **Production hardening.** `topology: Worker` with the two roles and `--schema
   grants|worker|deploy-recipe`, `CREATE INDEX CONCURRENTLY` with single-builder
   ownership and the unique-index readiness gate, the session-fenced DDL connection,
   runtime-owned tables under the format protocol, the `schema_version` claim predicate
   and typed dead letters on `tesl_jobs`/outboxes, `claim_seq` attempt tokens with lease
   renewal, **the `@effect "name" [key: …]` annotation with MIG032 and the canonical
   idempotency key** (moved here deliberately: the at-least-once duplicate exists today,
   and the annotation is a small compiler addition independent of the `jobs:` surface),
   non-transforming restamps at retirement and epoch closure, closure-hashed cache keys,
   the pooler compatibility suite for the pipelined transaction shapes. **Not** in phase 2:
   `jobs:`, `IgnoreOld`, transforming job migrations — the dependent item.
3. **Typed transformation and online compatibility.** `Migrate`/`Derived` and every
   `Rule` (`Rename`, `Retype` with `@column` and MIG027, `Legacy`, `WriteBack`,
   `Revalidate`), `establish`-based row proofs, sealed facts, `Same`, frozen stdlib slices under the
   execution ABI, `fixtures:`, `todo`, `_tesl_v` (added by adopt/expand as a format
   upgrade), invalidation triggers, dual writes, read-modify-write and partial-upsert
   rewriting, marker-aware SQL rewrites, lazy reads, batched conditional backfill, the
   Memory store's generation model, generated compatibility/support modules, `app
   --schema dry-run`, the AST-aware refresh, `tesl migrate rebase|repair` scaffolds.
   **And the non-destructive half of retirement**, because the first transforming
   migration cannot expand until the additive epoch has collapsed to the two-version
   window: `tesl_advance_floor`, slot retirement, atomic `app --schema close-epoch`,
   the protocol activation ceremony (`activate-protocol plan|verify`), the
   `staging unique index` declaration, its `tesl_schema_stages` lifecycle and its
   `V<n+1>` promotion (no runtime guard — see §7 and `staged-uniqueness-guard.md`). **Tooling cut:** MIG003–MIG010,
   MIG017–MIG019, MIG021–MIG023, MIG025–MIG027.
4. **Deployment coordination — destructive contract and automation.** `tesl migrate
   contract` and `app --schema contract` with validate-before-retire, quarantine and
   `Repair` amendments, `contract: WhenDrained | NextVersion`, `tesl migrate prune` with
   per-target evidence, the OFFLINE path (`apply-offline --wait-for-drain`, shadow-table
   copy, `--suggest-online`), **catch-up** (§8b) with the connection barrier it shares
   with `apply-offline`, the manual chapter and its anchors.
5. **JSONB integration.** Plan awareness of codec fallback lists; generate or verify
   the legacy decoder from the frozen codec; "may be removed at V<n>" tracking.
6. **Dependent items.** Row-level policies (own file); queue-payload migrations (own
   file, hard requirement recorded in §14); the Citus profile (§12).

## Decisions before phase 1

These are decision gates, not research; each has a leaning and a reason, and phase 1
should not start until they are closed.

**Normative status of the reopened items below (2026-09-03, updated 2026-09-04).** The
"Phases", "Product layers" and "Acceptance criteria" sections describe **one**
architecture — versioned schema modules (now in the decided `VCurrent` layout, §1),
migration records, the control schema and the dormant fence all in phase 1 — and they
are what is normative today. Several items below recommend a
different cut (a catalog-only phase 1, a live-module layout, a lazy default tier). They
are **recommendations awaiting the maintainer**, not a second normative architecture; a
reader must not implement from both. When one is adopted, the Phases, layer table and
every phase-labelled acceptance criterion are rewritten in the same commit, and the
dependency order below is preserved (and one input has since been settled: Tesl has no
re-exports, so the facade is withdrawn and the live-module layout is the only
import-stable layout — see "The developer-facing surface"): the phase-2 cross-version
queue claim needs a
durable database identity (`tesl_schema_meta`), the control schema, frozen and diffed
job-shape history with `Same`, and the write fence — so under a catalog-only phase 1
those four move to a phase-2 prerequisite slice; they do not wait for phase 3.

- **Contract lifecycle — DECIDED (maintainer, 2026-09-03): `contract: Explicit` is the
  default.** One setting, three values: `Explicit` (the committed `v<n>-contract.tesl`
  authorises; `app --schema contract V<n>` on the worker executes), `WhenDrained`
  (executes once no fenced old writer exists and no old heartbeat for a grace period),
  `NextVersion` (at the next version's boot). Retirement is the contract's internal
  first step; there is no separate retire command or setting. The write fence keeps
  every value safe against a straggling writer. `--schema contract` **warns and refuses**
  when `tesl_schema_instances` still shows recent heartbeats from the version being
  retired (`--force` overrides, since heartbeats are not the safety fence). Boot under
  `Explicit` never executes a contract; it reports the pending command. Expand and
  backfill stay automatic and zero-downtime; only the destructive step is deliberate.
  The earlier "no separate step at all" stance is superseded by this decision.
- **Read admission default — REOPENED (review 2026-09-03; maintainer to confirm):
  `Trusted` in v1, `Strict` when row-level policies ship.** The same-day `Strict`
  decision rested on "fail-closed at no round trip"; the review checked what it closes in
  v1 and found nothing: a post-retirement, pre-contract read is correct data, and a
  post-contract read fails on the dropped column before the admission statement runs.
  `Strict` stays in the protocol as the opt-in so the flip later is a default, not a
  migration. The budgets (≤ 1 % p99 for `Strict` reads, ≤ 5 % for writes) remain a
  **phase-1 release gate** with the fallback decided in advance (optimise within the
  fence domain — statement shape, key striping — or choose the trigger alternative before
  any binary ships); not revisited after release. Writes are fenced in both modes; the
  15-second zombie poll is on in both.
- **External effects inside a `transaction { }` — DECIDED (2026-09-03): a compile
  error.** Non-transactional capabilities may not be required by code reachable from a
  transaction body; outbox primitives (`enqueue`, `email`, `publish`) are the route.
  Ships with the fence; spec text to be written with it.
- **Granularity is per `database`, keyed by module references.** Each `database`
  names its schema module (`schema: NotesSchema.V8`) and its migration namespace
  (`migrations: NotesSchema.Migrate`, mandatory), and has its own `tesl_schema_*` control tables. What
  remains to decide is the small language addition this needs — a module reference as
  a `Database` field value, which Tesl does not have today — and the file layout
  convention the module names imply (`schema/notes/V8.tesl`,
  `migrations/notes/V8.tesl`). The optional `ddlConnection:` and `fence:` fields and
  their defaults are decided with it.
- **Topology — DECIDED (2026-09-03): `topology: Worker` is the production default;
  `Embedded` is an explicit option.** Under `Worker`, `tesl_app` has no DDL authority
  and the worker is the only executor; the DDL connection's session affinity is the
  worker's single direct DSN, a trusted deployment requirement. Under `Embedded` one
  process and one role do everything with every guard intact and reduced isolation,
  stated in the boot log. Development is `Embedded`.
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
  stated (refuse at `tesl migrate generate`, suggest a `reset`-free re-baseline) rather than
  discovered.
- **Diagnostic protocol and edit ownership.** The compiler emits a non-mutating edit
  manifest and structured diagnostics (`relatedInformation`, `actionClass`,
  `codeDescription`, command arguments, `needsConfirmation`) under a new protocol
  version; the LSP owns preview and atomic versioned application; the extension owns
  presentation only; edited generated nodes are user-owned until explicitly resolved.
  Decide the protocol version and field names before any MIG code ships.
- **Target model — DECIDED (2026-09-03): explicit, inferred only when unambiguous.**
  Every migration command and editor action resolves one **target**: entry program,
  `database`, schema family, predecessor and proposed version, migration directory.
  Inference from the open file's import graph is used only when exactly one candidate
  exists; otherwise the command refuses and asks, the answer is remembered in a
  workspace setting (`tesl.json` `targets`), and `--database <Name>` overrides on the
  CLI. Every preview and plan header prints the resolved target. Inference never
  silently chooses.
- **Refresh conflict rule.** Adopt the ownership rule of the LSP section (provenance
  ids; untouched generated nodes replaceable; edited nodes never auto-deleted; stale
  edited nodes stay with MIG002 and a diff resolution). Decide the provenance marker's
  concrete syntax.
- **Module re-export for a schema facade — WITHDRAWN (maintainer, 2026-09-04).** Tesl
  does not support re-exports, by design, and this item would have added them for one
  use. Consequence: the live-module layout above is the only route to a schema bump
  that touches no application import, which makes that reopened item the recommended
  layout rather than one of two.
- **Reserved names.** `_tesl_v`, `tesl_schema*`, `tesl_mig_v*` triggers/functions,
  `*_v<n>` index suffixes and the `tesl.writer.*` GUC prefix are reserved, as are advisory
  key2 values `0` (bootstrap) and `2147483647` (boot lock) under `fence_ns`; a user
  entity field or table name that collides is a compile error. Decide the exact
  prefix set once.

- **Phase-1 unit of versioning — REOPENED (review 2026-09-03).** Phase 1 as cut still
  requires a new module kind, module references as values, MIG015 across every import,
  hash freezing, a migration record, and the fence — to add a nullable column. The
  additive epoch (Phases, item 1) is the design's own admission that versions are pure
  bookkeeping while every change is additive, and the drift fingerprint in the phase-1
  acceptance criteria already specifies a catalog comparison. Recommendation: phase 1 =
  **catalog-reconciling additive expand** against the live catalog (add missing nullable
  or defaulted columns, tables and indexes; refuse anything else with the phase-3
  diagnostic), `lock_timeout`, dev boot / worker, drift classification — no schema
  modules, no versions, no migration record. Versioned modules, freezing and row
  functions arrive with the first transforming migration (phase 3), which is when a
  committed prior shape is actually needed (renames are undecidable against a catalog;
  additions are not). This also avoids "an `entity` outside a schema module is a compile
  error" breaking every existing program on the day phase 1 ships. What it does **not**
  remove: the control schema and database identity, versioned job-shape history and the
  fence are prerequisites of phase 2's cross-version queue claim and would ship as a
  phase-2 prerequisite slice (see the normative-status note above), so "no versions" holds
  for phase 1 only.
- **Schema history layout — DECIDED (maintainer, 2026-09-04): the `VCurrent` layout.**
  Copy current to `V<n>` first, then edit `VCurrent`; imports name `VCurrent` forever;
  §1 and "The developer-facing surface" are written for it. The argument that led there,
  kept for the record:** The hand-copied layout has
  a review cost this document had accepted as unavoidable: a schema change lands in a PR
  as a *new 200-line file* `v9.tesl`, and the reviewer cannot see the one line that
  changed without diffing `v8` against `v9` by hand (entity modules shrink the file, not
  the problem). It is avoidable by **inverting what is versioned**: the live schema
  module is the unversioned, hand-owned file (`schema/notes/notes.tesl`, `schema module
  NotesSchema version 9`), edited in place; `tesl migrate generate` **freezes** the
  previous content into `schema/notes/v8.tesl` as `schema module NotesSchema.V8`,
  byte-identical except for the header line, hash-recorded as today. The PR then shows
  the real edit in `notes.tesl` and a new file that `git diff -C` reports as a 100 %
  copy — Lamdera's `Evergreen/V<n>/Types.elm` layout, which nobody reads in review. Type
  origin stays explicit and improves: the application imports `NotesSchema`, **one**
  greppable hop to the file that declares it, hand-owned; MIG015 (import bumps) and the
  `reexporting` facade feature become unnecessary; *Tesl: Change Schema* stops editing
  imports. The migration record names `to: NotesSchema` while it is the current
  migration and the next freeze rewrites that one field to `NotesSchema.V8`
  (mechanical, generator-owned). The frozen copy is a generated *file* but not a
  generated *declaration* — it is the maintainer's own earlier text — which is the
  property the 2026-09-02 decision asked for. Recommendation: adopt.
- **Lazy decoding as the default tier; materialisation opt-in — NEW (maintainer's
  question, 2026-09-03: "migrate only the structure and solve data with codecs?").**
  Pure codec-only is **not sufficient**: a value that is never stored can never be used
  inside SQL — `where`, `order`, `groupBy`, joins, indexes, `unique index` — which is the
  point of a typed relational entity, and PostgreSQL evaluates those before Go sees a
  row; a proof that is only re-checked on read turns a bad row into a 500 at request time
  instead of a quarantined row at retirement. But it is the **right default tier**, and
  it removes most of the runtime protocol from the common path: (1) **`Rename` becomes
  pure metadata** — the logical name moves, the physical column keeps its name through
  the existing storage-name indirection (`@column`), so no dual write, no trigger, no
  backfill, no marker change for the commonest transform; (2) a **derived column that the application never writes defaults to `OnRead`** —
  computed in Go from the row on decode, like a codec fallback, never stored, usable in
  projections only, no backfill, no trigger, no `_tesl_v` bump; the old schema module
  and row function stay in the program for as long as the column is `OnRead` (as a
  legacy `fromJson` decoder does). `OnRead` is **read-complete, not write-complete**: a
  field the new code can *write* has nowhere to put a value of the new type, no
  encoding old readers understand, and no way for a decoder to tell the two
  representations apart — so a `Retype` of a written field is `Materialise` (new storage,
  `WriteBack` for the window) or, for JSONB, a reversible codec on the shape list; there
  is no `Retype … OnRead` for a written field; (3) **`Materialise`**
  is the opt-in that runs today's protocol — storage column, invalidation trigger,
  backfill, final pass, retirement gate — and is what a developer chooses when the
  column must be queried, indexed or made unique, or when the legacy decoder should be
  retired; the plan header prints the cost of each and MIG008 points from a
  non-materialised column used in SQL to `Materialise`; (4) JSONB shape changes stay
  on the codec list unchanged; (5) `Legacy`/`LegacyWith` remain, because V7 still decodes
  a removed `NOT NULL` column during the window whatever the tier — the write side of the
  two-version rule is not a data-migration question. Net effect: the fence, `_tesl_v`,
  trigger, backfill, quarantine and repair machinery is paid only by the entities and
  releases that ask for a materialised column, and a rename is free. Recommendation:
  adopt as the tiering of layer 4; specify `OnRead` versus `Materialise` as the `Rule`
  that replaces the current "every transform backfills" default.
- **Frozen stdlib slice, Migration Core ABI and primitive semantic tags — REOPENED
  (review 2026-09-03); recommendation: drop.** The guarantee they buy — two builds of one
  migration cannot disagree — is stronger than the application itself has: `createNote`
  computes `wordCount` with whichever `String.split` the compiler that built it ships,
  and a compiler upgrade mid-life changes what new rows contain, with no protocol at all.
  The acceptance criterion for a migrated row is the target module's **proof**, which
  both builds' rows satisfy. The reviewer's objection stands on one point: a proof is
  validity, not equality, so with nothing recorded one `artefact_hash` would no longer name
  one behaviour — which binary, which pass and which compiler produced a row would be
  unknowable afterwards. So the recommendation is the middle: **record, do not freeze.**
  Every lifecycle row and every executor carries a `compiler_abi` identity (the compiler's
  semantic-version tag for the Migration Core subset, bumped when a lowering changes
  meaning); the expanding binary's tag is recorded with `(v, 'expanded')` and in
  `tesl_schema_entities.processing_abi` the moment the first row of an entity is
  processed under it. A later step of that migration — provisional backfill, final pass,
  repair — by an executor with a **different** tag is **refused**. The re-review was right
  that a recorded `--accept-abi-drift` override (the previous draft) preserves
  auditability but not consistency: provisional rows already at the target generation
  are never revisited, batches carry no lifecycle row of their own, and a reason on a
  later row cannot say which rows were produced by which semantics. So the override
  exists only **before the first migrated row** (`rows_done = 0` for every entity of the
  migration and no provisional pass recorded) — the point at which choosing the new ABI
  costs nothing — and after that the two paths are: finish with a same-ABI executor (a
  build from the recorded compiler), or declare a **new generation** in the next version
  whose row function reprocesses every row deterministically under the new ABI (an
  identity `Derived` migration is enough for that). Retaining old lowerings inside the
  compiler is still rejected: it is the permanent maintenance cost this item exists to
  avoid. What is dropped is the frozen stdlib slice, the retained old lowerings and the
  primitive tag registry — the machinery that made two compilers *produce* the same rows.
  Catch-up (§8b) sharpens the choice: it runs V4's row function under the V57 compiler.
  Under the frozen model that needs retained lowerings for the whole history; under
  "record, do not freeze" each replayed version starts with zero rows processed, so the
  refused-by-default rule never triggers and every version's rows are produced under
  one ABI — which is another argument for this recommendation. **This is the one
  execution-model decision that must close before phase 3**; until it does, the frozen
  passages (§1's artefact row, §11) and this item are labelled and coexist.
  The hard-prohibition cost the earlier text worried about — a compiler upgrade waiting on
  in-flight migrations — is real and accepted: it is bounded by finalising the migration
  on the old build, which is a deploy, not a redesign. Keep the source-level hash of the
  migration closure for edited-history detection (MIG013). **Acceptance, if adopted:**
  a different-ABI executor is refused after one provisional batch and admitted before any;
  `processing_abi` is recorded with the first batch; a new-generation reprocess leaves every
  row produced under one ABI.
- **Protocol activation ceremony — proportionality noted (review 2026-09-03).** The
  threat it closes is a pre-fence process paused across a whole roll, a retirement and a
  contract, then resuming to update a surviving source column. Every current Tesl
  database is pre-fence, so every operator pays a role-generation rotation, a DBA job and
  a redeploy with new credentials once, for that scenario. Fail-closed, consistent, and
  disproportionate; the maintainer's call. If the phase-1 recommendation above is taken
  (no fence until phase 3), the ceremony is needed by every database anyway and its cost
  should be weighed against a **time-based** attestation (no pre-fence heartbeat for N
  days, recorded as `evidence_kind = 'age'`), which this document currently rejects.
- **`where` over-approximation for Go-computed columns — decide before phase 3.** See
  §6 invariant 3's proposed row: it removes the otherwise-empty release for "filter on a
  new column" at the cost of fetching unmigrated rows, and is exact after the Go filter.

## Non-goals (v1)

- Down migrations. Rollback is redeploying the previous binary, or a new forward
  migration.
- Cross-entity row functions (joins or lookups inside a migration). Route: staged
  `Maybe` field filled by the application, a new entity, or the offline path.
- Online decomposition of primary-key changes (OFFLINE; `--suggest-online` offers the
  new-entity alternative).
- Skipping versions while **serving**: a binary two versions ahead of the database is
  refused; a database with no fleet is brought forward by `catch-up` (§8b), one version
  at a time, never by a jump.
- A signing step for plans (the commit is the approval; the hash binds the database
  to the embedded artefact; provenance is the build system's).
- External writers to entity tables during a migration.
- Sharded / multi-primary PostgreSQL (Citus has a stated future path, §12; multi-primary does not).
- PostgreSQL below 14.
- Snapshot as JSON: snapshots are Tesl source; the hash is over the elaborated
  catalog.

## Acceptance criteria (phase 1)

- (Phase 1) additive catalog reconciliation: a `Maybe` column, a `Default` column, a
  plain index, an **epoch-preserving** unique index (over a newly introduced nullable,
  default-free column; the same index over a defaulted column, or composite with an old
  column, is classified window-narrowing and refused in phase 1),
  and a new entity are expanded on a populated database by the executor (`Embedded`);
  the `ALTER`s are metadata-only, the index builds are classified as scans (lock mode,
  scan, WAL, disk) in the plan; the catalog matches the module afterwards. **Catalog
  drift is classified, not tolerated wholesale:** a pre-existing extra column is *benign* only when **both** hold —
  it is nullable **or** has a default (so a Tesl insert that omits it succeeds), **and**
  its default, if any, is **literal-only**: a constant, or a constant under a type cast,
  and nothing else (the earlier "nullable *or* safe default" let a nullable column with
  `DEFAULT nextval(…)` through, and every Tesl insert would have run that side effect);
  an extra non-unique index is benign too; both are left alone and reported. An extra
  `NOT NULL` column without default, any default that calls a function or operator
  (`now()`, `nextval`, `gen_random_uuid()`, a user function — classified conservatively,
  built-in or not), unique index or constraint, check, trigger, generated column,
  identity column (`attidentity`), row-level-security policy, partitioning, or a
  type/nullability/**collation** difference on a declared column is *behaviour-affecting* and the binary refuses to
  become ready with the object named — `--schema adopt` and a `@external` entity
  annotation are the only ways to accept one, each recorded. Readiness compares a
  canonical fingerprint of the behaviour-affecting catalog built from **semantic
  catalog columns** (`pg_attribute` type/notnull/generated/`attcollation`/`attidentity`,
  `pg_attrdef.adbin` for the default expression — `pg_attribute` only says whether one
  exists — `pg_index`,
  `pg_constraint`, `pg_trigger`, `pg_policy`, `pg_class.relrowsecurity`/`relispartition`),
  never from `pg_get_*def` text taken as-is, for every Tesl-owned table. **The one canonical
  comparator for expressions** (check constraints, defaults, generated columns, index
  expressions and predicates): the live expression is deparsed by the server
  (`pg_get_expr(adbin | conbin | indexprs, relid)`) and the *expected* expression is
  deparsed by the **same server** — the executor creates it on a temporary table with the
  same column types **and collations** inside a transaction it rolls back, and reads it back through the same
  function — both under `set local search_path = ''`, so function and operator names are
  fully qualified by the one deparser and formatting, qualification and rendering
  differences cannot appear. Equality of the two deparsed strings is the definition of
  "semantically equal" on that server; the fingerprint stores the live deparsed form.
  **Default classification is literal-only**, decided on the deparsed form: benign iff the
  deparsed default is a single constant, optionally under one or more type casts
  (`0`, `''::text`, `'{}'::jsonb`, `'2020-01-01'::date`); anything containing a function
  call or an operator is behaviour-affecting, built-in or not. A `pg_depend` walk was
  the first draft's rule and is **not** usable: dependencies on pinned `pg_catalog`
  objects are not recorded in `pg_depend`, so `now()` and `nextval()` would have evaded
  it. Conservative is correct here — a default that computes anything runs on every Tesl
  insert, and `--schema adopt` is the recorded way to accept one. The earlier text named
  `pg_get_constraintdef` for an "exact" match, which contradicted this rule.
- (Phase 1) every **normative template** SQL block in this document is generated from
  the integration suite's fixture and runs, with the harness's named binds, against
  every PostgreSQL major supported upstream; illustrative and generated-snapshot blocks
  are marked as such and not executed; each concurrency scenario named in §6, §7 and §13
  is an executable test, not prose.
- (Phase 3) window → settled plan switch: a V8 binary keeps serving through
  `contract V8` with zero failed requests when the grace wait completes, and with only
  transparently retried statements when the drops start early; a paused V8 process
  resumed after the drops switches on its first `undefined_column`; a V7 process
  resumed after retirement and contract exits as retired, delivering nothing.
- (Phase 1) the safety kernel: every write transaction takes the fence and runs the
  raising `tesl_admit`; every read transaction under `admission: Strict` (opt-in in v1)
  runs the query-first `tesl_admit`; both pass while nothing is retired; the protocol level
  is recorded on every expanded version; the write-fence and read-admission budgets
  (below) are measured **here**, not in phase 4, and the pooler compatibility suite runs
  here.
- (Phase 2) privilege separation: a request process under `tesl_app` cannot expand,
  waits for the worker, becomes ready when the expanded state appears, and can write
  only its own heartbeat row; the worker under `tesl_schema` does everything else.
- (Phase 3) **crash-resumable backfill on a large table**: a 100 M-row fixture (nightly
  tier; 10 M in PR CI), the executor killed at every failpoint — mid-batch, after a
  batch commit, before and after the shard cursor write, during lease renewal, during
  the partial-index build — and a second executor (same version, and separately a V9
  executor embedding the V8 migration) takes the lease and resumes from the shard
  cursors; asserted: total rows processed ≤ rows + kills × shards × batch, no row at the
  target generation is rewritten, `--schema status` reports the resume, the
  `tesl.schema.job.resumed` event carries the cursors, and the progress gauges are
  monotone across the takeover; an `INVALID` partial marker index does not stall the
  backfill.
- (Phase 3) **successor detection**: (a) the backfill holder's pod is killed — the
  successor takes the lease at its next poll (≤ 5 s), before `expires_at`, reason
  `holder-absent`; (b) the holder's node is partitioned (packets dropped, no FIN) — the
  boot-lock successor proceeds within the keepalive bound (~25 s), and the lease
  successor terminates the zombie backend once the lease expires and resumes; (c) the
  holder is `SIGSTOP`ped — the lease expires, the successor terminates the backend and
  resumes, and when the holder is `SIGCONT`ed its next statement fails on the dead
  connection and it exits without writing; (d) a **slow** holder whose batch takes 3×
  the TTL under throttling is never taken over, because renewal runs outside the batch;
  (e) a holder whose renewal goroutine is deadlocked (test-only failpoint) while its
  batches continue is terminated and its in-flight batch rolls back — exactly one
  duplicated batch, asserted.
- (Phase 2) progress telemetry: during a backfill, an index build and a contract the
  progress metrics above are exported at every poll interval with the expected
  attributes, `rows_per_second` and `eta_seconds` track the measured rate within
  tolerance, `throttle{reason}` reflects the active limit, and the executor label moves
  on takeover.
- (Phase 4) **catch-up equals the live path**: a database driven live through V50 → V57
  (rolls, backfills, contracts, one quarantined-then-repaired row) and a V50 snapshot
  brought to V57 by `app --schema catch-up` end with **identical** catalog fingerprints,
  lifecycle rows (bar timestamps and executor ids), row generations and row contents —
  the differential oracle; the same for a point-in-time snapshot taken mid-backfill
  ("V53 expanded, provisional"), which resumes from that position; the chain includes
  additive versions, a `staging unique index` promotion and a version with a committed
  contract; `--dry-run` prints the chain and touches nothing; catch-up refuses while a
  live instance holds a fence and names it; a snapshot older than a pruned version is
  refused with the prune's recorded statement.
- (Phase 3) RMW page boundaries against a native `UPDATE` oracle: with the cursor
  open, interpose an insert matching the predicate, an update moving a row into and out
  of the predicate, and a delete-and-reinsert of a fetched key, each before and after the
  cursor position; the set of rows the RMW writes equals the set a native `UPDATE` in the
  same interleaving writes; the failpoint inventory gains `rmw-fetch-boundary`.
- (Phase 3) continuous duplicate writes during promotion: V8 (staging, unguarded)
  inserts duplicates at a steady rate throughout the V9 roll — nothing builds; `contract
  V9` retires V8 and starts the build while two V9 writers insert the same key
  concurrently — the per-key guard serialises them, the second fails typed, the build
  succeeds; pre-existing V8 duplicates block it as `blocked_duplicates` with keys;
  `onConflict [email]` does not compile in V9 and does in V10.
- (Phase 3) takeover with separate backends: the stuck holder has a lease connection, a
  DDL connection holding the session fence and a running `CREATE INDEX CONCURRENTLY`,
  and three shard connections mid-batch; the successor terminates all five by tag,
  waits until `pg_stat_activity` shows none, and only then holds the lease; asserted:
  the index is `INVALID` and rebuilt, each batch rolled back exactly once, the fence
  key free — and a takeover that only killed the lease connection (test-only flag) is
  shown to fail these assertions.
- (Phase 4) catch-up barrier: a `Trusted` old reader looping on selects and an idle old
  `tesl_app` connection exist when catch-up starts; both are terminated, the reader
  cannot reconnect while the barrier holds, catch-up completes, `grant connect` is
  restored; without barrier privileges and without `--barrier platform:` it refuses.
- (Phase 4) catch-up from every partial lifecycle state: current-version provisional
  backfill, current-version quarantine, predecessor not retired, partial contract (k of
  n statements), a repair recorded with batches incomplete, a promoting stage — each
  normalises current before expanding the next version, and the end state equals the
  live path.
- (Phase 4) historical catch-up under a newer compiler and runtime: a V3 snapshot with
  ten versions of history, two committed repairs on old migrations and one newly added
  repair for a rejecting old row, replayed by a binary built with the current compiler;
  a binary whose pruned cutoff is V6 refuses it with the recorded prune statement.
- (Phase 1) freeze of a multi-module schema: root plus three entity modules and a
  shared module; the frozen copy differs from the live tree only in the version segment
  of headers and qualified references; `snapshot_hash(VCurrent) = snapshot_hash(V8
  copy)`; the finished migration's hash is unchanged after its references are rewritten;
  both trees compile; an application-module import inside a schema module is refused.
- (Phase 1) crash-safe expand: the executor killed at **every failpoint** resumes to
  the same end state, **and** at every failpoint an old-version writer is interposed and
  the data invariant (no gen-`g` row with a stale derived value, no unprotected write)
  is asserted *during* the interruption, not only after recovery; the lifecycle row and
  `current` are never observed disagreeing; ten executors started at once produce one
  expander.
- (Phase 2) queue across an epoch: a delayed V1 job survives V1–V10 (claimable by the
  V10 worker, decoded directly), then epoch closure — after which its stored
  `schema_version` is asserted to be 10 and it is claimable; a job type changed inside an
  epoch is refused (MIG028, window-narrowing); a handler changed while its payload type
  is unchanged processes old jobs with the new handler and the plan header says so.
- (Dependent item `queue-payload-migrations.md`) the same job then crosses a V11
  **transforming** `jobs:` migration, and `IgnoreOld` deletes with the audited count.
- (Phase 4) a V9 whose schema reuses a physical name held by an interrupted
  `contract V8` stays unready until the contract completes, and never adopts the
  leftover object.
- (Phase 3) a pgx prepared window-plan statement executed after `compat_floor`
  advanced and the columns were dropped is retried once on the settled plan with the
  cache cleared, under `go test -race` for the process-wide switch.
- (Phase 2) a stale queue attempt that performs an external HTTP effect after a newer
  attempt started: queue state is untouched (`claim_seq`), the duplicate effect is
  observed and documented, and the `(job id, effect name, key)` key — computed through
  the canonical hashed wire form — is **identical** across the two attempts' different
  `claim_seq` values, so the receiving stub deduplicates it; an empty key and a 10 kB key
  produce a 49-character header with no payload bytes in clear; **cross-component
  collisions** are asserted absent — `(id: "a", name: "b", key: "c")` versus `(id: "ab",
  name: "", key: "c")` and every other boundary shift of the same bytes hash differently —
  and the same `Int` and `String` keys produce identical preimages from a V7 and a V8
  binary (frozen scalar encoding); a `key:` of record, `Float` or ADT type is MIG032.
- (Phase 2) a V8 claimant paused mid-handler on a V7-stamped row while `contract V8`
  retires V7: **immediately after the floor's commit**, with the attempt still paused,
  the row is stamped 8 with `status`, `claim_seq`, `claimed_by_version` and
  `lease_until` unchanged; the attempt's later completion deletes it, or its failure
  requeues it at 8.
- (Phase 1) crash/retry against an existing lifecycle row with a **different**
  artefact hash refuses with the immutable-history error; with equal hashes it
  continues silently.
- (Phase 4) crash after `ADD CONSTRAINT … NOT VALID` and before `VALIDATE`: the rerun
  skips the add, validates, and completes.
- (Phase 1) concurrent **V8 and V9** first bootstrap of an empty database: exactly one
  seeds; `current` and `min_version` are 0 until the initial `tesl_record_expanded(v,
  'expanded')`, which sets both in one statement; if V8 installs first, V9 then expands
  normally; if V9 installs first, V8 is refused with the deploy-order message — both
  outcomes asserted, and both leave one `expanded` row and a consistent singleton.
- (Phase 1) crash after the bootstrap seed and before the initial expansion, at every
  failpoint of `install_schema`: the next lock holder completes it; the catalog, the
  lifecycle rows and the singleton agree afterwards; no table is created twice.
- (Phase 1) a V8 executor **paused beyond the lease expiry** halfway through
  `install_schema` while a V9 executor arrives: V9 blocks on the session-level boot lock
  (it does not take over on the expired lease row), the V8 resumes and completes at V8,
  V9 then expands V8 → V9; the same with V8's connection killed instead of paused: the lock
  vanishes, V9 completes the install — at **V9's** shape, since `install_schema` verifies
  every existing table against its own module before recording — and records V9.
- (Phase 1) a **genuinely empty database** — no `notes_app` namespace, fixture setup
  creates nothing — bootstraps to a ready V<n>; a namespace owned by another role is
  refused with the owner named.
- (Phase 1) catalog drift: a nullable extra column with `DEFAULT nextval(…)` is
  behaviour-affecting (nullability does not rescue a computing default); `DEFAULT now()`,
  `DEFAULT gen_random_uuid()` and a user function are behaviour-affecting although
  `pg_depend` records nothing for the built-ins; `DEFAULT 0`, `DEFAULT ''::text`,
  `DEFAULT '{}'::jsonb` are benign; a declared column whose collation differs from the
  module's is refused; the expected temporary column is created with the module's
  collation so the comparator does not report a false difference.
- (Phase 3) every `tesl_advance_floor` prerequisite **independently absent** — a reversed
  range (`next < expected`), an empty one (`next = expected`), a target beyond `current`,
  a version in the range with no `expanded` row (lifecycle gap), one already `retired`,
  protocol floor below an expanded version's level, a version expanded in another fence
  domain, the exclusive key not held (or held by another session), an entity with
  `generation < target_generation`, a non-quarantined job below the new floor,
  `min_version` not equal to `expected` — refuses with its own message and leaves
  `min_version` and the lifecycle rows untouched; with all present it moves the floor and writes every `retired` row in
  one transaction.
- (Phase 1) every illegal lifecycle edge against the real functions: `contracted` before
  `expanded`, before the predecessor's `retired`, before `compat_floor`; a repair with a
  sequence gap or for an unexpanded version; `expanded` out of order or after `retired`;
  a direct `INSERT` into `tesl_schema_versions` and a direct call of the private core as
  `tesl_schema` — each refused with its own message and no row written.
- (Phase 1) the lifecycle recorder on an existing row inside a **live** transaction: equal
  hashes continue the transaction (it is not aborted, later statements succeed and
  commit); different hashes raise; `current` and `min_version` are moved by the same
  statement as the `expanded` row and never observed apart from it.
- (Phase 1) semantic constraint and default equivalence: the same check written with
  different whitespace, casing, redundant parentheses, unqualified versus qualified
  operator names and an equivalent cast spelling compares **equal**; a changed literal or
  operator compares different; defaults are read from `pg_attrdef.adbin`, and a default
  calling `now()`, `nextval`, `lower('X')` or a user function is classified
  behaviour-affecting (literal-only rule: any call is a call) while `0`, `''` and
  `'{}'::jsonb` are benign.
- (Phase 3) `close-epoch` with a **surviving** claimant paused mid-handler on a row stamped
  below the target: at the floor's commit the row is restamped in place with `status`,
  `claim_seq`, `claimed_by_version` and `lease_until` unchanged, the postcondition holds,
  and the claimant's later completion deletes it (or its failure requeues it at the
  surviving version).
- (Phase 2) stale V7 and V8 attempts perform the same `@effect "charge"` call after the
  handler's source moved and changed between versions: the receiving stub sees one key.
- (Phase 2) queue oracles: no non-quarantined job row below `min_version` after any
  retirement or `close-epoch`, asserted at the floor's commit; a surviving-version claimant finishing an older payload
  during retirement leaves no old stamp (completion deletes, failure requeues at the
  claimant's version); a retired claimant's renewal fails and its row expires within
  one lease; a crash between queue restamping and the floor advance resumes the
  restamp and never advances the floor early.
- (Phase 1) invalid or half-built indexes of an equivalent shape are rebuilt; `NULLS
  NOT DISTINCT`, deferrable and constraint-owned indexes are distinguished from their
  plain counterparts.
- (Phase 1) old and new binaries both run correctly against the expanded additive
  schema for the whole roll.
- (Phase 1) control-schema upgrade: a database at format `k` is upgraded to `k+1` in
  one transaction; a binary with maximum format `k` refuses to start against `k+1`.
- (Phase 1, release gate) fence overhead on a write transaction: measured, and below an agreed
  budget (the proposal is ≤ 5% p99 latency at the **reference workload**, which the
  suite defines rather than assumes: PostgreSQL 16 on a stated instance size; direct
  connections and each supported pooler mode; a stated transaction rate with a stated
  concurrency; one read and one write per transaction and a 10-statement mixed
  transaction; local and 1 ms network latency; one and ten tables under migration; hot
  and cold cache; with and without a concurrent backfill and a concurrent index build;
  with a streaming replica; and the lock-manager saturation point for the shared fence
  key, found by ramping). `admission: Strict`
  read admission: **no advisory lock and no extra round trip** — the one admission
  statement per read transaction is measured against its own budget (proposal ≤ 1%
  p99); "zero" is not a supportable claim and is not made. Ordering tests: a retirement
  interposed between query and admission aborts the transaction; between admission and
  commit, pre-retirement rows are delivered; a contract DDL interposed anywhere blocks
  until commit.
- (Phase 3) rolling deploy V7→V8 on a 10M-row table with continuous writes: no failed
  request attributable to the migration in the `ONLINE` class; in the `ROLL-WINDOW
  RISK` class, the failure count is bounded exactly when the chosen policy (staged
  uniqueness via `staging unique index`, bounded window, offline) supplies a bound, and the test asserts
  the bound that policy states.
- (Phase 1) additive generation: the next schema revision and a sparse migration
  record created for an additive diff (no entry for unchanged entities), the plan
  header correct; every non-additive diff
  produces a placeholder entry the compiler rejects with a phase-1 diagnostic naming
  the change — the typed-hole *workflow* (MIG003 contents, skeleton actions) is phase 3.
- (Phase 3) the generated compatibility tests, both directions (`insertOld`/`readOld`),
  pass for every row in the decomposition table, including nullable-rename cases:
  equality with `Nothing`, equality with `Something x`, `isNull`/`isNotNull`, grouping,
  ordering, joins and aggregates on a renamed `Maybe` column.
- (Phase 3) protocol activation: an old-generation reconnect racing `verify` is refused
  (`nologin`); a single old backend that survives termination makes `verify` fail and
  nothing is recorded; a paused old client's next statement fails on its dead connection.
- (Phase 3) epoch closure: V1–V10 accumulated additively, `close-epoch --through V10`
  retires V1–V9 in one transaction, a V1 binary is refused afterwards, V11 (the first
  transforming migration) then expands; the same after a long epoch with a
  window-narrowing unique index in the middle, which must have forced an earlier closure.
- (Phase 3) `staging unique index` (v1, no runtime guard): in V8 `onConflict [email]`
  does not compile, the Memory backend does not enforce uniqueness, and the entity type
  carries no promise; V9's promotion does not start the build while V7 is admitted,
  starts it once V7 is retired, and V9 is unready until the index is `VALID`; duplicates
  V8 created in the window make the build fail, the keys appear in `--schema status` with
  state `blocked_duplicates`, and the build succeeds once they are resolved; an
  abandoned stage is reported outstanding; a deleted `staging` line is a decision-class
  plan entry; a V9 that neither promotes nor cancels a V8 stage carries it forward and
  the plan says so; every MIG030 case is exercised.
- (Phase 3) `close-epoch` with recent heartbeats refuses without `--force`; with a
  long-running old transaction it gives up on `lock_timeout` and reports rather than
  hanging.
- (Phase 3) activation plan: an expired, replayed, or database-mismatched nonce is
  refused by `verify` and the plan row shows why.
- (Phase 4) retirement robustness: a `Reject` injected after several final-pass
  batches have committed leaves those batches committed, `min_version` and lifecycle
  rows unchanged, the quarantine written, and the retry resuming from the remaining
  rows; a crash of the retiring process mid-transaction leaves the same state.
- (Phase 1–4) **ergonomic budgets**, each an automated scenario with a hard number:
  a nullable field in a small app is one schema edit, one preview acceptance, zero
  hand-written migration lines, zero contract steps; one entity changed in a 300-entity
  schema produces a diff of exactly the one entity file plus one frozen copy, no
  unchanged-entity entries, and zero application-file edits (every import names
  `VCurrent`); two branches colliding on V20 are resolved by
  `rebase` with every valid user-owned function retained and at most one focused hole
  per genuinely conflicting change; a shared-type change marks exactly the dependent
  entities; a `Retype` changes zero logical field names outside schema and migration
  source; `prune` is one preview and one confirmation with no manual file selection;
  `deploy-recipe` output validates, exposes every required parameter explicitly (image,
  namespace, secrets, DSNs), runs once only those are supplied, and contains no hidden
  wiring between worker, grants, contract job and readiness; an ambiguous target
  is refused, never guessed; "prepare the unlock" produces a compiling next version in
  one action; a redacted fixture export contains no `@pii`/`Secret` value, is
  reported as a non-compiling skeleton, and compiles once every hole has a synthetic
  value.
- (Phase 4) the deliberately failing production row: `--schema dry-run` passes; an old
  binary then inserts a row the frozen row function rejects; the next version boots
  and attempts retirement. Required outcome: retirement rolls back, the row appears in
  `--schema status` with the validator's reason, the old version stays admitted, and
  the system is repaired by one of the three documented paths without editing the
  applied migration or running raw SQL — then retirement succeeds on the next boot.
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
  edit fails, or is restored, per the negotiated capabilities). Phase 3: an edited row
  function survives a refresh (fingerprint-based); the created migration opens with the
  first MIG003 selected.

## Test infrastructure (required before phase 1's acceptance suite is written)

The scenarios above are only as reliable as the harness that runs them; none may be
implemented with sleeps or the production visibility timeout.

- **Deterministic interleaving.** Test-only failpoints (a build tag, never in release
  binaries) at named events: fence acquired, query complete, admission begins/ends,
  `compat_floor` read and switch, trigger replaced, each DDL commit, final-pass batch
  commit, lifecycle-row write, queue claim / renewal / expiry / reclaim / completion,
  retirement and contract commit. A test pauses at an event, performs the competing
  action, releases; every wait has a hard timeout whose failure dumps
  `pg_stat_activity`, `pg_locks` and the lifecycle rows.
- **A reference state machine and invariant checker.** An executable model (Go,
  property-based) that generates legal and adversarial sequences — boot, expand,
  backfill, contract, repair, crash, resume; old/new reads and writes; enqueue, claim,
  expiry, migrate, retry; index success/failure; lease expiry and competing executors —
  and after **every** operation asserts catalog, admission, row-generation,
  queue-attempt and lifecycle invariants against the real database. A TLA+ model of the
  admission/contract kernel (fence, floor, `compat_floor`, retry) is justified and is
  an open item below.
- **Independent oracles.** Checked-in V7/V8/V9 fixture applications compiled and run as
  **black-box processes** against one database, so generated old SQL is not judged only
  by generated new SQL; differential comparison of Memory and PostgreSQL outcomes, of
  raw catalog/row state against a canonical model, and of old and new binaries under
  the same operation trace.
- **CI tiers.** Today `ci.sh` provides one project-local PostgreSQL and the workflow
  has a 60-minute limit. Every PR: compiler and unit tests, the state-machine model,
  the current and the oldest supported PostgreSQL major, the deterministic core
  interleavings, the Go race detector. Nightly: every supported major, PgBouncer
  session and transaction modes, a lagged replica, backend/process/primary termination,
  long randomised traces with recorded seeds. Performance: a dedicated pinned
  environment (10 M rows, network latency, replica, concurrent backfill and index
  build, saturation ramps) with warm-ups, enough samples and confidence intervals —
  the ≤ 1 % p99 read budget is **not** decidable on shared runners and is gated there,
  not in PR CI.
- **Invariant traceability.** Every safety invariant and state transition in this
  document carries a stable id (`INV-…`, `TR-…`, to be assigned when the normative
  split is made); generated mappings — invariant → implementation paths, → failpoints,
  → tests and PostgreSQL-matrix coverage — are checked in and a documentation CI step
  fails when a transition has no test or a test names no invariant, so the inventory
  cannot silently omit a new transition.
- **SQL fence classification.** Every SQL fence in the normative documents starts with
  a machine-readable class comment — `-- [normative-template]`, `-- [illustrative]`,
  `-- [generated-snapshot]` — and documentation CI fails on an unclassified fence; only
  the first class is executed, and it is generated from the test fixture.
- **Isolation.** Per-test database or schema for ordinary integration tests;
  disposable per-test clusters for primary restart, control-schema upgrade and failover
  tests; every randomised test records its seed and operation trace.

## Open questions

- **A TLA+/PlusCal model of the admission kernel** (fence, `min_version`,
  `compat_floor`, retry table, contract ordering, queue restamping) is a **gate**: it
  need not exist for phase 1's dormant admission, but no implementation that advances
  `min_version` or `compat_floor` (phase 3's first slice) merges before the model checks.
  What is open is only its scope beyond the kernel.

Items decided in direction but not yet specified to implementation depth, listed here
rather than claimed closed:

- **Document structure.** The maintainer split this into a normative spec and a
  history file (2026-09-03). A reviewer proposes a further cut — protocol/state-machine
  specification, PostgreSQL implementation design, operational runbook, roadmap. The
  design is still moving under review; that split is the right editorial step **once
  it settles**, before implementation starts, and the section boundaries above (§13b,
  the SQL blocks, §11, Phases) are already drawn along it.

- **The exact elaboration rules of `Migration { … }`, `Repair { … }` and `Contract
  { … }`** — the table in §4 states what each position must be; the formal typing
  judgments (how `entities:` derives its record type from two modules, how `Migrate f`
  is checked against the specific pair, how a `Contract`'s object list is checked
  against the two modules) belong in LANGUAGE-SPEC before implementation, together with
  the **Migration Core** subset and its ABI.
- **The read-admission ordering proof** — the argument in §13 rests on `ACCESS SHARE`
  being held to commit and on READ COMMITTED snapshot ordering; it must be written up
  against the PostgreSQL manual's lock and snapshot rules and pinned by the interposed-
  retirement tests before phase 3 first advances `min_version` (epoch closure; the
  admission statement itself ships dormant in phase 1).
- **`establish` in the migration seal.** `Check.attempt` is withdrawn (2026-09-04) in
  favour of the existing `establish`; what remains to confirm is that the `establish`
  kind accepts the canonical optional return `-> Maybe (v: T ::: P v)` (D7 lists the form
  as canonical for proof-carrying returns; the committed tests exercise `-> Maybe (Fact
  (P n))` on `establish`), and the exact MIG019 rule for an `establish` outside the
  schema module that names a column fact.
- **The `schemaTest` capability and test-only module kind** for the generated support
  module: how a test build grants it and how the production build excludes the module.

Two items were moved out — typed holes (`todo`) anywhere in the language belong to
their own compiler/LSP roadmap item, and whether row-level policies are mandatory
belongs to the row-policy roadmap file.
