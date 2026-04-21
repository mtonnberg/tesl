#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Tesl Chat — Backend runner
#
# Starts PostgreSQL, compiles backend.tesl → Racket, and runs the server.
#
# Usage (from repository root OR example/chat/):
#   bash example/chat/run-backend.sh
#
# The server starts on http://localhost:3000
# Press Ctrl-C to stop.
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"

# ─── Re-enter via nix-shell if needed ────────────────────────────────────────
if [ -z "${IN_NIX_SHELL:-}" ]; then
    echo "▶  Entering nix-shell (Racket + PostgreSQL)..."
    exec nix-shell "$REPO_ROOT/shell.nix" \
        --run "IN_NIX_SHELL=1 bash \"$SCRIPT_DIR/run-backend.sh\""
fi

cd "$REPO_ROOT"

# ─── Bootstrap tesl package (raco pkg link) ──────────────────────────────────
echo "▶  Bootstrapping tesl Racket package..."
bash scripts/bootstrap-tesl-lang.sh >/dev/null 2>&1 || true

# ─── PostgreSQL ───────────────────────────────────────────────────────────────
TESL_POSTGRES_PORT="${TESL_POSTGRES_PORT:-55432}"
TESL_POSTGRES_USER="${TESL_POSTGRES_USER:-tesl}"
export TESL_POSTGRES_PORT TESL_POSTGRES_USER

echo "▶  Starting PostgreSQL on port $TESL_POSTGRES_PORT..."
bash scripts/postgres-start.sh

# Create chat database if it doesn't exist
createdb \
    -h 127.0.0.1 \
    -p "$TESL_POSTGRES_PORT" \
    -U "$TESL_POSTGRES_USER" \
    chat 2>/dev/null \
    && printf '   Created database "chat"\n' \
    || printf '   Database "chat" already exists\n'

# ─── Environment variables for the backend ───────────────────────────────────
# Use TCP (host + port) only — do NOT set socket when host is already set,
# as the Racket PostgreSQL driver rejects both being specified simultaneously.
export CHAT_DB_NAME=chat
export CHAT_DB_USER="$TESL_POSTGRES_USER"
export CHAT_DB_PASSWORD=""
export CHAT_DB_HOST=127.0.0.1
export CHAT_DB_PORT="$TESL_POSTGRES_PORT"
export CHAT_DB_SOCKET=""          # empty: use TCP, not Unix socket

# Port this instance listens on. Set CHAT_PORT=3002 to run a second instance.
CHAT_PORT="${CHAT_PORT:-8080}"
export CHAT_PORT

# ─── Compile and run ─────────────────────────────────────────────────────────
echo ""
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│  Tesl Chat  →  http://127.0.0.1:${CHAT_PORT}                     │"
echo "│  No nginx needed — API + frontend on one port.              │"
echo "│  Press Ctrl-C to stop                                       │"
echo "└──────────────────────────────────────────────────────────────┘"
echo ""
TESL_VERBOSE=1 exec tesl run example/chat/chatbackend.tesl
