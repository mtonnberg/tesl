#!/usr/bin/env bash
# Creates a dedicated local demo cluster. Never touches an existing remote database.
set -euo pipefail
APP_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$APP_DIR/deploy/local-env.sh"
if [[ -f "$TODO_LOCAL_DIR/postgres/PG_VERSION" && ! -f "$TODO_LOCAL_DIR/todo-demo-cluster" ]]; then
  echo "Refusing a PostgreSQL directory not created by this demo: $TODO_LOCAL_DIR/postgres" >&2
  exit 1
fi
if [[ -f "$TODO_LOCAL_DIR/postgres/PG_VERSION" && "$(cat "$TODO_LOCAL_DIR/todo-demo-cluster")" != 'Field Notes Schema.Todo contract-5 local PostgreSQL cluster' ]]; then
  echo 'This retained demo directory uses an earlier schema or stored-value contract. Its history is a different identity.' >&2
  echo 'Keep that data intact. Choose a fresh TODO_LOCAL_DIR and an unused TODO_DB_PORT; no schema was changed.' >&2
  exit 1
fi
mkdir -p "$TODO_LOCAL_DIR/socket"
if [[ ! -f "$TODO_LOCAL_DIR/postgres/PG_VERSION" ]]; then
  initdb -D "$TODO_LOCAL_DIR/postgres" -U todo_setup_admin --auth-local=trust --auth-host=trust > "$TODO_LOCAL_DIR/initdb.log"
  printf 'Field Notes Schema.Todo contract-5 local PostgreSQL cluster\n' > "$TODO_LOCAL_DIR/todo-demo-cluster"
fi
if ! pg_ctl -D "$TODO_LOCAL_DIR/postgres" status >/dev/null 2>&1; then
  pg_ctl -D "$TODO_LOCAL_DIR/postgres" -l "$TODO_LOCAL_DIR/postgres.log" \
    -o "-p $TODO_DB_PORT -h 127.0.0.1 -k '$TODO_LOCAL_DIR/socket'" -w start
fi
export PGHOST="$TODO_DB_HOST" PGPORT="$TODO_DB_PORT" PGUSER=todo_setup_admin PGDATABASE=postgres
ACTUAL_DATA="$(psql -X -At -v ON_ERROR_STOP=1 -c 'SHOW data_directory')"
if [[ "$(realpath -- "$ACTUAL_DATA")" != "$(realpath -- "$TODO_LOCAL_DIR/postgres")" ]]; then
  echo 'The selected port belongs to a different PostgreSQL cluster; no roles or database changed.' >&2
  exit 1
fi
# These identities live only in the dedicated cluster above. In production the DBA
# provisions equivalent roles; a request/worker never receives the admin password.
psql -X -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='todo_control') THEN CREATE ROLE todo_control NOLOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='todo_schema') THEN CREATE ROLE todo_schema LOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='todo_app') THEN CREATE ROLE todo_app LOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='todo_installer') THEN CREATE ROLE todo_installer LOGIN; END IF;
END $$;
SELECT 'CREATE DATABASE todo_demo' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='todo_demo') \gexec
GRANT CREATE ON DATABASE todo_demo TO todo_control;
REVOKE TEMPORARY ON DATABASE todo_demo FROM PUBLIC;
GRANT TEMPORARY ON DATABASE todo_demo TO todo_control, todo_schema;
SQL
PGDATABASE=todo_demo psql -X -v ON_ERROR_STOP=1 <<'SQL'
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT CREATE ON SCHEMA public TO todo_control;
SQL
printf 'Local PostgreSQL ready on 127.0.0.1:%s; data retained in %s/postgres\n' "$TODO_DB_PORT" "$TODO_LOCAL_DIR"
