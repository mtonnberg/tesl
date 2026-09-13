# Preparing storage cleanup after a migration

A transforming migration temporarily keeps the storage needed by the old app.
A **Contract** describes the cleanup after all rows have migrated and old writers
have been retired. Prepare it with the migration, before building the rollout:

```sh
tesl migrate contract app.tesl --version 2
tesl check app.tesl
```

This creates `migrations/<family>/v2-contract.tesl`. Review the generated file;
your handlers, database connection, and current entity definitions stay where they
are. For example, a rename can leave an old column and its index to remove:

```tesl
module Schema.Work.Migrate.V2Contract exposing [contract]
import Tesl.Migration exposing [Contract, Drop(..), Tighten(..)]
import Schema.Work.Migrate.V2

contract = Contract {
  of: Schema.Work.Migrate.V2
  drops: [Index Note old_author, Trigger Note, Column Note author]
  tighten: [NotNull Note owner, NotNull Note count]
  promote: []
}
```

The compiler checks the exact cleanup against the migration. An omitted or extra
operation is an error. `Trigger Note` removes Tesl's temporary old-write
invalidation machinery. Required changes to the internal generation default are
included automatically. Before switching new writes to the cleaned-up layout,
Tesl also relaxes obsolete required columns so inserts can continue while those
columns are being removed. This preparation follows from the reviewed drop;
you do not add another source operation.

`NotNull` also includes the internal steps needed to keep writes running during
validation. Tesl prepares and validates a temporary check, uses that check when
making the column required, then removes it. Your Contract still contains just
the one `NotNull` entry for the field.

When a record or ADT changes its JSONB representation, its logical field may keep
the same name while the migration uses a new physical column. Cleanup then names
old storage explicitly, for example `Storage Note "metadata"`. The compiler
generates that distinction for you.

Generating a Contract only writes a checked source proposal. It does not run DDL,
finish backfill, retire a process, or prove that cleanup is safe now. The compiled
worker must establish the required row generations and retirement floor before
executing the checked cleanup. Keep the Contract in the versioned source history;
starting the next revision freezes it with the completed migration.

For scripts, add `--manifest-json` to preview the same guarded source edit. The
command refuses to overwrite an existing Contract. After undeployed schema or
migration edits, `tesl check` reports any stale selectors and the exact
selection it expects; review those changes before rebuilding. A purely additive
migration does not need an empty Contract.

For an unchanged record or ADT field, copy its original projection, such as
`id: old.id` or `metadata: old.metadata`, and retain the generated `Same` entries
for the type and its dependencies. A rename uses the same rule, for example
`details: old.metadata`. Tesl preserves the value across the frozen schema types,
including fields omitted by a lossy JSONB codec. A primary key must always keep
its original identity; reconstructing a new key is rejected.

When another field uses `Legacy` or `WriteBack`, Tesl also preserves these copied
values while constructing the old row for compatible writes. This needs no
extra conversion function. Ordinary functions still distinguish the two schema
types, and your handlers continue to use the current schema as before.


When removing a logical field, the old app still needs a value for it during the
rollout. Use `Legacy author "former"` for a fixed value, or
`LegacyWith metadata legacyMetadata` for a function that constructs the old field
from the new row. The function returns the old schema's field type, so a removed
JSONB record still uses its original codec. The migration supplies these values
for converted rows and new writes; choose values the old app can safely read.

Your current entity and handlers no longer use the removed field. The generated
Contract names it as `Column Note author` (and removes any obsolete index).
After cleanup, new inserts stop supplying the legacy value and the old column is
removed. Removing a field and changing a field's type therefore use the same
migration and cleanup workflow.
