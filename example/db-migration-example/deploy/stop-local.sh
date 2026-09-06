#!/usr/bin/env bash
set -euo pipefail
APP_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$APP_DIR/deploy/local-env.sh"
if [[ ! -f "$TODO_LOCAL_DIR/todo-demo-cluster" || ! -f "$TODO_LOCAL_DIR/postgres/PG_VERSION" ]]; then
  echo "Refusing to stop a PostgreSQL directory not created by this demo: $TODO_LOCAL_DIR/postgres" >&2
  exit 1
fi
pg_ctl -D "$TODO_LOCAL_DIR/postgres" -m fast -w stop
