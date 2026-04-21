#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Kanel — Backend runner
#
# Builds the Elm frontend, starts PostgreSQL, compiles KanelBackend.tesl →
# Racket, and runs the server.  The Racket server serves both the API and the
# Elm SPA on the same port — no nginx needed.
#
# Usage (from repository root OR example/kanel/):
#   bash example/kanel/run-backend.sh
#
# Everything is on http://localhost:8080
# Press Ctrl-C to stop.
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
FRONTEND_DIR="$SCRIPT_DIR/frontend"

# ─── Re-enter via nix-shell if needed ────────────────────────────────────────
if [ -z "${IN_NIX_SHELL:-}" ]; then
    echo "▶  Entering nix-shell (Racket + PostgreSQL + Elm)..."
    exec nix-shell "$REPO_ROOT/shell.nix" \
        --run "IN_NIX_SHELL=1 bash \"$SCRIPT_DIR/run-backend.sh\""
fi

cd "$REPO_ROOT"

# ─── Bootstrap tesl package (raco pkg link) ──────────────────────────────────
echo "▶  Bootstrapping tesl Racket package..."
bash scripts/bootstrap-tesl-lang.sh >/dev/null 2>&1 || true

# ─── Build Elm frontend ───────────────────────────────────────────────────────
echo "▶  Building Elm frontend..."
(cd "$FRONTEND_DIR" && elm make src/Main.elm --output=main.js --optimize)
echo "   Built frontend/main.js"

# ─── PostgreSQL ───────────────────────────────────────────────────────────────
TESL_POSTGRES_PORT="${TESL_POSTGRES_PORT:-55432}"
TESL_POSTGRES_USER="${TESL_POSTGRES_USER:-tesl}"
export TESL_POSTGRES_PORT TESL_POSTGRES_USER

echo "▶  Starting PostgreSQL on port $TESL_POSTGRES_PORT..."
bash scripts/postgres-start.sh

# Create kanel database if it doesn't exist
createdb \
    -h 127.0.0.1 \
    -p "$TESL_POSTGRES_PORT" \
    -U "$TESL_POSTGRES_USER" \
    kanel 2>/dev/null \
    && printf '   Created database "kanel"\n' \
    || printf '   Database "kanel" already exists\n'

# ─── Environment variables ────────────────────────────────────────────────────
export KANEL_DB="kanel"
export TESL_POSTGRES_USER="$TESL_POSTGRES_USER"
export TESL_POSTGRES_PASSWORD=""
export TESL_POSTGRES_HOST="127.0.0.1"
export TESL_POSTGRES_PORT="$TESL_POSTGRES_PORT"
export TESL_POSTGRES_SOCKET=""        # empty: use TCP, not Unix socket
export KANEL_PORT="${KANEL_PORT:-8080}"

# ─── Compile and run ─────────────────────────────────────────────────────────
echo ""
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│  Kanel  →  http://127.0.0.1:$KANEL_PORT                     │"
echo "│  API + Elm frontend on one port — no nginx needed            │"
echo "│  2 notification worker threads active                        │"
echo "│  Press Ctrl-C to stop                                        │"
echo "└──────────────────────────────────────────────────────────────┘"
echo ""
TESL_VERBOSE=1 exec tesl run example/kanel/KanelBackend.tesl
