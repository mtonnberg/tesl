#!/usr/bin/env bash

SCRIPT_DIR=$(dirname "$(realpath "$0")")
REPO_ROOT=$(realpath "$SCRIPT_DIR/..")
TESL_POSTGRES_DIR=${TESL_POSTGRES_DIR:-$REPO_ROOT/.tesl-postgres}
TESL_POSTGRES_DATA_DIR=${TESL_POSTGRES_DATA_DIR:-$TESL_POSTGRES_DIR/data}
TESL_POSTGRES_USER=${TESL_POSTGRES_USER:-tesl}

if [ -f "$TESL_POSTGRES_DATA_DIR/PG_VERSION" ]; then
  printf 'Postgres data directory already initialized at %s\n' "$TESL_POSTGRES_DATA_DIR"
  exit 0
fi

mkdir -p "$TESL_POSTGRES_DIR"
initdb -D "$TESL_POSTGRES_DATA_DIR" -A trust -U "$TESL_POSTGRES_USER" --locale=C >/dev/null
printf 'Initialized Postgres data directory at %s\n' "$TESL_POSTGRES_DATA_DIR"
