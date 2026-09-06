#!/usr/bin/env bash
# Bootstrap only. Ordinary releases use --schema worker, never install again.
set -euo pipefail
APP_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
source "$APP_DIR/scripts/local-env.sh"
if (( $# != 1 )); then echo "usage: $0 APP_BINARY" >&2; exit 2; fi
export PGHOST="$TODO_DB_HOST" PGPORT="$TODO_DB_PORT" PGUSER=todo_setup_admin PGDATABASE=todo_demo
psql -X -v ON_ERROR_STOP=1 -c 'GRANT todo_control TO todo_installer'
cleanup() { psql -X -v ON_ERROR_STOP=1 -c 'REVOKE todo_control FROM todo_installer'; }
trap cleanup EXIT
TODO_DB_USER=todo_installer "$1" --schema install --worker "$TODO_WORKER_ROLE" --request "$TODO_REQUEST_ROLE" --json
