#!/usr/bin/env bash
# gen-stdlib-rkt.sh — regenerate the LIFTED stdlib runtime files.
#
# Some stdlib modules now keep their pure combinator BODIES in Tesl source
# (e.g. tesl/list.tesl) instead of hand-written Racket.  Those sources are
# compiled at build time by the just-built `tesl` binary into a committed
# `*-derived.rkt` snapshot that the public shim (e.g. tesl/list.rkt) re-exports.
#
# Because the `tesl/` directory lives OUTSIDE the dune project root
# (compiler/), a dune `(mode promote)` rule cannot write these targets — so we
# regenerate them with this script and commit the result, exactly like the
# byte-exact `example/learn/*.rkt` lesson snapshots.  `--check` mode (used by CI)
# regenerates into a temp dir and fails if the committed snapshot has drifted.
#
# Usage:
#   scripts/gen-stdlib-rkt.sh           # regenerate in place (writes tesl/*-derived.rkt)
#   scripts/gen-stdlib-rkt.sh --check   # verify committed snapshots are up to date
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPILER_DIR="$REPO_ROOT/compiler"
export TESL_REPO_ROOT="$REPO_ROOT"

# Map of lifted source -> generated runtime snapshot (relative to repo root).
# Add a row here when a new module is lifted.
LIFTED=(
  "tesl/list.tesl:tesl/list-derived.rkt"
  "tesl/either.tesl:tesl/either-derived.rkt"
)

MODE="write"
if [ "${1:-}" = "--check" ]; then MODE="check"; fi

# Build the compiler once.
( cd "$COMPILER_DIR" && dune build bin/main.exe ) >/dev/null
MAIN="$COMPILER_DIR/_build/default/bin/main.exe"

# Compile a lifted source and NORMALISE the embedded source path so the committed
# snapshot is environment-independent (reproducible across checkouts/worktrees/CI).
# The compiler bakes the absolute input path into the `thsl-src!` debug annotation;
# we strip the repo-root prefix so it becomes a stable repo-root-relative path
# (e.g. "tesl/list.tesl"). The debugger resolves stdlib sources via TESL_REPO_ROOT,
# so a relative path is both correct and portable.
gen() { "$MAIN" "$1" | sed "s|$REPO_ROOT/||g"; }

rc=0
for row in "${LIFTED[@]}"; do
  src="${row%%:*}"
  out="${row##*:}"
  src_abs="$REPO_ROOT/$src"
  out_abs="$REPO_ROOT/$out"
  if [ "$MODE" = "write" ]; then
    gen "$src_abs" > "$out_abs"
    echo "regenerated: $out"
  else
    tmp="$(mktemp)"
    gen "$src_abs" > "$tmp"
    if diff -q "$tmp" "$out_abs" >/dev/null 2>&1; then
      echo "up-to-date: $out"
    else
      echo "DRIFT: $out is stale — run scripts/gen-stdlib-rkt.sh and commit"
      diff "$out_abs" "$tmp" | head -20 || true
      rc=1
    fi
    rm -f "$tmp"
  fi
done
exit $rc
