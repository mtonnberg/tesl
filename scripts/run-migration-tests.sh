#!/usr/bin/env bash
# The migration protocol suite owns its PostgreSQL cluster. It never reuses a
# developer's application database or modifies a shared cluster's login roles.
set -euo pipefail
repo_root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
required_tools=(initdb pg_ctl go)
if [[ ${TESL_MIGRATION_TEST_POOLERS:-0} == 1 ]]; then required_tools+=(pgbouncer); fi
if [[ ${TESL_MIGRATION_TEST_CLUSTER_CRASH:-0} == 1 ]]; then required_tools+=(pg_basebackup); fi
for tool in "${required_tools[@]}"; do
  command -v "$tool" >/dev/null || { echo "migration tests require $tool (nix develop)" >&2; exit 1; }
done
migration_tmp="$(mktemp -d "${TMPDIR:-/tmp}/tesl-migration.XXXXXXXX")"
cleanup() {
  local status=$?
  if (( status != 0 )) && [[ -f "$migration_tmp/postgres.log" ]]; then
    local failure_log
    if failure_log="$(mktemp "${TMPDIR:-/tmp}/tesl-migration-postgres.XXXXXXXX.log")" &&
       cp -- "$migration_tmp/postgres.log" "$failure_log"; then
      echo "Complete migration test PostgreSQL log: $failure_log" >&2
    fi
    echo "Migration test PostgreSQL log (last 100 lines):" >&2
    tail -100 "$migration_tmp/postgres.log" >&2
  fi
  pg_ctl -D "$migration_tmp/data" -m immediate -w stop >/dev/null 2>&1 || true
  rm -rf -- "$migration_tmp"
  return "$status"
}
trap cleanup EXIT INT TERM
mkdir "$migration_tmp/socket"
initdb -D "$migration_tmp/data" -U migration_installer --auth=trust --no-locale --encoding=UTF8 >"$migration_tmp/init.log"
# A private Unix socket removes port-allocation races and network exposure.
pg_ctl -D "$migration_tmp/data" -l "$migration_tmp/postgres.log" -o "-k $migration_tmp/socket -h '' -c max_connections=40 -c log_min_duration_statement=1000 -c log_lock_waits=on -c log_checkpoints=on" -w start >/dev/null
export TESL_MIGRATION_TEST_DSN="host=$migration_tmp/socket user=migration_installer dbname=postgres"
export TESL_TEST_POSTGRES_SHARED_HOST="$migration_tmp/socket"
export TESL_TEST_POSTGRES_SHARED_PORT=5432
export TESL_TEST_POSTGRES_SHARED_USER=migration_installer
export TESL_TEST_POSTGRES_SHARED_ADMIN_DATABASE=postgres
export TESL_REPO_ROOT="$repo_root"
cd "$repo_root/runtime/go"
go test -race -count=1 -timeout=180s ./internal/migrationtest "$@"
