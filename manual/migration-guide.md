# Authoring and rolling out a migration

`tesl migrate app.tesl` prepares checked source files. It does not connect to your
application database or convert stored data. Deployment runs the resulting
application binary with separate Installer, Worker and Request database roles.

## Work through one revision

1. Edit `schema/<family>/v-current.tesl` (add, rename or change fields) and save,
   then run `tesl migrate app.tesl` in an interactive terminal. When your saved
   edits are newer than the latest revision, the wizard asks once: press Enter to
   start the next revision with them. It backs your edited files up under
   `.tesl-stuff/migrate-edits/`, restores the exact source the latest revision
   recorded (taken from git and checked against the recorded SHA-256), freezes it
   as before, starts the new revision and puts your edits back. Press `r` instead
   only when the latest revision is an undeployed draft you meant to change. You
   can also run the wizard first and edit when it asks. Use
   `tesl migrate app.tesl --resume` to continue an existing undeployed revision.
2. Save the current schema changes. Refresh produces the compiler's proposed
   migration, preserving user-owned conversion code. Read the overview and work
   through the remaining decisions. Enter a displayed compiler option number to
   write its scaffold directly into the migration files. `?` expands help, `n`
   advances, and Enter refreshes and rechecks saved changes. Save editor buffers
   before using the CLI: its choices update saved files.
3. Fill the typed holes with the business decisions the compiler cannot infer.
   Each hole is a `todo "..."` that names what to choose; a rejected-row policy is
   generated as `Reject (todo "Reason to reject ...")`, so replacing the text gives
   a reason and replacing the whole `Reject` chooses another policy. Generated
   files keep one import per module and pass `tesl fmt --check` and `--lint`.
   A rename can copy the exact old field; a new default needs a value you choose;
   a changed representation needs a converter; a changed proof may also need a
   reverse converter so old code can keep writing during overlap. Suggested
   options explain these choices; they do not authorize data loss or make an
   unchecked template safe.
4. Run `tesl agent-context app.tesl` after edits. Inspect
   `tesl migrate plan app.tesl`, add application and conversion fixtures covering
   real historical values, and run their tests. Generate the required cleanup
   proposal with `tesl migrate contract app.tesl --version N` and review it before
   building the deployment artifact. The wizard's final summary lists the table,
   column and index changes and the exact next steps derived from the plan: a
   prior Contract that must have run, `--schema close-epoch` before the first
   transforming revision or a unique index that older versions could violate, the
   Worker-first deploy order, and the Contract to run after old processes stop.
   When a Contract is required and its source is missing, it offers to write it.
5. Choose the deployment route below. Source generation, compilation, a passing
   fixture and runtime readiness are separate checks. None substitutes for the
   others.

Explicit commands also work in scripts:

```sh
tesl migrate generate app.tesl --manifest-json
tesl migrate generate app.tesl
tesl agent-context app.tesl
tesl migrate plan app.tesl
```

`tesl migrate generate app.tesl --new-revision` handles already-saved schema edits
the same way without asking: it starts the next revision, reapplies the edits,
lists them in `editsReapplied` and reports progress on stderr. Run
`tesl migrate generate app.tesl` afterwards to refresh the new revision with them.
Both paths refuse without changing files when the recorded source cannot be found
in git; then copy your edited schema aside, restore the recorded file, start the
revision and reapply the edits by hand.

`--manifest-json` is a non-mutating guarded source preview. The guided writer
requires an interactive terminal and its supported filesystem protections;
portable previews do not imply portable source application. Keep every frozen
schema, migration, codec and reviewed Contract that the retained history needs.

## Apply choices in VSCodium

You do not need to write a migration declaration, choose internal storage column
names, or wire forward/reverse helpers yourself for the supported scaffolds below.
Describe the change in your current schema; Tesl proposes the migration structure.
Your inputs are domain values and policies, such as what an existing row should
receive for a new field or what to do with a value rejected by a stricter rule.

Install extension 0.7.21 or later with a matching compiler and language server,
then reload the editor. Open **Tesl: Migrate database/queues** from the Command
Palette, editor/explorer context menu, migration lightbulb or CodeLens.

**Start before editing `v-current.tesl`.** Opening the workflow only displays a
short welcome page. No compiler proposal is requested and no source files change
until you press **Start migration**.

1. **Prepare.** Press **Start migration**. Tesl checks and freezes the current
   schema, then creates the next migration through the guarded source writer.
   For the V13 example, this prepares V14; it does not refresh V13 with your new
   changes. Wait for **Draft V14 prepared — Now edit your schema**.
2. **Edit.** Change fields, validation or queue payloads in the current schema
   opened beside the workflow. Press **Review my changes**. Temporary stale-schema
   warnings are expected while editing this prepared draft.
3. **Choose and fill.** Select a compiler-proposed plan and press **Generate this
   plan**. Tesl writes the boilerplate and selects a whole domain placeholder.
   Replace it with your value or policy, then **Recheck and continue**. Editing
   source makes rechecking the primary action rather than reopening an old hole. Simple
   automatic proposals instead offer **Write migration files**.
4. **Check and test.** If the compiler requires cleanup, **Review cleanup** shows
   the proposed `vN-contract.tesl`; **Add reviewed cleanup source** writes it and
   rechecks. **Your migration source is ready** means the reviewed source passes
   compiler checks and required cleanup source exists. **Save and run application tests** saves this project's
   dirty Tesl buffers, rechecks, then runs the tests. The guide shows progress and
   reports the Test Explorer runner's result. It does not report a pass for failed,
   cancelled, empty or unreported runs. Source changes during tests invalidate the
   result for this draft.
5. **Finish.** After passing tests, **Finish and close** is the primary action.
   It saves and rechecks source, keeps your files, and clears the active-draft
   marker and Cancel backup. Reopening offers a new migration. Closing the tab
   after a confirmed successful run also remembers authoring as complete.
   **Start next migration** is visible on the final page. Deployment remains separate.

The draft number and phase remain visible. Reopening a remembered draft offers
**Continue migration V14** and verifies that revision before continuing. A draft
completed with an older extension can still have this marker: continue once and
choose **Finish and close**, or use **Start a new migration instead** on the welcome
page. Closing unfinished work retains its draft marker. A draft
prepared elsewhere can be selected through **Already have a draft?**. If schema
edits were made before Start, the editor preparation refuses rather than silently
changing the old revision. Run `tesl migrate app.tesl` in a terminal to keep those
edits as the next revision automatically (see above), or keep them separately,
restore the old source, then Start and reapply them. Continue the old revision only
if that was explicitly your intended undeployed draft.

Application discovery uses `[project].entrypoint` in the nearest `tesl.toml`.
Opening the whole repository and starting from
`example/db-migration-example/schema/todo/v-current.tesl` selects that example's
`todo-app.tesl`. Only missing entrypoints or multiple reachable databases require
a picker. Database and queue authoring share this source-revision workflow;
the compiler still checks which changes require separate ordered revisions.

**Back** returns to the previous step and keeps your edits. **Cancel migration**
first shows a discard confirmation. For drafts started by this workflow, confirming
Cancel restores the selected family's `.tesl` files under `schema/<family>/` and
`migrations/<family>/` from the private backup captured at Start. It removes files
created during the draft and preserves pre-existing unsaved buffer contents.
Other application files and other schema families are not restored. Cancel is
for an undeployed source draft, not a database rollback.

The backup persists across editor restarts. Changes made after the cancellation
review require another review; an incomplete restore retains its backup for a
retry. A later migration revision or an active source-update journal prevents
discarding the older draft. Drafts created by older tools without a Start backup
can be closed with their files kept, but cannot be automatically restored.

Prefer completion? Under **Details and source changes**, apply **Write proposal without choosing a plan**, put the cursor on an
unresolved `todo` decision, and press **Ctrl+Space**. The completion list offers
the compiler's complete plans with explanations, not just individual migration
keywords. Accepting one fills its multi-file boilerplate and selects the whole
remaining placeholder expression. Type your domain value or code over that
selection. If the editor has not selected an application yet, **Set up migration
choices…** starts the guided flow. No copying from a preview or manual import
editing is needed. A stale choice asks for a fresh preview instead of overwriting
newer edits.

The single **Migrate database/queues…** CodeLens opens the start-first workflow.
Repeated identical diagnostics appear only once. General background is available
separately through **Tesl: Migration Reference**. Low-level source previews remain
available through diagnostic actions and the internal `tesl.previewMigration`
command, separate from starting a revision.
**Generate this plan** writes the scaffold into actual files or open buffers,
selects remaining domain logic and rechecks. The diff view is for review; there
is no manual copy/paste step. See the
[extension setup](../editor/vscode-tesl/README.md) if CodeLens or completion is missing.

Dirty buffers stay unsaved until you save them. A stale preview or changed buffer
refuses instead of overwriting your edit: request a fresh preview. The editor
checks exact text, versions and open/close lifetimes before and after application.
If an outcome is unknown or requires recovery, preserve buffers and the
`.tesl-source-edit` journal, and use **Check application outcome**. Follow its
guidance before starting another operation. Automatic reconciliation after a
server restart is not implemented; an editor-pending journal deliberately refuses
disk-only recovery. Saved-source publication requires Linux filesystem protections.

### Supported changes and your remaining inputs

Plans use the checked old and new schemas. They fill imports, exact type/proof
signatures, row or payload mappings, migration rules and historical fixture
structure. These are the main authoring routes:

| Schema change | Generated plan | Your inputs |
|---|---|---|
| New required primitive columns | Literal defaults, or a row-dependent mapping | Default values or expressions |
| Add columns while changing existing fields | One composed row mapping | Added values, conversions and any rejection policy |
| Rename one or several columns with unchanged contracts | Explicit rename candidates; a pure rename uses `Derived` | Select which old field corresponds to which new field |
| Remove columns | Retain old storage and generate `LegacyWith` helpers for old writers | Values satisfying the removed fields' historical contracts. A removed `Maybe` field is filled with `Something Nothing` (old binaries store NULL); `Nothing` would refuse their writes |
| Optional → required | Preserve present values and handle missing ones | Missing-value policy |
| Required → optional | Wrap existing values; generate historical write-back | What old writers receive when a new value is missing |
| Add field-local proofs | Checked revalidation where supported, including multiple primitive fields | Valid fixture values and failure policy |
| Change or remove proofs | Reuse exact exported validators; generate historical write-back | Rejection policy and any validated historical fallback |
| Change stored records or JSON codecs | Rebuild values with the exact current/historical constructors and codecs | New fields and conversions that cannot be inferred |
| Add/remove concrete ADT variants or change their payload fields | Exhaustive forward/reverse cases | Mapping for removed variants, new payload values and reverse compatibility |
| Nested `Maybe`/`List` record values | Recursive typed adapters preserving container structure | Remaining nested field values or conversion policies |
| Change queued record payloads or their codecs | Pure helper module with exact payload types and a historical fixture | Added values, renamed-field/variant mappings and any rejection reason |
| Remove a whole queue | Explicit `RemoveEmpty` retirement | Confirm that retirement must wait until the queue is empty |

Renames are choices, not guesses. A field that disappears and another that appears
may instead be a removal plus an addition. Removed-column helpers supply values
for new writes during old/new application overlap; cleanup of retained storage is
a separate checked step.

Validator reuse requires a uniquely matching exported pure `establish` returning
the exact proof-bearing `Maybe` type. This also supports record-valued fields.
Missing or ambiguous validators leave typed conversion holes where the shape is
supported. More permissive validation still changes the proof contract: new values
may fail the old check. Historical fallbacks can lose information; tests should
cover both conversion directions and actual old values.

**Current limits:** table/primary-key changes, cross-field reverse proofs, private
historical APIs needed by a converter and generic stored ADT conversion have no
automatic plan. Export needed APIs in a compatible preparatory revision; do not
amend frozen history. The compiler also refuses mixed row/queue-payload changes:
finish the row revision and its required cleanup, then start a queue-payload
revision with stable queue membership. Moving, renaming or removing individual
job kinds is not supported by this queue route. Index changes still require the
physical-plan and rollout checks; a field scaffold does not establish index
readiness. An empty choice list means no supported generated plan for that shape.

Cleanup source records exactly which old columns, tables or constraints may be
retired. The editor previews it before writing. Start refuses another revision
when required cleanup source is missing, so its absence cannot be frozen into
history. Writing a Contract does not execute cleanup: runtime still checks
conversion completion and retirement of old writers.

### Example: make an optional string required

Change `details: Maybe String` to `details: String`, and update your application's
constructor for new rows. **Review my changes** now offers **Keep existing values
and fill in missing ones**. Choose it, then **Generate this plan**.

Tesl preserves every existing `Something value`. It selects a typed placeholder
asking what to use for `Nothing`; enter a String such as `"No details"`, or an
expression using the historical row, such as `old.title`. It also
generates the historical write-back (`Something current.details`), row mapping,
storage rules and imports. The same bounded conversion supports optional `Int`,
`Bool` and `Float` becoming the same required primitive type without extra proofs.

For test fixtures, a uniquely matching exported historical constructor is reused
when its primitive parameters and proof validators can be resolved exactly. In
the Todo example, you supply just an example ID and a valid historical title;
Tesl fills unrelated fields and the old validation call. Other shapes retain
explicit historical row-value placeholders. These are test inputs, not defaults
for production rows.

Incomplete helpers report **Migration needs a value**, with the field or example
being requested, instead of the unrelated `unknown name: todo` error. Use the
selected placeholder or **Fill value or policy**, enter the value, and recheck.

A scaffold with holes cannot build or deploy. Complete the code, inspect its
diagnostics and test historical values before reviewing the deployment plan.
Selecting an option prepares source and never executes database work.

### Example: change a queued record and its JSON keys

Suppose `Notify` changes from `{ text: String }` to
`{ body: String, priority: Int }`, with `body` encoded under the JSON key
`"message"`. Update the current record and both codec directions, then review.
Choose the queued-payload mapping plan. Tesl creates a pure helper such as
`migrations/notes/v2/author-notify.tesl` and focuses its missing inputs.

For this rename, supply `value.text` for the new `body` and your chosen priority
for retained jobs. Supply a representative historical `text` for the fixture.
Tesl fills the old/new payload signatures, constructor, codec-owned conversion
and migration declaration. Queue-only conversion needs no row write-back helper.
Recheck and run the generated/application tests. A rejected job remains retained;
the scaffold never chooses to discard it.

### Example: changing a stored title's validation

Suppose the exported `accept` establish function now rejects `"blocked"`, while
the frozen version only rejected empty titles. After refreshing the draft, choose
**Reuse existing validators for changed field proofs**. Tesl generates:

- The call to the current schema's `accept`, plus `Nothing`/`Something` handling.
- The new row, copying unchanged fields and inserting the validated title.
- `Retype title`, its compiler-owned storage column, and `WriteBack` with the exact
  historical proof type.
- A call to the frozen schema's `accept` for historical writes, returning its
  validated value on success.
- Required imports and the historical fixture structure.

You supply the rejected-row policy and representative fixture values. Historical
write-back may return `Nothing` to refuse an incompatible write. An optional fallback is a business
decision; it is not necessarily a lossless reverse conversion. Review validators
that normalize values and test both directions. If only a `check` function is
available, the generic typed converter scaffold remains available; this shortcut
requires a pure `establish` returning the exact `Maybe` proof type.

### Fallible historical write-back

`WriteBack` and `LegacyWith` accept ordinary pure functions returning either the
historical field type directly, or `Maybe` of that exact type. Attached historical
proofs remain required on the successful value. Generated validators use `Maybe`:

```tesl
fn writeBackTodoTitle(current: Schema.Todo.VCurrent.Todo)
  -> Maybe (title: String ::: Schema.Todo.V14.ValidTitle title) =
  Schema.Todo.V14.tryTitle current.title
```

`Something` supplies the old representation. `Nothing` refuses the entire new
write transaction while historical columns are required, rolling back earlier
writes in that transaction. It does not discard a row, fabricate a proof or trap
through an HTTP check. After Contract retires the old columns, their write-back
callbacks are no longer required for current writes.

During Worker backfill, an exact historical row already exists. If optional
write-back refuses its converted value, the Worker preserves that original old
projection, under the same tuple-version check as the conversion. No invented
default is needed to finish converting existing rows. Application inserts and
updates have no such fallback. Runtime traps and codec failures always abort;
they are not treated as `Nothing` decisions.

If a business fallback is meaningful, validate it normally in the new migration:

```tesl
fn writeBackTodoTitle(current: Schema.Todo.VCurrent.Todo)
  -> Maybe (title: String ::: Schema.Todo.V14.ValidTitle title) =
  case Schema.Todo.V14.tryTitle current.title of
    Something title -> Something title
    Nothing -> Schema.Todo.V14.tryTitle "business fallback"
```

An invalid fallback also returns `Nothing`. There is no compile-time evaluator,
literal-proof shortcut or migration-specific exception to exhaustive matching.
`Maybe.fromMaybe` is not currently a Tesl export; a default-taking unwrap would
need an already valid default and would not establish a proof. Use ordinary case
handling to preserve the validator's proof. Frozen schemas remain unchanged.

### Explicit row deletion

Choose **Convert retained rows and explicitly delete obsolete rows** when a
removed ADT variant should have no replacement row. The compiler scaffolds a
deletion predicate, reason and conversion for retained rows. There is no need to
add an `Unknown` variant in advance. The ordinary result type is:

```tesl
type RowChange a = KeepRow a | DeleteRow String | RejectRow String
```

Import `RowChange(..)` from `Tesl.Migration`. `Migrate` accepts
`From.Entity -> RowChange To.Entity`; existing `Migrated` row functions and queue
conversions retain their `Row`/`Reject` result unchanged.

- `KeepRow` supplies the complete checked target row and preserves its primary key.
- `DeleteRow reason` explicitly selects the entire source row for deletion.
- `RejectRow reason` retains unresolved data and prevents successful completion.

A rejected stored row stays in its old representation. The ongoing Worker leaves
it unconverted, keeps converting the other rows, and reports the entity and
primary key on its standard error after each pass; the reason text is not
repeated there. Contract refuses to retire the old version while the row remains
and names the same key. Repair the row through the admitted old version, or
change the migration's policy in a new undeployed revision, then let the Worker
pass again.

The Worker physically deletes only the exact source tuple it decoded, using the
same generation, xmin, transaction-age and lease checks as backfill updates.
Deletion, processing-ABI latching and progress commit together; crashes roll back
uncommitted work and database constraints remain enforced. The `rows_done` progress
count includes both converted and deliberately deleted rows.

Reads never perform migration deletion. A new-version request encountering a
pending deletion reports that Worker processing is required; once deleted, the
row is absent. An old writer can change or recreate a row during overlap: a stale
deletion is skipped, and later passes re-evaluate the new source row. Contract's
final pass and old-writer retirement close that window. An explicit application
reinsert after retirement is a new application operation, not migration replay.

### Squiggles, completion and lightbulbs

Schema and migration files use the same live compiler diagnostics as application
files, including unsaved changes. Draft hash mismatches show a warning squiggle;
frozen-history mismatches remain errors. File-level migration diagnostics underline
an available character instead of using an invisible zero-width marker.

Migration lightbulbs open **Migrate database/queues** or **Inspect migration source
diagnostics**. Ordinary compiler-provided
mechanical fixes remain available through the LSP. Semantic decisions require
choosing an option; Fix All cannot invent a rejection or data-loss policy.
`MIG013` offers guidance rather than regeneration of frozen history.

CodeLens appears on application `database` declarations, current schemas and
migration/Contract declarations, with a file-level entry in other `schema/` and
`migrations/` files, including incomplete drafts. Enable `editor.codeLens` if
hidden. Use **Ctrl+Space** at a generated migration decision for complete
multi-file scaffolds. Elsewhere inside a migration declaration, completion offers
contextual fields and constructors with their requirements for manual authoring.

## Same proofs and changed meaning

`Same Old.Valid New.Valid` means the compiler verified the complete reached
semantic closure, including the relevant checks, proof-producing functions,
helpers and codecs. A matching name or carrier type is insufficient, and manually
adding `Same` cannot bypass the closure check. The closure includes the fact's
name, so `Same` cannot express renaming a fact either: a renamed fact goes through
the same `Retype` conversion as a changed one.

| Your change | Supported decision |
|---|---|
| Comments or unrelated helpers change while the reached meaning is unchanged | Keep the compiler-verified `Same` entries. |
| Add a field's first proof without changing its stored value | Use the checked `Revalidate` path and a check for the new proof. |
| Add a field-local conjunction while retaining every historical proof unchanged | `Revalidate` can retain those exact proofs through verified `Same` evidence and establish the additional proof. |
| Replace an existing proof's meaning, such as changing a bound from `n >= 0` to `n > 0` | Do not mark it `Same`. Use the supported `Migrate` / `Retype` path, plus `WriteBack` returning the exact previous proof when required for rolling overlap. |
| Make an existing check more permissive, so every old-valid value still passes | Still a changed proof, not `Same`. Choose **Reuse existing validators for changed field proofs** when offered, or a custom conversion. Newly accepted values may fail the old check; supply an old-valid reverse policy while old writers remain. |
| Change a record/ADT representation or codec | Use the checked conversion path; a same-shaped source declaration does not establish codec identity. |
| A reverse converter or historical value cannot satisfy the required old/new contract | Reconsider the business policy or use a supported staged design. Do not weaken the old proof, rewrite frozen history or assume the change is online. |

`Revalidate` checks the same stored value; it is not a general replacement for
changed historical proofs. Current reverse-proof support is field-local, not a
general solution for cross-field facts. The compiler's refusal is part of the
compatibility contract.

For example, increasing a title limit from 120 to 200 accepts every previously
valid title. A new 150-character title still fails the historical check. Decide
how to represent that value for old writers, or keep new writes within the old
limit until those writers are retired. A fallback or truncation is a business
decision, not something the compiler infers. Old-to-new acceptance alone does not
prove unchanged meaning or a lossless reverse conversion.

Worked examples: [adding a proof](../example/learn/lesson89-proof-revalidation.md),
[changing an existing proof](../example/learn/lesson90-changing-field-proofs.md),
and [retaining old proofs while strengthening a field](../example/learn/lesson94-same-column-proof-strengthening.md).

### What is checked at runtime, and what is trusted

Proofs are checked where values are produced. A migration re-establishes them
when it converts a row: every old-generation row a request or the Worker reads
goes through the checked converter, including rows written by old application
versions or by plain SQL that changed a column the old version can see. Rows
already in the current representation are decoded without re-running checks on
primitive proof fields. A field carried over with `Same` keeps its stored value,
so data that never satisfied the old check is not re-validated by `Same` either.
Proof-bearing record fields are different: their codec's `via` checks run on
every decode.

The database is therefore part of the trusted boundary. Writes made outside
Tesl to current-representation columns, at any time, and to any column after
Contract has dropped the old-write trigger, are served as already proven. Use
`Revalidate` or a converter that calls the validator when existing data must
be checked, and keep other writers away from Tesl-owned tables.

## Current schema edits and recorded hashes

After editing `v-current.tesl`, `MIG001` means the latest migration does not yet
describe those saved changes. It is reported once per changed file. That is an
expected incomplete authoring state. Run `tesl migrate app.tesl`: it starts the
next revision with your edits. If the latest revision is an undeployed draft you
meant to change, run `tesl migrate app.tesl --resume` to refresh it instead. Then
resolve its decisions and recheck.
The editor's draft guidance does not make the program deployable; the compiler
still rejects an inconsistent current schema or unresolved migration.

`MIG013` is different: frozen history or its protected metadata no longer matches.
Restore the exact historical file from version control and investigate the change.
Do not dismiss it as an in-progress migration, change a stored digest to match,
or reseal an already-deployed revision. If source publication was interrupted, use
the guarded recovery command named by the tool rather than manually completing a
partial multi-file write.

## Choose the deployment route

Rolling support depends on the change and the retained history. It is not a
promise that every migration can run with every old application still serving.

| Change or operation | Rolling behavior and required action |
|---|---|
| Compatible additive revisions | Several compatible versions can remain admitted. A Worker can catch up a supported additive gap using retained history. Close the additive epoch before its first transforming revision. |
| Supported adjacent row transformation | Keep old/new storage and the required reverse-write behavior during overlap. Start `worker --install`, roll Request instances after expansion is ready, then retire old instances and complete the reviewed Contract. New transformed values may be usable in projections before they are safe in SQL filters or indexes; follow the compiler's restrictions. |
| Queue payload change | Keep the supported stored-row contracts unchanged on that edge. The Worker converts exact historical payload versions; live old claims and rejected/invalid jobs can block retirement. |
| Both stored rows and queue payloads change | Split into a row revision and Contract, then a payload revision. A latest artifact can execute the supported ordered history without shipping intermediate application images. This does not make an incompatible multi-version gap an always-online upgrade. |
| Staged uniqueness | Use the staged releases and per-key guards. Promotion requires the reviewed Contract and correct old-writer retirement; declaring an index does not by itself make conflicting writes safe. |
| Non-adjacent transforming catch-up | Stop incompatible old processes and wait for their heartbeat/claim windows. `deploy` / `catch-up` execute the supported history and refuse unsafe publication. Plan for interrupted availability when there is no admitted surviving service. |
| Contract or additive-epoch closure | This retires old versions and can remove their storage. Do not automatically roll back to an image below the new admission floor. Restore/recovery planning must respect that irreversible boundary. |
| Unrelated table Drop or whole empty-queue removal | Use their explicit reviewed source decisions and narrow history restrictions. Neither allows arbitrary dependency removal, implicit discard or silent queue rename. |

For a compatible adjacent Kubernetes rollout, the order is:

```text
worker --install → worker ready → roll Request pods → old pods/claims drain → deploy/Contract
```

The finite `--schema deploy` command completes retirement. Running it as a
pre-upgrade hook while the controller still keeps old pods alive can wait for
those very pods. Use the [rolling example](../example/kubernetes-rolling/README.md)
for that ordering. A stop → deploy → start pipeline is a useful finite deployment
route, but does not promise continuous availability.

See [operating a migration](migration-operations.md) for credentials, blockers and
recovery, [cleanup Contracts](migration-contracts.md), and
[reviewed empty queue removal](queue-removal.md) for detailed restrictions.
