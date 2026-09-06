# Field Notes: a todo app with database migrations

A PostgreSQL todo app with an Elm frontend. Its request handlers, routes, public
JSON, connection configuration and application tests stay identical while the
storage schema evolves. The response is always `{ id, title, completed }`.

**Start with [todo-app.tesl](todo-app.tesl), then read
[how to update the database](how-to-update-the-db.md).**

| Location | Your concern |
| --- | --- |
| [todo-app.tesl](todo-app.tesl) | Connections, handlers, routes and application tests |
| [schema/todo/v-current.tesl](schema/todo/v-current.tesl) | All current entities, stored facts and pure constructors |
| [migrations/todo/](migrations/todo/) | Reviewed rules for moving between schema versions |
| [frontend/](frontend/) | The Elm interface and stable HTTP contract |
| [deploy/](deploy/) | Local deployment demonstration and historical test fixtures |

Database connections and handlers do not belong in schema modules. A storage
change usually touches the current schema and its migration; adding an app
feature may also change the handlers and UI.
Each accepted snapshot is one `schema/todo/vN.tesl` file beside the current one.

## Run it

Use the repository development environment, with Go, PostgreSQL, Python 3,
Elm 0.19.1 and the built compiler:

```sh
cd compiler && dune build && cd ..
bash example/db-migration-example/deploy/run-cluster.sh
```

Open **http://127.0.0.1:8085**. Create, edit, complete, filter and delete todos
while the demo rolls two request processes through the saved releases. A real
HTTP reverse proxy keeps each healthy old process serving until its replacement
is ready and its in-flight requests have drained. CRUD probes run throughout.

The Python and shell files under `deploy/` arrange that local cluster; Tesl's
compiled schema worker performs the migrations. They are not migration code and
are not needed in your own application. You might use Helm or something
yourself in a real world scenario. [Deployment details](deploy/README.md)
include credentials, standalone commands, logs and cleanup.

## The storage changes

The sequence repeats common nullable additions, creates another entity, adds a
required field with a typed default, and adds a concurrent index to the populated
todo table. [The version table](how-to-update-the-db.md#the-saved-example-history)
explains what each change means for retained rows and old writers.

Derived-field backfills, record/ADT JSONB transformations, repair and physical
contraction need further scenarios as their runtime support lands. A new JSON
codec alone does not migrate retained JSON.

## Tests

```sh
tesl test example/db-migration-example/todo-app.tesl
python3 example/db-migration-example/deploy/test-workflow.py
bash scripts/run-migration-tests.sh -run '^TestCompiledTodoShowcaseRollingUpgrade$'
```

The app tests cover CRUD, title proofs and limits, invalid-update preservation,
malformed JSON, duplicate/missing IDs and idempotent deletion. The native
PostgreSQL regression builds standalone releases, checks that app and frozen
source bytes stay unchanged, retains real rows through rolling requests, and
interrupts both a table expansion and a blocked concurrent index worker. The
local walkthrough is separate from that regression gate.
