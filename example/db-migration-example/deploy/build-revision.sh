#!/usr/bin/env bash
# Replay a reviewed release without rewriting a frozen migration or its creator ABI.
set -euo pipefail
APP_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$APP_DIR/../.." && pwd)"
if (( $# < 2 || $# > 3 )); then
  echo "usage: $0 REVISION OUTPUT [--prepare-only|--emit-only]" >&2
  exit 2
fi
MODE="${3:-build}"
case "$MODE" in build|--prepare-only|--emit-only) ;; *) echo "unknown mode: $MODE" >&2; exit 2 ;; esac
OUTPUT="$(python3 "$APP_DIR/deploy/prepare-release.py" "$1" "$2")"
if [[ "$MODE" == --prepare-only ]]; then printf '%s\n' "$OUTPUT"; exit 0; fi
COMPILER="${TESL_COMPILER:-$REPO_ROOT/compiler/_build/default/bin/main.exe}"
if [[ ! -x "$COMPILER" ]]; then echo "Build the compiler first (cd compiler && dune build), or set TESL_COMPILER." >&2; exit 1; fi
export TESL_REPO_ROOT="${TESL_REPO_ROOT:-$REPO_ROOT}"
"$COMPILER" agent-context "$OUTPUT/source/todo-app.tesl" > "$OUTPUT/diagnostics.json"
"$COMPILER" --backend go "$OUTPUT/source/todo-app.tesl" --out "$OUTPUT/go"
if [[ "$MODE" == build ]]; then
  (cd "$OUTPUT/go" && go test ./internal/teslmodtodoapp && go build -o "$OUTPUT/app" ./cmd/app)
fi
printf 'Release %s prepared in %s\n' "$1" "$OUTPUT"
