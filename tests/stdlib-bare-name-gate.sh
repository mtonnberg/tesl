#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  tests/stdlib-bare-name-gate.sh — the constructor import gate must agree with
#  what the EMITTER actually binds.
# ═══════════════════════════════════════════════════════════════════════════════
#
# roadmap/completed/import_gated_stdlib_constructors.md.  A bare stdlib constructor
# used to type-check in a module that never imported its home module, and then
# die at load time ("Monday: unbound identifier") because the emitter drives its
# Racket `require` list off the imports.  `Checker.check_stdlib_fn_import_scope`
# now rejects that — and the ONLY correct definition of "must be gated" is the
# runtime one:
#
#   gated  ⟺  the name is UNBOUND when used without its import
#
# (The language rule is wider than the runtime one: a constructor in PATTERN
# position needs its import too, so that a module's import list is a complete
# inventory of the stdlib surface it uses.  A pattern emits a quoted variant tag,
# so THAT half cannot be verified against the runtime and is pinned by
# compiler/test/test_import_gated_ctors.ml instead.  This script covers the half
# where the runtime is the authority: value positions.)
#
# The compiler-side tables (Type_system.stdlib_ctor_home_modules,
# always_available_stdlib_names) are a static approximation of that fact, and a
# static test can only check them against each other.  This ratchet checks them
# against `raco expand`, which is the authority, in both directions:
#
#   * for a GATED name — `tesl --check` must reject it without the import, and
#     with the import both the check AND `raco expand` must succeed (so the
#     accepted spelling really emits the require: a gate that rejects the only
#     working spelling would be worse than the hole);
#   * for an AMBIENT name (`True`) — `tesl --check` must accept it with no
#     import, and `raco expand` must confirm it is genuinely bound.
#
# Usage:  tests/stdlib-bare-name-gate.sh
# Exit:   0 = pass, 1 = failure, 77 = skipped (compiler or raco unavailable)
# Env:    TESL_REPO_ROOT, TESL_OCAML_COMPILER (both auto-detected)

set -uo pipefail

REPO_ROOT="${TESL_REPO_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
MAIN_EXE="${TESL_OCAML_COMPILER:-$REPO_ROOT/compiler/_build/default/bin/main.exe}"

if [ ! -x "$MAIN_EXE" ]; then
    echo "  SKIP: compiler not built ($MAIN_EXE)"
    exit 77
fi
if ! command -v raco >/dev/null 2>&1; then
    echo "  SKIP: raco not on PATH"
    exit 77
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAIL=0

# One probe module per case.  The file is named probe.tesl, so the header is
# `module Probe`; the body puts the name in a VALUE position (the gated one) via
# a wildcard `case`, which accepts any scrutinee type.
write_probe() {
    local import_line="$1" expr="$2"
    {
        echo "module Probe exposing [f]"
        echo ""
        echo "import Tesl.Prelude exposing [Bool(..), Int, String]"
        [ -n "$import_line" ] && echo "$import_line"
        echo ""
        echo "fn f(s: String, n: Int) -> Bool ="
        echo "  case $expr of"
        echo "    _ -> True"
    } > "$WORK/probe.tesl"
}

# expand_ok — emit the probe and expand it; 0 = expands, 1 = unbound, 2 = other
expand_ok() {
    "$MAIN_EXE" "$WORK/probe.tesl" > "$WORK/probe.rkt" 2>"$WORK/emit.err" || return 2
    if TESL_REPO_ROOT="$REPO_ROOT" raco expand "$WORK/probe.rkt" \
        >/dev/null 2>"$WORK/expand.err"; then
        return 0
    fi
    grep -q "unbound identifier" "$WORK/expand.err" && return 1
    return 2
}

# ── Gated names: rejected without the import, and working WITH it ──────────────
#
# One representative per emit shape: a nullary constructor, a unary one, a
# constructor with two home modules (the Tesl.Either / Tesl.EitherPrim split),
# and a multi-argument one.
#
#   name | value expression | the import that must make it work
GATED=(
  "Monday|Monday|import Tesl.CivilTime exposing [Weekday(..)]"
  "TextBody|TextBody s|import Tesl.Email exposing [EmailBody(..)]"
  "Loopback|Loopback|import Tesl.Net exposing [HostClass(..)]"
  "Left|Left n|import Tesl.EitherPrim exposing [Either(..)]"
  "Tuple2|Tuple2 n n|import Tesl.Tuple exposing [Tuple2]"
)

for row in "${GATED[@]}"; do
    IFS='|' read -r name expr import_line <<< "$row"

    # (a) no import → the CHECK must reject, naming the import.
    write_probe "" "$expr"
    check_out="$("$MAIN_EXE" --check "$WORK/probe.tesl" 2>&1)"
    if [ -z "$check_out" ]; then
        # Accepted with no import: only legitimate if the emitter binds it
        # anyway — in which case the name does not belong in the gate at all.
        write_probe "" "$expr"
        expand_ok; rc=$?
        echo "  FAIL: \`$name\` is accepted with NO import (expand rc=$rc)."
        echo "        If it is genuinely ambient, move it to \
Type_system.always_available_stdlib_names; if not, the gate regressed."
        FAIL=1
    elif ! grep -q "requires \`import" <<< "$check_out"; then
        echo "  FAIL: \`$name\` without its import was rejected for another reason:"
        echo "$check_out" | head -3 | sed 's/^/        /'
        FAIL=1
    fi

    # (b) with the import → check clean AND the emitted module really expands.
    write_probe "$import_line" "$expr"
    check_out="$("$MAIN_EXE" --check "$WORK/probe.tesl" 2>&1)"
    if [ -n "$check_out" ]; then
        echo "  FAIL: \`$name\` with \`$import_line\` still does not check:"
        echo "$check_out" | head -3 | sed 's/^/        /'
        FAIL=1
    else
        expand_ok; rc=$?
        case $rc in
            0) : ;;
            1) echo "  FAIL: \`$name\` passes the gate with \`$import_line\` but is \
UNBOUND at expand — the accepted spelling does not emit the require."; FAIL=1 ;;
            *) echo "  FAIL: \`$name\` with \`$import_line\` failed to emit/expand:"
               head -3 "$WORK/expand.err" "$WORK/emit.err" 2>/dev/null | sed 's/^/        /'
               FAIL=1 ;;
        esac
    fi
done

# ── Ambient names: no module provides them, so no import is possible ──────────
AMBIENT=("True" "False")

for name in "${AMBIENT[@]}"; do
    write_probe "" "$name"
    check_out="$("$MAIN_EXE" --check "$WORK/probe.tesl" 2>&1)"
    if [ -n "$check_out" ]; then
        echo "  FAIL: ambient \`$name\` was rejected without an import:"
        echo "$check_out" | head -3 | sed 's/^/        /'
        FAIL=1
        continue
    fi
    expand_ok; rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "  FAIL: ambient \`$name\` type-checks with no import but is not bound \
at expand (rc=$rc) — this is the typechecks-then-unbound class, in the \
always-available list."
        FAIL=1
    fi
done

if [ "$FAIL" -eq 0 ]; then
    echo "  OK: ${#GATED[@]} gated + ${#AMBIENT[@]} ambient bare stdlib name(s) agree with raco expand"
fi
exit "$FAIL"
