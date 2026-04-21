#!/usr/bin/env bash

SCRIPT_DIR=$(dirname "$(realpath "$0")")
REPO_ROOT=$(realpath "$SCRIPT_DIR/..")
TESL_POSTGRES_DIR=${TESL_POSTGRES_DIR:-$REPO_ROOT/.tesl-postgres}
TESL_POSTGRES_DATA_DIR=${TESL_POSTGRES_DATA_DIR:-$TESL_POSTGRES_DIR/data}

if [ ! -f "$TESL_POSTGRES_DATA_DIR/PG_VERSION" ]; then
  printf 'No local Postgres data directory found at %s\n' "$TESL_POSTGRES_DATA_DIR"
  exit 0
fi

if pg_ctl -D "$TESL_POSTGRES_DATA_DIR" status >/dev/null 2>&1; then
  pg_ctl -D "$TESL_POSTGRES_DATA_DIR" -m fast stop >/dev/null
  printf 'Stopped Postgres at %s\n' "$TESL_POSTGRES_DATA_DIR"
else
  printf 'Postgres is not running for %s\n' "$TESL_POSTGRES_DATA_DIR"
fi
