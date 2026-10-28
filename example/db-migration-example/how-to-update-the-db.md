# How to update the database

Work in `example/db-migration-example/`. The application file contains the
connection, handlers, routes and API tests. A database change normally touches
only the current schema and one migration:

- `schema/todo/v-current.tesl` is the row shape used by the new binary.
- `migrations/todo/vN.tesl` is the reviewed, typed transition from the previous
  frozen row shape.
- `migrations/todo/vN-contract.tesl` is the separately reviewed cleanup after
  old binaries and old rows no longer need compatibility storage.

`Database.migrations` names the history. The PostgreSQL `MigrationConfig` groups
worker and role settings; it is application configuration and does not belong in
a schema or migration module.

## 1. Open a revision

The guided command prepares a new frozen snapshot and migration:

```sh
tesl migrate todo-app.tesl
```

Edit the file it names, save it, and continue in the terminal. Use `--resume`
only for an opened revision that has not been deployed. After a revision is
deployed, start the next revision; never rewrite a frozen snapshot or completed
migration.

For a scriptable workflow, the equivalent commands are:

```sh
tesl migrate generate todo-app.tesl --new-revision
# edit schema/todo/v-current.tesl
tesl migrate generate todo-app.tesl
```

The connection and handlers stay in `todo-app.tesl`. Frozen files under
`schema/todo/vN.tesl` are historical inputs and should not be edited.

## 2. Choose the migration operation

Use the smallest operation that describes the stored-value change.

| Change | Migration shape | What to check |
| --- | --- | --- |
| Nullable field | `Additive []` | Existing SQL NULL decodes as `Nothing`; current constructors include `Nothing`. |
| Required field with a constant | `Additive [Default field value]` | The default covers retained rows and inserts from admitted old writers. |
| Required or derived value from an old row | `Migrate callback []` | Return a complete new row for every old row, or `Reject reason`; test both paths. |
| Remove a field | `Migrate callback [Legacy ...]` | Keep the old column and reverse value until a checked Contract drops it. |
| Record/ADT JSONB representation | `Migrate callback [Retype ...]` | Convert the typed old value explicitly; preserve the old codec for reverse writes. |
| Physical cleanup | `vN-contract.tesl` | Name the exact `Column`, `Storage`, `Index` or `Trigger` to drop and any `NotNull` tightening. |

Changing a codec does not rewrite existing JSONB. A typed migration must read the
old value and write the new representation. Keep the old decoder and reverse
adapter while an older binary can still read or write the row.

The example deliberately exercises each case:

- V10 derives `priorityWeight` from the retained `priority` value.
- V11 removes `priority`, reconstructs it for V10 writers with `LegacyWith`,
  and drops the old column only in its Contract.
- V12 converts an integer into a JSONB `PriorityInfo` record with provenance.
- V13 retypes that record into an ADT, writes a new physical JSONB column, and
  reverses both constructors with `WriteBack` before its Contract removes the
  old storage.

## 3. Check the source and run the tests

Run Tesl commands from the example directory (or pass the full path):

```sh
tesl check todo-app.tesl
tesl test todo-app.tesl
tesl run todo-app.tesl
```

`tesl test` runs the migration fixtures as generated tests, including `Row` and
`Reject`, old codecs, reverse values and the unchanged application tests. The
compiled application contains the checked row callback and physical companion;
the handlers do not need a migration branch.

`tesl migrate plan todo-app.tesl` previews this complete history without connecting
to PostgreSQL. Transforming histories report table generations, row mappings,
source/target columns, proof enforcement, codec changes and checked Contracts.
The guided command also summarizes the current revision and any required prior
Contract. Both additive and transforming previews have `executable: false`.

These are source descriptions, not persisted receipts or proof that rows have
migrated. Codec reports do not authorize an in-place rewrite or removing a legacy
decoder. This example uses typed `Retype` plus `WriteBack`, separate retained
storage and checked Contract cleanup for the record-to-ADT change. Run the tests
and deployed worker to verify the actual migration lifecycle.

## 4. Roll out with a worker

Before the first transforming release (V10 here), retire V1–V8 and close the
additive epoch using the retained **V9 source/binary** and worker login:

```sh
tesl run todo-app.tesl --schema close-epoch --through V9 --dry-run --json
tesl run todo-app.tesl --schema close-epoch --through V9 --json
```

Run those commands from the V9 release, before deploying V10. V9 requests can
continue serving. If closure reports recent older instances, stop them and wait
for their heartbeats to expire. Closure permanently prevents V1–V8 from returning.

Build the same Tesl source into the request and worker processes. In development
you can run them separately:

```sh
tesl run todo-app.tesl --schema worker --json   # worker login / DDL
tesl run todo-app.tesl                         # request login / DML
```

The worker prepares physical storage, runs typed row transformations and records
the generation. Request processes wait for readiness and continue using the same
handlers. Keep an admitted old request process serving until the worker has
backfilled the rows and the new process is ready; then drain it. Prepare and run
the matching Contract only after old processes are gone and the readiness floor
has settled.

The deployment scripts under [deploy/](deploy/) demonstrate one possible local
PostgreSQL cluster and rolling proxy. They are infrastructure examples, not a
Tesl migration requirement; a production deployment can use Helm or another
orchestrator.

## The saved history

| Version | Change | Compatibility detail |
| --- | --- | --- |
| V1 | Todo with proven title and completion flag | Baseline |
| V2 | Add `details: Maybe String` | SQL NULL reads as `Nothing` |
| V3 | Add `dueAt: Maybe PosixMillis` | Nullable timestamp addition |
| V4 | Add `Project` and its `archived` index | New table and index |
| V5 | Add `projectId: Maybe String` to Todo | Optional reference |
| V6 | Add `description: Maybe String` to Project | Optional text |
| V7 | Add `priority: Int` with `Default priority 0` | Old rows and old inserts get zero |
| V8 | Add an index on `Todo.completed` | Worker builds it while requests serve |
| V9 | Add `reminderAt: Maybe PosixMillis` | Another nullable timestamp |
| V10 | Derive `priorityWeight = priority + 1` | Typed backfill from retained rows |
| V11 | Remove `priority` | `LegacyWith` keeps V10 writes valid until Contract |
| V12 | Add JSONB `PriorityInfo` record | Explicit record conversion and provenance |
| V13 | Retype `PriorityInfo` record to an ADT | `WriteBack`, new physical storage and Contract |

The public response remains `{ id, title, completed }` throughout. Storage-only
changes therefore leave the handlers, routes, frontend and API tests untouched;
only the versioned schema and migration source evolve.
