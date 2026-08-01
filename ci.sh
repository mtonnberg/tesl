#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  ci.sh — THE single authoritative "is the codebase green?" gate for Tesl.
# ══════════════════════════════════════════════════════════════════════════════
#
# This script is the UNION / strict SUPERSET of the two historical QA scripts it
# replaces:
#
#   * ./compile-examples.sh   (was: format → dune test → validate-sweep → Tesl
#                              tests → mutation → integration → Racket aggregate
#                              suite w/ shared PostgreSQL)
#   * ./compiler/ci.sh        (was: dune build → dune test (ID-keyed waivers) →
#                              lifted-stdlib snapshots → compile-all → exact-match
#                              .rkt snapshots → Racket suites → AI suites)
#
# Both of those files are now THIN SHIMS that `exec` this script, so any hook,
# muscle-memory, or CI reference to either keeps working (see their headers).
#
# Overlap between the two originals is DEDUPED — every logical phase runs exactly
# once:
#   * `dune test`   ran in BOTH → runs ONCE here (with compiler/ci.sh's explicit,
#                   dated, ID-keyed failure-waiver list — NOT the old
#                   substring/`grep -viE` swallow).
#   * per-file compile ran in BOTH (ci.sh "compile-all" + compile-examples.sh
#                   "validate") → `tesl validate` is the strict superset
#                   (check+lint+fmt-check), so it SUBSUMES the bare compile-all.
#
# Phase order (each runs at most once):
#    1. Build                 dune build                              (compiler/)
#    2. Dune test             OCaml alcotest suite, ID-keyed waivers   (compiler/)
#    3. Lifted-stdlib snaps   scripts/gen-stdlib-rkt.sh --check
#    4. Embedded-docs sync    embedded_docs.ml matches manual/+example/ (promote)
#   4a. Doc integrity         tests/doc-integrity.sh — relative links, cited
#                             #anchors, MANUAL.md ↔ `tesl help manual` round-trip,
#                             orphan docs, hand-typed corpus counts
#   4b. Manual coherence      manual/tests — the standalone dune project guarding
#                             the anchor contract + doc-prose lints (str/unix only)
#    5. Format                tesl fmt (in place), bounded xargs -P pool
#    6. Validate              tesl validate (check+lint+fmt), xargs -P pool
#    7. Exact-match snaps     byte-exact re-emit vs committed example/learn/*.rkt
#                             + templates/{api,minimal}/app.rkt (`tesl init` scaffold)
#    8. Tesl test files       generated Racket test submodules (batch runner)
#    9. Mutation              tesl --mutate lesson42
#   10. Integration           httpclient + email alcotest integration exes
#   11. Racket suites         debugger / headless-inspect / MCP / lifted-stdlib
#                             + AI (Tesl.Agent) mock feature/runtime suites
#   12. Racket aggregate      tests/all.rkt (shared PostgreSQL when available)
#   13. Boot smoke            tesl run app.tesl — activation-path banner check
#   14. Playground parity     scripts/playground-parity.sh — the browser build's
#                             teslCheck vs `tesl --check-json` over 30 lessons
#                             (SKIPs when js_of_ocaml or node is unavailable)
#
# A per-phase progress line is printed as each phase STARTS and again when it
# finishes:  [N/T] <phase> … OK/FAIL/SKIP (Xs).  Output stays clean (no colour,
# no cursor tricks) when stdout is not a TTY (CI logs).  A final collated summary
# lists every phase with its status + timing and the overall verdict.
#
# Optional dependencies (racket/raco, initdb/pg_ctl, python3, MailHog) that are
# absent cause the affected phase to SELF-SKIP with an explicit SKIPPED line — a
# missing optional tool is never a hard failure (mirrors the originals).  A real
# test failure always fails the gate; exit code is 0 iff every phase passed or
# was legitimately skipped.  We NEVER swallow a real failure with `|| true`.
#
# Usage (from repo root, inside the nix dev-shell / nix-shell):
#     ./ci.sh
#
# Env knobs (all preserved from the originals):
#   TESL_CI_JOBS               parallel worker count for fmt/validate (default: nproc)
#   RKT_SUITES_SKIP=1          skip the Racket suites + AI suites (fast inner loop)
#   TESL_RACKET_SUITE_TIMEOUT  cap on the tests/all.rkt aggregate run (default 600s)
#   TESL_MUTATION_TIMEOUT      cap on the full --mutate run (default 120s)
#   TESL_TEST_FORCE_NIX_SHELL  force nix-shell wrapping even if racket is on PATH
#   TESL_TEST_USE_TEMP_PG      use a temp PostgreSQL data root (default: CI)
#   TESL_TEST_BUFFERED_OUTPUT  buffer sub-phase output instead of streaming
#   TESL_TEST_DISABLE_PRECOMP  skip the raco-make precompile warm-up
#   TESL_POSTGRES_HOST/PORT/USER  reuse an external PostgreSQL cluster
#   TESL_CI_NO_COLOR=1         force plain output even on a TTY
#
# Exit code 0: all checks passed (or self-skipped).  Non-zero: a real failure.
# ══════════════════════════════════════════════════════════════════════════════

set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
export TESL_REPO_ROOT="$SCRIPT_DIR"
COMPILER_DIR="$SCRIPT_DIR/compiler"

# ── CI hermetic-store guard ──────────────────────────────────────────────────
# Under `nix develop`, the flake source is realised into the READ-ONLY Nix
# store, so the dev shell's shellHook can neither build the OCaml compiler in
# place nor `raco --link` the runtime collections there — it leaves the `tesl`
# wrapper pointing at an unbuilt store binary and no `tesl` collection linked.
# ci.sh always runs from the WRITABLE checkout ($SCRIPT_DIR, basename `tesl`), so:
#   (1) point the compiler env at the binary phase 1 builds here — the dev `tesl`
#       wrapper now honours a pre-set $TESL_OCAML_COMPILER (see flake.nix), and
#   (2) register the `tesl` Racket collection against the checkout so a bare
#       `racket foo.rkt` (integration tests) resolves `(require tesl/dsl/…)`.
# Both are idempotent and harmless when the source is already writable (local).
export TESL_OCAML_COMPILER="$COMPILER_DIR/_build/default/bin/main.exe"

# Option E: run the S7 generative gate in EXHAUSTIVE mode (scan the WHOLE proof
# corpus for accepted soundness-breaking mutants — the full detector), not the
# fast budget-bounded mode the developer dune-test loop uses.  Overridable.
export TESL_S7_EXHAUSTIVE="${TESL_S7_EXHAUSTIVE:-1}"

if command -v raco >/dev/null 2>&1; then
    if ! raco pkg show tesl 2>/dev/null | grep -qF "link $SCRIPT_DIR"; then
        if raco pkg show tesl 2>/dev/null | grep -Eq '^[[:space:]]*tesl([[:space:]]|$)'; then
            raco pkg update  --auto --link "$SCRIPT_DIR" >/dev/null 2>&1 || true
        else
            raco pkg install --auto --link "$SCRIPT_DIR" >/dev/null 2>&1 || true
        fi
    fi
fi

# ── Parallel worker pool size (fmt/validate) ─────────────────────────────────
# The per-file `tesl fmt` and `tesl validate` loops are embarrassingly parallel.
# TESL_CI_JOBS overrides the worker count (default: one per core). 1 = serial.
TESL_CI_JOBS="${TESL_CI_JOBS:-$(nproc 2>/dev/null || echo 1)}"
case "$TESL_CI_JOBS" in
    ''|*[!0-9]*) TESL_CI_JOBS=1 ;;
esac
[ "$TESL_CI_JOBS" -lt 1 ] && TESL_CI_JOBS=1

# ── Colour / TTY handling ────────────────────────────────────────────────────
# Only emit ANSI colour when stdout is an interactive terminal and colour is not
# explicitly disabled — CI logs stay plain and greppable.
if [ -t 1 ] && ! [ "${TESL_CI_NO_COLOR:-0}" = "1" ]; then
    C_RESET=$'\033[0m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_BOLD=$'\033[1m'
else
    C_RESET=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_BOLD=""
fi

script_started_at=$SECONDS
phase_started_at=$SECONDS

# ── Phase registry / progress bar ────────────────────────────────────────────
# We know the phase count up front so each phase can print "[N/T] <name>".
TOTAL_PHASES=20
PHASE_NUM=0
# Parallel arrays: name / status (OK|FAIL|SKIP) / elapsed seconds.
PHASE_NAMES=()
PHASE_STATUS=()
PHASE_SECONDS=()
GATE_FAILURES=0

# phase_begin <name> — bump the counter, remember the name, print the start line.
phase_begin() {
    PHASE_NUM=$((PHASE_NUM + 1))
    phase_started_at=$SECONDS
    CURRENT_PHASE_NAME="$1"
    printf "\n%s━━━ [%d/%d] %s ━━━%s\n" \
        "$C_BOLD" "$PHASE_NUM" "$TOTAL_PHASES" "$CURRENT_PHASE_NAME" "$C_RESET"
}

# phase_end <status: OK|FAIL|SKIP> — record + print the "… OK/FAIL/SKIP (Xs)" line.
phase_end() {
    local status="$1"
    local elapsed=$((SECONDS - phase_started_at))
    PHASE_NAMES+=("$CURRENT_PHASE_NAME")
    PHASE_STATUS+=("$status")
    PHASE_SECONDS+=("$elapsed")
    local mark colour
    case "$status" in
        OK)   mark="OK";   colour="$C_GREEN" ;;
        SKIP) mark="SKIP"; colour="$C_YELLOW" ;;
        *)    mark="FAIL"; colour="$C_RED"; GATE_FAILURES=$((GATE_FAILURES + 1)) ;;
    esac
    printf "  %s[%d/%d] %s … %s (%ss)%s\n" \
        "$colour" "$PHASE_NUM" "$TOTAL_PHASES" "$CURRENT_PHASE_NAME" "$mark" "$elapsed" "$C_RESET"
}

is_truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

# print_summary_and_exit — collate every recorded phase with its status + timing,
# print the overall verdict, and exit 0 iff no phase FAILed (SKIP is not a
# failure).  Called at the natural end AND at every early-abort point, so the
# summary always reflects the phases that actually ran.
print_summary_and_exit() {
    local total_elapsed=$((SECONDS - script_started_at))
    printf "\n%s════════════════════════════════════════════%s\n" "$C_BOLD" "$C_RESET"
    printf "%s  CI SUMMARY%s\n" "$C_BOLD" "$C_RESET"
    printf "%s════════════════════════════════════════════%s\n" "$C_BOLD" "$C_RESET"
    local i mark colour
    # Option E: SKIP ≠ PASS.  A soundness-required phase that SKIPs — e.g. because
    # racket/raco/initdb was missing — used to be counted as "legitimately skipped"
    # and the gate still printed "All good", silently masking that the entire
    # runtime/proof-runtime layer never ran.  We now treat a SKIP of any required
    # phase (everything except the cosmetic "Format" phase) as a gate FAILURE.
    # Local fast-loops that intentionally skip (RKT_SUITES_SKIP=1, no racket, …)
    # opt out with TESL_CI_ALLOW_SKIP=1.
    local skipped_required=0
    local allow_skip=0
    # An explicit fast-loop skip knob (RKT_SUITES_SKIP=1) or TESL_CI_ALLOW_SKIP=1
    # opts out of the strict SKIP-is-FAIL rule; the authoritative gate sets neither.
    if is_truthy "${TESL_CI_ALLOW_SKIP:-}" || is_truthy "${RKT_SUITES_SKIP:-}"; then allow_skip=1; fi
    for i in "${!PHASE_NAMES[@]}"; do
        local st="${PHASE_STATUS[$i]}"
        local nm="${PHASE_NAMES[$i]}"
        local required=1
        case "$nm" in *Format*) required=0 ;; esac
        local note=""
        if [ "$st" = "SKIP" ] && [ "$required" -eq 1 ] && [ "$allow_skip" -eq 0 ]; then
            skipped_required=$((skipped_required + 1))
            mark="✗"; colour="$C_RED"; note="  (required — SKIP is a FAIL)"
        else
            case "$st" in
                OK)   mark="✓"; colour="$C_GREEN" ;;
                SKIP) mark="⚠"; colour="$C_YELLOW" ;;
                *)    mark="✗"; colour="$C_RED" ;;
            esac
        fi
        printf "  %s%s%s  [%d/%d] %-46s %-4s %ss%s\n" \
            "$colour" "$mark" "$C_RESET" \
            "$((i + 1))" "$TOTAL_PHASES" \
            "${PHASE_NAMES[$i]}" "${PHASE_STATUS[$i]}" "${PHASE_SECONDS[$i]}" "$note"
    done
    printf "────────────────────────────────────────────\n"
    printf "  total %ss\n" "$total_elapsed"
    local total_failures=$((GATE_FAILURES + skipped_required))
    if [ "$total_failures" -eq 0 ]; then
        printf "  %s✓  All good — every phase passed (or was legitimately skipped).%s\n" "$C_GREEN" "$C_RESET"
        printf "%s════════════════════════════════════════════%s\n" "$C_BOLD" "$C_RESET"
        exit 0
    else
        [ "$skipped_required" -gt 0 ] && printf "  %s✗  %d soundness-required phase(s) SKIPPED (missing tool? set TESL_CI_ALLOW_SKIP=1 to permit locally).%s\n" "$C_RED" "$skipped_required" "$C_RESET"
        [ "$GATE_FAILURES" -gt 0 ] && printf "  %s✗  %d phase(s) FAILED.%s\n" "$C_RED" "$GATE_FAILURES" "$C_RESET"
        printf "%s════════════════════════════════════════════%s\n" "$C_BOLD" "$C_RESET"
        exit 1
    fi
}

# ── Racket invocation: prefer direct racket/raco, else wrap in nix-shell ──────
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

# ── Shared PostgreSQL cluster (async warm-up) ────────────────────────────────
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

# ── Bounded-parallel per-file phase runner (fmt / validate) ──────────────────
# Runs an independent `tesl <subcmd> <file>` across many files concurrently with
# a bounded `xargs -P` pool while preserving deterministic collated output (each
# file's stdout+stderr is captured to its own temp file keyed by input position
# and printed by the parent in input order) and correct aggregate exit status
# (each worker records its exit code; the parent re-reads every code).
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

# run_parallel_phase <subcmd> <result-callback> <header>:<count> [...] -- <file> [...]
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

    local i
    for i in "${!files[@]}"; do
        printf '%d\t%s\0' "$i" "${files[$i]}"
    done | TESL_PHASE_SUBCMD="$subcmd" TESL_PHASE_WORKDIR="$workdir" \
        xargs -0 -P "$TESL_CI_JOBS" -I{} bash -c '_tesl_phase_worker "$@"' _ {}

    local sec=0
    local sec_remaining=0
    [ "${#section_counts[@]}" -gt 0 ] && sec_remaining=${section_counts[0]}
    local rc out label
    for i in "${!files[@]}"; do
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
            printf "  %s✓%s  %s\n" "$C_GREEN" "$C_RESET" "$label"
        else
            printf "  %s✗%s  %s\n" "$C_RED" "$C_RESET" "$label"
        fi

        "$result_cb" "$rc"
    done

    rm -rf "$workdir"
}

# ── fmt / validate counters ──────────────────────────────────────────────────
compile_pass=0; compile_fail=0
lint_pass=0;    lint_fail=0
fmt_pass=0;     fmt_fail=0
format_apply_pass=0; format_apply_fail=0
test_pass=0;    test_fail=0
tesl_test_skipped_no_blocks=0

tally_format_result() {
    if [ "$1" -eq 0 ]; then
        format_apply_pass=$((format_apply_pass + 1))
    else
        format_apply_fail=$((format_apply_fail + 1))
    fi
}

tally_validate_result() {
    if [ "$1" -eq 0 ]; then
        compile_pass=$((compile_pass + 1)); lint_pass=$((lint_pass + 1)); fmt_pass=$((fmt_pass + 1))
    else
        compile_fail=$((compile_fail + 1)); lint_fail=$((lint_fail + 1)); fmt_fail=$((fmt_fail + 1))
    fi
}

# ── Tesl test-block detection + batch runner ─────────────────────────────────
TESL_TESTABLE_TESL_FILES=()
TESL_TESTABLE_RKT_FILES=()
TESL_NO_TEST_BLOCK_FILES=()

has_test_submodule() {
    local rkt_file="$1"
    [ -f "$rkt_file" ] && grep -Fq "(module+ test" "$rkt_file"
}

detect_tesl_test_files() {
    TESL_TESTABLE_TESL_FILES=()
    TESL_TESTABLE_RKT_FILES=()
    TESL_NO_TEST_BLOCK_FILES=()
    local tesl_file="" rkt_file=""
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
        printf "  %s✓%s  Racket precompile cache warmed\n" "$C_GREEN" "$C_RESET"
        return 0
    fi
    printf "  %s⚠%s  Racket precompile failed; continuing with on-demand compilation\n" "$C_YELLOW" "$C_RESET"
    return 1
}

run_tesl_batch_runner() {
    test_pass=0
    test_fail=0
    if [ "$#" -eq 0 ]; then
        return 0
    fi
    local output_log batch_exit=0 summary_line="" parsed_pass=0 parsed_fail=0
    output_log="$(mktemp "${TMPDIR:-/tmp}/tesl-example-batch.XXXXXX")"

    # lesson80-testing-sso.tesl's `sessionKey "LESSON80_SESSION_KEY"` clause
    # compiles to an unconditional Env.requireSecret read (every `sso` route,
    # not only the callback, seals its state cookie with it) — there is no
    # literal-secret form of `sessionKey` in the grammar. The whole learn corpus
    # runs as ONE racket process here, so one fixed, obviously-dev-only value
    # covers it without per-lesson env plumbing.
    export LESSON80_SESSION_KEY="lesson80-signing-key-not-for-production"

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
    # TESL_RACKET_SUITE_TIMEOUT caps the tests/all.rkt aggregate run.  It starts
    # its own PostgreSQL; on WSL2 pg_ctl -w can block indefinitely.  Default 600s;
    # 0 disables.  `timeout` cannot wrap a bash function, so we apply it to the
    # real racket/nix-shell command.
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
            local cmd_string=""
            printf -v cmd_string '%s' "$racket_cmd"
            timeout "$timeout_secs" nix-shell --run "$cmd_string"
        fi
    else
        run_with_optional_nix_shell $racket_cmd
    fi
}

# ── File corpus ───────────────────────────────────────────────────────────────
# Relative paths (we `cd "$SCRIPT_DIR"` above): the compiler embeds the input
# path into each emitted .rkt's source map, so relative paths keep the committed
# .rkt snapshots machine-independent.  Drop transient LSP validation copies that
# the globs could race-capture (see roadmap/later/lsp-temp-files-pollute-repo.md).
_drop_transient() {
    local f
    for f in "$@"; do
        case "$(basename -- "$f")" in
            tesl-lsp-*.tesl) ;;  # skip transient LSP validation copy
            *) printf '%s\n' "$f" ;;
        esac
    done
}
mapfile -t LEARN_FILES < <(_drop_transient example/learn/*.tesl)
mapfile -t KANEL_FILES < <(_drop_transient example/kanel/*.tesl)

# Glob EVERY shipped example (top-level example/*.tesl + example/chat/) rather
# than a hand-maintained list, so a newly-added or previously-forgotten example
# can no longer silently escape `tesl validate` (check+lint+fmt) and the test
# sweep. The old hardcoded list omitted example/queue-api.tesl, int32-boundary,
# and debug-test — exactly the "CI should tesl-check every shipped example" gap
# in bug-report #10. (KANEL_FILES stays a separate glob; learn is globbed above.)
mapfile -t EXAMPLE_TOP_FILES < <(_drop_transient example/*.tesl)
mapfile -t CHAT_FILES < <(_drop_transient example/chat/*.tesl)
EXAMPLE_FILES=(
    "${EXAMPLE_TOP_FILES[@]}"
    "${CHAT_FILES[@]}"
    "${KANEL_FILES[@]}"
)

mapfile -t TEST_FILES < <(_drop_transient tests/*.tesl)

# The `tesl init` scaffold — the FIRST Tesl code a new user ever runs, and until
# now the one shipped corpus in no phase at all: not validate, not the snapshot
# diff, not the Tesl-test sweep (templates/ held no .rkt, so detect_tesl_test_files
# could not see its `test` blocks).  A scaffold that does not boot is the worst
# first impression there is, and it went unguarded through a change that made the
# templates depend on libsodium at runtime.  Globbed, like the examples, so a new
# template subdirectory is covered without an edit here.  templates/docker/ ships
# only .tmpl files and has no app.tesl, so it drops out of the glob by itself.
mapfile -t TEMPLATE_FILES < <(_drop_transient templates/*/app.tesl)

ALL_FILES=( "${LEARN_FILES[@]}" "${EXAMPLE_FILES[@]}" "${TEST_FILES[@]}" "${TEMPLATE_FILES[@]}" )

# Kick off the shared PostgreSQL warm-up immediately so the cluster is ready by
# the time the Tesl-test / aggregate phases need it (async — overlaps the build).
start_shared_postgres_async

# ══════════════════════════════════════════════════════════════════════════════
#  Phase 1 — Build (dune)
# ══════════════════════════════════════════════════════════════════════════════
phase_begin "Build (dune build)"
if [ -z "${IN_NIX_SHELL:-}" ] && [ -z "${OCAMLPATH:-}" ] && [ -d "$HOME/.nix-profile/lib/ocaml/5.4.1/site-lib" ]; then
    export OCAMLPATH="$HOME/.nix-profile/lib/ocaml/5.4.1/site-lib"
fi
build_fail=0
if command -v dune >/dev/null 2>&1; then
    BUILD_JOBS="$(nproc 2>/dev/null || echo 1)"
    if ( cd "$COMPILER_DIR" && dune build -j "$BUILD_JOBS" ); then
        phase_end OK
    else
        build_fail=1
        phase_end FAIL
    fi
else
    printf "  %s⚠%s  dune not found — skipping build\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
fi

# A broken build makes every downstream phase meaningless — abort early.
if [ "$build_fail" -gt 0 ]; then
    printf "\n  %sBuild failed — aborting the gate.%s\n" "$C_RED" "$C_RESET"
    print_summary_and_exit
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Phase 2 — Dune test (OCaml alcotest, ID-keyed failure waivers)
# ══════════════════════════════════════════════════════════════════════════════
# The OCaml alcotest suite is the authoritative frontend regression gate.  It ran
# in BOTH originals; here it runs ONCE.  We match [FAIL] anywhere, normalise each
# to its stable ID "<suite-name> <case-index>", dedupe, and compare against an
# EXPLICIT, dated, ID-keyed waiver list — NOT the old substring `grep -viE` swallow
# (which could mask a genuine regression whose name merely contained a substring).
#
# ── Dune-test failure waivers ────────────────────────────────────────────────
# Each entry is an EXACT normalised test ID plus a reason and grant date, so
# waivers are auditable and cannot rot into a catch-all.  Add an entry ONLY for a
# failure genuinely accepted as not-a-regression; remove it when the test is fixed.
# Verified on `main`: `dune test` is fully GREEN (0 [FAIL] lines), so the list is
# EMPTY — any [FAIL] fails the gate.
TEST_WAIVERS=(
  # (empty — dune test is green on main)
  # Example entry format (exact normalised ID | reason | date):
  #   "some-suite 3"   # flake tracked in roadmap #NN — waived 2026-01-01
)

_normalize_fail_id() {
    sed -E 's/[│┌┐└┘─├┤]//g; s/^[[:space:]]*\[FAIL\][[:space:]]*//; s/[[:space:]]+/ /g; s/^ //; s/ $//' \
        | awk '{ if (NF >= 2) print $1 " " $2; else print $0 }'
}
_is_waived() {
    local id="$1" w
    for w in "${TEST_WAIVERS[@]}"; do
        [ "$id" = "$w" ] && return 0
    done
    return 1
}

phase_begin "Dune test (OCaml alcotest suite)"
dune_test_fail=0
if ! command -v dune >/dev/null 2>&1; then
    printf "  %s⚠%s  dune not found — skipping dune test\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
else
    # -j1 avoids the known parallel-httpclient flake; unset the compiler overrides
    # so dune uses its own freshly-built binary rather than a stale one.
    _test_log=$(mktemp "${TMPDIR:-/tmp}/tesl-dune-test.XXXXXX")
    if ( cd "$COMPILER_DIR" && unset TESL_OCAML_COMPILER TESL_BIN && dune test -j1 ) 2>&1 | tee "$_test_log"; then
        phase_end OK
    else
        mapfile -t _fail_ids < <(grep -aoE "\[FAIL\][^│]*" "$_test_log" | _normalize_fail_id | sort -u)
        _unknown_fails=""
        _waived_fails=""
        for _id in "${_fail_ids[@]}"; do
            [ -n "$_id" ] || continue
            if _is_waived "$_id"; then
                _waived_fails+="    (waived) $_id"$'\n'
            else
                _unknown_fails+="    $_id"$'\n'
            fi
        done
        if [ -n "$_unknown_fails" ]; then
            printf "  %s✗%s  NEW test failures (not in the explicit waiver list):\n%s" "$C_RED" "$C_RESET" "$_unknown_fails"
            [ -n "$_waived_fails" ] && printf "  (also-waived, ignored:)\n%s" "$_waived_fails"
            dune_test_fail=1
            phase_end FAIL
        elif [ -n "$_waived_fails" ]; then
            printf "  %s⚠%s  Only explicitly-waived failures present; no un-waived failures:\n%s" "$C_YELLOW" "$C_RESET" "$_waived_fails"
            phase_end OK
        else
            printf "  %s✗%s  dune test exited non-zero but no [FAIL] lines parsed (build/crash?); see log above\n" "$C_RED" "$C_RESET"
            dune_test_fail=1
            phase_end FAIL
        fi
    fi
    rm -f "$_test_log"
fi

if [ "$dune_test_fail" -gt 0 ]; then
    printf "\n  %sOCaml dune test suite failed — aborting.%s\n" "$C_RED" "$C_RESET"
    print_summary_and_exit
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Phase 3 — Lifted-stdlib runtime snapshots
# ══════════════════════════════════════════════════════════════════════════════
# Modules whose pure combinator bodies are written in Tesl (e.g. tesl/list.tesl)
# compile to a committed *-derived.rkt snapshot the public shim re-exports.
# `tesl/` is outside the dune root, so the snapshot is committed; a drift fails.
phase_begin "Lesson catalog (gen-lesson-index --check)"
# The lesson corpus was indexed by hand in three places that all disagreed, and
# every count had drifted (73 / 70+ / 50+ against a real 77), while 37 lesson
# files appeared in no index at all.  The index is now GENERATED from two comment
# lines in each lesson, and this phase fails on drift — so a new lesson without
# metadata, a duplicate reading-order position, a dangling prerequisite, or a
# prerequisite that comes LATER than the lesson needing it all fail here rather
# than rotting into the docs.
if [ ! -f "$SCRIPT_DIR/scripts/gen-lesson-index.sh" ]; then
    printf "  %s⚠%s  scripts/gen-lesson-index.sh not found — skipping\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
else
    _lesson_idx_rc=0
    bash "$SCRIPT_DIR/scripts/gen-lesson-index.sh" --check || _lesson_idx_rc=$?
    if [ "$_lesson_idx_rc" -eq 0 ]; then
        phase_end OK
    elif [ "$_lesson_idx_rc" -eq 77 ]; then
        phase_end SKIP
    else
        printf "  %s✗%s  lesson metadata invalid or manual/lessons.md drifted (run scripts/gen-lesson-index.sh and commit)\n" "$C_RED" "$C_RESET"
        phase_end FAIL
    fi
fi

phase_begin "Lifted-stdlib snapshots (gen-stdlib-rkt --check)"
if [ ! -f "$SCRIPT_DIR/scripts/gen-stdlib-rkt.sh" ]; then
    printf "  %s⚠%s  scripts/gen-stdlib-rkt.sh not found — skipping\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
elif bash "$SCRIPT_DIR/scripts/gen-stdlib-rkt.sh" --check; then
    phase_end OK
else
    printf "  %s✗%s  lifted-stdlib snapshot drift (run scripts/gen-stdlib-rkt.sh and commit)\n" "$C_RED" "$C_RESET"
    phase_end FAIL
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Embedded-docs sync (compiler/lib/embedded_docs.ml matches manual/ + example/)
# ══════════════════════════════════════════════════════════════════════════════
# embedded_docs.ml bakes the manual/ and example/ files into the binary for
# `tesl help manual` / examples.  A `(mode promote)` dune rule regenerates it on
# every build (the Build phase above), writing the fresh copy back to the source
# tree.  So if a manual/example edit was committed WITHOUT the regenerated
# snapshot, the Build phase just promoted a different version and the tracked
# file is now dirty.  Fail so a stale embedded copy (out-of-date `tesl help`)
# cannot ship.  Depends on the Build phase having run `dune build` first.
phase_begin "Embedded-docs sync (embedded_docs.ml up to date)"
if ! command -v git >/dev/null 2>&1 || ! git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf "  %s⚠%s  git unavailable / not a work tree — skipping\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
elif git -C "$SCRIPT_DIR" diff --quiet -- compiler/lib/embedded_docs.ml; then
    phase_end OK
else
    printf "  %s✗%s  embedded_docs.ml is stale vs manual/ + example/ — run 'dune build' (it promotes the snapshot) and commit compiler/lib/embedded_docs.ml\n" "$C_RED" "$C_RESET"
    phase_end FAIL
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Phase 4a — Doc integrity (links, anchors, section map, orphans, counts)
# ══════════════════════════════════════════════════════════════════════════════
# The docs had no structural test at all: ~280 relative markdown links and ~55
# cited `#anchor`s were unverified, the manual section→file map was duplicated in
# SIX places that disagreed, and four different hand-typed corpus counts were all
# wrong.  tests/doc-integrity.sh is the ratchet, and it is deliberately runnable
# standalone (`bash tests/doc-integrity.sh`, ~2 s, markdown only) so a docs edit
# gets the answer without the full gate — while still running HERE so it cannot be
# skipped by forgetting.  Placed right after the build because the section-map and
# diagnostic-deep-link halves invoke `tesl help manual`; without main.exe those two
# halves self-skip and the script exits 77.
phase_begin "Doc integrity (links, anchors, section map, orphans)"
_docint_main_exe="$COMPILER_DIR/_build/default/bin/main.exe"
_docint_rc=0
TESL_REPO_ROOT="$SCRIPT_DIR" TESL_OCAML_COMPILER="$_docint_main_exe" \
    bash "$SCRIPT_DIR/tests/doc-integrity.sh" || _docint_rc=$?
if [ "$_docint_rc" -eq 0 ]; then
    phase_end OK
elif [ "$_docint_rc" -eq 77 ]; then
    phase_end SKIP
else
    phase_end FAIL
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Phase 4b — Manual coherence suite (manual/tests, standalone dune project)
# ══════════════════════════════════════════════════════════════════════════════
# manual/tests/ guards the stable-anchor contract from the CONSUMING side (every
# anchor listed in manual/anchors.md and every anchor main.ml's get_help_suggestion
# emits resolves to a real heading), plus the doc-prose lints: no stale proof
# cost-model wording, no banned marketing phrases, every dev-docs page declares an
# Audience, no orphan manual page, and no D1-class syntax rot in ```tesl fences.
# It has its OWN dune-project (str + unix only, no compiler library, no Racket), so
# the root `dune build` / `dune test` never reaches it — it was orphaned from the
# gate entirely until this phase.  A missing dune SKIPs; a real failure FAILs.
phase_begin "Manual coherence suite (manual/tests)"
if ! command -v dune >/dev/null 2>&1; then
    printf "  %s⚠%s  dune not found — skipping the manual coherence suite\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
elif [ ! -f "$SCRIPT_DIR/manual/tests/dune-project" ]; then
    printf "  %s⚠%s  manual/tests/dune-project not found — skipping\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
else
    _mancoh_log="$(mktemp "${TMPDIR:-/tmp}/tesl-manual-coherence.XXXXXX")"
    # --force: the alias is cached on the .ml alone, but the assertions read the
    # markdown, so a doc-only edit must still re-run it.
    if ( cd "$SCRIPT_DIR/manual/tests" && dune runtest --force ) > "$_mancoh_log" 2>&1; then
        printf "  %s✓%s  %s\n" "$C_GREEN" "$C_RESET" \
            "$(grep -c '^ok   - ' "$_mancoh_log" 2>/dev/null || echo 0) manual coherence checks passed"
        phase_end OK
    else
        grep -E '^(FAIL - |FAILURES)' "$_mancoh_log" | head -40 | sed 's/^/  /'
        grep -qE '^(FAIL - |FAILURES)' "$_mancoh_log" || tail -20 "$_mancoh_log" | sed 's/^/  /'
        phase_end FAIL
    fi
    rm -f "$_mancoh_log"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Phase 4 — Format (tesl fmt, in place)
# ══════════════════════════════════════════════════════════════════════════════
# All files are independent — fan out with a bounded parallel pool, then print
# captured per-file results in input order under their section headers.
phase_begin "Format (tesl fmt, in place)"
if ! command -v tesl >/dev/null 2>&1; then
    printf "  %s⚠%s  tesl not on PATH — skipping format\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
else
    run_parallel_phase fmt tally_format_result \
        "  Learn examples (example/learn/):${#LEARN_FILES[@]}" \
        "  Sandbox/example files (example/):${#EXAMPLE_FILES[@]}" \
        "  Test files (tests/):${#TEST_FILES[@]}" \
        "  Scaffold templates (templates/*/app.tesl):${#TEMPLATE_FILES[@]}" \
        -- "${LEARN_FILES[@]}" "${EXAMPLE_FILES[@]}" "${TEST_FILES[@]}" "${TEMPLATE_FILES[@]}"
    if [ "$format_apply_fail" -gt 0 ]; then
        printf "  %s%d file(s) failed to format.%s\n" "$C_RED" "$format_apply_fail" "$C_RESET"
        phase_end FAIL
    else
        phase_end OK
    fi
fi

if [ "$format_apply_fail" -gt 0 ]; then
    printf "\n  %sFormatter failures — aborting before validate.%s\n" "$C_RED" "$C_RESET"
    print_summary_and_exit
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Phase 5 — Validate (compile + lint + format check)
# ══════════════════════════════════════════════════════════════════════════════
# `tesl validate` = check + lint + fmt-check per file; this is the strict superset
# of the old bare "compile-all" per-file loop, so it subsumes it (deduped).
phase_begin "Validate (compile + lint + format-check)"
if ! command -v tesl >/dev/null 2>&1; then
    printf "  %s⚠%s  tesl not on PATH — skipping validate\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
else
    run_parallel_phase validate tally_validate_result \
        "  Learn examples (example/learn/):${#LEARN_FILES[@]}" \
        "  Sandbox/example files (example/):${#EXAMPLE_FILES[@]}" \
        "  Test files (tests/):${#TEST_FILES[@]}" \
        "  Scaffold templates (templates/*/app.tesl):${#TEMPLATE_FILES[@]}" \
        -- "${LEARN_FILES[@]}" "${EXAMPLE_FILES[@]}" "${TEST_FILES[@]}" "${TEMPLATE_FILES[@]}"
    if [ "$compile_fail" -gt 0 ]; then
        printf "  %s%d file(s) failed validation.%s\n" "$C_RED" "$compile_fail" "$C_RESET"
        phase_end FAIL
    else
        phase_end OK
    fi
fi

if [ "$compile_fail" -gt 0 ]; then
    printf "\n  %sValidation failures — aborting before test run (avoids stale .rkt artifacts).%s\n" "$C_RED" "$C_RESET"
    print_summary_and_exit
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Phase 6 — Exact-match .rkt snapshots
# ══════════════════════════════════════════════════════════════════════════════
# Assert byte-exact emit for every committed snapshot under EXACT_DIRS below
# (example/learn/*.rkt plus the templates/ scaffold): re-emit
# from the paired .tesl and diff, canonicalising only the baked-in thsl-src! path
# prefix to its basename (same normalisation test_integration uses).  Any diff is
# a real emit change, not a stale snapshot.  Needs the built OCaml binary.
# Canonicalise every emitted form that bakes the INPUT .tesl path — the
# checkpoints and the debugger's read-only-query line table — down to a bare
# basename, so comparing a snapshot compiled with an absolute path against the
# repo-relative committed one still asserts the full emission structure.
canon_thsl() {
    sed -E -e 's#\(thsl-src(-control)?! "[^"]*/#(thsl-src\1! "#g' \
           -e 's#\(register-sql-read-lines! "[^"]*/#(register-sql-read-lines! "#g'
}
phase_begin "Exact-match .rkt snapshots"
_main_exe="$COMPILER_DIR/_build/default/bin/main.exe"
if [ ! -x "$_main_exe" ]; then
    printf "  %s⚠%s  compiler not built — skipping exact-match snapshots\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
else
    EXACT_SKIP=""   # space-separated lesson basenames to skip (none today)
    EXACT_FAILS=()
    EXACT_OK=0
    EXACT_SKIPPED=()
    # Directories held to byte-exact emit HERE.  example/learn is the historical
    # one; templates/{api,minimal} is the `tesl init` scaffold, whose committed
    # app.rkt exists FOR this ratchet and is seeded by
    # scripts/regen-rkt-snapshots.sh (see SEED_DIRS there) — it is not stray
    # build output.  example/ and tests/ are NOT repeated here: `dune test`
    # already walks them (test_integration.ml's exact_match_dir), and templates/
    # is deliberately gated in ci.sh instead so a scaffold emit regression fails
    # the same gate that validates and test-runs it.
    EXACT_DIRS="example/learn templates/api templates/minimal"
    for exact_dir in $EXACT_DIRS; do
    for rkt_file in "$SCRIPT_DIR/$exact_dir"/*.rkt; do
        [ -f "$rkt_file" ] || continue
        # Lesson basenames are unique, so they stay bare (the historical output
        # format).  Every template's snapshot is `app.rkt`, so those carry their
        # directory or a failure line could not say WHICH template broke.
        case "$exact_dir" in
            example/learn) lesson="$(basename "${rkt_file%.rkt}")" ;;
            *)             lesson="$exact_dir/$(basename "${rkt_file%.rkt}")" ;;
        esac
        tesl_file="${rkt_file%.rkt}.tesl"
        if [ ! -f "$tesl_file" ]; then
            echo "  NO .tesl FOR SNAPSHOT: $lesson (orphan .rkt)"
            EXACT_FAILS+=("$lesson(orphan)")
            continue
        fi
        case " $EXACT_SKIP " in
            *" $lesson "*) echo "  SKIP (env-dependent): $lesson"; EXACT_SKIPPED+=("$lesson"); continue ;;
        esac
        ocaml_out=$("$_main_exe" "$tesl_file" 2>/dev/null | canon_thsl)
        diff_lines=$(diff <(printf "%s\n" "$ocaml_out") <(canon_thsl < "$rkt_file") 2>/dev/null || true)
        diff_count=$(printf "%s\n" "$diff_lines" | grep -c "^[<>]" || true)
        if [ "$diff_count" -eq 0 ]; then
            EXACT_OK=$((EXACT_OK + 1))
        else
            echo "  DIFF ($diff_count lines): $lesson"
            EXACT_FAILS+=("$lesson")
        fi
    done
    done
    printf "  EXACT MATCH: %d snapshot(s); %d skipped; %d differ\n" \
        "$EXACT_OK" "${#EXACT_SKIPPED[@]}" "${#EXACT_FAILS[@]}"
    if [ ${#EXACT_FAILS[@]} -eq 0 ]; then
        phase_end OK
    else
        printf "  %sDiffering snapshots: %s%s\n" "$C_RED" "${EXACT_FAILS[*]}" "$C_RESET"
        phase_end FAIL
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Phase 7 — Tesl test files (generated Racket test submodules)
# ══════════════════════════════════════════════════════════════════════════════
detect_tesl_test_files
printf "\n  Detected %d Tesl file(s) with test blocks; %d without\n" \
    "${#TESL_TESTABLE_TESL_FILES[@]}" "$tesl_test_skipped_no_blocks"

# Warm the Racket precompile cache (shared deps) before the test sweep.
declare -a PRECOMPILE_TARGETS=(tests/example-test-batch.rkt tests/*.rkt tests/private/*.rkt)
if [ "${#TESL_TESTABLE_RKT_FILES[@]}" -gt 0 ]; then
    PRECOMPILE_TARGETS+=("${TESL_TESTABLE_RKT_FILES[@]}")
fi
if command -v raco >/dev/null 2>&1; then
    precompile_racket_modules "${PRECOMPILE_TARGETS[@]}" || true
fi

# Join the async PostgreSQL warm-up before the tests that need it.
if ! wait_for_shared_postgres; then
    printf "  %s⚠%s  Shared PostgreSQL warm-up failed; continuing without a preconfigured cluster\n" "$C_YELLOW" "$C_RESET"
fi

phase_begin "Tesl test files (batch runner)"
tesl_files_fail=0
if ! command -v racket >/dev/null 2>&1; then
    printf "  %s⚠%s  racket not on PATH — skipping Tesl test files\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
else
    if [ "$shared_postgres_configured" -eq 1 ]; then
        if [ "$shared_postgres_started" -eq 1 ]; then
            printf "  Shared PostgreSQL test cluster ready on port %s\n" "$TESL_TEST_POSTGRES_SHARED_PORT"
        else
            echo "  Using preconfigured shared PostgreSQL test cluster"
        fi
    fi
    if [ "${#TESL_TESTABLE_TESL_FILES[@]}" -eq 0 ]; then
        echo "  No Tesl test blocks detected in the example corpus"
        phase_end OK
    else
        if ! run_tesl_batch_runner "${TESL_TESTABLE_TESL_FILES[@]}"; then
            printf "  %s✗%s  Tesl batch runner exited unexpectedly\n" "$C_RED" "$C_RESET"
        fi
        if [ "${test_fail:-0}" -gt 0 ]; then
            tesl_files_fail=1
            phase_end FAIL
        else
            phase_end OK
        fi
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Phase 8 — Mutation testing (lesson42 — GDP boundary functions)
# ══════════════════════════════════════════════════════════════════════════════
phase_begin "Mutation testing (lesson42)"
mutation_fail=0
mutation_lesson="$SCRIPT_DIR/example/learn/lesson42-mutation-testing.tesl"
TESL_BIN="${TESL_BIN:-}"
if [ -z "$TESL_BIN" ]; then
    if [ -x "$_main_exe" ]; then
        TESL_BIN="$_main_exe"
    else
        TESL_BIN="tesl"
    fi
fi
if [ -f "$mutation_lesson" ] && command -v raco >/dev/null 2>&1; then
    printf "  Running: tesl --mutate %s\n" "$(basename "$mutation_lesson")"
    # TESL_MUTATION_TIMEOUT caps the full --mutate run (default 120s). Each mutant
    # calls raco test; TESL_MUTATE_TIMEOUT (passed through) caps each invocation.
    _mutation_timeout="${TESL_MUTATION_TIMEOUT:-120}"
    mutation_out=$(timeout "$_mutation_timeout" "$TESL_BIN" --mutate "$mutation_lesson" 2>&1)
    _mut_exit=$?
    if [ "$_mut_exit" -eq 124 ]; then
        printf "  %s⚠%s  Mutation testing timed out after %ss — skipping\n" "$C_YELLOW" "$C_RESET" "$_mutation_timeout"
        phase_end SKIP
    elif [ "$_mut_exit" -ne 0 ]; then
        mutation_fail=1
        printf "  %s✗%s  Mutation testing failed\n" "$C_RED" "$C_RESET"
        printf "%s\n" "$mutation_out" | head -40
        phase_end FAIL
    else
        printf "  %s✓%s  All mutants killed (score: 100%%)\n" "$C_GREEN" "$C_RESET"
        phase_end OK
    fi
elif ! command -v raco >/dev/null 2>&1; then
    printf "  %s⚠%s  raco not available — skipping mutation testing\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
else
    printf "  %s⚠%s  %s not found — skipping mutation testing\n" "$C_YELLOW" "$C_RESET" "$mutation_lesson"
    phase_end SKIP
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Phase 9 — Integration tests (httpclient + email)
# ══════════════════════════════════════════════════════════════════════════════
phase_begin "Integration tests (httpclient + email)"
integration_fail=0
_DUNE="$(command -v dune 2>/dev/null)"
if [ -z "$_DUNE" ]; then
    printf "  %s⚠%s  dune not found — skipping integration tests\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
elif [ ! -f "$_main_exe" ]; then
    printf "  %s⚠%s  compiler not built — skipping integration tests\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
else
    integration_ran=0
    for _suite in test_httpclient_integration test_email_integration; do
        _exe="$COMPILER_DIR/_build/default/test/${_suite}.exe"
        if [ ! -x "$_exe" ]; then
            ( cd "$COMPILER_DIR" && dune build "test/${_suite}.exe" 2>/dev/null ) || true
        fi
        if [ -x "$_exe" ]; then
            integration_ran=1
            printf "  Running %s...\n" "$_suite"
            if "$_exe" --color=never 2>&1 | grep -E "^\s+\[FAIL\]|Test Successful|failure" | grep -v "Test Successful"; then
                integration_fail=$((integration_fail + 1))
                printf "  %s✗%s  %s: failures detected\n" "$C_RED" "$C_RESET" "$_suite"
            else
                printf "  %s✓%s  %s\n" "$C_GREEN" "$C_RESET" "$_suite"
            fi
        else
            printf "  %s⚠%s  %s not built — skipping\n" "$C_YELLOW" "$C_RESET" "$_suite"
        fi
    done
    if [ "$integration_fail" -gt 0 ]; then
        phase_end FAIL
    elif [ "$integration_ran" -eq 0 ]; then
        phase_end SKIP
    else
        phase_end OK
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Phase 9b — tesl CLI smoke: multi-module `tesl test` (#33) + build layout
# ══════════════════════════════════════════════════════════════════════════════
# `tesl test <entrypoint>` must compile the entrypoint's imported local modules
# (like `tesl run` does) — on a fresh checkout (no .tesl-stuff/build/ yet) it
# used to die with a SWALLOWED "cannot open module file" and print "(no test
# results)".  Also locks the build-output relocation: every generated .rkt (and
# Racket's compiled/ bytecode) lands under <project-root>/.tesl-stuff/build/ in
# a tree MIRRORING the sources — never next to the .tesl files — and deleting
# .tesl-stuff/ then rerunning must always work.
# Drives the real CLI body script end-to-end from a clean temp project.
phase_begin "tesl CLI smoke (multi-module test + .tesl-stuff/build layout)"
if ! command -v racket >/dev/null 2>&1; then
    printf "  %s⚠%s  racket not found — skipping CLI smoke\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
elif [ ! -f "$_main_exe" ]; then
    printf "  %s⚠%s  compiler not built — skipping CLI smoke\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
else
    _cli_smoke_dir="$(mktemp -d)"
    _cli_fail=0
    # tesl.toml at the top marks the PROJECT ROOT — build output anchors here.
    cat > "$_cli_smoke_dir/tesl.toml" <<'EOF'
[project]
name = "cli-smoke"
entrypoint = "main.tesl"
EOF
    cat > "$_cli_smoke_dir/lib.tesl" <<'EOF'
module Lib exposing [double]
import Tesl.Prelude exposing [Int]

fn double(n: Int) -> Int = n + n
EOF
    cat > "$_cli_smoke_dir/main.tesl" <<'EOF'
module Main exposing [quad]
import Tesl.Prelude exposing [Int]
import Lib exposing [double]

fn quad(n: Int) -> Int = double (double n)

test "quad 3 == 12" {
  expect quad 3 == 12
}
EOF
    # Subdirectory module pair (imports are same-directory-only, so a
    # "subdirectory module" is an entry + its deps living together in a subdir
    # of the project root) — locks the mirrored-tree build layout.
    mkdir -p "$_cli_smoke_dir/sub"
    cat > "$_cli_smoke_dir/sub/util.tesl" <<'EOF'
module Util exposing [triple]
import Tesl.Prelude exposing [Int]

fn triple(n: Int) -> Int = n + n + n
EOF
    cat > "$_cli_smoke_dir/sub/app.tesl" <<'EOF'
module App exposing [nine]
import Tesl.Prelude exposing [Int]
import Util exposing [triple]

fn nine(n: Int) -> Int = triple (triple n)

test "nine 1 == 9" {
  expect nine 1 == 9
}
EOF
    _cli_run() {  # run the real CLI body from the project root
        ( cd "$_cli_smoke_dir" && \
            TESL_REPO_ROOT="$SCRIPT_DIR" TESL_OCAML_COMPILER="$_main_exe" \
            bash "$SCRIPT_DIR/nix/tesl-cli-body.sh" "$@" 2>&1 )
    }

    # 1) multi-module test from the project root
    _cli_out="$(_cli_run test main.tesl)"; _cli_rc=$?
    if [ "$_cli_rc" -eq 0 ] && printf '%s' "$_cli_out" | grep -q "1 test passed"; then
        printf "  %s✓%s  tesl test compiles imported modules and runs tests\n" "$C_GREEN" "$C_RESET"
    else
        printf "  %s✗%s  multi-module tesl test failed (rc=%s):\n%s\n" "$C_RED" "$C_RESET" "$_cli_rc" "$_cli_out"
        _cli_fail=1
    fi

    # 2) subdirectory module: mirrored tree under .tesl-stuff/build/
    _cli_out="$(_cli_run test sub/app.tesl)"; _cli_rc=$?
    if [ "$_cli_rc" -eq 0 ] && printf '%s' "$_cli_out" | grep -q "1 test passed" \
        && [ -f "$_cli_smoke_dir/.tesl-stuff/build/sub/app.rkt" ] \
        && [ -f "$_cli_smoke_dir/.tesl-stuff/build/sub/util.rkt" ]; then
        printf "  %s✓%s  subdirectory module builds into the mirrored .tesl-stuff/build/ tree\n" "$C_GREEN" "$C_RESET"
    else
        printf "  %s✗%s  subdirectory-module tesl test failed (rc=%s):\n%s\n" "$C_RED" "$C_RESET" "$_cli_rc" "$_cli_out"
        _cli_fail=1
    fi

    # 3) NO generated files outside .tesl-stuff/ (the whole point of the layout)
    _cli_stray="$(find "$_cli_smoke_dir" \( -name '*.rkt' -o -name 'compiled' \) \
        -not -path "$_cli_smoke_dir/.tesl-stuff/*" 2>/dev/null)"
    if [ -z "$_cli_stray" ] && [ -f "$_cli_smoke_dir/.tesl-stuff/build/main.rkt" ] \
        && [ -f "$_cli_smoke_dir/.tesl-stuff/build/lib.rkt" ]; then
        printf "  %s✓%s  all generated output lives under .tesl-stuff/\n" "$C_GREEN" "$C_RESET"
    else
        printf "  %s✗%s  generated files leaked outside .tesl-stuff/:\n%s\n" "$C_RED" "$C_RESET" "$_cli_stray"
        _cli_fail=1
    fi

    # 4) always safe to delete: rm -rf .tesl-stuff, rerun, must pass
    rm -rf "$_cli_smoke_dir/.tesl-stuff"
    _cli_out="$(_cli_run test main.tesl)"; _cli_rc=$?
    if [ "$_cli_rc" -eq 0 ] && printf '%s' "$_cli_out" | grep -q "1 test passed"; then
        printf "  %s✓%s  rm -rf .tesl-stuff && tesl test still passes (fresh rebuild)\n" "$C_GREEN" "$C_RESET"
    else
        printf "  %s✗%s  rerun after deleting .tesl-stuff failed (rc=%s):\n%s\n" "$C_RED" "$C_RESET" "$_cli_rc" "$_cli_out"
        _cli_fail=1
    fi

    rm -rf "$_cli_smoke_dir"
    if [ "$_cli_fail" -eq 0 ]; then phase_end OK; else phase_end FAIL; fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Phase 9c — CLI portability (BSD/macOS userland) + manifest-driven verbs
# ══════════════════════════════════════════════════════════════════════════════
# Issue #46: the CLI assumed a GNU userland (`mktemp --suffix=`, `readlink -f`,
# `realpath --relative-to`, `stat -c`, `sed -i`, `xargs -d`), so a fresh macOS
# install could not run a scaffolded project; `tesl test`/`tesl run` with no file
# contradicted the scaffolded README; and `tesl build` built a Docker image even
# for [deploy].target = "local".  tests/cli-portability.sh is the ratchet: a
# STATIC scan of nix/tesl-cli-body.sh for GNU-only constructs plus a DYNAMIC
# re-run of the verbs with BSD-only mktemp/stat/readlink/sed/xargs shimmed onto
# PATH — both run on this Linux CI, so a macOS-only regression fails here.
phase_begin "CLI portability (BSD userland) + manifest-driven verbs"
_portability_rc=0
TESL_REPO_ROOT="$SCRIPT_DIR" TESL_OCAML_COMPILER="$_main_exe" \
    bash "$SCRIPT_DIR/tests/cli-portability.sh" || _portability_rc=$?
if [ "$_portability_rc" -eq 0 ]; then
    phase_end OK
elif [ "$_portability_rc" -eq 77 ]; then
    phase_end SKIP
else
    phase_end FAIL
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Phase 10 — Racket suites (debugger / headless-inspect / MCP / lifted-stdlib
#             + AI (Tesl.Agent) mock feature & runtime suites)
# ══════════════════════════════════════════════════════════════════════════════
# These exercise the DSL-side runtime the OCaml dune test does NOT cover.  All
# mock-based — no network/keys/cost; DB-dependent suites are intentionally NOT
# here.  RKT_SUITES_SKIP=1 skips this whole phase for a fast inner loop.
phase_begin "Racket suites (debugger / MCP / lifted-stdlib + AI)"
racket_suites_fail=0
if [ "${RKT_SUITES_SKIP:-0}" = "1" ]; then
    printf "  %s⚠%s  RKT_SUITES_SKIP=1 — skipping\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
elif ! command -v raco >/dev/null 2>&1; then
    printf "  %s⚠%s  raco not on PATH — skipping\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
else
    RKT_SUITES=(
        "tests/dap-server-test.rkt"
        "tests/checkpoint-condition-test.rkt"
        "tests/dap-domain-registry-smoke.rkt"
        "tests/dap-stop-the-world-smoke.rkt"
        "tests/dap-headless-inspect-smoke.rkt"
        "tests/dap-headless-inspect-conditional-smoke.rkt"
        # Persistent NDJSON inspector mode (session-started / stopped× / exited)
        "tests/dap-headless-persistent-smoke.rkt"
        # Live attach control channel: protocol + socket lifecycle + re-arm +
        # detach/EOF semantics + pause timeout + concurrent-stop serialization
        "tests/dap-attach-smoke.rkt"
        # Debugger value lenses: the composite-implies-expandable invariant plus
        # launch-mode ≡ attach-mode tree equivalence (dsl/debug/value-tree.rkt)
        "tests/dap-value-tree-tests.rkt"
        # …and the attach wire JSON that carries those trees between processes
        "tests/dap-attach-value-tree-smoke.rkt"
        "tests/dap-sql-scope-smoke.rkt"
        # SQL lens on the query LINE: the compiler's read-line table drives an
        # AFTER-the-statement pause, and the freshness flag distinguishes this
        # line's statement from the previous one
        "tests/sql-read-lines-tests.rkt"
        # Int32 (NT-07) boundary values: overflow answers Nothing at the exact
        # edge, pow bounds the exponent before expt, NaN/inf convert cleanly —
        # plus issue #45's api-test path normalization (literal ≡ computed)
        "tests/int32-runtime-tests.rkt"
        # `secret X = T` runtime half (roadmap/completed/tesl_crypto.md phases 3+4).
        # Here because the enforcement is spread across SIX independent sinks
        # (telemetry jsexpr + OTLP AnyValue, metric attributes, safe-display, the
        # value-tree display/children pair, dap-server's Copy Value text, the SQL
        # trace) and the property that matters is STRUCTURAL: a secret nested in a
        # record inside a tuple inside a List inside a Maybe inside an ADT payload
        # must redact while its siblings render normally.  A shallow
        # implementation passes a flat test and fails this suite, and none of that
        # is reachable from the OCaml `dune test` side.  It also pins the one
        # thing a well-meaning future edit gets wrong: `runtime-value->jsexpr` is
        # the PERSISTENCE walk too, so redaction there is opt-in and both
        # directions are asserted.
        "tests/secret-runtime-tests.rkt"
        # Tesl.Regex runtime last line of defence: the ReDoS deadline (a
        # pathological pattern the COMPILER rejects, handed straight to the
        # runtime, must not hang the process), the input bound, and the
        # capture-list shape `Regex.captures` promises
        "tests/regex-runtime-tests.rkt"
        # Tesl.Crypto — the security suite, and the one place in the gate where a
        # green run means something a round-trip test cannot prove:
        #   * KNOWN-ANSWER digests/MACs (NIST + RFC 4231) plus an INDEPENDENT
        #     oracle (libsodium vs OpenSSL libcrypto) across the HMAC block
        #     boundary, because a self-consistently wrong implementation
        #     round-trips perfectly;
        #   * the COST-PARAMETER REGRESSION — wall clock AND the memory limit
        #     libsodium reports. A build whose Argon2id work factor silently
        #     collapsed passes every other test in the file, and that is a total
        #     security failure that looks like everything working. This is the
        #     test most likely to be skipped and most likely to matter;
        #   * TIMING EQUALISATION: verifying against Nothing (no user row) must
        #     cost the same as against a real hash, or the login endpoint
        #     enumerates registered addresses;
        #   * the documented foreign-hash LIMITS as ratchets (foreign Argon2id
        #     verifies; bcrypt and scrypt do not) so behaviour and docs cannot
        #     drift apart.
        "tests/crypto-runtime-tests.rkt"
        "tests/codec-specialization-test.rkt"
        "tests/lifted-list-tests.rkt"
        "tests/body-proof-test.rkt"
        "tests/check-test.rkt"
        "tests/sql-test.rkt"
        # Memory-database registry: imported-db test isolation (fresh-memory-db
        # resets ALL registered memory databases, not just the emitter's list)
        "tests/memory-db-registry-test.rkt"
        "tests/sql-group-by-pg-test.rkt"
        # First-Class Units: Money two-column storage (Memory decision-table +
        # PG parity; the PG suite self-skips without initdb/pg_ctl)
        "tests/sql-money-tests.rkt"
        "tests/sql-money-pg-test.rkt"
        # First-Class Units: hand-written conversion-factor oracle (golden)
        # + direct money-tagged tool-argument decode contract
        "tests/units-factor-golden-tests.rkt"
        "tests/agent-money-tools-tests.rkt"
        # Issue #31: pool-lease waiting + 503 mapping (fake connections, no PG)
        "tests/pg-pool-tests.rkt"
        # Outbound-HTTP deadlines: connect / total-read / SSE-idle against real
        # loopback servers that ACCEPT the connection (so, unlike
        # tests/httpclient-test.rkt below, nothing depends on how the network
        # filters a connect to a dead port), plus the outbound wire-shape
        # regressions the deadline work uncovered (Tuple2 headers, ?query URLs)
        "tests/http-timeout-tests.rkt"
        # Phase -1 (roadmap/next/ensure_sso_works.md): outbound HTTPS must
        # authenticate its TLS peer.  A self-signed loopback server is refused by
        # the verifying context; the single loopback-only dev escape is gated on
        # env + host; and a ratchet forbids any bare `#:ssl? #t` from returning.
        "tests/http-tls-tests.rkt"
        # #48 (issue): SSRF egress containment on Tesl.HttpClient — cloud
        # metadata / RFC1918 / CGNAT / ULA / link-local / 0.0.0.0/8 refused for
        # every outbound call by resolved-address judgement + connect-pinning;
        # loopback is deploy-gated with an opt-in dev escape.
        "tests/http-ssrf-tests.rkt"
        # #51 (issue): request.clientAddress + the trustedProxies edge
        # declaration — socket peer with no declaration; rightmost untrusted
        # X-Forwarded-For hop when declared; refuse on disagreement.
        "tests/http-client-address-test.rkt"
        "tests/timezone-zones-test.rkt"
        "tests/web-test.rkt"
        # Phase -2 (roadmap/next/ensure_sso_works.md): the server-wide response
        # security-header baseline (nosniff/Referrer-Policy/X-Frame-Options,
        # HSTS from publicOrigin scheme, CSP on served HTML), incl. the two paths
        # that skipped all headers today (static file + SPA fallback).
        "tests/response-security-headers-test.rkt"
        "tests/exists-test.rkt"
        "tests/jwt-test.rkt"
        # Stage 2 runtime halves (roadmap/next/ensure_sso_works.md): SessionPolicy
        # (TTL/absolute-cap decoupling), session-key rotation ([current,previous]),
        # and revocation at the renewal boundary — all SSO-independent, in jwt.rkt.
        "tests/jwt-session-policy-test.rkt"
        # Phase 1 down-payment: SSRF containment classifier (Risk 47) — the
        # metadata endpoint, loopback, RFC1918/CGNAT/link-local and their
        # IPv4-mapped spellings are refused; fail-closed on unparseable input.
        "tests/ssrf-guard-test.rkt"
        # Phase 1 & 2: dsl/sso.rkt OIDC + plain-OAuth2 runtime.  Pure security
        # layer (PKCE S256, injective SsoSubjectKey, EmailClaim rule, OIDC claim
        # + Entra multi-tenant validation, integrity-protected __Host-oauth
        # cookie, provider defaults) and the orchestration driven through the
        # outbound-HTTP stub (discovery -> token -> id_token/userinfo -> identity).
        "tests/sso-runtime-test.rkt"
        # Item A (#50.2): Tesl.Proxy runtime — ProxyBound minted only by a
        # constant-time Proxy.verifyBinding match.
        "tests/proxy-runtime-test.rkt"
        "tests/sso-flow-test.rkt"
        # Phase 2.5: RS256/ES256 ID-token signature verification + JWKS over
        # openssl/libcrypto (verify-only).  Valid RS256/ES256 fixtures plus the
        # adversarial refusals: alg:none, HMAC-on-ID-token, alg-not-pinned,
        # header key nomination (jwk/jku/x5u/x5c/crit), JWE, wrong kid, <2048-bit
        # modulus, tampered payload.
        "tests/jws-verify-test.rkt"
        # Phase 5 adversarial review pass over the SSO runtime: the spec's own
        # attack list (secret-in-URL, provider-error reflection, broken signature,
        # PKCE downgrade, http/SSRF transport, state cross-swap, unverified-email
        # takeover, absent hd, subject/clock shapes, flattened-claims, Entra
        # multi-tenant trap, extraAuthorizeParams smuggling, key stability).
        "tests/sso-adversarial-test.rkt"
        # Phase 3: the Tesl.Sso stdlib runtime (tesl/sso.rkt) that the
        # Sso.defaults / Sso.keyText type rows resolve to.
        "tests/sso-stdlib-test.rkt"
        # Systemic: every opaque/nominal stdlib type usable in a checked position
        # must resolve a runtime predicate (fail-closed define/pow return check) —
        # closes the class the SSO e2e surfaced (non-newtype opaque types).
        "tests/opaque-type-registration-test.rkt"
        # Phase 3: the runtime-owned SSO routes in dsl/web.rkt (303 redirect +
        # Set-Cookie on a redirect, route matching, full login->callback->session).
        "tests/sso-web-test.rkt"
        # SSE path capability wiring + the credentialed-response CORS rule
        # (adversarial review F6/F9): an `auth`/`capture` with a `requires` row
        # runs on a subscribe, and a Set-Cookie response drops the wildcard
        # ACAO.  Drives handle-sse-request directly (serve needs a real port).
        "tests/sse-capabilities-test.rkt"
        # Confused-deputy fix (F1): a tool body cannot write the OUTER request's
        # session cookie.  Drives the real agent loop with a scripted cookie-
        # setting tool inside a live response scope; not reachable from the .tesl
        # api-test path, so it lives here.
        "tests/session-cookie-tool-confinement-test.rkt"
        "tests/record-test.rkt"
        "tests/dap-conditional-smoke.rkt"
        "tests/otlp-exporter-test.rkt"
        # OTel Metrics signal: registry + OTLP mapping + /v1/metrics exporter
        "tests/otlp-metrics-test.rkt"
        # W3C trace context (Phase A of the traces item).  Here because the
        # parser's contract is TOTALITY over attacker-controlled header input —
        # every malformed `traceparent` must answer "start a fresh trace" rather
        # than raise on a request path — and because log correlation and outbound
        # propagation are properties of the WIRE (an OTLP log record's traceId
        # field, an injected request header), neither of which a .tesl api-test
        # can observe.
        "tests/trace-context-test.rkt"
        # OTel Traces signal: span recorder + parent/child shape + OTLP mapping +
        # /v1/traces exporter + the `traces False` zero-cost gate + the
        # secret-in-a-span-attribute regression (a span is a rendering sink, and
        # it is the newest one).
        "tests/otlp-traces-test.rkt"
        "editor/tesl-mcp/tests/protocol-smoke.rkt"
        # The LSP server's own in-module suite (hover/completion/code-action/
        # semantic-token rendering, incl. quick-fix ACTION TITLES).  It was not
        # gated anywhere before, so ~400 assertions could rot unnoticed.
        "editor/tesl-lsp/tesl-lsp.rkt"
        # NOT gated here (by design): tests/httpclient-test.rkt makes real loopback
        # TCP connects that hang where the network filters rather than RST-refuses.
    )
    for suite in "${RKT_SUITES[@]}"; do
        if [ ! -f "$SCRIPT_DIR/$suite" ]; then
            printf "  %s⚠%s  %s (missing — skipped)\n" "$C_YELLOW" "$C_RESET" "$suite"
            continue
        fi
        if TESL_REPO_ROOT="$SCRIPT_DIR" timeout 300 raco test "$SCRIPT_DIR/$suite" >/dev/null 2>&1; then
            printf "  %s✓%s  %s\n" "$C_GREEN" "$C_RESET" "$suite"
        else
            printf "  %s✗%s  %s\n" "$C_RED" "$C_RESET" "$suite"
            racket_suites_fail=1
        fi
    done

    # AI suites (Tesl.Agent): emit each .tesl mock block → raco test, plus the
    # racket provider-norm / runtime suites.  The temp-PG runtime suite self-skips
    # when PostgreSQL is absent.
    echo "  ── AI suites (Tesl.Agent mock feature / runtime) ──"
    ai_tmp="$(mktemp -d)"
    AI_TESL=( "tests/agent-feature-tests.tesl" "tests/agent-tests.tesl" \
              "tests/agent-tools-tests.tesl" "tests/agent-conversation-tests.tesl" \
              "tests/agent-run-tests.tesl" "tests/server-tools-tests.tesl" \
              "tests/two-api-server-tools-tests.tesl" \
              "tests/human-actions-tests.tesl" \
              "example/support-assistant.tesl" \
              "example/ai-conversation-service.tesl" )
    AI_RKT=( "tests/agent-provider-norm-test.rkt" "tests/agent-runtime-tests.rkt" \
             "tests/agent-conversation-pg-test.rkt" )
    for f in "${AI_TESL[@]}"; do
        [ -f "$SCRIPT_DIR/$f" ] || { printf "  %s⚠%s  %s (missing — skipped)\n" "$C_YELLOW" "$C_RESET" "$f"; continue; }
        out="$ai_tmp/$(basename "$f" .tesl).rkt"
        if [ -x "$_main_exe" ] \
           && TESL_REPO_ROOT="$SCRIPT_DIR" "$_main_exe" "$SCRIPT_DIR/$f" > "$out" 2>/dev/null \
           && TESL_REPO_ROOT="$SCRIPT_DIR" timeout 300 raco test "$out" >/dev/null 2>&1; then
            printf "  %s✓%s  %s\n" "$C_GREEN" "$C_RESET" "$f"
        else
            printf "  %s✗%s  %s\n" "$C_RED" "$C_RESET" "$f"; racket_suites_fail=1
        fi
    done
    rm -rf "$ai_tmp"
    for suite in "${AI_RKT[@]}"; do
        [ -f "$SCRIPT_DIR/$suite" ] || { printf "  %s⚠%s  %s (missing — skipped)\n" "$C_YELLOW" "$C_RESET" "$suite"; continue; }
        if TESL_REPO_ROOT="$SCRIPT_DIR" timeout 300 raco test "$SCRIPT_DIR/$suite" >/dev/null 2>&1; then
            printf "  %s✓%s  %s\n" "$C_GREEN" "$C_RESET" "$suite"
        else
            printf "  %s✗%s  %s\n" "$C_RED" "$C_RESET" "$suite"; racket_suites_fail=1
        fi
    done

    if [ "$racket_suites_fail" -eq 0 ]; then
        phase_end OK
    else
        phase_end FAIL
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Phase 11 — Racket aggregate suite (tests/all.rkt, shared PostgreSQL)
# ══════════════════════════════════════════════════════════════════════════════
phase_begin "Racket aggregate suite (tests/all.rkt)"
aggregate_fail=0
if ! command -v racket >/dev/null 2>&1; then
    printf "  %s⚠%s  racket not on PATH — skipping aggregate suite\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
else
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

    summary_failures=$(printf '%s' "$test_output" | grep -oE '[0-9]+ failure\(s\)' | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}' || true)
    summary_errors=$(printf '%s' "$test_output" | grep -oE '[0-9]+ error\(s\)' | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}' || true)
    bare_failures=$(printf '%s' "$test_output" | grep -cE '^[[:space:]]*FAILURE[[:space:]]*$' || true)
    tests_failed=$(( ${summary_failures:-0} + ${summary_errors:-0} + ${bare_failures:-0} ))
    postgres_failed=$(echo "$test_output" | grep -c "pg_ctl: could not start server" || true)

    if [ "$tests_failed" -gt 0 ]; then
        printf "  %s✗%s  Racket tests failed (%s failure(s))\n" "$C_RED" "$C_RESET" "$tests_failed"
        aggregate_fail=1
        phase_end FAIL
    elif [ "$test_exit" -ne 0 ] && [ "$postgres_failed" -gt 0 ]; then
        # Honest SKIP: PostgreSQL could not start (known WSL2 limitation).  We do
        # NOT force this green — the real non-zero exit is propagated so the gate
        # never falsely reports success when the suite did not complete cleanly.
        printf "  %s⚠%s  SKIP: PostgreSQL could not start (known WSL2 limitation);\n" "$C_YELLOW" "$C_RESET"
        printf "      the aggregate suite did NOT complete — exit %d is propagated (not forced green).\n" "$test_exit"
        aggregate_fail=1
        phase_end FAIL
    elif [ "$test_exit" -eq 0 ]; then
        printf "  %s✓%s  All Racket tests pass\n" "$C_GREEN" "$C_RESET"
        phase_end OK
    else
        printf "  %s✗%s  test suite exited with code %d\n" "$C_RED" "$C_RESET" "$test_exit"
        aggregate_fail=1
        phase_end FAIL
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Phase 12 — Boot smoke (App activation path)
# ══════════════════════════════════════════════════════════════════════════════
# `tesl check` and `tesl test` never run `main`, so a codegen bug in the App
# ACTIVATION path (start-workers! / start-dead-workers! / serve / sse) crashes only
# at `tesl run` — invisible to the rest of the gate. This is exactly how issue #15
# (start-dead-workers! handed #:concurrency) slipped through. Boot an activation-
# heavy fixture (queue + single-threaded dead-letter worker + numberOfWorkers +
# serve) and confirm it reaches the serving banner, which is printed only AFTER
# every activation call. A boot crash exits before the banner → FAIL.
phase_begin "Boot smoke (App activation via tesl run)"
boot_smoke_src="$SCRIPT_DIR/scripts/boot-smoke/app.tesl"
if ! command -v racket >/dev/null 2>&1; then
    printf "  %s⚠%s  racket not on PATH — skipping boot smoke\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
elif [ ! -x "$_main_exe" ]; then
    printf "  %s⚠%s  compiler binary missing — skipping boot smoke\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
elif [ ! -f "$boot_smoke_src" ]; then
    printf "  %s⚠%s  boot-smoke fixture missing — skipping\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
else
    boot_rkt="$(mktemp "${TMPDIR:-/tmp}/tesl-boot-smoke.XXXXXX.rkt")"
    boot_out="$(mktemp "${TMPDIR:-/tmp}/tesl-boot-out.XXXXXX")"
    boot_err="$(mktemp "${TMPDIR:-/tmp}/tesl-boot-err.XXXXXX")"
    boot_port="${TESL_BOOT_SMOKE_PORT:-8199}"
    if ! TESL_REPO_ROOT="$SCRIPT_DIR" "$_main_exe" "$boot_smoke_src" > "$boot_rkt" 2>"$boot_err"; then
        printf "  %s✗%s  boot-smoke fixture failed to compile\n" "$C_RED" "$C_RESET"
        sed 's/^/      /' "$boot_err" | head -n 20
        phase_end FAIL
    else
        # Run under `timeout -s KILL` so a healthy (blocking) server is force-killed
        # and can never hang the gate; a boot crash exits on its own before then.
        # The serving banner is the positive signal (printed after all activation).
        PORT="$boot_port" TESL_REPO_ROOT="$SCRIPT_DIR" \
          run_with_optional_nix_shell timeout -s KILL 12 racket "$boot_rkt" \
          > "$boot_out" 2>"$boot_err" || true
        if grep -q "Web application is running at" "$boot_out"; then
            printf "  %s✓%s  App booted past activation (queue+dead-worker+numberOfWorkers+serve)\n" "$C_GREEN" "$C_RESET"
            phase_end OK
        else
            printf "  %s✗%s  App crashed on boot (activation path) — never reached serving\n" "$C_RED" "$C_RESET"
            sed 's/^/      /' "$boot_err" | tail -n 20
            phase_end FAIL
        fi
    fi
    rm -f "$boot_rkt" "$boot_out" "$boot_err"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Playground parity (browser teslCheck ≡ tesl --check-json)
# ══════════════════════════════════════════════════════════════════════════════
# playground/ ships the compiler compiled to JavaScript, reusing the SAME
# check_source + lint pair and the SAME diag_to_json serializer as
# `tesl --check-json`.  The failure mode worth a phase is not "the build broke"
# (loud) but the browser build silently DIVERGING from the CLI — which is exactly
# how the linter was once found to be contributing nothing in the browser.  So
# this phase asserts PARITY over the first 30 lessons, not that it compiles.
# All the logic lives in the script; this stays thin.
phase_begin "Playground parity (browser teslCheck ≡ --check-json)"
if [ ! -f "$SCRIPT_DIR/scripts/playground-parity.sh" ]; then
    printf "  %s⚠%s  scripts/playground-parity.sh not found — skipping\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
else
    _parity_rc=0
    bash "$SCRIPT_DIR/scripts/playground-parity.sh" || _parity_rc=$?
    if [ "$_parity_rc" -eq 0 ]; then
        phase_end OK
    elif [ "$_parity_rc" -eq 77 ]; then
        # 77 = js_of_ocaml or node absent, or no corpus/compiler.  An optional
        # tool that is missing is never a gate failure (same rule as racket/PG).
        phase_end SKIP
    else
        printf "  %s✗%s  the browser checker diverged from the CLI (see above)\n" "$C_RED" "$C_RESET"
        phase_end FAIL
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Phase 20 — SSO browser end-to-end (real dex IdP + headless Chromium)
# ══════════════════════════════════════════════════════════════════════════════
# The one gate that runs a COMPILED Tesl program through the real serve/handler
# path against a real IdP — a headless browser logs in via a local dex over the
# generic `Sso.oidc` connection and reads back the session (see e2e/sso/). It is
# what catches the "never executed end-to-end" class of bug. Needs `nix` (it
# realizes dex + playwright + the browser bundle) and `racket`; skipped in the
# fast inner loop (RKT_SUITES_SKIP) or explicitly (SSO_E2E_SKIP). Timeout-bounded.
phase_begin "SSO browser e2e (dex + Playwright, headless)"
if is_truthy "${SSO_E2E_SKIP:-0}" || is_truthy "${RKT_SUITES_SKIP:-0}"; then
    printf "  %s⚠%s  SSO_E2E_SKIP / RKT_SUITES_SKIP set — skipping\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
elif ! command -v nix >/dev/null 2>&1 || ! command -v racket >/dev/null 2>&1; then
    printf "  %s⚠%s  nix or racket not on PATH — skipping\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
else
    _e2e_rc=0
    _e2e_timeout="${SSO_E2E_TIMEOUT:-600}"
    if command -v timeout >/dev/null 2>&1; then
        timeout "$_e2e_timeout" bash "$SCRIPT_DIR/e2e/sso/run.sh" || _e2e_rc=$?
    else
        bash "$SCRIPT_DIR/e2e/sso/run.sh" || _e2e_rc=$?
    fi
    if [ "$_e2e_rc" -eq 0 ]; then
        phase_end OK
    else
        printf "  %s\xe2\x9c\x97%s  SSO browser e2e failed (rc=%s) — see output above\n" "$C_RED" "$C_RESET" "$_e2e_rc"
        phase_end FAIL
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Final collated summary + overall verdict
# ══════════════════════════════════════════════════════════════════════════════
print_summary_and_exit
