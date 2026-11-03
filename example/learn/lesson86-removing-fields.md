# Lesson 86 — Remove a field without breaking old writers

V11 of the [todo migration example](../db-migration-example/how-to-update-the-db.md)
removes `priority` from the current Todo row while V10 binaries may still write
it. The migration maps V10 to V11 and supplies the reverse value explicitly:

```tesl
entities: { Todo: Migrate retirePriority
  [LegacyWith priority previousPriority] }

fn previousPriority(current: Schema.Todo.V11.Todo) -> Int =
  current.priorityWeight - 1
```

The old column and trigger remain during the rollout. After old readers and
writers are retired, the checked V11 Contract names `Column Todo priority` and
`Trigger Todo`. The worker performs that cleanup; editing the schema alone never
drops data.

The same app and API tests run before and after the change. The migration fixture
asserts that a V10 row's priority is reconstructed exactly:

```sh
tesl test example/db-migration-example/todo-app.tesl
tesl check example/db-migration-example/todo-app.tesl
```

Keep a healthy old request process serving while the worker backfills and before
the Contract is executed. Handlers remain untouched because they already expose
only `{ id, title, completed }`.

## What happens while both versions run?

Removing a field from the current schema does not immediately remove its
PostgreSQL column. Old handlers still decode complete old rows, including fields
that the current handlers no longer use.

- `Legacy field value` supplies an explicit old-compatible constant.
- `LegacyWith field backward` computes that value from the current row. It runs
  for current inserts and updates, so an old reader sees a compatible value even
  after the current app changes the row. A removed JSONB field uses its old codec.

For example, if the current app changes `priorityWeight` from `5` to `8`, the
function above writes `7` to the retained `priority` column. The old app continues
to read its familiar field. An old app can also insert or update rows during this
window; the migration handles those rows before the current app writes them.

Migration and application writes share the transaction. A failed multi-row
update—whether a uniqueness constraint fails or the migration returns `Reject`—
must leave every row unchanged, including retained legacy values and migration
generations. The PostgreSQL regression suite checks these cases with separately
compiled old and current apps, including removed primitive and JSONB fields.

Only the reviewed Contract performs physical removal after retiring the old
version and completing the final migration pass. Tests also verify removal of an
index on an old field, continued reads and writes by the already-running current
app, and refusal of the retired old app. Run the example's `tesl test` and `tesl
check` commands above when changing the schema or migration; follow its deployment
instructions before executing the Contract.
