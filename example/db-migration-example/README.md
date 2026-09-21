# Field Notes: a todo app with database migrations

This is a complete PostgreSQL todo app with an Elm frontend. It shows the shape
of a real application while its storage moves through thirteen revisions. The
HTTP response stays `{ id, title, completed }`; the connection, handlers, routes,
frontend and application tests are independent of the migration modules.

Start with [todo-app.tesl](todo-app.tesl), then follow the concise
[database update guide](how-to-update-the-db.md).

| Location | What it contains |
| --- | --- |
| [todo-app.tesl](todo-app.tesl) | PostgreSQL connection, handlers, routes and app tests |
| [schema/todo/](schema/todo/) | Frozen snapshots and `v-current.tesl` |
| [migrations/todo/](migrations/todo/) | Typed transitions and reviewed Contracts |
| [frontend/](frontend/) | Elm UI using the stable HTTP contract |
| [deploy/](deploy/) | Optional local cluster, proxy and rolling-update fixtures |

The schema and migration modules contain no database connection, handler or
application capability. They are pure, versioned data definitions and row
functions. The application imports `Schema.Todo.VCurrent`; its `Database`
declaration selects `Schema.Todo.Migrate` and groups PostgreSQL migration roles
under `PostgresConfig.migrations`.

## Run it

With the repository toolchain, Go, PostgreSQL, Python 3 and Elm installed:

```sh
cd compiler && dune build && cd ..
bash example/db-migration-example/deploy/run-cluster.sh
```

Open **http://127.0.0.1:8085**. The proxy keeps two request processes available
while a schema worker applies the next revision. Create, edit, complete, filter
and delete todos during the rollout.

The files in `deploy/` arrange this local demonstration. Tesl's compiled worker
performs the migration; the scripts are replaceable infrastructure and are not
required by an application using migrations.

## What the history demonstrates

V2–V9 repeat nullable fields, a new entity, a defaulted required field and a
concurrent index. V10–V13 cover the cases that are easy to get wrong:

- a derived backfill from retained data;
- removal with a reverse `LegacyWith` value and a checked Contract;
- a record stored as JSONB whose payload needs explicit conversion;
- an ADT retype with constructor-specific reverse values, a new physical column
  and cleanup of the old representation.

Each migration has pure fixtures and tests. `tesl test` compiles those fixtures
alongside the unchanged app tests; generated Go tests exercise the row adapters,
source history and physical metadata. A new codec alone never rewrites an old
JSONB value.

## Tests

```sh
tesl check example/db-migration-example/todo-app.tesl
tesl test example/db-migration-example/todo-app.tesl
python3 example/db-migration-example/deploy/test-workflow.py
bash scripts/run-migration-tests.sh -run '^TestCompiledTodoShowcaseRollingUpgrade$'
bash scripts/run-migration-tests.sh -run '^TestCompiledTodoComplexHistoryPostgres$'
```

The first two commands are the fast source and generated-fixture checks. The
deployment workflow uses real PostgreSQL when configured and verifies retained
rows, old/new writers, worker interruption and rolling request traffic. The
native regression is separate from the optional local proxy walkthrough.
The complex-history regression advances V1→V13 with overlapping request versions,
non-default retained values, field removal, JSONB record/ADT conversion, reverse
writes and physical cleanup. It checks requests at lifecycle boundaries;
continuous rollout traffic is currently covered by the additive regression.
