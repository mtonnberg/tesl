# Lesson 85 — Backfill a derived field from retained rows

This scenario starts from the complete [todo app](../db-migration-example/todo-app.tesl).
The HTTP handlers and Elm frontend stay unchanged while V10 adds
`priorityWeight` to the stored Todo row.

The current schema adds the field and gives new rows a complete value:

```tesl
priority: Int
priorityWeight: Int
...
priorityWeight: 1
```

The migration cannot use one SQL default because the value depends on the old
row. Its typed callback reads the frozen V9 row and returns a complete V10 row:

```tesl
fn migrateTodo(old: Schema.Todo.V9.Todo) -> Migrated Schema.Todo.V10.Todo =
  Row (Schema.Todo.V10.Todo { ... priorityWeight: old.priority + 1 ... })
```

Every callback must handle `Reject`, and its fixture tests prove both the old
title proof and the derived value. Run the whole app check and generated tests:

```sh
tesl check example/db-migration-example/todo-app.tesl
tesl test example/db-migration-example/todo-app.tesl
```

At deployment, the compiled schema worker backfills retained rows. New request
processes wait for readiness; old processes continue using their V9/V10 query
shape until drained. The application file is unchanged because the derived value
is storage bookkeeping, not an API behavior.
