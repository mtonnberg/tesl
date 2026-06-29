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

# WS2 (roadmap/next/optimizations.md): the per-file `tesl fmt` and `tesl
# validate` loops are embarrassingly parallel — each file is independent.  We
# drive them with a bounded `xargs -P` pool.  TESL_CI_JOBS overrides the worker
# count (default: one per core).  Setting it to 1 restores fully serial
# behaviour, which is handy when debugging interleaving-sensitive issues.
TESL_CI_JOBS="${TESL_CI_JOBS:-$(nproc 2>/dev/null || echo 1)}"
case "$TESL_CI_JOBS" in
    ''|*[!0-9]*) TESL_CI_JOBS=1 ;;
esac
[ "$TESL_CI_JOBS" -lt 1 ] && TESL_CI_JOBS=1

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
        # Bound the wait with a 60-second timeout.  On WSL2 and some CI
        # environments pg_ctl -w can block indefinitely on socket readiness.
        timeout 60 pg_ctl -D "$shared_postgres_data_dir" -l "$shared_postgres_log_path" \
          -o "-F -k $shared_postgres_socket_dir -p $shared_postgres_port" -w start >/dev/null 2>&1
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

# ── WS2: bounded-parallel per-file phase runner ──────────────────────────────
#
# `run_parallel_phase` runs an independent per-file command (`tesl fmt` or
# `tesl validate`) across many files concurrently with a bounded `xargs -P`
# pool, while preserving the two properties the serial loops gave us:
#
#   * Deterministic, collated output — each file's combined stdout+stderr is
#     captured to its own temp file (keyed by the file's position in the input
#     list) and printed by the *parent* process in input order after the pool
#     drains.  Workers never write to the terminal, so output lines from
#     different files can never interleave.  Section headers are re-emitted at
#     their original boundaries so the grouped layout matches the serial run.
#   * Correct exit status — each worker records its command's exit code; the
#     parent re-reads every code and returns non-zero (and tallies per-file
#     failures) if ANY file failed.  xargs' own exit status is intentionally
#     ignored, because the authoritative pass/fail comes from the recorded
#     per-file codes.
#
# The worker is dispatched via `bash -c` rather than a bash function export so
# the behaviour is identical whether or not the parent shell exported the
# helper.  The subcommand and the work directory are passed through the
# environment.
_tesl_phase_worker() {
    # Args: <index>\t<file>
    local rec="$1"
    local idx="${rec%%$'\t'*}"
    local file="${rec#*$'\t'}"
    local out=""
    local rc=0
    if out="$(tesl "$TESL_PHASE_SUBCMD" "$file" 2>&1)"; then
        rc=0
    else
        rc=$?
    fi
    printf '%s' "$out"  > "$TESL_PHASE_WORKDIR/$idx.out"
    printf '%s' "$rc"   > "$TESL_PHASE_WORKDIR/$idx.rc"
}
export -f _tesl_phase_worker

# run_parallel_phase <subcmd> <result-callback> <header>:<count> [<header>:<count> ...] -- <file> [<file> ...]
#
# <subcmd>          the tesl subcommand to run per file (fmt | validate)
# <result-callback> shell function called once per file as `<cb> <rc>` (in
#                   input order) so the caller can update its pass/fail counters
# <header>:<count>  ordered section descriptors; <header> is printed before the
#                   first file of that section, <count> files belong to it
# after `--`        the flat, ordered list of files (sum of all counts)
run_parallel_phase() {
    local subcmd="$1"; shift
    local result_cb="$1"; shift

    local -a section_headers=()
    local -a section_counts=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        section_headers+=("${1%%:*}")
        section_counts+=("${1##*:}")
        shift
    done
    [ "${1:-}" = "--" ] && shift
    local -a files=("$@")

    local total=${#files[@]}
    if [ "$total" -eq 0 ]; then
        return 0
    fi

    local workdir
    workdir="$(mktemp -d "${TMPDIR:-/tmp}/tesl-ci-phase.XXXXXX")"

    # Fan out: one `tesl <subcmd> <file>` per file, capped at TESL_CI_JOBS
    # concurrent workers.  Records are NUL-separated `index<TAB>file` so paths
    # containing spaces are safe.
    local i
    for i in "${!files[@]}"; do
        printf '%d\t%s\0' "$i" "${files[$i]}"
    done | TESL_PHASE_SUBCMD="$subcmd" TESL_PHASE_WORKDIR="$workdir" \
        xargs -0 -P "$TESL_CI_JOBS" -I{} bash -c '_tesl_phase_worker "$@"' _ {}

    # Collate in input order, re-emitting section headers at their boundaries.
    local sec=0
    local sec_remaining=0
    [ "${#section_counts[@]}" -gt 0 ] && sec_remaining=${section_counts[0]}
    local rc out label
    for i in "${!files[@]}"; do
        # Print the header for the section this file starts, skipping any
        # empty sections so the layout stays clean.
        while [ "$sec" -lt "${#section_counts[@]}" ] && [ "$sec_remaining" -le 0 ]; do
            sec=$((sec + 1))
            [ "$sec" -lt "${#section_counts[@]}" ] && sec_remaining=${section_counts[$sec]}
        done
        if [ "$sec" -lt "${#section_headers[@]}" ] \
            && [ "$sec_remaining" -eq "${section_counts[$sec]}" ] \
            && [ -n "${section_headers[$sec]}" ]; then
            [ "$sec" -gt 0 ] && printf "\n"
            printf "%s\n" "${section_headers[$sec]}"
        fi
        sec_remaining=$((sec_remaining - 1))

        rc="$(cat "$workdir/$i.rc" 2>/dev/null || echo 1)"
        out="$(cat "$workdir/$i.out" 2>/dev/null || true)"
        label="$(basename "${files[$i]}")"

        if [ -n "$out" ]; then
            while IFS= read -r line; do
                printf "       %s\n" "$line"
            done <<< "$out"
        fi
        if [ "$rc" -eq 0 ]; then
            printf "  \033[32m✓\033[0m  %s\n" "$label"
        else
            printf "  \033[31m✗\033[0m  %s\n" "$label"
        fi

        # Hand the per-file result to the caller's counter callback.
        "$result_cb" "$rc"
    done

    rm -rf "$workdir"
}

# Counter callbacks for the two phases (invoked once per file, in order).
tally_format_result() {
    if [ "$1" -eq 0 ]; then
        format_apply_pass=$((format_apply_pass + 1))
    else
        format_apply_fail=$((format_apply_fail + 1))
    fi
}

tally_validate_result() {
    if [ "$1" -eq 0 ]; then
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
    # TESL_RACKET_SUITE_TIMEOUT caps the Racket aggregate test run.
    # tests/all.rkt starts its own PostgreSQL; on WSL2 that pg_ctl -w can
    # block indefinitely.  Default 600 s — long enough for a normal run,
    # short enough to surface hangs.  Set to 0 to disable.
    #
    # The internal regression suite compiles its evidence-bearing (non-zero-cost)
    # tests in-memory (tests/run-nzc.rkt, ~80 s of shared-dep compilation) on top
    # of the postgres-backed tests, so the cap is higher than a pure-runtime run
    # would need.  See roadmap/next/nonzero_cost_test_harness.md (a cached
    # non-zero-cost bytecode root would remove that recurring cost).
    #
    # NOTE: `timeout` cannot wrap bash functions — it only works with real
    # executables.  We apply it directly to the `racket` or `nix-shell`
    # command rather than passing run_with_optional_nix_shell as the argument.
    local timeout_secs="${TESL_RACKET_SUITE_TIMEOUT:-600}"
    local use_timeout=0
    if [ "${timeout_secs:-0}" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
        use_timeout=1
    fi

    local racket_cmd=""
    if [ "$use_direct_racket" -eq 1 ] && command -v stdbuf >/dev/null 2>&1; then
        racket_cmd="stdbuf -oL -eL racket tests/all.rkt"
    else
        racket_cmd="racket tests/all.rkt"
    fi

    if [ "$use_timeout" -eq 1 ]; then
        if [ "$use_direct_racket" -eq 1 ]; then
            timeout "$timeout_secs" $racket_cmd
        else
            # nix-shell --run takes a command string; timeout wraps nix-shell itself
            local cmd_string=""
            printf -v cmd_string '%s' "$racket_cmd"
            timeout "$timeout_secs" nix-shell --run "$cmd_string"
        fi
    else
        run_with_optional_nix_shell $racket_cmd
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
    "$(pwd)/example/chat/chat-backend.tesl"
    "$(pwd)/example/support-assistant.tesl"
    "$(pwd)/example/ai-live-check.tesl"
    "$(pwd)/example/ai-conversation-service.tesl"
    "${KANEL_FILES[@]}"
)

TEST_FILES=( "$(pwd)"/tests/*.tesl )

ALL_FILES=( "${LEARN_FILES[@]}" "${EXAMPLE_FILES[@]}" "${TEST_FILES[@]}" )

start_shared_postgres_async

echo ""
echo "━━━  1. Format (tesl fmt, in place)  ━━━"
echo ""
phase_start
# All files are independent — fan out with a bounded parallel pool, then print
# the captured per-file results in input order grouped under their section
# headers (see run_parallel_phase).  TESL_CI_JOBS=1 falls back to one-at-a-time.
run_parallel_phase fmt tally_format_result \
    "  Learn examples (example/learn/):${#LEARN_FILES[@]}" \
    "  Sandbox/example files (example/):${#EXAMPLE_FILES[@]}" \
    "  Test files (tests/):${#TEST_FILES[@]}" \
    -- "${LEARN_FILES[@]}" "${EXAMPLE_FILES[@]}" "${TEST_FILES[@]}"
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
# Each `tesl validate` (= check + lint + fmt-check) is independent per file;
# fan out the same way as the format phase.
run_parallel_phase validate tally_validate_result \
    "  Learn examples (example/learn/):${#LEARN_FILES[@]}" \
    "  Sandbox/example files (example/):${#EXAMPLE_FILES[@]}" \
    "  Test files (tests/):${#TEST_FILES[@]}" \
    -- "${LEARN_FILES[@]}" "${EXAMPLE_FILES[@]}" "${TEST_FILES[@]}"
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
    # TESL_MUTATION_TIMEOUT caps the full --mutate run (default 120 s).
    # Each mutant calls `raco test`; on machines without a database the DSL
    # can block indefinitely — TESL_MUTATE_TIMEOUT (passed through to the
    # binary) caps each individual raco invocation (default 15 s).
    _mutation_timeout="${TESL_MUTATION_TIMEOUT:-120}"
    mutation_out=$(timeout "$_mutation_timeout" "$TESL_BIN" --mutate "$mutation_lesson" 2>&1)
    _mut_exit=$?
    if [ "$_mut_exit" -eq 124 ]; then
        printf "  \033[33m⚠\033[0m  Mutation testing timed out after %ss — skipping\n" "$_mutation_timeout"
    elif [ "$_mut_exit" -ne 0 ]; then
        mutation_fail=1
    fi
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
echo "━━━  2.6. Integration tests  (httpclient + email — require racket, python3, MailHog)  ━━━"
echo ""
phase_start

integration_fail=0
integration_duration=0

# Locate the locally-built dune so we can run the integration test executables.
_COMPILER_DIR="$SCRIPT_DIR/compiler"
_DUNE="$(command -v dune 2>/dev/null)"

if [ -z "$_DUNE" ]; then
    printf "  \033[33m⚠\033[0m  dune not found — skipping integration tests\n"
elif [ ! -f "$_COMPILER_DIR/_build/default/bin/main.exe" ]; then
    printf "  \033[33m⚠\033[0m  compiler not built — skipping integration tests\n"
else
    for _suite in test_httpclient_integration test_email_integration; do
        _exe="$_COMPILER_DIR/_build/default/test/${_suite}.exe"
        if [ ! -x "$_exe" ]; then
            # Build it first if not already built
            (cd "$_COMPILER_DIR" && dune build "test/${_suite}.exe" 2>/dev/null) || true
        fi
        if [ -x "$_exe" ]; then
            printf "  Running %s...\n" "$_suite"
            if "$_exe" --color=never 2>&1 | grep -E "^\s+\[FAIL\]|Test Successful|failure" | grep -v "Test Successful"; then
                integration_fail=$((integration_fail + 1))
                printf "  \033[31m✗\033[0m  %s: failures detected\n" "$_suite"
            else
                printf "  \033[32m✓\033[0m  %s\n" "$_suite"
            fi
        else
            printf "  \033[33m⚠\033[0m  %s not built — skipping\n" "$_suite"
        fi
    done
fi

integration_duration=$((SECONDS - phase_started_at))
phase_complete "Integration tests completed"

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
printf "  Integration   %s\n" "$([ "${integration_fail:-0}" -gt 0 ] && echo "${integration_fail} suite(s) failed" || echo "OK (or skipped)")"
printf "  Racket tests  %s\n" "$([ "${tests_failed:-0}" -gt 0 ] && echo "${tests_failed} failure(s)" || echo "All pass")"
printf "  Timing        format=%ss validate=%ss tesl=%ss mutation=%ss integration=%ss racket=%ss total=%ss\n" \
    "$format_duration" \
    "$validate_duration" \
    "$tesl_tests_duration" \
    "${mutation_duration:-0}" \
    "${integration_duration:-0}" \
    "$racket_suite_duration" \
    "$((SECONDS - script_started_at))"

overall_fail=$(( format_apply_fail + compile_fail + lint_fail + fmt_fail + test_fail + test_exit + ${mutation_fail:-0} + ${integration_fail:-0} ))

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
