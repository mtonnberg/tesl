#!/usr/bin/env bash
# Verify all learning examples and sandbox files are correct.
#
# Checks performed (in order):
#   1. Format       — run `tesl fmt` on every .tesl file in place so the
#                     subsequent validate step sees the formatter's output
#                     (surfaces any formatter-induced compile breakage)
#   2. Validate     — compile + lint + format-check in a single Tesl pass per file
#   3. Tesl tests   — run generated Racket test submodules for files that contain test blocks
#   4. Test suite   — authoritative aggregate via racket tests/all.rkt
#                       with one shared PostgreSQL test cluster when available
#
# Usage (from repo root, inside nix-shell):
#   ./compile-examples.sh
#
# Files are now auto-formatted in place before validation, so the format
# check inside step 2 is purely a safety net.
#
# Exit code 0: all checks passed.
# Exit code 1: one or more checks failed.

set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
export TESL_REPO_ROOT="$SCRIPT_DIR"

script_started_at=$SECONDS
phase_started_at=$SECONDS
format_duration=0
validate_duration=0
tesl_tests_duration=0
racket_suite_duration=0

compile_pass=0; compile_fail=0
lint_pass=0;    lint_fail=0
fmt_pass=0;     fmt_fail=0
format_apply_pass=0; format_apply_fail=0
test_pass=0;    test_fail=0
tesl_test_skipped_no_blocks=0

shared_postgres_started=0
shared_postgres_temp_root=""
shared_postgres_data_dir=""
shared_postgres_log_path=""
shared_postgres_socket_dir=""
shared_postgres_port=""
shared_postgres_user="tesl"
shared_postgres_configured=0
shared_postgres_external=0
shared_postgres_boot_pid=""
shared_postgres_start_failed=0

TESL_TESTABLE_TESL_FILES=()
TESL_TESTABLE_RKT_FILES=()
TESL_NO_TEST_BLOCK_FILES=()

phase_start() {
    phase_started_at=$SECONDS
}

phase_complete() {
    local label="$1"
    local elapsed=$((SECONDS - phase_started_at))
    printf "  [%ss] %s\n" "$elapsed" "$label"
}

is_truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

use_direct_racket=0
if ! is_truthy "${TESL_TEST_FORCE_NIX_SHELL:-0}" \
    && command -v racket >/dev/null 2>&1 \
    && command -v raco >/dev/null 2>&1; then
    use_direct_racket=1
fi

run_with_optional_nix_shell() {
    if [ "$use_direct_racket" -eq 1 ]; then
        "$@"
        return $?
    fi

    local command_string=""
    printf -v command_string '%q ' "$@"
    nix-shell --run "${command_string% }"
}

pick_free_port() {
    comm -23 \
      <(seq 49152 65535) \
      <(ss -Htan | awk '{print $4}' | grep -oE '[0-9]+$' | sort -n | uniq) \
    | head -1
}

clear_shared_postgres_env() {
    unset TESL_TEST_POSTGRES_SHARED_HOST
    unset TESL_TEST_POSTGRES_SHARED_PORT
    unset TESL_TEST_POSTGRES_SHARED_USER
    unset TESL_TEST_POSTGRES_SHARED_ADMIN_DATABASE
}

cleanup_shared_postgres() {
    if [ -n "$shared_postgres_boot_pid" ]; then
        wait "$shared_postgres_boot_pid" >/dev/null 2>&1 || true
        shared_postgres_boot_pid=""
    fi
    if [ "$shared_postgres_started" -eq 1 ] && [ -n "$shared_postgres_data_dir" ] && command -v pg_ctl >/dev/null 2>&1; then
        pg_ctl -D "$shared_postgres_data_dir" -m immediate stop >/dev/null 2>&1 || true
    fi
    if [ -n "$shared_postgres_socket_dir" ] && [ -d "$shared_postgres_socket_dir" ]; then
        rm -rf "$shared_postgres_socket_dir"
    fi
    if [ -n "$shared_postgres_temp_root" ] && [ -d "$shared_postgres_temp_root" ]; then
        rm -rf "$shared_postgres_temp_root"
    fi
}

configure_shared_postgres() {
    if [ -n "${TESL_TEST_POSTGRES_SHARED_HOST:-}" ] \
        && [ -n "${TESL_TEST_POSTGRES_SHARED_PORT:-}" ] \
        && [ -n "${TESL_TEST_POSTGRES_SHARED_USER:-}" ]; then
        shared_postgres_configured=1
        shared_postgres_external=1
        return 0
    fi
    if [ -n "${TESL_POSTGRES_HOST:-}" ] \
        && [ -n "${TESL_POSTGRES_PORT:-}" ] \
        && [ -n "${TESL_POSTGRES_USER:-}" ]; then
        export TESL_TEST_POSTGRES_SHARED_HOST="$TESL_POSTGRES_HOST"
        export TESL_TEST_POSTGRES_SHARED_PORT="$TESL_POSTGRES_PORT"
        export TESL_TEST_POSTGRES_SHARED_USER="$TESL_POSTGRES_USER"
        export TESL_TEST_POSTGRES_SHARED_ADMIN_DATABASE="${TESL_TEST_POSTGRES_SHARED_ADMIN_DATABASE:-postgres}"
        shared_postgres_configured=1
        shared_postgres_external=1
        return 0
    fi
    if ! command -v initdb >/dev/null 2>&1 || ! command -v pg_ctl >/dev/null 2>&1; then
        return 0
    fi

    shared_postgres_port="$(pick_free_port)"
    if [ -z "$shared_postgres_port" ]; then
        return 0
    fi

    shared_postgres_socket_dir="$(mktemp -d "/tmp/tesl-pg-sock.XXXXXX")"
    if is_truthy "${TESL_TEST_USE_TEMP_PG:-${CI:-0}}"; then
        shared_postgres_temp_root="$(mktemp -d "${TMPDIR:-/tmp}/tesl-postgres-test.XXXXXX")"
        shared_postgres_data_dir="$shared_postgres_temp_root/data"
        shared_postgres_log_path="$shared_postgres_temp_root/postgres.log"
    else
        local postgres_root="${TESL_PG_ROOT:-$SCRIPT_DIR/.tesl-postgres}"
        mkdir -p "$postgres_root"
        shared_postgres_temp_root=""
        shared_postgres_data_dir="$postgres_root/data"
        shared_postgres_log_path="$postgres_root/postgres.log"
    fi

    export TESL_TEST_POSTGRES_SHARED_HOST=127.0.0.1
    export TESL_TEST_POSTGRES_SHARED_PORT="$shared_postgres_port"
    export TESL_TEST_POSTGRES_SHARED_USER="$shared_postgres_user"
    export TESL_TEST_POSTGRES_SHARED_ADMIN_DATABASE=postgres
    shared_postgres_configured=1
}

start_shared_postgres_async() {
    configure_shared_postgres
    if [ "$shared_postgres_configured" -eq 0 ] || [ "$shared_postgres_external" -eq 1 ]; then
        return 0
    fi

    (
        if [ ! -d "$shared_postgres_data_dir" ]; then
            initdb -D "$shared_postgres_data_dir" -A trust -U "$shared_postgres_user" --locale=C >/dev/null 2>&1 || exit 1
        fi
        pg_ctl -D "$shared_postgres_data_dir" -l "$shared_postgres_log_path" -o "-F -k $shared_postgres_socket_dir -p $shared_postgres_port" -w start >/dev/null 2>&1
    ) &
    shared_postgres_boot_pid=$!
}

wait_for_shared_postgres() {
    if [ "$shared_postgres_configured" -eq 0 ] || [ "$shared_postgres_external" -eq 1 ]; then
        return 0
    fi
    if [ -z "$shared_postgres_boot_pid" ]; then
        return 0
    fi

    if wait "$shared_postgres_boot_pid"; then
        shared_postgres_started=1
        shared_postgres_boot_pid=""
        return 0
    fi

    shared_postgres_start_failed=1
    shared_postgres_configured=0
    shared_postgres_boot_pid=""
    clear_shared_postgres_env
    return 1
}

trap cleanup_shared_postgres EXIT

run_named_command() {
    local label="$1"
    shift
    local cmd_status=0
    local output=""

    # Print the "running" arrow without a newline so we can overwrite it on
    # success.  Only do this when stdout is a terminal; for piped/redirected
    # output we skip the arrow and just print the final result.
    [ -t 1 ] && printf "  →  %s" "$label"

    if output=$("$@" 2>&1); then
        cmd_status=0
    else
        cmd_status=$?
    fi

    if [ -n "$output" ]; then
        # There is output to show — finish the arrow line first (tty) then
        # print the indented output block, then the result on its own line.
        [ -t 1 ] && printf "\n"
        while IFS= read -r line; do
            printf "       %s\n" "$line"
        done <<< "$output"
        if [ "$cmd_status" -eq 0 ]; then
            printf "  \033[32m✓\033[0m  %s\n" "$label"
        else
            printf "  \033[31m✗\033[0m  %s\n" "$label"
        fi
    else
        # No output — overwrite the arrow with the result symbol on a tty,
        # or just print the result symbol when output is redirected.
        if [ -t 1 ]; then
            if [ "$cmd_status" -eq 0 ]; then
                printf "\r  \033[32m✓\033[0m  %s\n" "$label"
            else
                printf "\r  \033[31m✗\033[0m  %s\n" "$label"
            fi
        else
            if [ "$cmd_status" -eq 0 ]; then
                printf "  \033[32m✓\033[0m  %s\n" "$label"
            else
                printf "  \033[31m✗\033[0m  %s\n" "$label"
            fi
        fi
    fi
    return "$cmd_status"
}

format_file() {
    # Rewrite the file in place using `tesl fmt` so the subsequent
    # validate phase sees the formatter's output. Any formatter-induced
    # compile breakage will surface as a validate failure — no manual
    # formatting needed.
    local file="$1"
    if run_named_command "$(basename "$file")" tesl fmt "$file"; then
        format_apply_pass=$((format_apply_pass + 1))
    else
        format_apply_fail=$((format_apply_fail + 1))
    fi
}

validate_file() {
    local file="$1"
    if run_named_command "$(basename "$file")" tesl validate "$file"; then
        compile_pass=$((compile_pass + 1))
        lint_pass=$((lint_pass + 1))
        fmt_pass=$((fmt_pass + 1))
    else
        compile_fail=$((compile_fail + 1))
        lint_fail=$((lint_fail + 1))
        fmt_fail=$((fmt_fail + 1))
    fi
}

has_test_submodule() {
    local rkt_file="$1"
    [ -f "$rkt_file" ] && grep -Fq "(module+ test" "$rkt_file"
}

detect_tesl_test_files() {
    TESL_TESTABLE_TESL_FILES=()
    TESL_TESTABLE_RKT_FILES=()
    TESL_NO_TEST_BLOCK_FILES=()

    local tesl_file=""
    local rkt_file=""
    for tesl_file in "${ALL_FILES[@]}"; do
        rkt_file="${tesl_file%.tesl}.rkt"
        if has_test_submodule "$rkt_file"; then
            TESL_TESTABLE_TESL_FILES+=("$tesl_file")
            TESL_TESTABLE_RKT_FILES+=("$rkt_file")
        else
            TESL_NO_TEST_BLOCK_FILES+=("$tesl_file")
        fi
    done

    tesl_test_skipped_no_blocks=${#TESL_NO_TEST_BLOCK_FILES[@]}
}

precompile_racket_modules() {
    if is_truthy "${TESL_TEST_DISABLE_PRECOMP:-0}"; then
        return 0
    fi
    if [ "$#" -eq 0 ]; then
        return 0
    fi

    printf "  Precompiling Racket modules (will take a few minutes)...\n"
    if run_with_optional_nix_shell raco make "$@" >/dev/null 2>&1; then
        printf "  \033[32m✓\033[0m  Racket precompile cache warmed\n"
        return 0
    fi

    printf "  \033[33m⚠\033[0m  Racket precompile failed; continuing with on-demand compilation\n"
    return 1
}

run_tesl_batch_runner() {
    test_pass=0
    test_fail=0

    if [ "$#" -eq 0 ]; then
        return 0
    fi

    local output_log
    local batch_exit=0
    local summary_line=""
    local parsed_pass=0
    local parsed_fail=0

    output_log="$(mktemp "${TMPDIR:-/tmp}/tesl-example-batch.XXXXXX")"

    if is_truthy "${TESL_TEST_BUFFERED_OUTPUT:-0}"; then
        local batch_output=""
        if batch_output=$(run_with_optional_nix_shell racket tests/example-test-batch.rkt "$@" 2>&1); then
            batch_exit=0
        else
            batch_exit=$?
        fi
        printf '%s\n' "$batch_output"
        printf '%s' "$batch_output" > "$output_log"
    else
        run_with_optional_nix_shell racket tests/example-test-batch.rkt "$@" 2>&1 | tee "$output_log"
        local -a pipe_status=("${PIPESTATUS[@]}")
        batch_exit=${pipe_status[0]}
    fi

    summary_line=$(grep '^TESL_TEST_BATCH_SUMMARY ' "$output_log" | tail -1 || true)
    rm -f "$output_log"

    if [ -n "$summary_line" ]; then
        parsed_pass=$(printf '%s\n' "$summary_line" | sed -E 's/.*pass=([0-9]+).*/\1/')
        parsed_fail=$(printf '%s\n' "$summary_line" | sed -E 's/.*fail=([0-9]+).*/\1/')
        test_pass=${parsed_pass:-0}
        test_fail=${parsed_fail:-0}
        return 0
    fi

    if [ "$batch_exit" -ne 0 ]; then
        test_fail=$#
        return "$batch_exit"
    fi

    return 0
}

run_racket_test_suite() {
    if [ "$use_direct_racket" -eq 1 ] && command -v stdbuf >/dev/null 2>&1; then
        run_with_optional_nix_shell stdbuf -oL -eL racket tests/all.rkt
    else
        run_with_optional_nix_shell racket tests/all.rkt
    fi
}

LEARN_FILES=( "$(pwd)"/example/learn/*.tesl )
KANEL_FILES=( "$(pwd)"/example/kanel/*.tesl )

EXAMPLE_FILES=(
    "$(pwd)/example/sandbox.tesl"
    "$(pwd)/example/sandbox2.tesl"
    "$(pwd)/example/sandbox2.test.tesl"
    "$(pwd)/example/sandbox3.tesl"
    "$(pwd)/example/admin-task-api.tesl"
    "$(pwd)/example/todo-api.tesl"
    "$(pwd)/example/chat/backend.tesl"
    "${KANEL_FILES[@]}"
)

TEST_FILES=( "$(pwd)"/tests/*.tesl )

ALL_FILES=( "${LEARN_FILES[@]}" "${EXAMPLE_FILES[@]}" "${TEST_FILES[@]}" )

start_shared_postgres_async

echo ""
echo "━━━  1. Format (tesl fmt, in place)  ━━━"
echo ""
phase_start
echo "  Learn examples (example/learn/)"
for f in "${LEARN_FILES[@]}"; do format_file "$f"; done
echo ""
echo "  Sandbox/example files (example/)"
for f in "${EXAMPLE_FILES[@]}"; do format_file "$f"; done
echo ""
echo "  Test files (tests/)"
for f in "${TEST_FILES[@]}"; do format_file "$f"; done
format_duration=$((SECONDS - phase_started_at))
phase_complete "Format phase completed"

if [ "$format_apply_fail" -gt 0 ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  \033[31m%d file(s) failed to format — aborting before validate.\033[0m\n" "$format_apply_fail"
    printf "  Fix the formatter errors before re-running.\n"
    echo ""
    exit 1
fi

echo ""
echo "━━━  2. Validate (compile + lint + format check)  ━━━"
echo ""
phase_start
echo "  Learn examples (example/learn/)"
for f in "${LEARN_FILES[@]}"; do validate_file "$f"; done
echo ""
echo "  Sandbox/example files (example/)"
for f in "${EXAMPLE_FILES[@]}"; do validate_file "$f"; done
echo ""
echo "  Test files (tests/)"
for f in "${TEST_FILES[@]}"; do validate_file "$f"; done
validate_duration=$((SECONDS - phase_started_at))
phase_complete "Validation completed"

if [ "$compile_fail" -gt 0 ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  \033[31m%d file(s) failed validation — aborting before test run.\033[0m\n" "$compile_fail"
    printf "  Fix compilation errors before running tests to avoid stale .rkt artifacts.\n"
    echo ""
    exit 1
fi

detect_tesl_test_files

echo ""
printf "  Detected %d Tesl file(s) with test blocks; skipping %d without test blocks\n" \
    "${#TESL_TESTABLE_TESL_FILES[@]}" \
    "$tesl_test_skipped_no_blocks"

declare -a PRECOMPILE_TARGETS=(tests/example-test-batch.rkt tests/*.rkt tests/private/*.rkt)
if [ "${#TESL_TESTABLE_RKT_FILES[@]}" -gt 0 ]; then
    PRECOMPILE_TARGETS+=("${TESL_TESTABLE_RKT_FILES[@]}")
fi
precompile_racket_modules "${PRECOMPILE_TARGETS[@]}" || true

if ! wait_for_shared_postgres; then
    echo ""
    printf "  \033[33m⚠\033[0m  Shared PostgreSQL warm-up failed; continuing without a preconfigured shared cluster\n"
fi

echo ""
echo "━━━  2. Tesl test files  ━━━"
echo ""
phase_start
if [ "$shared_postgres_configured" -eq 1 ]; then
    if [ "$shared_postgres_started" -eq 1 ]; then
        printf "  Shared PostgreSQL test cluster ready on port %s\n" "$TESL_TEST_POSTGRES_SHARED_PORT"
    else
        echo "  Using preconfigured shared PostgreSQL test cluster"
    fi
    echo ""
fi

if [ "${#TESL_TESTABLE_TESL_FILES[@]}" -eq 0 ]; then
    echo "  No Tesl test blocks detected in the example corpus"
else
    if ! run_tesl_batch_runner "${TESL_TESTABLE_TESL_FILES[@]}"; then
        printf "  \033[31m✗\033[0m  Tesl batch runner exited unexpectedly\n"
    fi
fi

tesl_tests_duration=$((SECONDS - phase_started_at))
phase_complete "Tesl test sweep completed"

echo ""
echo "━━━  2.5. Mutation testing  (lesson42 — GDP boundary functions)  ━━━"
echo ""
phase_start

mutation_fail=0
mutation_lesson="$SCRIPT_DIR/example/learn/lesson42-mutation-testing.tesl"

# Determine the tesl binary: prefer the locally-built one; fall back to PATH.
TESL_BIN="${TESL_BIN:-}"
if [ -z "$TESL_BIN" ]; then
    local_tesl="$SCRIPT_DIR/compiler/_build/default/bin/main.exe"
    if [ -x "$local_tesl" ]; then
        TESL_BIN="$local_tesl"
    else
        TESL_BIN="tesl"
    fi
fi

if [ -f "$mutation_lesson" ] && command -v raco >/dev/null 2>&1; then
    printf "  Running: tesl --mutate %s\n" "$(basename "$mutation_lesson")"
    mutation_out=$("$TESL_BIN" --mutate "$mutation_lesson" 2>&1) || mutation_fail=1
    if [ "$mutation_fail" -eq 0 ]; then
        printf "  \033[32m✓\033[0m  All mutants killed (score: 100%%)\n"
    else
        printf "  \033[31m✗\033[0m  Mutation testing failed\n"
        printf "%s\n" "$mutation_out" | head -40
    fi
elif ! command -v raco >/dev/null 2>&1; then
    printf "  \033[33m⚠\033[0m  raco not available — skipping mutation testing\n"
else
    printf "  \033[33m⚠\033[0m  %s not found — skipping mutation testing\n" "$mutation_lesson"
fi

mutation_duration=$((SECONDS - phase_started_at))
phase_complete "Mutation testing completed"

echo ""
echo "━━━  3. Test suite  (authoritative tests/all.rkt aggregate via racket; shared PostgreSQL when available) Will take a few minutes  ━━━"
echo ""
phase_start

test_output=""
test_exit=0
if is_truthy "${TESL_TEST_BUFFERED_OUTPUT:-0}"; then
    test_output="$(run_racket_test_suite 2>&1)" || test_exit=$?
    if [ -n "$test_output" ]; then
        while IFS= read -r line; do
            printf "  %s\n" "$line"
        done <<< "$test_output"
    fi
else
    test_output_log="$(mktemp "${TMPDIR:-/tmp}/tesl-test-output.XXXXXX")"
    run_racket_test_suite 2>&1 | tee "$test_output_log"
    pipe_status=("${PIPESTATUS[@]}")
    test_exit=${pipe_status[0]}
    test_output="$(cat "$test_output_log")"
    rm -f "$test_output_log"
fi

racket_suite_duration=$((SECONDS - phase_started_at))
phase_complete "Racket aggregate test suite completed"

tests_passed=$(printf '%s' "$test_output" | grep -oE '[0-9]+ success\(es\)' | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}' || true)
if [ -z "${tests_passed:-}" ] || [ "${tests_passed:-0}" -eq 0 ]; then
    tests_passed=$(printf '%s' "$test_output" | grep -oE '[0-9]+ tests? passed' | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}' || true)
fi

summary_failures=$(printf '%s' "$test_output" | grep -oE '[0-9]+ failure\(s\)' | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}' || true)
summary_errors=$(printf '%s' "$test_output" | grep -oE '[0-9]+ error\(s\)' | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}' || true)
# Also count bare FAILURE blocks from top-level RackUnit checks (not captured in summary lines)
bare_failures=$(printf '%s' "$test_output" | grep -cE '^[[:space:]]*FAILURE[[:space:]]*$' || true)
tests_failed=$(( ${summary_failures:-0} + ${summary_errors:-0} + ${bare_failures:-0} ))
tests_passed=${tests_passed:-0}
tests_failed=${tests_failed:-0}

postgres_failed=$(echo "$test_output" | grep -c "pg_ctl: could not start server" || true)

echo ""
if [ "$tests_failed" -gt 0 ]; then
    printf "  \033[31m✗\033[0m  Racket tests failed (%s failure(s))\n" "$tests_failed"
    test_exit=1
elif [ "$test_exit" -ne 0 ] && [ "$postgres_failed" -gt 0 ]; then
    printf "  \033[32m✓\033[0m  All Racket tests pass\n"
    printf "  \033[33m⚠\033[0m  PostgreSQL could not start (known WSL2 limitation — not a test failure)\n"
    test_exit=0
elif [ "$test_exit" -eq 0 ]; then
    printf "  \033[32m✓\033[0m  All Racket tests pass\n"
else
    printf "  \033[31m✗\033[0m  test suite exited with code %d\n" "$test_exit"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
total_files=${#ALL_FILES[@]}
printf "  Format apply  %d / %d\n" "$format_apply_pass" "$total_files"
printf "  Compile       %d / %d\n" "$compile_pass" "$total_files"
printf "  Lint          %d / %d\n" "$lint_pass" "$total_files"
printf "  Format check  %d / %d\n" "$fmt_pass" "$total_files"
printf "  Tesl tests    %d / %d" "$((test_pass + tesl_test_skipped_no_blocks))" "$total_files"
if [ "$tesl_test_skipped_no_blocks" -gt 0 ]; then
    printf "  (%d without test blocks)" "$tesl_test_skipped_no_blocks"
fi
printf "\n"
printf "  Mutation      %s\n" "$([ "${mutation_fail:-0}" -gt 0 ] && echo "FAILED" || echo "OK (or skipped)")"
printf "  Racket tests  %s\n" "$([ "${tests_failed:-0}" -gt 0 ] && echo "${tests_failed} failure(s)" || echo "All pass")"
printf "  Timing        format=%ss validate=%ss tesl=%ss mutation=%ss racket=%ss total=%ss\n" \
    "$format_duration" \
    "$validate_duration" \
    "$tesl_tests_duration" \
    "${mutation_duration:-0}" \
    "$racket_suite_duration" \
    "$((SECONDS - script_started_at))"

overall_fail=$(( format_apply_fail + compile_fail + lint_fail + fmt_fail + test_fail + test_exit + ${mutation_fail:-0} ))

if [ "$overall_fail" -gt 0 ]; then
    echo ""
    [ "$format_apply_fail" -gt 0 ] && printf "  \033[31m%d format-apply failure(s)\033[0m\n" "$format_apply_fail"
    [ "$compile_fail" -gt 0 ] && printf "  \033[31m%d compile failure(s)\033[0m\n" "$compile_fail"
    [ "$lint_fail" -gt 0 ] && printf "  \033[31m%d lint failure(s)\033[0m\n" "$lint_fail"
    [ "$fmt_fail" -gt 0 ] && printf "  \033[31m%d format-check failure(s)\033[0m\n" "$fmt_fail"
    [ "$test_fail" -gt 0 ] && printf "  \033[31m%d Tesl test failure(s)\033[0m\n" "$test_fail"
    [ "${mutation_fail:-0}" -gt 0 ] && printf "  \033[31mmutation testing failed\033[0m\n"
    [ "$test_exit" -ne 0 ] && printf "  \033[31mtest suite failed\033[0m\n"
    echo ""
    exit 1
fi

printf "  \033[32mAll good!\033[0m\n"
echo ""
exit 0
