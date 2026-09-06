# Local deployment demonstration

These scripts build saved app releases, provision a dedicated local PostgreSQL
cluster, and roll two request processes behind a small HTTP reverse proxy.
They are generic deployment support for this example. Database migration rules
live in `../migrations/` and execute inside the compiled Tesl schema worker.

From the repository root:

```sh
bash example/db-migration-example/deploy/run-cluster.sh
```

The script builds and tests the backend releases before deployment, compiles Elm,
and starts the dedicated database on port 55439. The proxy serves the UI and
round-robins API calls without retrying writes. Each new node must become ready
before replacing an old node; old requests drain before its process stops.
Continuous create/update/read/delete probes check every rollout.

Ctrl-C stops the app processes. PostgreSQL and its data remain under
`example/db-migration-example/.local-schema-todo/`. Logs and the saved binaries are printed
when the demo starts. Stop the owned database separately:

```sh
bash example/db-migration-example/deploy/stop-local.sh
```

`TODO_DB_PORT` and `TODO_PROXY_PORT` select different local ports. The proxy also
uses the next three ports for backend processes. `TODO_LOCAL_DIR` selects a new
owned data directory. Re-running against retained data observes the existing
history; it does not reset todos or replay committed DDL.

**Ran an earlier checkout with `TodoSchema`?** Its retained `.local/` database
belongs to a different schema identity. Keep it intact; the regenerated
`Schema.Todo` example uses a fresh default data directory. If the old database
still uses port 55439, choose another port:

```sh
TODO_LOCAL_DIR="$PWD/example/db-migration-example/.local-schema-todo" TODO_DB_PORT=55440 \
  bash example/db-migration-example/deploy/run-cluster.sh
```

The setup script refuses the old demo marker before invoking PostgreSQL tools.
It never renames, reseals or resets that retained history. Re-running against
retained data above means data created by this same new history.

## Ordinary deployments

The app explicitly selects Worker topology. Processes agree on
`TODO_CONTROL_OWNER`, `TODO_REQUEST_ROLE` and `TODO_WORKER_ROLE`.
`TODO_DB_USER`/`TODO_DB_PASSWORD` select the actual process login;
`TODO_DB_HOST`/`TODO_DB_PORT`/`TODO_DB_NAME` select the database.
`TODO_HTTP_PORT` selects a request listener.

Provision a NOLOGIN control owner, a temporary installer login, a request login
with DML access, and a separate schema worker login. `setup-local.sh` shows the
grants in a dedicated loopback-only development cluster with trust authentication.
Production supplies its own database and credentials.

```sh
# Bootstrap, with temporary installer membership in the control owner:
TODO_DB_USER=todo_installer ./app --schema install --worker todo_schema --request todo_app
# Revoke that installer membership before normal operation.

TODO_DB_USER=todo_schema ./app --schema worker --json
TODO_DB_USER=todo_app TODO_HTTP_PORT=8086 ./app
TODO_DB_USER=todo_app ./app --schema status --json
```

An empty `TODO_DDL_CONNECTION` uses the worker's normal connection settings.
When requests use a transaction pooler, the worker needs a trusted direct or
session-affine DSN through that variable. Request processes do not need the
worker credentials. The app is a shared todo list; authentication and user
ownership are separate app features.

The same worker/request split can be deployed with Helm or another deployment
system. This local example does not require Kubernetes; its proxy illustrates
readiness and draining without introducing a separate orchestration platform.

## Historical test fixtures

`releases/vN.json` preserves the exact editable target inputs saved at each
reviewed version. `build-revision.sh` combines those inputs with the canonical
frozen predecessors and verifies the unchanged app hash. It never regenerates
seals or rewrites the recorded creator ABI.

```sh
bash example/db-migration-example/deploy/build-revision.sh 4 /tmp/todo-v4
```

The output must be new. It contains `source/`, `go/`, `release.json`, diagnostics
and the standalone `app`. The script runs emitted unit/API tests before building.
`--emit-only` stops before Go tests/build; `--prepare-only` restores source only.
Use the normal `tesl compile` workflow for new app changes rather than modifying
these saved comparison fixtures.

Frontend compilation is independent:
`bash example/db-migration-example/deploy/build-frontend.sh`.
Backend tests do not require an Elm package download.

The local deployment and fixture regressions are:
`python3 example/db-migration-example/deploy/test-workflow.py`.
The deeper PostgreSQL acceptance gate is documented in the main README.
