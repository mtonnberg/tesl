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
# Bound every libpq connection attempt: on WSL2 mirrored networking a
# Windows-reserved port black-holes connects instead of refusing them,
# and an untimed createdb would block forever.
export PGCONNECT_TIMEOUT=${PGCONNECT_TIMEOUT:-3}

bash "$SCRIPT_DIR/postgres-init.sh"

if pg_ctl -D "$TESL_POSTGRES_DATA_DIR" status >/dev/null 2>&1; then
  printf 'Postgres is already running from %s\n' "$TESL_POSTGRES_DATA_DIR"
else
  if pg_ctl -D "$TESL_POSTGRES_DATA_DIR" \
       -l "$TESL_POSTGRES_LOG" \
       -o "-F -k $TESL_POSTGRES_SOCKET_DIR -p $TESL_POSTGRES_PORT" \
       -w start >/dev/null; then
    printf 'Started Postgres on port %s\n' "$TESL_POSTGRES_PORT"
  else
    printf 'ERROR: Postgres failed to start on port %s; last log lines:\n' "$TESL_POSTGRES_PORT" >&2
    tail -n 5 "$TESL_POSTGRES_LOG" >&2 2>/dev/null
    if tail -n 20 "$TESL_POSTGRES_LOG" 2>/dev/null | grep -q 'Address already in use'; then
      printf 'HINT: port %s is taken. On WSL2 check Windows-reserved ranges:\n' "$TESL_POSTGRES_PORT" >&2
      printf '  netsh int ipv4 show excludedportrange protocol=tcp\n' >&2
    fi
    exit 1
  fi
fi

createdb -h 127.0.0.1 -p "$TESL_POSTGRES_PORT" -U "$TESL_POSTGRES_USER" "$TESL_POSTGRES_DATABASE" >/dev/null 2>&1 || true
printf 'Database %s is ready for tesl examples\n' "$TESL_POSTGRES_DATABASE"
