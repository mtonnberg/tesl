#!/usr/bin/env bash
# Local demo identities only. Production should inject its own role credentials.
TODO_APP_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export TODO_LOCAL_DIR="${TODO_LOCAL_DIR:-$TODO_APP_DIR/.local}"
export TODO_DB_HOST=127.0.0.1
export TODO_DB_PORT="${TODO_DB_PORT:-55439}"
export TODO_DB_NAME=todo_demo
export TODO_CONTROL_OWNER=todo_control
export TODO_REQUEST_ROLE=todo_app
export TODO_WORKER_ROLE=todo_schema
export TODO_DB_PASSWORD=""
export TODO_DDL_CONNECTION=""
case "$TODO_DB_PORT" in ''|*[!0-9]*) echo 'TODO_DB_PORT must be a TCP port number' >&2; return 2 ;; esac
if (( TODO_DB_PORT < 1024 || TODO_DB_PORT > 65535 )); then echo 'TODO_DB_PORT must be 1024..65535' >&2; return 2; fi
# pgx also reads PostgreSQL's standard environment. Pin it to this local cluster
# so an ambient production PGHOST/PGSERVICE cannot redirect a demo process.
unset PGSERVICE PGSERVICEFILE PGHOSTADDR PGOPTIONS
export PGHOST="$TODO_DB_HOST" PGPORT="$TODO_DB_PORT" PGDATABASE="$TODO_DB_NAME"
export PGUSER="$TODO_REQUEST_ROLE" PGPASSWORD="" PGPASSFILE=/dev/null PGSSLMODE=disable
export PGTARGETSESSIONATTRS=any PGCONNECT_TIMEOUT=10
