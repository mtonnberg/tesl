# Lesson 87 — Migrate a record stored as JSONB

PostgreSQL still reports the column as `jsonb`, but changing the payload is a
schema change. V12 of the [todo app](../db-migration-example/todo-app.tesl)
turns the retained `priorityWeight` into a `PriorityInfo` record with a declared
codec and provenance:

```tesl
record PriorityInfo { weight: Int, origin: String }
codec PriorityInfo { ... }

fn addPriorityInfo(old: Schema.Todo.V11.Todo) -> Migrated Schema.Todo.V12.Todo =
  Row (Schema.Todo.V12.Todo { ...
    priorityInfo: PriorityInfo { weight: old.priorityWeight, origin: "migrated-v11" }
  })
```

A new codec does not rewrite existing data. The typed callback converts the V11
integer into a JSONB record in a separate column, while reverse writes maintain
the integer for V11 readers. The fixture checks
the payload and its provenance, and the unchanged app constructor checks new
rows:

```sh
tesl check example/db-migration-example/todo-app.tesl
tesl test example/db-migration-example/todo-app.tesl
```

Only after the old process is gone should the worker run the V12 Contract. The
HTTP handlers, database connection and Elm client do not need JSONB-specific
branches.
