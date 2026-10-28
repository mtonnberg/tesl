# Lesson 89 — Add a proof to existing data

A new proof on an entity field does not make old rows valid. This lesson adds
`NonEmpty` to an existing `String` title, keeps its physical column, and checks
stored values before treating them as the new entity type.

Start with the complete [notes app](db-revalidation/app.tesl). It has HTTP
handlers for creating, reading, updating and repairing notes. The same app source
is used for both revisions; only its imported schema and migration history
change.

| File | Responsibility |
| --- | --- |
| [app.tesl](db-revalidation/app.tesl) | Database connection, handlers, routes and startup |
| [V1](db-revalidation/schema/notes/v1.tesl) | Frozen schema accepting any title |
| [VCurrent](db-revalidation/schema/notes/v-current.tesl) | Current schema and its `NonEmpty` establish |
| [V2 migration](db-revalidation/migrations/notes/v2.tesl) | Check retained titles, preserving values or rejecting rows |
| [V2 Contract](db-revalidation/migrations/notes/v2-contract.tesl) | Finish validation and retire incompatible writers |

## Keep validation behind the same function

V1 exposes `tryTitle : String -> Maybe String` and accepts every string. The
handlers already use its `Something` branch when constructing or updating a
note. V2 changes that function to an establish:

```tesl
fact NonEmpty (value: String)
establish tryTitle(value: String) -> Maybe (v: String ::: NonEmpty v) =
  if value != "" then
    Something (value ::: NonEmpty value)
  else
    Nothing
```

The entity now declares `title: String ::: NonEmpty title`. The handlers keep
calling `tryTitle`; their existing `Nothing` branch handles invalid input. This
works because validation was already a boundary in the app. An app that directly
constructed arbitrary titles would need to introduce that boundary too.

## Check retained rows explicitly

The migration declares:

```tesl
entities: {
  Note: Migrate convert [Revalidate title Schema.Notes.VCurrent.tryTitle]
}
```

Its conversion calls the exact target-owned establish on `old.title`:

```tesl
case Schema.Notes.VCurrent.tryTitle old.title of
  Nothing -> Reject "empty title"
  Something title ->
    Row (Schema.Notes.VCurrent.Note {
      id: old.id, title: title, memo: old.memo
    })
```

`Revalidate` checks a value; it does not rewrite it. The compiler requires the
establish to return its original input with evidence, and the row callback to use
that exact `Something` binder. Valid Unicode titles survive unchanged. Empty
strings are rejected rather than silently replaced with a default.

## Repair, then finish the migration

During the compatibility window, a V1 process can still write an empty title:
its old `tryTitle` accepts it. The V2 runtime must refuse to present that row as a
proved V2 note. An unrelated update must not accidentally make the invalid row
current either.

Repair the source data through the retained application's repair operation, then
retry conversion. Stop the old writers before completing the checked Contract;
the final pass must establish that retained rows satisfy the new contract. A
successful provisional backfill alone does not prevent an old writer from
introducing another invalid value.

The example's `/one`, `/invalid`, `/repair` and `/touch` endpoints make these
states easy to exercise. `/invalid` deliberately attempts an empty title; V1
accepts it and V2 returns `"refused"`. `/repair` writes `"repaired"`. The
PostgreSQL regression runs both app versions, tests refusal and repair, and then
executes Contract.

This is runtime proof enforcement. It does **not** install a SQL `CHECK`
constraint or protect writes issued outside Tesl. Contract retires incompatible
old app versions; it does not turn the establish into a database constraint.

## Run the checks

From the repository root:

```sh
tesl check example/learn/db-revalidation/app.tesl
tesl test example/learn/db-revalidation/app.tesl
```

The migration includes executable tests for unchanged Unicode values and empty
title rejection. The live application regression is
`compiler/test/test_migration_revalidate_postgres.ml`; it builds both revisions
from these files and exercises real PostgreSQL with isolated connection roles.
The example's connection values are placeholders for that harness. To run it
manually, configure the application's `Database` block for your PostgreSQL
instance, then use `tesl run example/learn/db-revalidation/app.tesl`.

The initial supported scope is deliberately small: the same non-primary-key
`Int`, `Float`, `Bool` or `String` field, unchanged codec and physical storage,
and a first proof where the previous field had none. Replacing or strengthening
an existing proof, changing a carrier or codec, and combining `Revalidate` with
`Retype`, `Rename`, `Default` or `WriteBack` on that field are refused. Those
changes need a different migration strategy. Existing primitive proofs can use
retained-column `Retype` with a reverse function returning the exact old proof;
see [lesson 90](lesson90-changing-field-proofs.md).
