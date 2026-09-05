# Independently deployed applications

Each of `v7/`, `v8/`, and `v9/` is an independent application checkout. Its
`app.tesl` owns the connection settings, database binding, and tests;
`operations.tesl` owns the application operations, including database effects.
Its `schema/notes/v-current.tesl` owns only the entity definition and its types.
The three copies of `VCurrent` represent what each application was built with;
they are not historical schema modules imported by a newer application.

The database selects `schema: NotesSchema.VCurrent` and
`migrations: NotesSchema.Migrate`. Its PostgreSQL configuration separately selects
`namespace: "migration_fixture"`. No application duplicates an `entities:` list;
the compiler derives membership from the schema's complete import closure.

The process oracle compiles all three separately and runs them against one
disposable database. At this harness stage it prepares the additive catalog
explicitly. These fixtures do not yet exercise the production migration planner
or executor; that coverage must be added when those components exist.
