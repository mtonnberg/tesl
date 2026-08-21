#!/usr/bin/env bash
# ── SHIM ──────────────────────────────────────────────────────────────────────
# compile-examples.sh is now a THIN SHIM that delegates to the combined,
# authoritative gate at the repo root: ./ci.sh
#
# The two historical QA scripts (this one and compiler/ci.sh) were merged into a
# single super-set gate — see the header of ./ci.sh for the full phase list and
# the roadmap item roadmap/next/combine_qa_scripts.md.  ci.sh runs a STRICT
# SUPERSET of everything this script used to run (format → dune test →
# validate-sweep → Tesl tests → mutation → integration with the shared PostgreSQL
# cluster), plus the OCaml build, Go snapshots, corpus/runtime checks, and AI suites.
#
# We `exec` so this process is REPLACED by ci.sh: the exit code, all env-var
# knobs (TESL_CI_JOBS, TESL_MUTATION_TIMEOUT, CI, …), and
# every argument pass straight through, so existing hooks and muscle-memory that
# call `./compile-examples.sh` keep working unchanged.
set -uo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/ci.sh" "$@"
