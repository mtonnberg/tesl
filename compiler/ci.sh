#!/usr/bin/env bash
# ── SHIM ──────────────────────────────────────────────────────────────────────
# compiler/ci.sh is now a THIN SHIM that delegates to the combined, authoritative
# gate at the repo root: ../ci.sh
#
# The two historical QA scripts (this one and the repo-root compile-examples.sh)
# were merged into a single super-set gate — see the header of ../ci.sh for the
# full phase list and the roadmap item roadmap/next/combine_qa_scripts.md.  ci.sh
# runs a STRICT SUPERSET of everything this OCaml-centric script used to run:
# dune build, dune test (with the same explicit, dated, ID-keyed failure-waiver
# list), lifted-stdlib snapshots, compile-all (subsumed by the `tesl validate`
# sweep), exact-match Go snapshots, Go corpus/runtime checks, and AI suites —
# plus format, Tesl-test, mutation, integration, and tooling phases.
#
# We `exec` so this process is REPLACED by ci.sh: the exit code, all env-var
# knobs (TESL_CI_JOBS, TESL_MUTATION_TIMEOUT, CI, …), and every argument pass
# straight through, so existing hooks and muscle-memory that call
# `compiler/ci.sh` keep working unchanged.
set -uo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/../ci.sh" "$@"
