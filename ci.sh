#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  ci.sh — THE single authoritative "is the codebase green?" gate for Tesl.
# ══════════════════════════════════════════════════════════════════════════════
#
# This script is the UNION / strict SUPERSET of the two historical QA scripts it
# replaces:
#
#   * ./compile-examples.sh   (was: format → dune test → validate-sweep → Tesl
#                              tests → mutation → integration)
#   * ./compiler/ci.sh        (was: dune build → dune test (ID-keyed waivers) →
#                              compile-all → exact-match Go snapshots)
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
#   2a. Go backend           runtime + fresh emitted module toolchain gates
#    4. Embedded-docs sync    embedded_docs.ml matches manual/+example/ (promote)
#   4a. Doc integrity         tests/doc-integrity.sh — relative links, cited
#                             #anchors, MANUAL.md ↔ `tesl help manual` round-trip,
#                             orphan docs, hand-typed corpus counts
#   4b. Manual coherence      manual/tests — the standalone dune project guarding
#                             the anchor contract + doc-prose lints (str/unix only)
#    5. Format                tesl fmt (in place), bounded xargs -P pool
#    6. Validate              tesl validate (check+lint+fmt), xargs -P pool
#    7. Exact-match snaps     byte-exact Go snapshots
#    8. Go corpus             recursive tracked-source compile/build
#    9. Mutation              Go mutation testing on lesson42 + scalar proof corpus
#   10. Integration           full-chain Go: HTTP library + server chain, SMTP
#                             delivery (scripts/run-go-integration.sh)
#   10a. Clean install        nix-built #tesl-go-cli wrapper: init/emit/build
#                             under env -i (tests/go-clean-install.sh)
#   11. Boot smoke            Go App activation via `tesl run`
#   12. Playground parity     scripts/playground-parity.sh — the browser build's
#                             teslCheck vs `tesl --check-json` over 30 lessons
#                             (SKIPs when js_of_ocaml or node is unavailable)
#
# A per-phase progress line is printed as each phase STARTS and again when it
# finishes:  [N/T] <phase> … OK/FAIL/SKIP (Xs).  Output stays clean (no colour,
# no cursor tricks) when stdout is not a TTY (CI logs).  A final collated summary
# lists every phase with its status + timing and the overall verdict.
#
# Optional dependencies (initdb/pg_ctl, python3, MailHog) that are
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
#   TESL_MUTATION_TIMEOUT      cap on the full --mutate run (default 120s)
#   TESL_TEST_USE_TEMP_PG      use a temp PostgreSQL data root (default: CI)
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
# place nor register the runtime collection there — it leaves the `tesl` wrapper
# pointing at an unbuilt store binary.
# ci.sh always runs from the WRITABLE checkout ($SCRIPT_DIR, basename `tesl`), so:
#   (1) point the compiler env at the binary phase 1 builds here — the dev `tesl`
#       wrapper now honours a pre-set $TESL_OCAML_COMPILER (see flake.nix), and
# Both are idempotent and harmless when the source is already writable (local).
export TESL_OCAML_COMPILER="$COMPILER_DIR/_build/default/bin/main.exe"

# Option E: run the S7 generative gate in EXHAUSTIVE mode (scan the WHOLE proof
# corpus for accepted soundness-breaking mutants — the full detector), not the
# fast budget-bounded mode the developer dune-test loop uses.  Overridable.
export TESL_S7_EXHAUSTIVE="${TESL_S7_EXHAUSTIVE:-1}"

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
TOTAL_PHASES=21
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
    # Option E: SKIP ≠ PASS. A soundness-required phase that SKIPs — e.g. because
    # initdb/pg_ctl was missing — used to be counted as "legitimately skipped"
    # and the gate still printed "All good", silently masking that the entire
    # runtime/proof-runtime layer never ran.  We now treat a SKIP of any required
    # phase (everything except the cosmetic "Format" phase) as a gate FAILURE.
    # Local fast-loops that intentionally skip opt out with TESL_CI_ALLOW_SKIP=1.
    local skipped_required=0
    local allow_skip=0
    # TESL_CI_ALLOW_SKIP opts out of the strict SKIP-is-FAIL rule.
    if is_truthy "${TESL_CI_ALLOW_SKIP:-}"; then allow_skip=1; fi
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

# ── File corpus ───────────────────────────────────────────────────────────────
# Relative paths (we `cd "$SCRIPT_DIR"` above) keep diagnostics stable. Drop
# transient LSP validation copies that the globs could race-capture.
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
# diff, not the Tesl-test sweep. A scaffold that does not boot is the worst
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
#  Migration gate — contracts and traceability
# ══════════════════════════════════════════════════════════════════════════════
phase_begin "Protocol contracts"
migration_contract_fail=0
    if ! "$SCRIPT_DIR/tests/protocol/check-contracts.sh"; then
    migration_contract_fail=1
fi
if [ "$migration_contract_fail" -eq 0 ]; then phase_end OK; else phase_end FAIL; fi
if [ "$migration_contract_fail" -gt 0 ]; then
    printf "\n  %sProtocol contracts failed — aborting the gate.%s\n" "$C_RED" "$C_RESET"
    print_summary_and_exit
fi

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
#  Phase 2a — Go runtime and emitted-code gates
# ══════════════════════════════════════════════════════════════════════════════
phase_begin "Go runtime + emitted-code gates"
go_gate_fail=0
for tool in go gofmt staticcheck gosec govulncheck golangci-lint nilaway; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf "  %s✗%s  required Go gate tool not found: %s\n" "$C_RED" "$C_RESET" "$tool"
        go_gate_fail=1
    fi
done
if [ "$go_gate_fail" -eq 0 ]; then
    (
      cd "$SCRIPT_DIR/runtime/go" || exit 1
      _unformatted="$(gofmt -l teslrt/*.go)"
      if [ -n "$_unformatted" ]; then
          printf "unformatted Go files:\n%s\n" "$_unformatted" >&2
          exit 1
      fi
      go test -count=1 ./... &&
      go test -race -count=1 ./... &&
      go test ./teslrt -run '^$' -fuzz '^FuzzIntDecimalAndJSONRoundTrip$' -fuzztime="${TESL_GO_FUZZTIME:-3s}" &&
      go test ./teslrt -run '^$' -fuzz '^FuzzIntArithmeticAgainstBig$' -fuzztime="${TESL_GO_FUZZTIME:-3s}" &&
      go test ./teslrt -run '^$' -fuzz '^FuzzIntJSONInput$' -fuzztime="${TESL_GO_FUZZTIME:-3s}" &&
      go test ./internal/protocol -run '^$' -fuzz '^FuzzReaderAcceptsWriterFrames$' -fuzztime="${TESL_GO_FUZZTIME:-3s}" &&
      go test ./internal/protocol -run '^$' -fuzz '^FuzzUTF16PositionsNeverPanic$' -fuzztime="${TESL_GO_FUZZTIME:-3s}" &&
      go vet ./... &&
      CGO_ENABLED=0 go build ./... &&
      staticcheck ./... &&
      golangci-lint run ./... &&
      gosec -quiet ./... &&
      govulncheck ./... &&
      nilaway ./...
    ) || go_gate_fail=1
fi
if [ "$go_gate_fail" -eq 0 ] && [ -f "$SCRIPT_DIR/tests/go-cli-smoke.sh" ]; then
    bash "$SCRIPT_DIR/tests/go-cli-smoke.sh"
    _go_cli_rc=$?
    [ "$_go_cli_rc" -eq 0 ] || [ "$_go_cli_rc" -eq 77 ] || go_gate_fail=1
fi
if [ "$go_gate_fail" -eq 0 ]; then phase_end OK; else phase_end FAIL; fi

# ══════════════════════════════════════════════════════════════════════════════
#  Lesson catalog
# ══════════════════════════════════════════════════════════════════════════════
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
# It has its OWN dune-project (str + unix only, no compiler library), so
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
    printf "\n  %sValidation failures — aborting before test run.%s\n" "$C_RED" "$C_RESET"
    print_summary_and_exit
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Exact-match .go.snap snapshots
# ══════════════════════════════════════════════════════════════════════════════
# The corpus gate asks whether emitted Go BUILDS and its tests RUN,
# never whether it is the Go the maintainer last read.  A compiler change that
# "should not" alter the output is exactly the change nobody writes a test for.
#
# One snapshot per example source, holding every emitted artifact except the
# vendored runtime (identical for every program, gated in phase 2a) — see
# scripts/regen-go-snapshots.sh, which is also what regenerates them.
#
# The Go emitter bakes only the BASENAME into its `//line` directives, so a snapshot
# does not depend on where
# the repository sits.
phase_begin "Exact-match .go.snap snapshots"
_main_exe="$COMPILER_DIR/_build/default/bin/main.exe"
if [ ! -x "$_main_exe" ]; then
    printf "  %s⚠%s  compiler not built — skipping Go snapshots\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
else
    GO_SNAP_FAILS=()
    GO_SNAP_OK=0
    GO_SNAP_MISSING=()
    while IFS= read -r snap; do
        [ -f "$snap" ] || continue
        rel_snap="${snap#$SCRIPT_DIR/}"
        tesl="${snap%.go.snap}.tesl"
        if [ ! -f "$tesl" ]; then
            # An orphan snapshot means a source was renamed or deleted and the
            # snapshot was left behind; it would otherwise pass forever.
            GO_SNAP_MISSING+=("$rel_snap")
            continue
        fi
        rel_tesl="${tesl#$SCRIPT_DIR/}"
        _snap_out="$(mktemp -d)"
        rm -rf "$_snap_out"
        if ! ( cd "$SCRIPT_DIR" && TESL_REPO_ROOT="$SCRIPT_DIR" \
                 "$_main_exe" "$rel_tesl" --out "$_snap_out" ) >/dev/null 2>&1; then
            GO_SNAP_FAILS+=("$(basename "$rel_snap") (no longer emits)")
            rm -rf "$_snap_out"
            continue
        fi
        _snap_fresh="$(mktemp)"
        {
            printf '// Generated by scripts/regen-go-snapshots.sh — DO NOT EDIT.\n'
            printf '//\n'
            printf '// A byte-exact snapshot of the Go emitted for %s.\n' "$rel_tesl"
            printf '// The vendored runtime (internal/teslrt/**) is omitted: it is identical for every\n'
            printf '// program and gated on its own by ci.sh phase 2a.\n'
            ( cd "$_snap_out" && find . -type f \
                ! -path './internal/teslrt/*' ! -name '.golangci.yml' \
                | sed 's|^\./||' | LC_ALL=C sort ) | while IFS= read -r artifact; do
                printf '\n//tesl-snapshot: %s\n' "$artifact"
                cat "$_snap_out/$artifact"
            done
        } > "$_snap_fresh"
        if cmp -s "$_snap_fresh" "$snap"; then
            GO_SNAP_OK=$((GO_SNAP_OK + 1))
        else
            GO_SNAP_FAILS+=("$(basename "$rel_snap")")
        fi
        rm -rf "$_snap_out" "$_snap_fresh"
    done <<EOF
$(find "$SCRIPT_DIR/example" "$SCRIPT_DIR/tests" "$SCRIPT_DIR/templates" -name '*.go.snap' 2>/dev/null | LC_ALL=C sort)
EOF
    printf "  EXACT MATCH: %d snapshot(s); %d differ; %d orphan(s)\n" \
        "$GO_SNAP_OK" "${#GO_SNAP_FAILS[@]}" "${#GO_SNAP_MISSING[@]}"
    if [ ${#GO_SNAP_FAILS[@]} -eq 0 ] && [ ${#GO_SNAP_MISSING[@]} -eq 0 ]; then
        phase_end OK
    else
        [ ${#GO_SNAP_FAILS[@]} -eq 0 ] || printf "  %sDiffering: %s%s\n" \
            "$C_RED" "${GO_SNAP_FAILS[*]}" "$C_RESET"
        [ ${#GO_SNAP_MISSING[@]} -eq 0 ] || printf "  %sOrphan snapshot (no .tesl): %s%s\n" \
            "$C_RED" "${GO_SNAP_MISSING[*]}" "$C_RESET"
        printf "  Regenerate with: scripts/regen-go-snapshots.sh\n"
        phase_end FAIL
    fi
fi

# Join the async PostgreSQL warm-up before the tests that need it.
if ! wait_for_shared_postgres; then
    printf "  %s⚠%s  Shared PostgreSQL warm-up failed; continuing without a preconfigured cluster\n" "$C_YELLOW" "$C_RESET"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Go runtime — PostgreSQL backend (needs the shared cluster)
# ══════════════════════════════════════════════════════════════════════════════
# The rest of the Go gates run in phase 2a, well before the cluster is up; these
# tests need it, so they run HERE, after the warm-up has been joined.  They skip
# themselves when no cluster is configured, which is what a machine without
# initdb/pg_ctl gets.
phase_begin "Go runtime PostgreSQL backend (live cluster)"
if ! command -v go >/dev/null 2>&1; then
    printf "  %s⚠%s  go not on PATH — skipping\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
elif [ "$shared_postgres_configured" -eq 0 ]; then
    printf "  %s⚠%s  no shared PostgreSQL cluster — skipping\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
else
    # The selection covers every test that needs the cluster: the Postgres
    # backend's own (Postgres|OpenPostgres), the bound-vs-memory dispatch and
    # grouped-aggregate/Money parity (Bound), transactions (Transaction), and
    # pool saturation under a live server. Tests whose names match none of
    # these are hermetic by construction and already ran in phase 2a.
    if ( cd "$SCRIPT_DIR/runtime/go" && go test -count=1 ./teslrt -run 'Postgres|OpenPostgres|Bound|Transaction|MoneySum|GroupFold|PoolSaturates' ); then
        phase_end OK
    else
        phase_end FAIL
    fi
fi

phase_begin "Recursive Go corpus compile/build"
tesl_files_fail=0
if ! command -v go >/dev/null 2>&1; then
    printf "  %s⚠%s  go not on PATH — skipping Go test manifests\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
else
    if ! TESL_REPO_ROOT="$SCRIPT_DIR" TESL_OCAML_COMPILER="$_main_exe" \
        bash "$SCRIPT_DIR/scripts/run-go-corpus-build.sh" --build; then
        tesl_files_fail=1
    fi
    if [ "$tesl_files_fail" -eq 0 ]; then phase_end OK; else phase_end FAIL; fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Phase 8 — Go mutation testing
# ══════════════════════════════════════════════════════════════════════════════
phase_begin "Mutation testing (Go backend)"
mutation_fail=0
if [ -x "$_main_exe" ]; then
    TESL_BIN="$_main_exe"
else
    TESL_BIN="tesl"
fi
_mutation_timeout="${TESL_MUTATION_TIMEOUT:-180}"
for _mutation_spec in \
    "example/learn/lesson42-mutation-testing.tesl|20" \
    "example/learn/lesson05-intro-to-proofs.tesl|13"; do
    _mutation_relative="${_mutation_spec%|*}"
    _mutation_expected="${_mutation_spec##*|}"
    mutation_lesson="$SCRIPT_DIR/$_mutation_relative"
    if [ ! -f "$mutation_lesson" ]; then
        printf "  %s✗%s  %s not found\n" "$C_RED" "$C_RESET" "$mutation_lesson"
        mutation_fail=1
        continue
    fi
    _mutation_summary="Summary: $_mutation_expected mutants | $_mutation_expected killed | 0 survived"
    printf "  Running Go mutation backend: %s\n" "$(basename "$mutation_lesson")"
    go_mutation_out=$(timeout "$_mutation_timeout" "$TESL_BIN" --mutate "$mutation_lesson" 2>&1)
    _go_mut_exit=$?
    if [ "$_go_mut_exit" -ne 0 ]; then
        mutation_fail=1
        printf "  %s✗%s  Go mutation testing failed (exit %d)\n%s\n" \
            "$C_RED" "$C_RESET" "$_go_mut_exit" "$go_mutation_out"
    else
        case "$go_mutation_out" in
            *"$_mutation_summary"*) ;;
            *) mutation_fail=1; printf "  %s✗%s  Go mutation report was incomplete\n%s\n" "$C_RED" "$C_RESET" "$go_mutation_out" ;;
        esac
    fi
done
if [ "$mutation_fail" -eq 0 ]; then
    printf "  %s✓%s  Go mutation testing: 33/33 killed across 2 corpora\n" "$C_GREEN" "$C_RESET"
    phase_end OK
else
    phase_end FAIL
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Phase 9 — Integration tests (full-chain httpclient + email)
# ══════════════════════════════════════════════════════════════════════════════
# The Racket-era OCaml executables this phase used to drive are gone with the
# Racket backend. scripts/run-go-integration.sh is the Go-backend successor:
# it compiles real fixtures (tests/integration/*.tesl), injects harness tests
# into the emitted modules, and proves three live chains — an emitted handler
# dialing a real upstream over TCP, the compiled binary serving its own route,
# and generated email delivered through a real SMTP conversation.
phase_begin "Integration tests (httpclient + email)"
if ! command -v go >/dev/null 2>&1; then
    printf "  %s⚠%s  go not on PATH — skipping integration tests\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
elif [ ! -x "$_main_exe" ]; then
    printf "  %s⚠%s  compiler not built — skipping integration tests\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
else
    if TESL_REPO_ROOT="$SCRIPT_DIR" TESL_OCAML_COMPILER="$_main_exe" \
        bash "$SCRIPT_DIR/scripts/run-go-integration.sh"; then
        phase_end OK
    else
        phase_end FAIL
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Phase 9a — Clean install (nix-built shipped profile)
# ══════════════════════════════════════════════════════════════════════════════
# The dev shell exercises the repo compiler directly, so a broken INSTALLED
# wrapper ships unnoticed (it happened: the Racket-removal commit deleted the
# _tesl_project_root helper block while keeping every call site — every
# installed `tesl compile/build` died with "_tesl_project_root: command not
# found"). This phase builds the actual flake profile (#tesl-go-cli) and drives
# `init`/`emit`/`build --no-docker` through it under a scrubbed environment
# (env -i), exactly what a fresh `nix profile install` user gets.
phase_begin "Clean install (nix-built shipped wrapper)"
if ! command -v nix >/dev/null 2>&1; then
    printf "  %s⚠%s  nix not found — skipping clean-install gate\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
elif ! command -v go >/dev/null 2>&1; then
    printf "  %s⚠%s  go not found — skipping clean-install gate\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
else
    _clean_install_link="$(mktemp -d)/tesl-profile"
    if nix build .#tesl-go-cli -o "$_clean_install_link" \
        && TESL_BIN="$_clean_install_link/bin/tesl" bash "$SCRIPT_DIR/tests/go-clean-install.sh"; then
        phase_end OK
    else
        phase_end FAIL
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Phase 9b — tesl CLI smoke: multi-module `tesl test` (#33) + build layout
# ══════════════════════════════════════════════════════════════════════════════
# `tesl test <entrypoint>` must compile the entrypoint's imported local modules
# (like `tesl run` does) — on a fresh checkout (no .tesl-stuff/build/ yet) it
# used to die with a SWALLOWED "cannot open module file" and print "(no test
# results)". Also locks the build-output relocation: every generated Go artifact
# lands under <project-root>/.tesl-stuff/build/ in
# a tree MIRRORING the sources — never next to the .tesl files — and deleting
# .tesl-stuff/ then rerunning must always work.
# Drives the real CLI body script end-to-end from a clean temp project.
phase_begin "tesl CLI smoke (multi-module test + .tesl-stuff/build layout)"
if ! command -v go >/dev/null 2>&1; then
    printf "  %s⚠%s  go not found — skipping CLI smoke\n" "$C_YELLOW" "$C_RESET"
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

    # 1) Go backend: generated tests run in an isolated temporary module.
    _cli_out="$(_cli_run test main.tesl)"; _cli_rc=$?
    if [ "$_cli_rc" -eq 0 ] && printf '%s' "$_cli_out" | grep -qE "^ok[[:space:]]"; then
        printf "  %s✓%s  tesl test runs generated Go tests\n" "$C_GREEN" "$C_RESET"
    else
        printf "  %s✗%s  Go backend tesl test failed (rc=%s):\n%s\n" "$C_RED" "$C_RESET" "$_cli_rc" "$_cli_out"
        _cli_fail=1
    fi

    # 2) subdirectory module: imported Go source builds into .tesl-stuff/go-build.
    _cli_out="$(_cli_run test sub/app.tesl)"; _cli_rc=$?
    if [ "$_cli_rc" -eq 0 ] && printf '%s' "$_cli_out" | grep -qE "^ok[[:space:]]" \
        && [ -f "$_cli_smoke_dir/.tesl-stuff/go-build/go.mod" ]; then
        printf "  %s✓%s  subdirectory module builds into the Go .tesl-stuff/go-build tree\n" "$C_GREEN" "$C_RESET"
    else
        printf "  %s✗%s  subdirectory-module tesl test failed (rc=%s):\n%s\n" "$C_RED" "$C_RESET" "$_cli_rc" "$_cli_out"
        _cli_fail=1
    fi

    # 3) NO generated files outside .tesl-stuff/ (the whole point of the layout)
    _cli_stray="$(find "$_cli_smoke_dir" -type f \
        -not -path "$_cli_smoke_dir/.tesl-stuff/*" \
        -not -name '*.tesl' -not -name 'tesl.toml' 2>/dev/null)"
    if [ -z "$_cli_stray" ] && [ -f "$_cli_smoke_dir/.tesl-stuff/go-build/go.mod" ]; then
        printf "  %s✓%s  all generated output lives under .tesl-stuff/\n" "$C_GREEN" "$C_RESET"
    else
        printf "  %s✗%s  generated files leaked outside .tesl-stuff/:\n%s\n" "$C_RED" "$C_RESET" "$_cli_stray"
        _cli_fail=1
    fi

    # 4) always safe to delete: rm -rf .tesl-stuff, rerun, must pass
    rm -rf "$_cli_smoke_dir/.tesl-stuff"
    _cli_out="$(_cli_run test main.tesl)"; _cli_rc=$?
    if [ "$_cli_rc" -eq 0 ] && printf '%s' "$_cli_out" | grep -qE "^ok[[:space:]]"; then
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
#  Boot smoke (Go App activation via tesl run)
# ══════════════════════════════════════════════════════════════════════════════
# `tesl check` and `tesl test` do not execute `main`; this smoke starts the
# emitted Go server and probes its health route, covering queue-worker startup,
# dead-letter-worker startup, worker count, and HTTP serving in one process.
phase_begin "Boot smoke (Go App activation via tesl run)"
boot_smoke_src="$SCRIPT_DIR/scripts/boot-smoke/app.tesl"
if ! command -v go >/dev/null 2>&1; then
    printf "  %s⚠%s  go not on PATH — skipping boot smoke\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
elif ! command -v curl >/dev/null 2>&1; then
    printf "  %s⚠%s  curl not on PATH — skipping boot smoke\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
elif [ ! -x "$_main_exe" ]; then
    printf "  %s⚠%s  compiler binary missing — skipping boot smoke\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
elif [ ! -f "$boot_smoke_src" ]; then
    printf "  %s⚠%s  boot-smoke fixture missing — skipping\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
else
    boot_root="$(mktemp -d "${TMPDIR:-/tmp}/tesl-boot.XXXXXX")"
    boot_out="$(mktemp "${TMPDIR:-/tmp}/tesl-boot-out.XXXXXX")"
    boot_port="${TESL_BOOT_SMOKE_PORT:-8199}"
    boot_build_fail=0
    if ! TESL_REPO_ROOT="$SCRIPT_DIR" "$_main_exe" "$boot_smoke_src" \
        --out "$boot_root/go" >"$boot_out" 2>&1; then
        boot_build_fail=1
    elif ! (cd "$boot_root/go" && go build -o "$boot_root/app" ./cmd/app) >>"$boot_out" 2>&1; then
        boot_build_fail=1
    fi
    if [ "$boot_build_fail" -ne 0 ]; then
        printf "  %s✗%s  Go boot-smoke compile failed\n" "$C_RED" "$C_RESET"
        sed 's/^/      /' "$boot_out" | tail -n 20
        phase_end FAIL
    else
        PORT="$boot_port" "$boot_root/app" >"$boot_out" 2>&1 &
        boot_pid=$!
        boot_ok=0
        for _boot_attempt in $(seq 1 60); do
            if curl --max-time 1 --silent --show-error --fail \
                "http://127.0.0.1:$boot_port/health" >/dev/null 2>&1; then
                boot_ok=1
                break
            fi
            if ! kill -0 "$boot_pid" 2>/dev/null; then
                break
            fi
            sleep 0.25
        done
        kill -TERM "$boot_pid" 2>/dev/null || true
        wait "$boot_pid" 2>/dev/null || true
    fi
    if [ "$boot_build_fail" -eq 0 ] && [ "$boot_ok" -eq 1 ]; then
        printf "  %s✓%s  Go App booted and /health responded\n" "$C_GREEN" "$C_RESET"
        phase_end OK
    elif [ "$boot_build_fail" -eq 0 ]; then
        printf "  %s✗%s  Go App failed to boot or /health did not respond\n" "$C_RED" "$C_RESET"
        sed 's/^/      /' "$boot_out" | tail -n 20
        phase_end FAIL
    fi
    rm -rf "$boot_root" "$boot_out"
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
        # tool that is missing is never a gate failure.
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
# realizes dex + playwright + the browser bundle); skipped explicitly with
# `SSO_E2E_SKIP`. Timeout-bounded.
phase_begin "SSO browser e2e (dex + Playwright, headless)"
if is_truthy "${SSO_E2E_SKIP:-0}"; then
    printf "  %s⚠%s  SSO_E2E_SKIP set — skipping\n" "$C_YELLOW" "$C_RESET"
    phase_end SKIP
elif ! command -v nix >/dev/null 2>&1; then
    printf "  %s⚠%s  nix not on PATH — skipping\n" "$C_YELLOW" "$C_RESET"
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
