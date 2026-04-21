#!/usr/bin/env bash

SCRIPT_DIR=$(dirname "$(realpath "$0")")
REPO_ROOT=$(realpath "$SCRIPT_DIR/..")
TESL_POSTGRES_DIR=${TESL_POSTGRES_DIR:-$REPO_ROOT/.tesl-postgres}
TESL_POSTGRES_DATA_DIR=${TESL_POSTGRES_DATA_DIR:-$TESL_POSTGRES_DIR/data}
TESL_POSTGRES_LOG=${TESL_POSTGRES_LOG:-$TESL_POSTGRES_DIR/postgres.log}
TESL_POSTGRES_SOCKET_DIR=${TESL_POSTGRES_SOCKET_DIR:-$TESL_POSTGRES_DIR}
TESL_POSTGRES_PORT=${TESL_POSTGRES_PORT:-55432}
TESL_POSTGRES_USER=${TESL_POSTGRES_USER:-tesl}
TESL_POSTGRES_DATABASE=${TESL_POSTGRES_DATABASE:-tesl}

bash "$SCRIPT_DIR/postgres-init.sh"

if pg_ctl -D "$TESL_POSTGRES_DATA_DIR" status >/dev/null 2>&1; then
  printf 'Postgres is already running from %s\n' "$TESL_POSTGRES_DATA_DIR"
else
  pg_ctl -D "$TESL_POSTGRES_DATA_DIR" \
    -l "$TESL_POSTGRES_LOG" \
    -o "-F -k $TESL_POSTGRES_SOCKET_DIR -p $TESL_POSTGRES_PORT" \
    -w start >/dev/null
  printf 'Started Postgres on port %s\n' "$TESL_POSTGRES_PORT"
fi

createdb -h 127.0.0.1 -p "$TESL_POSTGRES_PORT" -U "$TESL_POSTGRES_USER" "$TESL_POSTGRES_DATABASE" >/dev/null 2>&1 || true
printf 'Database %s is ready for tesl examples\n' "$TESL_POSTGRES_DATABASE"
