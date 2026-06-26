#!/usr/bin/env bash
# differential-proofs.sh — behavior-preservation audit for the TESL
# "zero-cost proofs" erasure (roadmap A / Wave 0, agent ZC-HARNESS).
#
# TESL attaches GDP proofs to values.  Today a runtime "safety net" wraps every
# proof-carrying value in a `named-value` struct and re-validates it at each
# call boundary.  Agent ZC-SWITCH will add an opt-in erasure mode behind the
# environment variable TESL_ZERO_COST_PROOFS (1/true/yes/on).  This script
# PROVES that erasure is behavior-preserving:
#
#   For every .tesl file under tests/ and example/learn/ that contains a
#   `test "…" { … }` block:
#
#     (A) BYTE-IDENTITY OF EMISSION.  Compile the file twice with the same
#         compiler — once with TESL_ZERO_COST_PROOFS unset, once with it set —
#         and assert the produced .rkt is byte-for-byte identical.  This proves
#         the future toggle lives purely in the Racket DSL (macro-expansion
#         time), never in the OCaml emitter.  A diff here = the toggle leaked
#         into emit_racket.ml.
#
#     (B) BEHAVIORAL EQUIVALENCE.  Run the file's `(module+ test …)` submodule
#         twice — net OFF (env unset) and net ON (TESL_ZERO_COST_PROOFS=1) —
#         PURGING all `compiled/` bytecode between the two modes (the
#         expansion-time switch is NOT re-read from a stale .zo).  Capture
#         stdout+stderr+exit, normalize unstable output (gensyms, timing, UUIDs),
#         and diff.  Identical normalized output + identical exit => PASS.  Any
#         behavioral diff => FAIL = a static-checker gap that ZC-FINALIZE must
#         close before the net can be deleted.
#
# IMPORTANT: the erasure does NOT exist yet.  Until ZC-SWITCH lands, net-on ==
# net-off TRIVIALLY (the env var is ignored).  Every file will PASS.  That is
# expected and correct — the tooling is built ready to show the delta the
# instant the DSL honours the flag.
#
# Usage (from repo root, inside nix-shell or with racket/raco on PATH):
#   scripts/differential-proofs.sh                 # full corpus
#   scripts/differential-proofs.sh --subset 5      # first 5 testable files
#   scripts/differential-proofs.sh tests/multiparam_test.tesl ...   # explicit
#   scripts/differential-proofs.sh 'tests/critical-review6*.tesl'   # glob
#
# Options:
#   --subset N        run only the first N discovered testable files
#   --only-byte       only run the .rkt byte-identity check (skip running tests)
#   --no-color        disable ANSI colour
#   -v | --verbose    print normalized-diff bodies for failures and DB skips
#   -h | --help       this help
#
# Exit code 0: every file PASS (and no errors).  Exit code 1: >=1 FAIL or error.
#
# DB-dependent files: files that touch PostgreSQL are auto-detected.  If a
# shared cluster is configured in the environment (see compile-examples.sh's
# TESL_TEST_POSTGRES_SHARED_* convention) they run normally; otherwise they are
# SKIPPED with a logged, counted note (never a silent drop).

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate repo root (this script lives in <root>/scripts/).
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
export TESL_REPO_ROOT="$REPO_ROOT"

# ---------------------------------------------------------------------------
# Compiler binary: prefer the locally-built dune artifact, fall back to PATH.
# ---------------------------------------------------------------------------
TESL_MAIN="${TESL_MAIN:-}"
if [ -z "$TESL_MAIN" ]; then
    if [ -x "$REPO_ROOT/compiler/_build/default/bin/main.exe" ]; then
        TESL_MAIN="$REPO_ROOT/compiler/_build/default/bin/main.exe"
    elif command -v tesl >/dev/null 2>&1; then
        TESL_MAIN="$(command -v tesl)"
    else
        echo "FATAL: no tesl compiler found (build with: cd compiler && dune build)" >&2
        exit 1
    fi
fi

for tool in racket raco; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "FATAL: '$tool' not on PATH (Racket 8.18 expected)" >&2
        exit 1
    fi
done

# The environment variable under audit, and one accepted truthy value.  Kept in
# a variable so the contract has a single source of truth in this script.
ZC_ENV_VAR="TESL_ZERO_COST_PROOFS"
ZC_ENV_ON="1"

is_truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Colours.
# ---------------------------------------------------------------------------
USE_COLOR=1
if [ ! -t 1 ] || [ -n "${NO_COLOR:-}" ]; then USE_COLOR=0; fi
c_red=""; c_grn=""; c_ylw=""; c_dim=""; c_bld=""; c_rst=""
init_colors() {
    if [ "$USE_COLOR" -eq 1 ]; then
        c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'
        c_dim=$'\033[2m';  c_bld=$'\033[1m';  c_rst=$'\033[0m'
    fi
}

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------
SUBSET=0
ONLY_BYTE=0
VERBOSE=0
EXPLICIT_FILES=()

usage() { sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --subset) SUBSET="${2:-0}"; shift 2 ;;
        --subset=*) SUBSET="${1#*=}"; shift ;;
        --only-byte) ONLY_BYTE=1; shift ;;
        --no-color) USE_COLOR=0; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; while [ $# -gt 0 ]; do EXPLICIT_FILES+=("$1"); shift; done ;;
        -*) echo "Unknown option: $1" >&2; usage; exit 2 ;;
        *)  # may be a literal path or a glob; expand globs that match files
            matched=0
            for g in $1; do
                if [ -f "$g" ]; then EXPLICIT_FILES+=("$g"); matched=1; fi
            done
            if [ "$matched" -eq 0 ]; then
                # keep as-is; will be validated during discovery
                EXPLICIT_FILES+=("$1")
            fi
            shift ;;
    esac
done

init_colors

# ---------------------------------------------------------------------------
# Resolve the directory that `(require tesl/dsl/…)` loads from.  Emitted .rkt
# requires the *installed* tesl collection (a global `raco pkg --link`).  The
# expansion-time TESL_ZERO_COST_PROOFS switch lives in that DSL, and its read
# is frozen into bytecode the moment any `.zo` exists for it.  So purging
# `compiled/` between net-off and net-on runs MUST cover this resolved root in
# addition to the working tree — otherwise net-on silently reuses net-off's
# expansion.  We compute it once, dynamically, so the script is correct even
# when run from a worktree whose link points elsewhere.
# ---------------------------------------------------------------------------
TESL_PKG_ROOT="$(racket -e '(require racket/path)
(with-handlers ([exn:fail? (lambda (_) (void))])
  (define p (collection-file-path "web.rkt" "tesl" "dsl"))
  (printf "~a\n" (path->string (simplify-path (build-path p (quote up) (quote up))))))' 2>/dev/null \
    | tr -d '\r' | head -1)"

purge_bytecode() {
    # (a) The scratch work dir (where the test .rkt being run lives) and the
    #     working tree: always purge — cheap and local.  Any per-file .zo Racket
    #     wrote for the test module is removed so a stale toggle read in the test
    #     module itself cannot survive across modes.
    [ -n "${WORK_DIR:-}" ] && find "$WORK_DIR" -type d -name compiled -prune -exec rm -rf {} + 2>/dev/null || true
    find "$REPO_ROOT" -type d -name compiled -prune -exec rm -rf {} + 2>/dev/null || true

    # (b) Resolved tesl package root — where `(require tesl/dsl/…)` loads the DSL
    #     whose MACROS read TESL_ZERO_COST_PROOFS at expansion time.  This is the
    #     SHARED checkout: purging it disturbs every other tool on the machine
    #     (LSP, test runs) AND forces a multi-MINUTE full-DSL recompile, because
    #     the DSL is large and must be re-expanded from source.
    #
    #     CORRECTNESS GATE — purge this ONLY when the toggle can actually change
    #     the DSL expansion, i.e. once ZC-SWITCH has wired TESL_ZERO_COST_PROOFS
    #     into the macros.  UNTIL THEN the env var is a no-op: the cached DSL
    #     expansion is identical for net-off and net-on, so reusing it across
    #     modes is correct — and skipping the purge keeps the harness fast (the
    #     DSL compiles once and is reused).  ZC-SWITCH/ZC-FINALIZE MUST run with
    #     DIFFPROOFS_FORCE_DSL_PURGE=1 so the toggle is re-read fresh per mode;
    #     that is the strict, slow, fully-correct mode and is the gate for net
    #     deletion.  (See dev-docs/zero-cost-proofs-contract.md §1.)
    if is_truthy "${DIFFPROOFS_FORCE_DSL_PURGE:-0}" \
        && [ "$TESL_PKG_ROOT" != "$REPO_ROOT" ] && [ "$TESL_PKG_ROOT" != "$REPO_ROOT/" ] \
        && [ -n "$TESL_PKG_ROOT" ] && [ -d "$TESL_PKG_ROOT" ]; then
        find "$TESL_PKG_ROOT" -type d -name compiled -prune -exec rm -rf {} + 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Scratch workspace.  We compile each .tesl into here so we never disturb the
# tracked .rkt artifacts that live beside the sources.  We also keep the
# directory layout (relative to repo root) so that any `(require "./x.rkt")`
# style sibling imports resolve.  tesl/dsl imports resolve via the global link
# regardless of location.
# ---------------------------------------------------------------------------
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tesl-diffproofs.XXXXXX")"
cleanup() { rm -rf "$WORK_DIR" 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Output normalization.  Gensym-based output is unstable across runs; so are
# timestamps and UUIDs.  Strip them before diffing so only *semantic* output
# differences register.  Reads stdin, writes stdout.
#   - gNNN          gensym suffixes (e.g. subjectg1234 -> subject)
#   - valueNNN      generated value names
#   - UUIDs         8-4-4-4-12 hex
#   - ISO-ish times and "Ns"/"Nms" timing lines
#   - absolute scratch paths -> <FILE>
# ---------------------------------------------------------------------------
normalize() {
    sed -E \
        -e 's/g[0-9]+/g/g' \
        -e 's/value[0-9]+/value/g' \
        -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/<UUID>/g' \
        -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}([.,][0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})?/<TIMESTAMP>/g' \
        -e 's/[0-9]+(\.[0-9]+)?[[:space:]]*(ns|µs|us|ms|s)\b/<DURATION>/g' \
        -e 's/0x[0-9a-fA-F]+/<PTR>/g' \
        -e "s#${WORK_DIR//\#/\\\#}/[^ ]*#<FILE>#g"
}

# ---------------------------------------------------------------------------
# DB detection.  We only skip a file if its test submodule genuinely opens a
# PostgreSQL connection at RUN time — NOT merely because it mentions the SQL
# proof surface.  `FromDb` and `import Tesl.Sql` are proof *predicates* used in
# signatures by many proof-only lessons (e.g. lesson20/21) whose test blocks run
# standalone against in-memory data; flagging those would falsely skip them.
# So we match only true runtime-connection markers.  (Verified: no .tesl under
# tests/ or example/learn/ currently hits this — the whole corpus runs without
# a live DB.  The mechanism exists for genuine DB-backed tests added later.)
# ---------------------------------------------------------------------------
postgres_available() {
    [ -n "${TESL_TEST_POSTGRES_SHARED_HOST:-}" ] \
        && [ -n "${TESL_TEST_POSTGRES_SHARED_PORT:-}" ] \
        && [ -n "${TESL_TEST_POSTGRES_SHARED_USER:-}" ]
}

is_db_dependent() {
    local f="$1"
    grep -qE '\bconnectPostgres\b|\bwithConnection\b|\brunMigrations\b|\bopenConnection\b|\bDb\.connect\b|\bpostgresConnect\b' "$f"
}

# ---------------------------------------------------------------------------
# Discover testable files: .tesl under tests/ and example/learn/ that compile
# to a `(module+ test …)` submodule.  We detect by scanning the source for a
# `test "…" {` block (cheap, no compile) — matching compile-examples.sh's
# notion of "has test blocks".
# ---------------------------------------------------------------------------
has_test_block() {
    grep -qE '^[[:space:]]*test[[:space:]]+"' "$1"
}

declare -a CANDIDATES=()
if [ "${#EXPLICIT_FILES[@]}" -gt 0 ]; then
    for f in "${EXPLICIT_FILES[@]}"; do
        if [ ! -f "$f" ]; then
            echo "${c_ylw}warning:${c_rst} no such file: $f" >&2
            continue
        fi
        CANDIDATES+=("$f")
    done
else
    # Deterministic order for reproducible --subset slices.
    while IFS= read -r f; do CANDIDATES+=("$f"); done < <(
        { ls -1 "$REPO_ROOT"/tests/*.tesl 2>/dev/null
          ls -1 "$REPO_ROOT"/example/learn/*.tesl 2>/dev/null; } | sort
    )
fi

declare -a TESTABLE=()
for f in "${CANDIDATES[@]}"; do
    if has_test_block "$f"; then TESTABLE+=("$f"); fi
done

if [ "$SUBSET" -gt 0 ] && [ "${#TESTABLE[@]}" -gt "$SUBSET" ]; then
    TESTABLE=("${TESTABLE[@]:0:$SUBSET}")
fi

if [ "${#TESTABLE[@]}" -eq 0 ]; then
    echo "No testable .tesl files (with test blocks) matched." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Run one file's test submodule under a given env state.  Echoes combined
# stdout+stderr; the trailing line "##EXIT## N" carries the exit code so the
# caller can split it off after capture.
# Args: <rkt-path> <env-on?0|1>
# ---------------------------------------------------------------------------
run_submodule() {
    local rkt="$1" envon="$2"
    local out rc
    if [ "$envon" -eq 1 ]; then
        out="$(env "${ZC_ENV_VAR}=${ZC_ENV_ON}" racket -e \
            "(parameterize ([current-namespace (make-base-namespace)]) (dynamic-require (quote (submod (file \"$rkt\") test)) #f))" 2>&1)"
        rc=$?
    else
        # Safety-net (net-ON) mode.  Erasure is now DEFAULT-ON, so the net must be
        # requested EXPLICITLY with =0 — unsetting the var would erase (the flipped
        # default) and make the audit compare erased-vs-erased (vacuous).
        out="$(env "${ZC_ENV_VAR}=0" racket -e \
            "(parameterize ([current-namespace (make-base-namespace)]) (dynamic-require (quote (submod (file \"$rkt\") test)) #f))" 2>&1)"
        rc=$?
    fi
    printf '%s\n##EXIT## %d\n' "$out" "$rc"
}

# ---------------------------------------------------------------------------
# Counters & failing-file list.
# ---------------------------------------------------------------------------
n_total=${#TESTABLE[@]}
n_pass=0
n_fail=0
n_skip_db=0
n_byte_fail=0
declare -a FAIL_FILES=()
declare -a SKIP_FILES=()

print_header() {
    echo ""
    echo "${c_bld}━━━  Differential proof audit (net-off vs net-on)  ━━━${c_rst}"
    echo "  compiler : $TESL_MAIN"
    echo "  dsl root : ${TESL_PKG_ROOT:-<unresolved>}"
    echo "  env var  : ${ZC_ENV_VAR} (on=${ZC_ENV_ON})"
    echo "  files    : $n_total testable"
    [ "$ONLY_BYTE" -eq 1 ] && echo "  mode     : byte-identity only"
    if is_truthy "${DIFFPROOFS_FORCE_DSL_PURGE:-0}"; then
        echo "  purge    : ${c_bld}STRICT${c_rst} — DSL bytecode purged per mode (slow, fully correct)"
    else
        echo "  purge    : working-tree only (fast; toggle is a no-op until ZC-SWITCH)"
        echo "             ${c_dim}set DIFFPROOFS_FORCE_DSL_PURGE=1 for the strict per-mode DSL purge${c_rst}"
    fi
    if ! postgres_available; then
        echo "  ${c_dim}note: no shared PostgreSQL configured; DB-dependent files will be SKIPPED${c_rst}"
    fi
    echo ""
}

rel() { local p="$1"; echo "${p#"$REPO_ROOT"/}"; }

print_header

# ---------------------------------------------------------------------------
# Phase A — per file: compile twice (env unset / set), assert .rkt byte-identity.
# This phase needs no bytecode purge (it only runs the OCaml compiler).  Files
# that survive (compile OK + byte-identical + not DB-skipped) are queued for the
# behavioral phase in RUN_QUEUE.
# ---------------------------------------------------------------------------
declare -a RUN_QUEUE_RKT=()    # the .rkt to run (shared between both modes)
declare -a RUN_QUEUE_SHOWN=()  # display path, index-aligned with RUN_QUEUE_RKT

for tesl in "${TESTABLE[@]}"; do
    shown="$(rel "$tesl")"
    base="$(basename "${tesl%.tesl}")"
    rel_dir="$(dirname "$shown")"
    out_dir="$WORK_DIR/$rel_dir"
    mkdir -p "$out_dir"
    rkt_off="$out_dir/$base.off.rkt"
    rkt_on="$out_dir/$base.on.rkt"
    rkt_run="$out_dir/$base.rkt"
    err_off="$out_dir/$base.off.err"

    env -u "${ZC_ENV_VAR}" "$TESL_MAIN" "$tesl" >"$rkt_off" 2>"$err_off"
    rc_off=$?
    env "${ZC_ENV_VAR}=${ZC_ENV_ON}" "$TESL_MAIN" "$tesl" >"$rkt_on" 2>/dev/null
    rc_on=$?

    if [ "$rc_off" -ne 0 ] || [ "$rc_on" -ne 0 ]; then
        n_fail=$((n_fail + 1)); FAIL_FILES+=("$shown")
        printf "  ${c_red}✗${c_rst}  %-58s ${c_red}compile error (off=%d on=%d)${c_rst}\n" "$shown" "$rc_off" "$rc_on"
        [ "$VERBOSE" -eq 1 ] && sed 's/^/        /' "$err_off" | head -8
        continue
    fi

    if ! cmp -s "$rkt_off" "$rkt_on"; then
        n_byte_fail=$((n_byte_fail + 1))
        n_fail=$((n_fail + 1)); FAIL_FILES+=("$shown")
        printf "  ${c_red}✗${c_rst}  %-58s ${c_red}EMISSION DIFFERS (toggle leaked into emitter)${c_rst}\n" "$shown"
        [ "$VERBOSE" -eq 1 ] && diff "$rkt_off" "$rkt_on" | sed 's/^/        /' | head -20
        continue
    fi

    if [ "$ONLY_BYTE" -eq 1 ]; then
        n_pass=$((n_pass + 1))
        printf "  ${c_grn}✓${c_rst}  %-58s ${c_dim}byte-identical${c_rst}\n" "$shown"
        continue
    fi

    if is_db_dependent "$tesl" && ! postgres_available; then
        n_skip_db=$((n_skip_db + 1)); SKIP_FILES+=("$shown")
        printf "  ${c_ylw}⊘${c_rst}  %-58s ${c_ylw}SKIP (DB-dependent; no shared PostgreSQL)${c_rst}\n" "$shown"
        continue
    fi

    cp "$rkt_off" "$rkt_run"          # (A) proved emission identical; run either
    RUN_QUEUE_RKT+=("$rkt_run")
    RUN_QUEUE_SHOWN+=("$shown")
done

# ---------------------------------------------------------------------------
# Phase B — behavioral equivalence.  Bytecode is purged ONCE per mode (not per
# file): the expansion-time TESL_ZERO_COST_PROOFS switch is constant within a
# mode, so a single purge before each mode is sufficient to force a fresh
# re-expansion of the DSL — and it amortises the (expensive) DSL recompile over
# the whole queue instead of paying it twice per file.  We run every queued file
# net-OFF, then purge, then run every file net-ON, then diff per file.
# ---------------------------------------------------------------------------
if [ "$ONLY_BYTE" -ne 1 ] && [ "${#RUN_QUEUE_RKT[@]}" -gt 0 ]; then
    declare -a OFF_EXIT=() OFF_NORM=() ON_EXIT=() ON_NORM=()

    purge_bytecode   # mode boundary: enter net-OFF with no stale .zo
    for idx in "${!RUN_QUEUE_RKT[@]}"; do
        raw="$(run_submodule "${RUN_QUEUE_RKT[$idx]}" 0)"
        OFF_EXIT[$idx]="$(printf '%s' "$raw" | sed -nE 's/^##EXIT## ([0-9]+)$/\1/p' | tail -1)"
        OFF_NORM[$idx]="$(printf '%s' "$raw" | sed -E '/^##EXIT## [0-9]+$/d' | normalize)"
    done

    purge_bytecode   # mode boundary: enter net-ON; switch re-read fresh
    for idx in "${!RUN_QUEUE_RKT[@]}"; do
        raw="$(run_submodule "${RUN_QUEUE_RKT[$idx]}" 1)"
        ON_EXIT[$idx]="$(printf '%s' "$raw" | sed -nE 's/^##EXIT## ([0-9]+)$/\1/p' | tail -1)"
        ON_NORM[$idx]="$(printf '%s' "$raw" | sed -E '/^##EXIT## [0-9]+$/d' | normalize)"
    done

    for idx in "${!RUN_QUEUE_RKT[@]}"; do
        shown="${RUN_QUEUE_SHOWN[$idx]}"
        if [ "${OFF_NORM[$idx]}" = "${ON_NORM[$idx]}" ] \
            && [ "${OFF_EXIT[$idx]:-X}" = "${ON_EXIT[$idx]:-Y}" ]; then
            n_pass=$((n_pass + 1))
            printf "  ${c_grn}✓${c_rst}  %-58s ${c_dim}net-off==net-on (exit %s)${c_rst}\n" "$shown" "${OFF_EXIT[$idx]:-?}"
        else
            n_fail=$((n_fail + 1)); FAIL_FILES+=("$shown")
            printf "  ${c_red}✗${c_rst}  %-58s ${c_red}BEHAVIORAL DIFF (static-checker gap)${c_rst}\n" "$shown"
            printf "        ${c_dim}exit: off=%s on=%s${c_rst}\n" "${OFF_EXIT[$idx]:-?}" "${ON_EXIT[$idx]:-?}"
            if [ "$VERBOSE" -eq 1 ]; then
                diff <(printf '%s\n' "${OFF_NORM[$idx]}") <(printf '%s\n' "${ON_NORM[$idx]}") \
                    | sed 's/^/        /' | head -40
            fi
        fi
    done
fi

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
echo ""
echo "${c_bld}━━━  Summary  ━━━${c_rst}"
printf "  PASS         %d / %d\n" "$n_pass" "$n_total"
printf "  FAIL         %d\n" "$n_fail"
[ "$n_byte_fail" -gt 0 ] && printf "    ${c_red}of which emission-diffs: %d${c_rst}\n" "$n_byte_fail"
printf "  SKIP (DB)    %d\n" "$n_skip_db"

if [ "$n_fail" -gt 0 ]; then
    echo ""
    echo "  ${c_red}Failing files:${c_rst}"
    for f in "${FAIL_FILES[@]}"; do echo "    $f"; done
fi
if [ "$n_skip_db" -gt 0 ]; then
    echo ""
    echo "  ${c_ylw}Skipped (DB-dependent, no PostgreSQL):${c_rst}"
    for f in "${SKIP_FILES[@]}"; do echo "    $f"; done
    echo "  ${c_dim}(configure TESL_TEST_POSTGRES_SHARED_{HOST,PORT,USER} to include these)${c_rst}"
fi
echo ""

if [ "$n_fail" -gt 0 ]; then
    echo "  ${c_red}${c_bld}RESULT: behavioral divergence detected — net cannot be erased here yet.${c_rst}"
    exit 1
fi

if [ "$n_skip_db" -gt 0 ]; then
    echo "  ${c_grn}All audited files preserved behavior${c_rst} (${c_ylw}$n_skip_db DB file(s) skipped${c_rst})."
else
    echo "  ${c_grn}${c_bld}RESULT: every testable file preserved behavior net-off == net-on.${c_rst}"
fi
exit 0
