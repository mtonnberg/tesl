# Database migrations — design history (non-normative)

This file is the review log of `database-migrations.md`. **Nothing here is a
requirement.** It records, pass by pass, what each external review found and how the
design answered, including mechanisms that were later superseded — kept because the
*reasons* a mechanism was rejected are worth more than the mechanism. Where a row or
sentence below disagrees with `database-migrations.md`, the spec wins; the spec's
"Current mechanisms" table is the authoritative summary.

The reviews were run against successive drafts on 2026-09-02 and 2026-09-03; the
maintainer's decisions taken during them are recorded in the spec's "Decisions before
phase 1" section.

## Gaps the worked example exposed

The `notes` V7→V9 example in the spec was written as an intended-to-compile golden
fixture and reviewed as such. Writing it changed the design in the following places
(numbering as originally recorded):

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



## Review passes

**Reading the tables.** Each pass below is recorded as it was resolved at the time; a row marked
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
`Row`/`Reject` with checks applied through an `Attempt`-returning `Check.attempt` (no
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

A **fourteenth pass** found two blockers and eight gaps. A same-column proof change had
no legal source form (the revalidation example violated the exact-projection rule) — a
`Revalidate f check` rule now permits exactly one initialiser shape, with no shadow
column, a generation bump, a contract-time `CHECK` and a `ROLL-WINDOW RISK` label, and
same-named type changes are explicitly a new column + `Drop`. Retiring before
finishing could strand rows a frozen function rejects — retirement now runs the final
pass **under the exclusive fence first** and advances `min_version` only if every row
is accepted, otherwise rolls back, quarantines, and refuses, with three repair paths
(the admitted versions, an append-only `v<n>-repair.tesl` amendment, acknowledged
deletion) and a `MAY BLOCK RETIREMENT` plan label for rejecting functions. Also: the
control schema is now explicit DDL (`tesl_schema_state` singleton, append-only
`tesl_schema_versions`, per-entity state, leases, index state, quarantine, `tesl_admit`);
`--schema adopt` adds `_tesl_v` transactionally with lineage-derived generations;
`Same` is verified by semantic-closure hash, never asserted; renamed-column rewrites
select by generation marker, not by `NULL`, so nullable renames are correct; read
admission is specified for single, batched and data-dependent transactions with rows
released after `COMMIT`; `Check.attempt` is restricted to identity-preserving checks in
v1; compatibility tests cover both directions via `readOld<E>`; and the stale
`_tesl_v < 7`, "every transaction", "check function" and "Maybe-returning" phrases are
gone.

A **strategic review** (2026-09-03) was accepted in substance: the design had grown
into six systems shipped as one, and phase 1 carried the control plane to ship an
additive column. The document now has a **layers** section (schema history and
planning; typed transformation; migration executor; online compatibility; deployment
coordination), each useful without the next; a smaller **phase 1** (layers 1 and the
additive executor — no `_tesl_v`, triggers, fence or admission, since nothing
destructive exists yet); **product defaults** stated as choices — explicit `--schema
contract` by default with `retire: NextBoot` opt-in, write fence always on, read
admission `Strict` opt-in over a `Trusted` default, the schema worker as production
topology; a **privilege model** with `tesl_app` and `tesl_schema` roles and `--schema
grants`; user-journey acceptance criteria for the two-release rhythm; a full
specification of **repair amendments** (`Repair { of, entity, with }`, numbered,
chained, frozen, embedded, tested, `(version, step, seq)` keys); honest non-atomic
final-pass semantics (committed batches stay, quarantine in a separate transaction,
crash = abort); control-schema keys widened (`seq`, quarantine by target generation and
attempt, `jsonb` cursors, the one-job-per-entity argument, the boot lease row);
lifecycle writes in one transaction with a crash-recovery rule; `Revalidate`'s `CHECK`
made conditional on SQL-expressibility; external effects in read-only transactions
excluded from the guarantee and gated for a decision; and the summary's fence and
state-model bullets brought up to date. Two things were **not** conceded: zero-downtime
expand/backfill remains automatic and the default, and the write fence remains
unconditional — those are what keep corruption impossible in every mode. The
maintainer confirmed both recommended defaults the same day (explicit contract,
`Trusted` admission); they are decided, not open — and refined "explicit contract"
into a source-level form — first "deleting the old schema module is the request",
which the fifteenth pass then showed to be unsound (a missing file carries no intent
and no object list), and which became the committed, hashed `v<n>-contract.tesl`.

A **fifteenth pass** changed three foundations and fixed eight local points.
Deletion-as-contract was withdrawn: a missing file cannot carry intent or an object
list, and "match the catalog" contradicts the committed-plan principle — the request is
now a generated, reviewed, hashed `v<n>-contract.tesl` (`Contract { of, drops, tighten
}`), the worker applies exactly what it lists, and deleting old source is cleanup the
compiler permits only once that file exists. Hashing internal IR was not a frozen
semantics — migrations are now written in a **Migration Core** subset with a versioned,
golden-tested **execution ABI** in every header and hash, with retain-or-refuse across
compiler releases. The control schema gained its own **format version** and
transactional upgrade protocol (the feature's own "table exists, column does not"
problem). Locally: the lifecycle is now written **by mode** (default explicit,
`NextBoot`, `Trusted`/`Strict`) with worker/check step markers; request processes
write only their heartbeat row and never the boot lease; the worker is **required** in
production (decided); finalization state commits atomically with retirement after a
re-check, and quarantine re-runs the row function to avoid stale entries; `Trusted`'s
failure behaviour is stated plainly (stale reads, and failing reads after contract);
repairs gained `--migrate --repair`, MIG026, a `seq`-ordered history query and an
immutability rule; `Revalidate`'s `CHECK` is conditional in the example and the
elaboration row too; and the acceptance criteria were re-cut by phase, with phase 1
now testing additive reconciliation, privilege separation, crash-safe expand and the
control-schema upgrade rather than fences it does not have.

An **ergonomics review** (2026-09-03) judged the design safe but clunky at enterprise
scale, and most of it was accepted: source and review diffs now scale with the change
(entity modules under a one-line-per-entity versioned root; migration records name only
changed entities, absence being verified `Unchanged`); the facade re-export ships with
phase 1; same-name type changes keep their logical name through a `Retype` rule and an
`@column` storage name — reversing an earlier deferral, because the emitter pays that
once and every user paid the alternative; contract *authorisation* (the artefact) is
separated from *execution* (`--schema contract`, or `contract: OnDeploy`); the artefact
inventory is canonical and compat/support modules are build products, not commits; the
two-release rhythm has a "prepare the unlock" action; targeting is explicit and
decided; `--rebase`, `--prune`, a scaffolded repair journey with redacted fixtures, and
a generated deployment recipe exist; the contextual forms get completion and hover; and
the summary's admission and artefact claims match the decided defaults.

A **second ergonomics pass** (2026-09-03) found the document contradicting itself after
fifteen incremental revisions, and several remaining gaps; it was consolidated: the
authoritative mechanisms table was rewritten in full; every cited stale normative
passage (required `Unchanged` entries, contract-by-presence, `retire: NextBoot`,
`--schema retire`) was corrected; an **Everyday workflow** section now precedes the
machinery; schema version, entity **source revision** (`R<k>`) and row generation are
three distinct, differently named numbers; **shared modules** hold cross-entity types
with explicit revision imports and no cycles; the branch story states the linear
coordination cost honestly (root/record add-add conflicts, `rebase --combine`, release
trains, merge queues); `Retype` has a complete design (storage name from the revision,
free initialiser, same-name `WriteBack`, MIG027, contract drop, window SQL rules);
purely additive versions need no contract artefact and finish automatically; the
lifecycle collapsed to one setting `contract: Explicit | WhenDrained | NextVersion`
with retirement internal; the command surface is a `tesl migrate <verb>` family and a
complete `app --schema` inventory with `--database`; fixture export is a specified
privacy boundary (`@pii`, typed `todo`s, git-ignored 0600 output); `topology: Embedded`
exists for tiny services; and ergonomic acceptance budgets replaced the vague
measurement criterion.

The title was softened from "by construction" to "rolling deploys" in the same pass:
the `ONLINE` class is zero-downtime under the stated protocol, and the two
`ROLL-WINDOW RISK` cases and the `OFFLINE` class are named rather than claimed away.


A **seventeenth pass** (second review after the history split, 2026-09-03) found the
normative file still teaching old and new commands together and several gaps in the
ergonomic workflow; it was folded: every `tesl --migrate` became `tesl migrate
generate`; the facade paragraph stopped calling the facade optional; compatibility
fixtures gained a committed home (`fixtures:` in the migration record, user-owned
functions consumed by the generated module; generator-synthesised where every field is
constructible); the redacted-export state model was corrected (a non-compiling skeleton
until synthetic values are supplied; `@pii` is its own bounded subsection); additive
versions no longer retire the previous version on a timer — physical work finalises at
once and admission is retired only when the next version needs the slot; phase 1 no
longer retires or prunes anything, since it has no fence; `prune` computes source
candidates and takes per-environment `--schema status --json` evidence; a root names
exactly one revision of each shared module (MIG029); the queue-payload *language*
surface was split into `queue-payload-migrations.md` with a hard requirement recorded
in §14; `[executor]`/`[request-check]` replaced worker/dev wording; `Retype` got one
form, a revision-based storage name, a `Storage` drop and a worked example; freezing is
semantic; a *Finalise* step writes the contract artefact so it ships with the migration;
the `Trusted` default was kept but the reviewer's `Strict`-under-`Worker` refinement was
put to the maintainer; and the phases were re-cut into a genuinely small foundation
(Embedded only, additive, no retirement), production hardening, typed transformation
with online compatibility, and deployment coordination.

The maintainer then reversed the read-admission default to **`Strict`** (2026-09-03): fail-closed fits Tesl, the cost is no round trip and a ≤ 1 % p99 budget, and only a measured breach of that budget would reopen it; `Trusted` is the opt-in.

An **eighteenth pass** (2026-09-03) found two blockers: the pipelined write admission returned a value, which is no barrier — PostgreSQL executes queued statements regardless — so it is now a raising `tesl_admit` (a pipeline abort point, with a never-executed test); and phase-1 binaries would have bypassed the phase-4 fence, so the fence and admission ship dormant from phase 1 with a recorded protocol level and a `--certify-drained` barrier for pre-fence databases. Also folded: boot under `Explicit` never executes a contract; additive **slot retirement** is named and specified; external effects in transaction bodies are a compile error; adaptive backfill controls; a defined reference workload; unique-index livelock policies; the cross-entity non-goal with routes; canonical fixture synthesis; shared-revision churn mitigations; and the listed stale text.

A **nineteenth pass** (2026-09-03): the two-version window is now strict in every mode — a new version stays unready until its predecessor's predecessor is retired (`contract V<n-1>`), never three admitted; the pre-fence barrier became a durable, audited **protocol activation ceremony** with role generations and backend termination (password rotation does not disconnect sessions), and one `advanceAdmissionFloor` transition guards every `min_version` write including the offline path; the unique-index "stage" policy got a database-enforced guard trigger and the "reject" policy was removed; **Strategy A** was chosen — the fence and admission are a phase-1 safety kernel, measured in phase 1; the additive epoch is an explicit n-version rule ending at the first non-additive migration; `contract V<n>` naming prints all three facts; fixture synthesis is structural-only with a user fixture required for every `Migrate`; the backfill SLO metrics need a configured provider; prune evidence is per database target against a declared inventory; a state machine and a staged cross-entity example were added; stale phase and terminology drift removed.

A **twentieth pass** (2026-09-03): the additive epoch is now classified by **behavioural** monotonicity, not by the `Additive` constructor — a unique index over a column any admitted version writes is *window-narrowing* and forces `close-epoch` first; staged uniqueness became a **committed** `StageUnique` rule (no uniqueness exposed in V<n>, index declared in V<n+1>) with exact guard semantics (64-bit `hashtextextended` on the canonical typed key, typed lookup, `NULLS DISTINCT`, own-row exclusion, ascending-hash locking, final duplicate scan), and the runtime knob shrank to `index-wait`; the non-destructive half of retirement (`advanceAdmissionFloor`, slot retirement, atomic `close-epoch`, activation) moved to phase 3 so a first transforming migration can actually expand; the control schema gained `retirement_protocol_floor`, `fence_domain` and an append-only activations table; the activation ceremony was split into worker `plan`/`verify` and a privileged administrative job, and `--unsafe-assert-stopped` was removed; the boot summary states the epoch rule; the kernel budget is a phase-1 release gate with a decided fallback; the cross-entity example uses `Retype`; dynamic inventory providers; state-machine wording split into the two pictures; new activation, epoch-closure and `StageUnique` acceptance tests.

A **twenty-first pass** (2026-09-03): staged uniqueness moved into the schema as a `staging unique index` declaration (the migration record is a schema diff, so a migration-only `StageUnique` rule had no source of truth), with a tracked promote-or-cancel obligation and control state; the guard became a **reservation table** with a real unique index kept by a row trigger, replacing the advisory-lock design whose post-lock snapshot, cross-row lock ordering and collation-equality holes were all removed at once by letting PostgreSQL define equality, with bounded deadlock retry; the guard is dropped when the index is `VALID`, not at a later contract; `close-epoch` got per-mode semantics, a data-safe/traffic-safe preview, heartbeat refusal and `lock_timeout`; a pending activation-plan table makes `verify <nonce>` meaningful; `software_protocol` became informational `max_observed_protocol`; phase-1 unique-index scope, an everyday-workflow sentence about epoch closure, a generated backfill-worker scaffold for cross-entity fills, corrected acceptance semantics, and the remaining drift.

A **twenty-second pass** (2026-09-03): the reservation-table guard was **withdrawn from v1** — an empty reservation table covers no pre-existing rows, a table trigger fires for the old version too, population is a backfill of its own, and the invariant and states were unspecified — and recorded as the dependent item `staged-uniqueness-guard.md`; `staging unique index` remains as a compiler-enforced two-release declaration with no runtime guard (duplicates created in the window are reported, not prevented), with a stable semantic stage identity, `tesl_schema_stages` DDL, the MIG030 family and decision-class cancellation. Also: a real `database_uuid` with `reidentify` and clone rules; activation plans gained failure codes, verified/consumed timestamps and an identity-binding plan hash; a general whole-transaction retry policy; application fills get their own `tesl_schema_backfill_jobs` and the cross-entity scaffold states its invalidation limits (dual-write or a dirty-key queue); `deploy-recipe` emits the pre-expand `close-epoch` job; `--force` output wording; phase-3 retirement drift, epoch-preserving phase-1 index test, command grammar grouping, and the stage lifecycle in the state machine.

A **twenty-third pass** (2026-09-03, new reviewer; 17 findings, 8 called blockers): accepted (1) a deployed binary had **no post-contract SQL** — `contract V<n>` drops the predecessor's compatibility objects while V<n> is still admitted and dual-writing them; fixed by emitting a **window plan and a settled plan** per statement with a process-wide monotone switch driven by a new `tesl_schema_state.compat_floor` (read by the existing fence statement, the poll, or an `undefined_column` error with whole-transaction retry; contract sets the floor, waits a bounded grace on `compat_floor_seen` in lease rows, then drops); (2) repairs no longer amend a deployed version's identity — a separate append-only prefix-compatible chain, only the final-pass executor must carry it; (3) the read-admission guarantee stated exactly (responses linearise before retirement; a paused old process's late SQL is a controlled error, not a wrong result; no streaming API so no buffering cost); (4/14) queue claim predicate bounded to the two-version window, `(schema_version, job_type)` as decoder identity, retirement **migrates** pending/dead jobs in place instead of draining, `IgnoreOld` incl. pub/sub is counted and acknowledged; (5) the existing unfenced stale-attempt race in `pgstores.go` recorded as a prerequisite fix (`claim_seq` CAS); (6) phase-3 text no longer schedules the reservation guard; the guard doc picks the GUC model and notes the deferrable/two-step requirement for key swaps; (7) catalog drift classified benign vs behaviour-affecting with a canonical fingerprint; (8) normative SQL fixed (two-int32 advisory keys in an allocated namespace, idempotent trigger pair, complete insert); (9) explicit **Contracting** state with legal retry; (10) index equivalence via normalised `pg_get_indexdef` + validity, plain build only for tables created in the same expand; (11) index builds classified as scans, not metadata-only; (12) backfill cost = new heap tuples + index entries + WAL with pause thresholds; (13) reject-capable transforms labelled MAY FAIL REQUESTS, `ONLINE` reserved for total transforms; (16) PostgreSQL promise = upstream-supported majors; (17) `copyTo` removed from the offline alternative in favour of existing mechanisms; duplicated sentence removed; READ COMMITTED and "new subsystem" principles added; normative SQL and concurrency scenarios become executable tests. Pushed back on the four-way document split (right step once the design settles, recorded as open) and on "integer ordering is insufficient" for jobs (sufficient inside the window given in-place migration; the predicate now says so).

A **twenty-fourth pass** (2026-09-03, re-review by the same reviewer): accepted (1) the queue claim predicate `[mine−1, mine]` was wrong inside an additive epoch (V1–V10 admitted, delayed V1 job, no V1 worker left) — now `[min_version, mine]`, sound because a change to an existing job type's shape is window-narrowing and closes the epoch, so shared job types are `Same` within one; the "no cross-version claim" interim was dropped (it orphans delayed jobs) in favour of typed dead letters + a MIG028 warning until `jobs:` lands; (2) trigger install is one `CREATE OR REPLACE TRIGGER` (PostgreSQL 14+ floor) — a drop/create pair leaves a committed instant with no invalidation; rule recorded: idempotence must never introduce an invariant-violating intermediate state; crash tests now interpose an old writer at every failpoint and assert safety during the interruption; (3) normative SQL fixed: generic `artefact_hash` column, complete inserts with named binds, guarded contract drops, and the three SQL block classes (normative template / illustrative / generated snapshot) with only templates executed and generated from the test fixture; (4) the next version's expand now WAITS for `contracted` (physical-name reuse over a leftover object; dependency proof rejected as complexity without a use case); (5) queue attempts store `claimed_by_version`, `claim_seq`, `lease_until` with renewal; retirement refuses renewal by retired claimants so the processing wait is bounded by one lease; retirement guarantee explicitly WEAKENED for unfenced `httpClient` effects from job handlers (same at-least-once duplicate as today; transactional effects are fenced), with drain-first or `(job id, claim_seq)` idempotency keys as the routes; (6) decision: job identity covers the payload type, not the handler — old jobs run the claiming worker's handler by design, plan header reports `HANDLER CHANGED`; (7) `tesl_admit` becomes the ONE state-returning admission API (raises if retired, returns `compat_floor`), one retry decision table for reads and writes incl. `42704`/`42883`/`0A000` cached-plan errors and pgx statement-cache clearing on plan switch; lesser: `NULLS NOT DISTINCT`/deferrability in index equivalence, semantic catalog comparison instead of `pg_get_*def` text, benign defaults limited to constants/immutable built-ins, `VALIDATE CONSTRAINT` = `SHARE UPDATE EXCLUSIVE`, guard doc notes the base-table race. New section **Test infrastructure**: failpoints/barriers, executable state-machine + invariant checker (TLA+ of the kernel as an open item), black-box fixture-app oracles, CI tiers (PR / nightly / dedicated perf — the 1% p99 budget is not decidable on shared runners), per-test isolation; nine missing cases added to acceptance.

A **twenty-fifth pass** (2026-09-03): the worked `contract V8` SQL now matches the protocol — retirement goes through `advanceAdmissionFloor` (final-pass precondition/complete functions, jobs restamp, entity generation, CAS, `retired` row, one transaction), `compat_floor` is set BEFORE any drop with a bounded grace wait, and the `CHECK … NOT VALID` add is catalog-checked (no `ADD CONSTRAINT IF NOT EXISTS` in PostgreSQL); `close-epoch` restamps pending/dead jobs of the closed versions to the survivor without decoding and checks "no non-quarantined job below `min_version`" before commit; the external-effect idempotency key is `(job id, effect site, ordinal)` — `(job id, claim_seq)` was precisely wrong (differs per attempt); `processing` rows at retirement are handled BY CLAIMANT (retiring claimant: renewal fails, expires in one lease; surviving claimant: not waited for, completion deletes, failure requeues at the claimant's version); `tesl_schema_versions.step` gets a CHECK enum incl. `retired`, whose `artefact_hash` is the retirement-plan hash, and `protocol_level`/`fence_domain` are defined as the performing binary's; `tesl_schema_meta` gets an idempotent initialisation with a database-minted `gen_random_uuid()` under the boot lease; the plan switch only fires when `compat_floor` has reached that plan's contract version, after rollback, never on ambiguous COMMIT failures, per bound database; the interim queue rule is a compile ERROR for job-shape changes (visible loss rejected); the TLA+ model is a gate for the first `min_version`/`compat_floor`-advancing slice; invariant/transition ids with generated traceability, and machine-readable classes on every SQL fence with a documentation-CI check.

A **twenty-sixth pass** (2026-09-03): companion split into a PREREQUISITE half (frozen/diffed job types, `Same`, MIG028 error) that ships with cross-version claiming and a later migration-surface half; processing rows of a surviving claimant are RESTAMPED IN PLACE at retirement (status/claim_seq/claimant/lease preserved; commutes with the claimant's CAS), so "no job below min_version" holds at the floor's commit; `jobs_retire` and the final pass are HARNESS STEPS on other connections under the coordinator's fence with plain-SQL postconditions (the undefined `tesl_final_pass_*`/`tesl_jobs_retire` functions are gone); `ADD CONSTRAINT` lives inside the catalog-checking harness step; lifecycle rows are recorded by insert-or-VERIFY-hashes (never bare `on conflict do nothing`); bootstrap initialisation under `pg_advisory_xact_lock(32341, 0)` with `current = 0` until the first expanded row; effect identity = explicit `@effect "name" [key: expr]` (compiler-assigned site ids rejected as unstable across versions; MIG029 for loops without a key; un-annotated sites listed AT-LEAST-ONCE); epoch restamp range `[old min_version, n-2]` with its own `tesl_schema_queue_restamps` table; companion stale guarantee reworded per stage; five tests added.

A **twenty-seventh pass** (2026-09-03, fresh reviewer; the whole document read and its
claims checked against `compiler/lib`, `runtime/go/teslrt` and `tests/`): fixed (1) the
worked example's `updateContent` — the SQL snapshot claimed `wordCount` was "recomputed
in Go", which nothing can do (the row function is `V7 -> V8`, there is no `V8 -> V8`), so
the handler now sets `wordCount` and a new §4 rule says a row function fills a derived
column and never maintains it; (2) "proof removed" was classified additive — the old
binary trusts a proof nothing enforces and rows are never re-validated on decode, so it
is ROLL-WINDOW RISK and window-narrowing; (3) the read-admission default is REOPENED to
`Trusted`: `Strict` turns a correct post-retirement read into a 500 and cannot prevent
the post-contract failure because the query runs first — its payload is row-level
policies, not in v1; (4) the normative fence SQL used a fixed `32341` namespace while
the prose said `fence(schema, n)` — advisory locks are per database, so two schema
families would block and mis-refuse each other; the key is now the database's
`fence_ns` from `tesl_schema_meta`; (5) read-modify-write cost restated as O(matched
rows), paged by primary key, with MIG031 for non-PK-keyed updates; (6) the backfill's
conditional predicate compares the tuple `xmin` instead of shipping every source value
back; (7) a partial marker index (`where _tesl_v < g`) serves backfill, final pass and
the retirement count; (8) the HOT statement corrected (any indexed column change costs
an entry in every index); (9) advisory locks bypass the fast path, so the fence is a
`LockManager` hot spot at high write rates — noted with striping and the trigger
alternative as benchmark candidates; (10) syntax: interpolation is `${x}`, `tesl test`
is not yet a CLI route, an entity named `Legacy` beside the `Legacy` rule renamed; (11)
inconsistencies: PostgreSQL floor 14 everywhere, `tesl_schema_state`, `artefact_hash`,
the offline path's non-existent `'backfilled'` step, a duplicated table header; (12)
transaction retry and the external-effects rule marked as new language semantics
(`WithTransaction` has neither today). Verified true: bootstrap has no `ALTER`
(`postgres.go:226`), `TInt` maps to `NUMERIC` so the example's column types are right,
entity fields accept `:::`, `List.allCheck` exists, selects decode whole rows, the queue
`complete`/`fail` are keyed by id alone (`pgstores.go:422,431`) so the `claim_seq` bug
is real and pre-existing. Added to "Decisions before phase 1", as reopened or new:
catalog-reconciling additive phase 1 without schema modules; a live module plus frozen
snapshots layout (the PR-diff problem, raised by the maintainer); lazy `OnRead` as the
default transform tier with `Materialise` opt-in (the maintainer's codec question: pure
codec-only is insufficient because unstored values cannot be used in SQL, but as the
default tier it makes `Rename` free and confines the runtime protocol to materialised
columns); dropping the frozen stdlib slice / ABI / primitive tags; the proportionality
of the activation ceremony; the `where` over-approximation.

A **twenty-eighth pass** (2026-09-03, external re-review of the twenty-seventh): accepted
(1) the phases and the reopened decisions described two architectures — a normative-status
note now says the Phases/layers/acceptance sections are the single normative cut, the
reopened items are recommendations, and under a catalog-only phase 1 the control schema,
database identity, job-shape history and fence move to a phase-2 prerequisite slice
because cross-version queue claiming needs them; (2) the bootstrap template created the
control tables before taking the bootstrap lock, seeded `min_version = :v` (so a V9 seeder
would have refused a V8 that won the lease) and had no transition out of `current = 0` —
the lock now precedes the first CREATE, the seed is `min_version = current = 0`, and an
initial-expansion template with recovery and the two race outcomes is specified;
(3) the normative SQL wrote `min_version` with raw updates while claiming a single
transition — `tesl_advance_floor` is now a control-schema function that checks protocol
coverage, fence domain, exclusive-key ownership from `pg_locks`, entity finality and the
queue postcondition, then CASes the floor and records the `retired` rows; (4) lifecycle
rows were raw inserts whose duplicate would abort the transaction — `tesl_record_lifecycle`
is the sole writer, insert-or-compare without aborting, moving `current` (and the initial
`min_version`) in the same statement; (5) three processing-row rules collapsed to the one
claimant rule (retiring claimant: lease lapses then restamp; surviving claimant: restamp
in place immediately), in both documents; (6) the effect-key tests still said `(job id,
effect site, ordinal)` and the wire key was a raw delimited string — now `(job id, effect
name, key)` with a domain-separated SHA-256 header of fixed length and no payload bytes;
(7) MIG029 was assigned twice — the effect diagnostic is MIG032 and MIG028/MIG032 are in
the registry table; (8) the constraint helper compared `pg_get_constraintdef` text while
the acceptance criteria forbade `pg_get_*def` identity, and defaults were attributed to
`pg_attribute` — one comparator is defined (both expressions deparsed by the same server
under an empty `search_path`, the expected one via a rolled-back temporary table;
defaults from `pg_attrdef.adbin`; volatility via `pg_depend` → `pg_proc`); (9) `OnRead`
restricted to derived columns the application never writes — a written `Retype` needs
`Materialise` or a reversible codec; (10) the ABI recommendation revised to "record, do not
freeze": a `compiler_abi` identity on every lifecycle row and a refused-by-default,
recorded `--accept-abi-drift` override — pushing back on a hard prohibition, which would
make every compiler upgrade wait for every environment's in-flight migrations. Eight
acceptance scenarios added or corrected (bootstrap crash, both race outcomes, each floor
prerequisite absent, live-transaction duplicate handling, semantic equivalence, default
classification, paused surviving claimant through close-epoch, effect-key
canonicalisation).

A **twenty-ninth pass** (2026-09-03, external re-review of the twenty-eighth): accepted all
nine findings. (1) The boot lease was not mutual exclusion — a holder paused past expiry
and a second version taking the lease could both install (and `create table if not
exists` at V9 adopts a V8-shaped table, so "every step is idempotent" was false across
versions); the guard is now a session-level advisory boot lock (`fence_ns`, key
`2147483647`) on the DDL connection, the lease row is a handoff record that its holder
may renew; (2) `tesl_advance_floor` accepted reversed, empty, beyond-`current` and
gapped ranges and would have written a synthetic `retired` row for a version that never
expanded — it now checks increasing bounds, `next <= current`, exactly one `expanded` row
per version, none already retired, and `min_version = expected` before any other work;
(3) `tesl_record_lifecycle(…, q smallint, …)` was called with a bare `0`, which
PostgreSQL does not narrow in function resolution — the parameter is `int`, range-checked
and cast; (4) the normative bootstrap created `notes_app.tesl_schema_meta` on a database
with no `notes_app` schema — `create schema if not exists` plus an owner check follow the
bootstrap lock; (5) drift classification let a nullable column with `DEFAULT nextval(…)`
through and relied on a `pg_depend` walk that cannot see pinned built-ins — benign is now
"insert can omit it AND the default is literal-only"; collation and identity join the
fingerprint and the comparator's temporary columns; (6) §14 item 2 still said processing
rows are waited for — replaced by the claimant rule; (7) phase-2 acceptance depended on
`jobs:`, `@effect` and MIG032 — `@effect`/MIG032/canonical key moved into phase 2
explicitly, the transforming V11 test relabelled to the dependent item; (8) the
effect-key preimage used a `0x1F` delimiter, which hashing does not disambiguate — now
length-prefixed components and a frozen scalar encoding for `key:` (String/Int/Bool or
newtypes over them; anything else is MIG032); (9) the `--accept-abi-drift` override gave
audit but not consistency — allowed only before the first migrated row, otherwise finish
on a same-ABI build or reprocess under a new generation; retained lowerings still
rejected. Eight test cases added or adjusted as requested.

A **thirtieth pass** (2026-09-04, maintainer's questions): (1) who runs the backfill, how
parallel, how long — the executor runs it as goroutines, sharded by primary-key range
(`TESL_BACKFILL_CONCURRENCY`, `tesl_schema_backfill_shards`) under one throttle
controller; cross-instance sharding is available but not the default because the
primary's write path is the shared bottleneck and a distributed throttle would
oscillate; `Derived` migrations whose rules are SQL-expressible backfill in pure SQL; the
load table gained honest 100 M and 1 B rows rows (hours, days) with the ways out
(`OnRead`, pure SQL, staged `Maybe`), and the text states that a slow backfill delays the
contract, never correctness. (2) How the developer knows the migration may be contracted
— the condition is named *contractable* and exposed through OpenTelemetry (gauges
`tesl_schema_contractable`, `tesl_schema_old_instances`, event
`tesl.schema.contractable`), `--schema status`, a blocking `--schema await contractable
V<n>` for pipelines, and `contract`'s own refusal messages.

Same day, maintainer's correction: the non-propagating proof boundary a row function
needs is the existing `establish` (`-> Maybe (v: T ::: P v)`), not a new `Check.attempt`
intrinsic — the intrinsic, the `Attempt` type and the `Tesl.Check` module are withdrawn;
the schema module declares one `establish` per column fact, the handler-facing `check`
delegates to it, the row function pattern-matches on it and supplies the `Reject`
reason itself; the seal (MIG019) and the `Same` closure cover `check` and `establish`
alike.

Same day, maintainer's requirements: (1) a crash of the first executor of a new version
must be resumed by another without starting over — a per-job crash-and-resume table now
states what each job loses, how the successor resumes (shard cursors in
`tesl_schema_backfill_shards`; the marker makes even a lost cursor a scan of remaining
rows only; a V9 executor resumes V8's backfill), and names the one job PostgreSQL cannot
resume (`CREATE INDEX CONCURRENTLY` starts over); `TESL_LEASE_TTL_S` added; acceptance
on a 100 M-row fixture with kills at every failpoint. (2) OpenTelemetry must report
progress, not only completion — progress gauges, rates, ETA, throttle reason, index
build progress from `pg_stat_progress_create_index`, executor identity and resume/throttle
events added, with an acceptance criterion.

Same day, maintainer's question "how does a successor know to resume rather than keep
waiting?": the boot lock needs no polling (PostgreSQL wakes the blocked successor when
the holder's session ends) but had a half-open-TCP gap — per-session
`tcp_keepalives_*` GUCs on the executor's connection close it; leases now record the
holder's `pid`/`backend_start`, the successor takes over immediately when that backend is
absent from `pg_stat_activity`, waits while it is present and renewing, and
`pg_terminate_backend`s it (same role, no superuser) when present but expired — so
"dead or stuck?" is a server-side fact plus an enforced answer, not a guess; renewal
runs outside batch transactions so a slow batch is never mistaken for death. Privilege
table, lease DDL and acceptance scenarios updated.

Same day, maintainer's four questions: (1) why Repair exists — the row function is
immutable once expanded (hash recorded, running on lazy paths, rows already produced), a
rebuilt V8 with another hash is refused, and V9 cannot carry the fix because V9 cannot
expand until V7 retires while rejected rows block that retirement; Repair is the only
forward channel for a code-level fix, now explained in §6 and flagged as first to cut if
"fix the data through the app" covers practice; (2) `Money` and other multi-column fields
— every mechanism is stated over the field's column set, which the emitter already owns
(`entity_columns`), spelled out in §3; (3) the facade needed re-exports, which Tesl lacks
by design — facade and the re-export decision withdrawn, making the live-module layout
the only import-stable layout; (4) a new section "The developer-facing surface (spec)"
shows the complete code a developer writes end to end, counts the new constructs (five,
no keywords: module references in `Database`, `todo`, the `Migration`/`Contract`/`Repair`
records, `@column`, `staging unique index`) and lists what was deliberately not added
(`schema module`/`entity module`/`shared module` kinds, the root map and `R<k>`
revisions, `reexporting`, `Check.attempt`, a `version N` header).

Same day, maintainer's proposal for the facade/diff problem: `tesl migrate` copies the
current schema module to `V<n>` first, the developer then edits `VCurrent`; at V9 the
repository holds `VCurrent`, `V8`, `V7`; the diff shows only the change and no import
ever moves. This is the reopened live-module layout under a clearer name and is adopted
as the recommended layout in "The developer-facing surface"; the copy-failure modes are
analysed there (manifest write is atomic; an un-frozen edit is MIG001 with one
developer question; a wrong answer is caught by the boot gate exactly as an edited
`V8.tesl` is today; a corrupt frozen copy is MIG013). The large-schema root no longer
re-exports entity types (Tesl has no re-exports): applications import entity modules
directly, still under `VCurrent`.

Same day, maintainer: the `VCurrent` layout is DECIDED. §1 rewritten for it (no `schema
module` kind, no root map, no `R<k>` revisions, version derived from the frozen
snapshots, freeze-by-copy first, imports never move); mechanisms table and phase 1
updated. Repair scoped to the two migrations a binary embeds (`V<n-2> → V<n-1>` and
`V<n-1> → VCurrent`), MIG026 otherwise — the maintainer's "previous version only" is
right in spirit and off by one, since the next version's contract runs the previous
migration's final pass; the "empty or very old database" worry does not arise because an
empty database installs directly at `VCurrent` and a database behind by two transforming
versions is refused by the boot gate.

Same day, maintainer: a restored backup or curated test snapshot at V50 must not require
a team to reconstruct and redeploy the exact chain of versions to reach V57. Added §8b
**catch-up**: `app --schema catch-up` replays every missing version sequentially under
the exclusive fence of every version from `min_version` to the target — the same proof
of "no writer exists" that `apply-offline` and every retirement use, so nothing is
weakened; per version it expands, runs the migration to final, applies repairs,
retires, contracts, and resumes from any state a crash or point-in-time restore left.
Consequences: a binary embeds every committed migration/repair/contract (the serving
path still uses only the two most recent); `prune` becomes decision-class with a
recorded "snapshots older than V<k> cannot be caught up" statement; the repair-scope rule
(MIG026) refuses only *adding* a repair to an old migration, existing ones stay for
catch-up; a differential acceptance test requires catch-up to produce a database
identical to one driven live through the same versions.

A **thirty-first pass** (2026-09-04, external review of the `VCurrent`/catch-up revision;
thirteen findings, all accepted, two with a chosen remedy): (1) paged RMW gave each page
its own snapshot — one server-side cursor now fixes the target set as a native `UPDATE`
does; (2) staged uniqueness only moved the livelock from V7 to V8 — promotion is now a
three-release recipe with a compiled per-key advisory-lock guard in the promoting
version and the build inside that version's contract, or an explicit bounded write
stall; (3) takeover terminated only the lease connection — every executor connection is
tagged by `application_name`, all are terminated, and the successor waits until none
remain; (4) catch-up (and `apply-offline`) did not prove the fleet was gone because
`Trusted` readers take no fence — a connection barrier (`revoke connect`, terminate,
wait) precedes both, with a recorded platform barrier as the alternative; (5) catch-up
now normalises the current version's partial state before expanding the next, with
session-level fences on the coordinator; (6) "unique index over new columns" was not a
sufficient additive condition — the test is every column new, nullable, default-free,
not row-function-filled, `NULLS DISTINCT`; (7) the frozen-execution and
record-`compiler_abi` models are now labelled where they coexist and named the one
execution-model decision the maintainer must close before phase 3, with catch-up's
argument for recording; (8) repairs are retained and may be added for any committed
migration, since catch-up can apply them — the earlier MIG026 clause is withdrawn and
the remediation for an old snapshot's rejected row is a repair or an acknowledged
delete; (9) freeze closure boundary, reference rewrite and alpha-renamed canonical IR
hashing specified; (10) one executable admission algorithm replaces the two readings of
the boot gate; (11) the last lease-as-guard wordings replaced by the session boot lock;
(12) lifecycle recording split into a private core and validated SECURITY DEFINER
transitions owned by a new `tesl_control` role, `retired` reachable only from
`tesl_advance_floor`, negative tests for every illegal edge; (13) stage identity includes
deferrability and the companion's deferrable reservation index is rejected. Acceptance
inconsistencies fixed (`lower('X')`, "facade in use", MIG030 registry row, catch-up in
the command summary and phase 4) and eight scenarios added.
