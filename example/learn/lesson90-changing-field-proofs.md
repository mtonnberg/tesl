# Lesson 90 — Change an existing field proof

Changing a proof changes which stored values your application may trust. A title
that satisfied yesterday's rule can fail today's rule, even though both versions
store a `String`.

The runnable [notes app](db-proof-change/app.tesl) strengthens an existing title
proof. Its [frozen V1 schema](db-proof-change/schema/notes/v1.tesl) accepts any
nonempty title; [VCurrent](db-proof-change/schema/notes/v-current.tesl) also rejects
`"blocked"`. The [V2 migration](db-proof-change/migrations/notes/v2.tesl) converts
stored rows and maintains an old representation until the generated
[Contract](db-proof-change/migrations/notes/v2-contract.tesl) retires V1.

Start with the app and its schema/history files. The application's handlers call `tryTitle` in both
versions; the database connection and Worker role settings stay in `app.tesl`.
The later table also explains weakening and removing a proof, which are covered
by separate live regression scenarios.

## Run the example

From the repository root:

```sh
tesl check example/learn/db-proof-change/app.tesl
tesl test example/learn/db-proof-change/app.tesl
```

The migration tests cover valid Unicode titles, reverse conversion, rejection of
`"blocked"`, and empty-title validation. They need no running database.

To run the full app, provision a PostgreSQL database with separate control-owner,
request and worker roles as described in the
[Worker deployment guide](../db-migration-example/deploy/README.md#ordinary-deployments). Set `NOTES_DB_HOST`,
`NOTES_DB_PORT` (default `5432`), `NOTES_DB_NAME`, `NOTES_CONTROL_OWNER`,
`NOTES_REQUEST_ROLE` and `NOTES_WORKER_ROLE`. `NOTES_DB_USER` and
`NOTES_DB_PASSWORD` select the process login; `NOTES_DDL_CONNECTION` contains the
worker's direct DDL connection string (empty uses the normal connection).
Install with a temporary installer login that belongs to the control owner;
revoke that membership afterwards. Run the worker with its separate login and
the app with the request login:

```sh
tesl run example/learn/db-proof-change/app.tesl --schema install \
  --worker "$NOTES_WORKER_ROLE" --request "$NOTES_REQUEST_ROLE" --json
# Switch to the worker login:
tesl run example/learn/db-proof-change/app.tesl --schema worker --json
# In a second terminal, with the request login:
tesl run example/learn/db-proof-change/app.tesl
```

The default HTTP port is `8093` (`ROW_PORT` overrides it):

```sh
curl -X POST localhost:8093/one
curl localhost:8093/all
curl -X PUT localhost:8093/invalid  # "refused": V2 rejects "blocked"
curl -X PUT localhost:8093/repair
```

A fresh installation has no old rows to reject. The live regression deploys V1
first, writes `"blocked"` through the same `/invalid` handler, then starts V2. It
repairs the rejected row through V1's `/repair` handler before completing the
migration. `/two` and `/touch-all` exercise bulk writes; the intentional `MIG031`
warning on the latter explains that this operation visits every matching row
during the compatibility window.

## Keep the application boundary

The handlers already call `tryTitle` and handle `Nothing` before writing a note.
Changing that function's validation and its returned proof leaves those handlers
unchanged. An application that constructs unrestricted values directly must add
that validation boundary first.

In the strengthening scenario, V1's `NonEmpty` proof excludes `""`. V2's
`Allowed` proof also excludes `"blocked"`. Previously valid rows therefore need
an explicit conversion:

```tesl
fn convert(old: Schema.Notes.V1.Note) -> Migrated Schema.Notes.VCurrent.Note =
  case Schema.Notes.VCurrent.tryTitle old.title of
    Nothing -> Reject "title rejected by changed proof"
    Something title ->
      Row (Schema.Notes.VCurrent.Note {
        id: old.id, title: title, memo: old.memo
      })
```

A rejection does not grant the new proof or mark the row migrated. The old app
can repair the value, after which the new app can read it and the migration
worker can finish processing it.

## Give each version an honest representation

Use `Retype` and an explicit reverse callback:

```tesl
entities: {
  Note: Migrate convert [Retype title, WriteBack title title backward]
}
```

V2 retains the logical field name while selecting its introducing-version column:

```tesl
title: String ::: Allowed title @column("title__v2")
```

During the migration, `title` holds the old representation and `title__v2` holds
the new one. `WriteBack` must return a value carrying the **exact previous
schema's proof**. A plain string or a similarly named proof from another module
is insufficient. The tested callback calls V1's establish function again.

Weakening a rule makes that reverse direction especially important:

| Scenario | V1 accepts | V2 accepts | Reverse representation |
| --- | --- | --- | --- |
| Stronger rule | Nonempty titles, including `"blocked"` | Nonempty titles except `"blocked"` | Re-establish the old proof on the same title |
| Weaker rule | Nonempty titles except `"blocked"` | Every nonempty title | Preserve representable titles; otherwise establish the documented `"valid"` fallback |
| Removed proof | Nonempty titles except `"blocked"` | Any `String`, including `""` | Keep the new raw value and supply a valid old fallback when necessary |

In the weaker scenario, a new write of `"blocked"` remains exactly `"blocked"`
in `title__v2`; the old column receives `"valid"`. Old and new readers therefore
see different, deliberately chosen representations. That fallback is a product
decision, not an automatic conversion supplied by Tesl. The test's frozen old
validator accepts its fixed fallback; its full callback and fixture construction
are in the linked regression source.

A valid fallback is not a lossless round trip. While V1 can write, even an
update to another field such as `memo` invalidates the whole migrated row. V2
then rebuilds it from V1's representation: `"blocked"` (or a newly permitted
empty title) becomes `"valid"`. The newer bytes may still be present in the
retained column immediately after that update, but reads no longer use them;
a worker or subsequent write can replace them. If those newer values must be
preserved exactly, drain and retire old writers before allowing values the old
schema cannot represent. Test unrelated old updates as well as title updates.

## Finish the compatibility window

1. Deploy V2 and run the migration worker. Repair rejected old rows through a
   valid application path.
2. Keep both representations while V1 can still write. Old writes invalidate
   the migrated generation; subsequent migration uses the value written by V1.
3. Run the generated V2 Contract when ready to retire V1. A failed final pass
   leaves V1 admitted. Successful Contract retires old writers and removes the
   old `title` column, preserving the new representation in `title__v2`.

During this window, filtering or sorting on a retyped field is currently
refused. These applications sort by unchanged `id`; they still read and update
the logical `title` field. Same-column `Revalidate` can add a first proof or
strengthen a field with a conjunction that preserves every historical proof
through exact `Same` evidence. It cannot replace changed historical evidence;
see [lesson 94](lesson94-same-column-proof-strengthening.md) for that bounded
same-column path.

The [live lifecycle assertions](../../runtime/go/teslrt/migration_row_proof_retype_native_test.go)
cover rejection, repair, writes from both revisions, weaker-rule fallback,
old-write invalidation, and successful and refused Contract. The strengthening scenario
also verifies that a bulk write spanning valid and rejected rows rolls back both
physical representations, generation markers, and migration progress.
