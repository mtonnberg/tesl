#!/usr/bin/env bash
# The migration protocol suite owns its PostgreSQL cluster. It never reuses a
# developer's application database or modifies a shared cluster's login roles.
set -euo pipefail
repo_root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
required_tools=(initdb pg_ctl go python3)
if [[ ${TESL_MIGRATION_TEST_POOLERS:-0} == 1 ]]; then required_tools+=(pgbouncer); fi
if [[ ${TESL_MIGRATION_TEST_CLUSTER_CRASH:-0} == 1 ]]; then required_tools+=(pg_basebackup); fi
for tool in "${required_tools[@]}"; do
  command -v "$tool" >/dev/null || { echo "migration tests require $tool (nix develop)" >&2; exit 1; }
done
migration_tmp="$(mktemp -d "${TMPDIR:-/tmp}/tesl-migration.XXXXXXXX")"
# PostgreSQL's Unix socket filename is limited to 107 bytes on Linux. Keep the
# data/build files on TMPDIR, while allowing a short socket-only directory.
migration_socket=""
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
  if [[ -n "$migration_socket" ]]; then rmdir -- "$migration_socket" 2>/dev/null || true; fi
  rm -rf -- "$migration_tmp"
  return "$status"
}
trap cleanup EXIT INT TERM
migration_socket="$(mktemp -d "${TESL_MIGRATION_TEST_SOCKET_TMPDIR:-$migration_tmp}/socket.XXXXXXXX")"
# Event-control sockets in compiled applications and runtime crash tests need
# the same short-path treatment as PostgreSQL itself.
export TESL_MIGRATION_TEST_SOCKET_TMPDIR="${TESL_MIGRATION_TEST_SOCKET_TMPDIR:-$migration_tmp}"
export TESL_MIGRATION_TEST_SOCKET_ROOT="${TESL_MIGRATION_TEST_SOCKET_ROOT:-$TESL_MIGRATION_TEST_SOCKET_TMPDIR}"
initdb -D "$migration_tmp/data" -U migration_installer --auth=trust --no-locale --encoding=UTF8 >"$migration_tmp/init.log"
# A private Unix socket removes port-allocation races and network exposure.
pg_ctl -D "$migration_tmp/data" -l "$migration_tmp/postgres.log" -o "-k $migration_socket -h '' -c max_connections=40 -c log_min_duration_statement=1000 -c log_lock_waits=on -c log_checkpoints=on" -w start >/dev/null
export TESL_MIGRATION_TEST_DSN="host=$migration_socket user=migration_installer dbname=postgres"
export TESL_MIGRATION_TEST_REQUIRE_POSTGRES=1
export TESL_TEST_POSTGRES_SHARED_HOST="$migration_socket"
export TESL_TEST_POSTGRES_SHARED_PORT=5432
export TESL_TEST_POSTGRES_SHARED_USER=migration_installer
export TESL_TEST_POSTGRES_SHARED_ADMIN_DATABASE=postgres
export TESL_REPO_ROOT="$repo_root"
cd "$repo_root/runtime/go"
# This package builds and runs both the archived rolling releases and the full
# V1–V13 transforming application. Keep individual scenario deadlines intact,
# but allow their sequential sum to finish after repairing earlier short exits.
go test -race -count=1 -timeout=1800s ./internal/migrationtest "$@"
if (( $# == 0 )); then
  # Production control/executor APIs and their crash tests use the same
  # isolated cluster and supported-major matrix as the independent harness.
  go test -race -count=1 -timeout=300s -tags=tesl_migration_test ./teslrt -run '^TestPgMigration(Control|Expansion|Admission|Boot|Status|Install|StoredValueCompatibility|Compatibility|Worker)'
  # Long-running index work and its application lifetime have independent
  # mandatory budgets; neither gate may skip unavailable PostgreSQL.
  go test -race -count=1 -timeout=300s -tags=tesl_migration_test ./teslrt -run '^(TestPgMigration(Index|FutureIndex|Embedded)|TestServe(Shutdown|ListenFailure))'
  # Permanent generation baseline: marker/catalog/role guards and real backend deaths.
  go test -race -count=1 -timeout=300s -tags=tesl_migration_test ./teslrt -run '^(TestPgRowBaseline|TestPgRowIndex|TestPgRowEpoch|TestRowBaseline|TestRowPhysical|TestPgRowForwardInvalidation)'
  (cd "$repo_root/compiler" && dune build test/test_migration_queue.exe && dune exec --no-build ./test/test_migration_queue.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_queue_transform.exe && dune exec --no-build ./test/test_migration_queue_transform.exe)
  go test -race -count=1 -timeout=60s ./teslrt -run '^TestQueueConversionPipeline'
  (cd "$repo_root/compiler" && dune build test/test_migration_queue_application.exe && dune exec --no-build ./test/test_migration_queue_application.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_fixtures.exe && dune exec --no-build ./test/test_migration_fixtures.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_row_companion.exe && dune exec --no-build ./test/test_migration_row_companion.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_contract.exe && dune exec --no-build ./test/test_migration_contract.exe)
  # Typed source/target and reverse JSONB codecs must exercise real PostgreSQL.
  (cd "$repo_root/compiler" && dune build test/test_migration_row_storage.exe && dune exec --no-build ./test/test_migration_row_storage.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_retype.exe && dune exec --no-build ./test/test_migration_retype.exe)
  # Actual separately compiled predecessor/successor executables, including a
  # compatible second compiler build; no patched runtime or metadata fixtures.
  (cd "$repo_root/compiler" && dune build test/test_migration_row_forward.exe && dune exec --no-build ./test/test_migration_row_forward.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_row_access.exe && dune exec --no-build ./test/test_migration_row_access.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_delete.exe && dune exec --no-build ./test/test_migration_delete.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_row_additive.exe && dune exec --no-build ./test/test_migration_row_additive.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_row_tables.exe && dune exec --no-build ./test/test_migration_row_tables.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_row_indexes.exe && dune exec --no-build ./test/test_migration_row_indexes.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_additive_tail.exe && dune exec --no-build ./test/test_migration_additive_tail.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_row_derived.exe && dune exec --no-build ./test/test_migration_row_derived.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_nominal_derived.exe && dune exec --no-build ./test/test_migration_nominal_derived.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_nominal_optional.exe && dune exec --no-build ./test/test_migration_nominal_optional.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_row_scc.exe && dune exec --no-build ./test/test_migration_row_scc.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_row_civil.exe && dune exec --no-build ./test/test_migration_row_civil.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_nominal_pk.exe && dune exec --no-build ./test/test_migration_nominal_pk.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_nominal_copy.exe && dune exec --no-build ./test/test_migration_nominal_copy.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_row_contract_abi.exe && dune exec --no-build ./test/test_migration_row_contract_abi.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_row_retype_physical.exe && dune exec --no-build ./test/test_migration_row_retype_physical.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_revalidate.exe && dune exec --no-build ./test/test_migration_revalidate.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_revalidate_postgres.exe && dune exec --no-build ./test/test_migration_revalidate_postgres.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_reverse_proof.exe && dune exec --no-build ./test/test_migration_reverse_proof.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_proof_retype_postgres.exe && dune exec --no-build ./test/test_migration_proof_retype_postgres.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_proof_removal_postgres.exe && dune exec --no-build ./test/test_migration_proof_removal_postgres.exe)
  (cd "$repo_root/compiler" && dune build test/test_proof_return_field_scope.exe && dune exec --no-build ./test/test_proof_return_field_scope.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_table_drop.exe && dune exec --no-build ./test/test_migration_table_drop.exe)
  (cd "$repo_root/compiler" && dune build test/test_migration_table_drop_postgres.exe && dune exec --no-build ./test/test_migration_table_drop_postgres.exe)
  go test -race -count=1 -timeout=120s -tags=tesl_migration_test ./teslrt -run '^(TestRowRetirement|TestRowTableContract|TestPgRowTableContract|TestPgRowTableDrop)'
  python3 "$repo_root/example/db-three-upgrades/run.py" --output "$migration_tmp/review05-releases/row"
  python3 "$repo_root/example/queue-three-upgrades/run.py" --output "$migration_tmp/review05-releases/queue"
  python3 "$repo_root/scripts/test-db-migration-review-05.py" --artifacts "$migration_tmp/review05-releases" --output "$migration_tmp/review05-results"
  python3 "$repo_root/scripts/test-db-migration-review-11.py" --artifacts "$migration_tmp/review05-releases" --output "$migration_tmp/review11-results"
fi
