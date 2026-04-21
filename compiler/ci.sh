#!/usr/bin/env bash
# CI script for the OCaml Tesl compiler frontend.
# Builds the compiler, runs all tests, and verifies lesson files compile.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPILER_DIR="$REPO_ROOT/compiler"

# Global summary tracking
SECTION_RESULTS=()  # array of "section:status" pairs
GLOBAL_FAILURES=0

record_section() {
  local name="$1" status="$2"
  SECTION_RESULTS+=("$name: $status")
  if [ "$status" != "OK" ]; then
    GLOBAL_FAILURES=$((GLOBAL_FAILURES + 1))
  fi
}

echo "=== Building OCaml compiler ==="
if [ -z "${IN_NIX_SHELL:-}" ] && [ -z "${OCAMLPATH:-}" ] && [ -d "$HOME/.nix-profile/lib/ocaml/5.4.1/site-lib" ]; then
  export OCAMLPATH="$HOME/.nix-profile/lib/ocaml/5.4.1/site-lib"
fi
cd "$COMPILER_DIR"
if dune build -j 1; then
  record_section "Build" "OK"
else
  record_section "Build" "FAILED"
fi

echo ""
echo "=== Running test suite ==="
# Use dune's registered test set so newly-added suites are exercised automatically.
if dune runtest -f -j 1; then
  record_section "Tests" "OK"
else
  record_section "Tests" "FAILED (see above)"
fi

echo ""
echo "=== Verifying all Tesl files compile ==="
COMPILE_FAIL=0
COMPILE_FAIL_FILES=()
for f in "$REPO_ROOT/example/learn"/*.tesl "$REPO_ROOT/example"/*.tesl "$REPO_ROOT/tests"/*.tesl; do
  [ -f "$f" ] || continue
  if ! ./_build/default/bin/main.exe "$f" >/dev/null 2>&1; then
    echo "FAIL: $(basename $f)"
    COMPILE_FAIL=1
    COMPILE_FAIL_FILES+=("$(basename $f)")
  fi
done
if [ $COMPILE_FAIL -eq 0 ]; then
  echo "All files: OK"
  record_section "Compile-all" "OK"
else
  record_section "Compile-all" "FAILED: ${COMPILE_FAIL_FILES[*]}"
fi

echo ""
echo "=== Verifying exact output matches for key lessons ==="
EXACT_FAILS=()
for lesson in lesson00-hello-world lesson04-newtypes lesson05-intro-to-proofs; do
  tesl_file="$REPO_ROOT/example/learn/$lesson"*.tesl
  rkt_file="$REPO_ROOT/example/learn/$lesson"*.rkt
  tesl_file=$(ls $tesl_file 2>/dev/null | head -1)
  rkt_file=$(ls $rkt_file 2>/dev/null | head -1)
  if [ -z "$tesl_file" ] || [ -z "$rkt_file" ]; then continue; fi
  ocaml_out=$(./_build/default/bin/main.exe "$tesl_file" 2>/dev/null)
  diff_lines=$(diff <(printf "%s
" "$ocaml_out") "$rkt_file" 2>/dev/null || true)
  diff_count=$(printf "%s
" "$diff_lines" | grep -c "^[<>]" || true)
  if [ "$diff_count" -eq 0 ]; then
    echo "EXACT MATCH: $lesson"
  else
    echo "DIFF ($diff_count lines): $lesson"
    EXACT_FAILS+=("$lesson")
  fi
done
if [ ${#EXACT_FAILS[@]} -eq 0 ]; then
  record_section "Exact-match" "OK"
else
  record_section "Exact-match" "FAILED: ${EXACT_FAILS[*]}"
fi

echo ""
echo "════════════════════════════════════════════"
echo "  CI SUMMARY"
echo "════════════════════════════════════════════"
for result in "${SECTION_RESULTS[@]}"; do
  if [[ "$result" == *": OK"* ]]; then
    echo "  ✓  $result"
  else
    echo "  ✗  $result"
  fi
done
echo "────────────────────────────────────────────"
if [ $GLOBAL_FAILURES -eq 0 ]; then
  echo "  ✓  All sections passed"
else
  echo "  ✗  $GLOBAL_FAILURES section(s) failed"
fi
echo "════════════════════════════════════════════"

[ $GLOBAL_FAILURES -eq 0 ]
