#!/usr/bin/env bash
# dev.sh — start elm reactor and watch for .tesl changes
#
# Usage:
#   cd example/frontend-elm
#   ./dev.sh
#
# Starts elm reactor on :8000.
# The Tesl backend runs separately on :8086 (use `tesl run ../todo-api.tesl`).
# Configure CORS or use a browser extension to allow cross-origin requests
# during development, or point your browser at the backend directly.
#
# On startup:   regenerates src/Api/TodoApi.elm from todo-api.tesl
# On .tesl save: regenerates again; elm reactor recompiles on next browser refresh
# Ctrl+C: kills elm reactor cleanly
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESL_FILE="$SCRIPT_DIR/../todo-api.tesl"
OUT_DIR="$SCRIPT_DIR/src/Api"

generate() {
  local label="${1:-change}"
  if tesl generate elm "$TESL_FILE" --out "$OUT_DIR/TodoApi.elm" 2>/dev/null; then
    echo "[tesl] regenerated ($label) → $OUT_DIR/TodoApi.elm"
  else
    tesl generate elm "$TESL_FILE" --out "$OUT_DIR/TodoApi.elm"  # re-run to print error
    echo "[tesl] generation failed ($label) — previous client kept" >&2
  fi
}

mkdir -p "$OUT_DIR"

generate startup

elm reactor &
ELM_PID=$!

trap 'echo; kill "$ELM_PID" 2>/dev/null; wait "$ELM_PID" 2>/dev/null' EXIT INT TERM

echo "[tesl] elm reactor on :8000"
echo "[tesl] Open: http://localhost:8000/src/Main.elm"
echo "[tesl] Watching $(realpath "$TESL_FILE") for changes (Ctrl+C to stop)"

PREV_SNAP="$(stat -c "%Y" "$TESL_FILE" 2>/dev/null || echo "")"

while true; do
  CURR_SNAP="$(stat -c "%Y" "$TESL_FILE" 2>/dev/null || echo "")"
  if [ "$CURR_SNAP" != "$PREV_SNAP" ]; then
    PREV_SNAP="$CURR_SNAP"
    echo "[tesl] change detected — regenerating..."
    generate "$(basename "$TESL_FILE")" || true
  fi
  sleep 0.3
done
