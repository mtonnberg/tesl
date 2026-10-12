#!/usr/bin/env bash
# The migration protocol suite owns its PostgreSQL cluster. It never reuses a
# developer's application database or modifies a shared cluster's login roles.
# CI's supported-major matrix calls this same complete gate, with matching
# PostgreSQL tools on PATH. Arguments select focused kernel tests only.
set -euo pipefail
repo_root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
required_tools=(initdb pg_ctl go python3 dune timeout tee)
if [[ ${TESL_MIGRATION_TEST_POOLERS:-0} == 1 ]]; then required_tools+=(pgbouncer); fi
if [[ ${TESL_MIGRATION_TEST_CLUSTER_CRASH:-0} == 1 ]]; then required_tools+=(pg_basebackup); fi
for tool in "${required_tools[@]}"; do
  command -v "$tool" >/dev/null || { echo "migration tests require $tool (nix develop)" >&2; exit 1; }
done
migration_tmp="$(mktemp -d "${TESL_MIGRATION_TEST_DATA_TMPDIR:-${TMPDIR:-/tmp}}/tesl-migration.XXXXXXXX")"
evidence="${TESL_MIGRATION_TEST_OUTPUT:-$(mktemp -d "${TMPDIR:-/tmp}/tesl-migration-evidence.XXXXXXXX")}"
mkdir -p "$evidence"
printf 'Migration gate evidence: %s\n' "$evidence"
printf 'phase\tseconds\texit_code\n' >"$evidence/phases.tsv"
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
  if [[ -f "$migration_tmp/postgres.log" ]]; then
    cp -- "$migration_tmp/postgres.log" "$evidence/postgres.log" || status=1
  fi
  if [[ -n "$migration_socket" ]]; then rmdir -- "$migration_socket" 2>/dev/null || true; fi
  rm -rf -- "$migration_tmp"
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
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
run_phase() {
  local name="$1" budget="$2" started=$SECONDS result=0
  shift 2
  printf '\nMigration phase: %s (outer limit %ss)\n' "$name" "$budget"
  timeout --kill-after=30s "${budget}s" "$@" 2>&1 | tee "$evidence/$name.log" || result=$?
  printf '%s\t%s\t%s\n' "$name" "$((SECONDS - started))" "$result" >>"$evidence/phases.tsv"
  return "$result"
}
compiler_test() {
  run_phase "$1" 1800 dune exec --root "$repo_root/compiler" --no-build "./test/$1.exe"
}
runtime_test() {
  local name="$1" budget="$2" pattern="$3"
  run_phase "$name" "$((budget + 60))" go -C "$repo_root/runtime/go" test \
    -race -count=1 "-timeout=${budget}s" -tags=tesl_migration_test ./teslrt -run "$pattern"
}
run_phase compiler-build 1800 dune build --root "$repo_root/compiler" -j "${TESL_CI_JOBS:-2}"
# This package builds and runs both the archived rolling releases and the full
# V1–V13 transforming application. Keep individual scenario deadlines intact,
# but allow their sequential sum to finish after repairing earlier short exits.
run_phase kernel 1860 go -C "$repo_root/runtime/go" test -race -count=1 -timeout=1800s -v ./internal/migrationtest "$@"
if (( $# == 0 )); then
  # Production control/executor APIs and their crash tests use the same
  # isolated cluster and supported-major matrix as the independent harness.
  runtime_test control 300 '^TestPgMigration(Control|Expansion|Admission|Boot|Status|Install|StoredValueCompatibility|Compatibility|Worker)'
  # Long-running index work and its application lifetime have independent
  # mandatory budgets; neither gate may skip unavailable PostgreSQL.
  runtime_test indexes 300 '^(TestPgMigration(Index|FutureIndex|Embedded)|TestServe(Shutdown|ListenFailure))'
  # Permanent generation baseline: marker/catalog/role guards and real backend deaths.
  runtime_test row-baseline 300 '^(TestPgRowBaseline|TestPgRowIndex|TestPgRowEpoch|TestRowBaseline|TestRowPhysical|TestPgRowForwardInvalidation)'
  # Preserve the former matrix-only suites in the shared gate as well.
  runtime_test queue-runtime 300 '^(TestQueue|TestDurableQueue|TestAppPreflight|TestDeadJob|TestDurableDeadJob|TestWorkerLifetime)'
  runtime_test row-generation 300 '^(TestPgMigration(TriggerCatalog|RowGeneration)|TestMigrationRowGeneration)'
  compiler_test test_migration_queue
  compiler_test test_migration_queue_transform
  run_phase queue-pipeline 120 go -C "$repo_root/runtime/go" test -race -count=1 -timeout=60s ./teslrt -run '^TestQueueConversionPipeline'
  # Exact source/target codecs, separate predecessor/successor executables,
  # proof obligations and the isolated candidate all remain mandatory.
  for suite in \
    test_migration_queue_application test_queue_candidate_app \
    test_migration_fixtures test_migration_row_companion test_migration_contract \
    test_migration_row_storage test_migration_retype test_migration_row_forward \
    test_migration_row_access test_migration_delete test_migration_row_additive \
    test_migration_row_tables test_migration_row_indexes test_migration_additive_tail \
    test_migration_row_derived test_migration_nominal_derived test_migration_nominal_optional \
    test_migration_row_scc test_migration_row_civil test_migration_nominal_pk \
    test_migration_nominal_copy test_migration_row_contract_abi test_migration_row_retype_physical \
    test_migration_revalidate test_migration_revalidate_postgres test_migration_reverse_proof \
    test_migration_proof_retype_postgres test_migration_proof_removal_postgres \
    test_proof_return_field_scope test_migration_table_drop test_migration_table_drop_postgres; do
    compiler_test "$suite"
  done
  runtime_test row-retirement 120 '^(TestRowRetirement|TestRowTableContract|TestPgRowTableContract|TestPgRowTableDrop)'
  run_phase row-releases 3600 python3 "$repo_root/example/db-three-upgrades/run.py" --output "$migration_tmp/review05-releases/row"
  run_phase queue-releases 3600 python3 "$repo_root/example/queue-three-upgrades/run.py" --output "$migration_tmp/review05-releases/queue"
  run_phase review05 3600 python3 "$repo_root/scripts/test-db-migration-review-05.py" --artifacts "$migration_tmp/review05-releases" --output "$migration_tmp/review05-results"
  run_phase review11 3600 python3 "$repo_root/scripts/test-db-migration-review-11.py" --artifacts "$migration_tmp/review05-releases" --output "$migration_tmp/review11-results"
  run_phase twenty-releases 3600 python3 "$repo_root/example/db-twenty-releases/run.py" --output "$migration_tmp/twenty-releases"
fi
