# Lesson 88 — Retype JSONB from a record to an ADT

V13 of the [todo app](../db-migration-example/todo-app.tesl) changes
`PriorityInfo` from a record to two constructors, `Imported` and `Created`.
The migration uses `Retype` and `WriteBack`:

```tesl
entities: { Todo: Migrate tagPriorityInfo
  [Retype priorityInfo, WriteBack priorityInfo priorityInfo previousInfo] }
```

`upgradeInfo` preserves the weight and chooses the constructor from the old
origin. `previousInfo` reconstructs the exact V12 record and its original codec,
so V12 writers remain valid during the rolling update. The new field is stored in
`priority_info__v13`; the Contract removes the old physical JSONB storage only
after compatibility is no longer needed.

The two fixtures cover both constructors and the unchanged `newTodo` constructor:

```sh
tesl check example/db-migration-example/todo-app.tesl
tesl test example/db-migration-example/todo-app.tesl
```

The worker owns the row conversion and Contract. Request processes still run the
same handlers, routes and frontend, which makes this a useful test that storage
evolution has not leaked into application behavior.
## Inspecting codec changes

Run `tesl migrate plan example/db-migration-example/todo-app.tesl` to inspect the
checked history, including the source and target columns and reverse adapters.
Codec reports distinguish encoder edits, decoder order and dependency changes.
They describe source changes, not proof that the database has been rewritten.

A fallback decoder can read old JSON without changing it. Even when old and new
decoders accept both shapes, changing the stored shape can change SQL equality
results for an older application. This example therefore uses `Retype` with a
separate column and `WriteBack` for the old representation. Removing old storage
still requires the worker's checked Contract lifecycle.
