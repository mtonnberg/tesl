# Lesson 92 — Change the same stored field again

A second breaking change uses a new `Retype` and a reverse adapter to the
**immediately previous schema**. Refresh advances the inherited physical column
name; you keep editing the same logical field in `VCurrent`.

Read [lesson 88](lesson88-jsonb-adt-retype.md) for the first Retype and
[lesson 90](lesson90-changing-field-proofs.md) for proof-bearing reverse writes.
The executable example for this lesson is `repeated_generated_column` in
[`test_migration_retype.ml`](../../compiler/test/test_migration_retype.ml).
It generates and freezes the source history, refreshes the second change, and
runs the emitted migration tests with the original source files removed.

## Start from the deployed version

Suppose V1 stored a `Metadata` record containing `text`. V2 added `extra` through
Retype. Its live schema now contains:

```tesl
record Metadata { text: String, extra: String }
entity Note table "notes" primaryKey id {
  id: String
  metadata: Metadata @column("metadata__v2")
}
```

Complete Contract V2 before deploying the next transforming version. Freeze V2
through `tesl migrate app.tesl` before editing the live schema. The frozen V2
schema and migration stay in source control.

Now change the stored record to `{ text: String, detail: String }` and update its
codec. Leave the inherited `@column("metadata__v2")` in the live file while
writing the new migration. The V3 entry is:

```tesl
entities: {
  Note: Migrate convert [Retype metadata, WriteBack metadata metadata backward]
}
```

The functions name V2, not V1:

```tesl
fn convert(old: Schema.Notes.V2.Note) -> Migrated Schema.Notes.VCurrent.Note =
  Row (Schema.Notes.VCurrent.Note {
    id: old.id
    metadata: Schema.Notes.VCurrent.Metadata {
      text: old.metadata.text
      detail: old.metadata.extra
    }
  })

fn backward(row: Schema.Notes.VCurrent.Note) -> Schema.Notes.V2.Metadata =
  Schema.Notes.V2.Metadata { text: row.metadata.text, extra: row.metadata.detail }
```

Here the conversion preserves both values. Test that property explicitly: the
types prove the result has the right shape, but a function replacing `detail`
with a constant could also have that shape.

## Refresh owns the physical storage name

Refresh the current migration through the guided `tesl migrate app.tesl`
workflow. Its source preview changes only the inherited annotation's string:

```tesl
metadata: Metadata @column("metadata__v3")
```

The old V2 column remains available during overlap. V3 writes its current value
and supplies V2's representation through `backward`. Worker conversion and the
reviewed Contract finish the transition before a later transforming deployment.

Refresh changes an existing annotation only when it matches the exact preceding
field selected by the explicit rules. An unrelated custom name, a wrong historical
generation, or a future generation stays visible as a diagnostic. Repeating
refresh is idempotent. Comments, whitespace, other storage annotations and frozen
sources are preserved.

If you also rename the logical field to `details`, use:

```tesl
Note: Migrate convert [Rename metadata details, Retype details,
                      WriteBack metadata details backward]
```

Update the row constructor and reverse function to use `details`. Refresh derives
`details__v3` from the new field name and uses the `Rename` source to recognize
the inherited V2 annotation. `Rename` alone cannot change a stored type or codec.

## Verify the values in both directions

The regression executes three Tesl business tests in both the ordinary and
renamed variants:

1. The old primary key, text and non-default extra value survive conversion.
2. Empty strings and Unicode survive forward/reverse conversion unchanged.
3. A newly constructed V3 row produces the exact V2 representation for old readers.

It also checks invalid reverse types, missing Retype, ambiguous Rename rules,
wrong physical generations, repeated preview identity and frozen-source integrity.
Run its focused suite from the repository root:

```sh
nix develop --command bash -c 'dune exec --root compiler ./test/test_migration_retype.exe -- test repeat'
```

## Exercise both deployment windows on PostgreSQL

The live companion is `repeated_export` in
[`test_migration_row_retype_physical.ml`](../../compiler/test/test_migration_row_retype_physical.ml),
with runtime assertions in
[`migration_row_repeated_retype_native_test.go`](../../runtime/go/teslrt/migration_row_repeated_retype_native_test.go).
It builds V1 before freezing anything, uses guarded start/refresh manifests to
produce V2 and V3, and invokes public compilation for every release. The handlers
stay byte-identical. The original source tree is removed before execution.

The live trace verifies:

- V3 expansion refuses until Contract V2 completes; no V3 column appears early.
- Both windows use their own physical JSONB columns and codecs. V2 can read a
  row created by V3, including its non-default detail.
- A late V2 insert remains generation 2. V3's lazy read returns the converted
  value without modifying the row or claiming generation 3.
- Failed bulk writes preserve the complete table snapshot; late V2 updates
  invalidate generation 3 without losing values representable in V2.
- A rejected V2 row blocks Contract V3 without retiring V2. V2 repairs its stored
  value, after which V3 can read it and Contract can finish.
- Each Contract removes only obsolete storage, retires its predecessor, and
  permits current reads and writes. Completed Contract is restartable, and a
  restarted V3 process reads the settled representation.

The private-cluster gate in [lesson 93](lesson93-testing-breaking-migrations.md)
runs this scenario with the Go race detector, alongside the separate interrupted
DDL and crash-recovery suites.
