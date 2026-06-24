# First-Class Database Migrations

## Motivation

The current `auto-migrate?: true` approach creates/alters tables at startup. This is convenient for development but not always suitable for production: no rollback path, no audit trail, destructive changes (rename column, change type) not supported, and multi-instance deployments can race.

## Proposed design

```tesl
migration AddUserBio "2026-03-20-001" {
  database MainDatabase
  up {
    alter User add { bio: String }
  }
  down {
    alter User remove { bio }
  }
}
```

`tesl migrate --database MainDatabase` applies pending migrations in order. A `tesl_migrations` table tracks applied migrations (name, applied_at, checksum). `tesl migrate --status` shows which have and haven't been applied.

## Scope

Large. Requires:
1. New `migration` top-level form in compiler
2. New `alter ... add/remove/rename` body statements
3. `tesl migrate` CLI subcommand
4. Migration state table + locking to prevent concurrent races
5. Interaction with `auto-migrate?` (probably: disable auto-migrate when any migration is defined)
