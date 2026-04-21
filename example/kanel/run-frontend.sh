#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Kanel — Frontend rebuild script
#
# Recompiles the Elm application during development without restarting the
# backend server.  The backend (run-backend.sh) serves the compiled main.js
# directly via the `static` keyword — no nginx needed.
#
# Usage (from repository root OR example/kanel/):
#   bash example/kanel/run-frontend.sh        # build once
#   bash example/kanel/run-frontend.sh --watch  # rebuild on file change (inotifywait)
#
# After running this, refresh your browser at http://localhost:8080
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
FRONTEND_DIR="$SCRIPT_DIR/frontend"
WATCH="${1:-}"

build() {
    echo "▶  Building Elm frontend..."
    nix-shell -p elmPackages.elm --run "
        set -e
        cd \"$FRONTEND_DIR\"
        elm make src/Main.elm --output=main.js --optimize
    "
    echo "   Done → frontend/main.js  (refresh http://localhost:8080)"
}

build

if [ "$WATCH" = "--watch" ]; then
    echo "▶  Watching src/ for changes (Ctrl-C to stop)..."
    nix-shell -p inotify-tools --run "
        while inotifywait -r -e modify,create,delete \"$FRONTEND_DIR/src\" 2>/dev/null; do
            bash \"$SCRIPT_DIR/run-frontend.sh\"
        done
    "
fi
