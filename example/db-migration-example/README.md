# Field Notes: a PostgreSQL todo app that survives schema changes

This is a full Tesl application with an Elm frontend, six migrations after its
initial schema, and two request processes behind a real HTTP reverse proxy.
The rolling example continuously creates, edits, reads and deletes todos while
upgrading through all seven releases.

**Start with [todo-app.tesl](todo-app.tesl). Its handlers, routes, JSON codecs,
connection configuration and tests are identical in every release.** The public
response remains `{ id, title, completed }`. Storage changes live in the pure
[schema modules](schema/todo/v-current/todos.tesl) and
[migration history](migrations/todo/v7.tesl).

## Run the app and watch a rolling deployment

Prerequisites: the repository development environment (Go, PostgreSQL and the
built Tesl compiler), Python 3 and Elm 0.19.1. From the repository root:

```sh
cd compiler && dune build && cd ..
bash example/db-migration-example/run-cluster.sh
```

Open **http://127.0.0.1:8085**. Create a todo, edit its title, mark it done, filter
the list, and delete it. Leave the browser open during the V1 → V7 rollout.
Another browser tab sees changes through periodic refreshes.

The script builds and tests all seven backend releases before deployment,
compiles Elm, starts a dedicated local PostgreSQL cluster on port 55439, installs
the protected migration state, and starts two V1 request processes. For each
subsequent version it:

1. Replaces the schema worker with the new version, using the worker login.
2. Starts a new request process with the request login. The process waits for its
   schema revision before its health endpoint becomes available.
3. Adds that healthy process to the proxy, removes one old process from routing,
   drains its in-flight requests, then stops it.
4. Repeats for the second old process while continuous CRUD probes use the proxy.

The proxy round-robins API requests and serves the compiled Elm assets. It never
retries a write. A failed rollout leaves the already routed processes running so
you can inspect the logs; Ctrl-C explicitly stops the application processes.
The script prints the count of complete CRUD cycles and the log directory.
The proxy is a small local demonstration; use your deployment platform's load
balancer and equivalent readiness/drain rules in a real cluster.

PostgreSQL data stays in `example/db-migration-example/.local/postgres` after
Ctrl-C. Stop that local cluster separately with:

```sh
bash example/db-migration-example/stop-local.sh
```

`TODO_DB_PORT` and `TODO_PROXY_PORT` change the local ports. The proxy also uses
the following three ports for its request processes. Re-running against the
retained database observes its existing history; it does not replay committed
DDL or reset your todos. For a separate fresh demonstration, set
`TODO_LOCAL_DIR` to a new directory and choose an unused `TODO_DB_PORT`.

## What the seven versions actually do

| Version | Storage change | Retained rows and old writers |
| --- | --- | --- |
| V1 | Todo with a proven title and completion flag | Baseline |
| V2 | Add `details: Maybe String` | SQL NULL becomes `Nothing` |
| V3 | Add `dueAt: Maybe PosixMillis` | The same nullable addition for a different type |
| V4 | Add Project with an index on `archived` | Existing todos are untouched; the new table and its initial index are created together |
| V5 | Add `projectId: Maybe String` to Todo | A second optional text field; no mandatory link or join |
| V6 | Add `description: Maybe String` to Project | Repeat the nullable addition on the other entity |
| V7 | Add required `priority: Int` with `Default priority 0` | Retained rows and V1–V6 inserts get zero; the V7 constructor also supplies zero |

The migration default and constructor solve different problems. A constructor
creates values for the new binary. The migration also defines how existing rows
and still-running old writers populate the new column. V7 demonstrates why
updating only a constructor is insufficient.

`ValidTitle` is established after trimming and checking a 1–120 character title.
Both inserts and updates pass that proof to storage. The checked `Same` entries
preserve the unchanged stored title fact across these additive steps. They do not
authorize running arbitrary new transformation code on old rows.

The frontend deliberately uses a stable public DTO. Adding an internal field or
a new table does not automatically expand HTTP responses or force handler edits.
The optional fields and Project table prepare later app features; they are not
pretended to be visible features of this basic todo screen.

This first runnable sequence covers nullable additions, creation of an entity
with its initial index, and a typed constant default. It does **not** claim to
exercise concurrent indexes on populated tables, derived-field backfills,
record/ADT JSONB changes, repair, retirement or physical contraction. Those
require the corresponding runtime protocols and additional release scenarios;
a new JSON codec by itself does not migrate stored JSON.

## Want to update the database? Follow these steps

Work in this example's directory with the native `tesl` CLI and current compiler:

```sh
cd example/db-migration-example
# Freeze the accepted current schema and open the next editable revision.
tesl migrate generate todo-app.tesl --new-revision
```

Edit only `schema/todo/v-current.tesl` and its children. For example, add another
optional field to Todo and supply `Nothing` in `newTodo`. Keep database
connections, handlers and environment access in `todo-app.tesl`; schema modules
are pure. Then refresh the migration against the actual saved source:

```sh
tesl agent-context todo-app.tesl
tesl migrate generate todo-app.tesl
tesl agent-context todo-app.tesl
tesl migrate plan todo-app.tesl
```

A stale-target diagnostic immediately after a schema edit means the editable
migration needs refreshing. Read the generated migration. If a required field
has no additive value source, generation leaves an explicit `todo` to resolve;
V7 shows `Additive [Default priority 0]`. Never hide a transformation requirement
by selecting an arbitrary constant. Check the migration and plan again, run the
app and migration regression tests, and review both the behavior and history.

Once accepted, compile a standalone release with the normal CLI:

```sh
tesl compile todo-app.tesl --out /tmp/todo-next-go
(cd /tmp/todo-next-go && go test ./internal/teslmodtodoapp && go build -o /tmp/todo-next ./cmd/app)
```

Deploy that executable as the new schema worker first, then roll request
processes using readiness and draining. Source files and compiler executables
are not needed on deployed nodes. Do not edit a frozen schema or an accepted
migration to make a compiler error disappear. Its exact source and semantic
compatibility contract are part of the checked history.

## Worker credentials and ordinary deployment commands

The app explicitly selects `topology: Worker`. Every process agrees on
`TODO_CONTROL_OWNER`, `TODO_REQUEST_ROLE` and `TODO_WORKER_ROLE`.
`TODO_DB_USER` and `TODO_DB_PASSWORD` select that process's actual login.
`TODO_DB_HOST`, `TODO_DB_PORT` and `TODO_DB_NAME` select the database.
`TODO_HTTP_PORT` selects a request process's listener.

An operator provisions a NOLOGIN control owner, a temporary installer login,
a DML-only request login, and a separate schema worker login. The local setup
scripts show a concrete PostgreSQL grant profile. They create a dedicated,
loopback-only development cluster with local trust authentication. Production
credentials come from your own deployment's secret configuration.

```sh
# Once, using the installer with temporary membership in the control owner:
TODO_DB_USER=todo_installer ./app --schema install --worker todo_schema --request todo_app
# Revoke installer membership in the control owner before normal operation.

# Separate long-running process; no HTTP handlers:
TODO_DB_USER=todo_schema ./app --schema worker --json

# Ordinary app process; cannot perform migration DDL:
TODO_DB_USER=todo_app TODO_HTTP_PORT=8086 ./app

# Read-only observation using the request login:
TODO_DB_USER=todo_app ./app --schema status --json
```

An empty `TODO_DDL_CONNECTION` uses the worker's ordinary connection settings.
When requests use a transaction pooler, supply the worker with a trusted direct
or session-affine PostgreSQL DSN through that variable. Do not give the worker's
connection credentials to request processes. The application here is a shared
local todo list; authentication and user ownership are separate app concerns.

## Reproduce and test individual releases

The historical demo build is separate from the normal new-release workflow:

```sh
bash example/db-migration-example/build-revision.sh 4 /tmp/todo-v4
tesl migrate plan /tmp/todo-v4/source/todo-app.tesl
```

`build-revision.sh REVISION OUTPUT` requires a new output directory and creates
`source/`, `go/`, `release.json`, diagnostics and the standalone `app` binary. It
runs the emitted unit/API tests before building. `--emit-only` stops before Go
tests/build; `--prepare-only` restores only the reviewed source tree.

The small JSON archives under `releases/` retain the exact editable target source
and migration text captured when each revision was generated. Prior frozen
modules and migrations are copied verbatim from the canonical history. Every
release copies the same app file and verifies its hash. No archive build
regenerates a seal, rewrites its creator ABI, or marks a new proof as an old one.
If you change the app itself, use the normal compile workflow for that new app
release; the archived comparison intentionally requires the unchanged app.

Frontend compilation is independent: `bash example/db-migration-example/build-frontend.sh`.
No Elm download is required to compile or test the backend.

From the repository root:

```sh
# Unit and API tests in the current source:
tesl test example/db-migration-example/todo-app.tesl
# Archive integrity, real compiler refusal cases and proxy drain behavior:
python3 example/db-migration-example/scripts/test-workflow.py
# Real PostgreSQL, seven standalone releases and rolling requests:
bash scripts/run-migration-tests.sh -run '^TestCompiledTodoShowcaseRollingUpgrade$'
```

The app tests cover complete CRUD, list isolation, duplicate/missing IDs,
idempotent deletion, malformed JSON, title limits and invalid-update preservation.
The native migration regression builds each archive, checks unchanged app bytes,
keeps real PostgreSQL rows across worker and request rollouts, and probes a real
reverse proxy throughout. It also kills a V4 worker at an uncommitted new-table
boundary, verifies rollback and continued old requests, then resumes with the
ordinary worker. See that test's result for the executable coverage; the local
runner is a walkthrough, not a substitute for the regression gate.
