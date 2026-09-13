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
