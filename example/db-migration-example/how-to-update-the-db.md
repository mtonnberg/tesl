# How to update the database

Work in `example/db-migration-example/`. Read
[todo-app.tesl](todo-app.tesl) once: the database connection and handlers live
there. Then focus on two things:

- **The current schema** describes the rows the new binary uses.
- **The migration** explains how that schema can coexist with retained rows and
  older binaries. Review it as code, including any rule you must supply.

## 1. Start the guided workflow

```sh
tesl migrate todo-app.tesl
```

The interactive CLI freezes the accepted schema, opens a new version, and tells
you which file to edit. Save your changes, then continue in the terminal. It
refreshes the migration, shows diagnostics and any decisions still required,
and displays the checked plan. You remain responsible for the migration rules.

Use `tesl migrate todo-app.tesl --resume` only to continue an **undeployed** current
revision. Once a revision has been deployed, start a new one instead.

Edit **[schema/todo/v-current.tesl](schema/todo/v-current.tesl)**. This one file
contains Todo, Project, their facts and constructors. For example, add
`snoozedUntil: Maybe PosixMillis` to Todo and supply `Nothing` in its constructor.
The connection and handlers can stay untouched because their public DTO does not
expose this storage field. Frozen predecessors describe accepted old versions;
leave them unchanged.

## 2. Review the migration, not just the new entity

Generation refreshes the editable migration against the actual saved source.
A stale-target diagnostic before refreshing means the schema and its migration
still describe different edits. Inspect the generated file under
`migrations/todo/` and the plan.

A nullable addition has a useful SQL default already: NULL, read as `Nothing`.
For a required field, decide where the value comes from. V7 supplies this rule:

```tesl
"Todo": Additive [Default priority 0]
```

It gives existing rows and old binaries' future inserts a priority of zero.
The new constructor also supplies zero, but changing the constructor alone
cannot update retained rows or old writers. A derived value needs a real row
transformation; choosing an arbitrary constant does not solve that problem.

The title proof stays unchanged in this example. Checked `Same` entries record
that fact across versions; they do not authorize arbitrary new code to assert
old stored values satisfy a different proof.

## 3. Test and build

```sh
tesl test todo-app.tesl
tesl compile todo-app.tesl --out /tmp/todo-next-go
(cd /tmp/todo-next-go && go test ./internal/teslmodtodoapp && go build -o /tmp/todo-next ./cmd/app)
```

Add a regression that starts with real rows from the previous binary, runs the
migration, and exercises old/new reads and writes. Test interruption and restart
where the operation can span multiple transactions. The existing native todo
regression provides that pattern; replay archives under `deploy/releases/` are
its historical fixtures, not another migration mechanism.

## 4. Deploy the worker, then roll request processes

Run the new executable as `./app --schema worker --json` with the schema worker
login. Run ordinary `./app` processes with the request login. A new request waits
for its schema readiness; only then route traffic to it and drain an old one.
Keep a healthy old process available throughout the rollout.

A plain concurrent index may still be building when requests become ready.
The separate worker continues and records its result. Requests never build the
index. Worker interruption must preserve its job and verify the old PostgreSQL
executor has stopped before a replacement takes ownership.

[Deployment commands and role configuration](deploy/README.md) show the concrete
local setup. The deployed executable contains its checked migration history;
source files and the compiler are not required on application nodes.

## Explicit commands for scripts

These are the noninteractive alternative to the guided workflow:

```sh
# Freeze the accepted version and open a new current target.
tesl migrate generate todo-app.tesl --new-revision
# Edit and save schema/todo/v-current.tesl, then:
tesl migrate generate todo-app.tesl
tesl check todo-app.tesl
tesl migrate plan todo-app.tesl
```

For an already-open, undeployed revision, continue from the edit/refresh steps.
Do not run the new-revision command again merely to clear a diagnostic.

## The saved example history

| Version | Change | Meaning for retained rows and old writers |
| --- | --- | --- |
| V1 | Todo with a proven title and completion flag | Baseline |
| V2 | Add `details: Maybe String` | SQL NULL becomes `Nothing` |
| V3 | Add `dueAt: Maybe PosixMillis` | Repeat the nullable addition with a timestamp |
| V4 | Add Project and its initial `archived` index | Create the new table and initial index together |
| V5 | Add `projectId: Maybe String` to Todo | Another optional text field |
| V6 | Add `description: Maybe String` to Project | Repeat the same change on the other entity |
| V7 | Add `priority: Int` with `Default priority 0` | Retained rows and old inserts receive zero |
| V8 | Add a plain index on Todo's `completed` field | Build concurrently while requests keep reading and writing |
| V9 | Add `reminderAt: Maybe PosixMillis` | Repeat the common nullable timestamp addition after index completion |

These storage-only additions do not automatically become UI features. The stable
public DTO is the reason the handlers can stay unchanged.
