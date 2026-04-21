#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Tesl Chat — Cluster runner
#
# Starts three backend instances on ports 3000, 3002, and 3004, then starts
# an nginx load balancer on port 8080 that round-robins REST requests across
# all three and stickily routes SSE connections via ip_hash.
#
# All three backends share the same PostgreSQL database.  Workers compete
# via FOR UPDATE SKIP LOCKED — each job is processed exactly once regardless
# of which instance picks it up.  Pub/sub fan-out via PostgreSQL NOTIFY means
# every backend's LISTEN thread forwards messages to its own connected
# SSE clients, so all users receive all messages.
#
# Usage (from repository root OR example/chat/):
#   bash example/chat/run-cluster.sh
#
# Press Ctrl-C to stop all processes.
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
FRONTEND_DIR="$SCRIPT_DIR/frontend"
RUN_DIR="/tmp/tesl-chat-cluster-nginx"

# ─── Re-enter via nix-shell if needed ────────────────────────────────────────
if [ -z "${IN_NIX_SHELL:-}" ]; then
    echo "▶  Entering nix-shell (Racket + PostgreSQL)..."
    exec nix-shell "$REPO_ROOT/shell.nix" \
        --run "IN_NIX_SHELL=1 bash \"$SCRIPT_DIR/run-cluster.sh\""
fi

cd "$REPO_ROOT"

# ─── Bootstrap tesl package (raco pkg link) ──────────────────────────────────
echo "▶  Bootstrapping tesl Racket package..."
bash scripts/bootstrap-tesl-lang.sh >/dev/null 2>&1 || true

# ─── Build Elm frontend ───────────────────────────────────────────────────────
echo "▶  Building Elm frontend..."
nix-shell -p elmPackages.elm --run "
    set -e
    cd \"$FRONTEND_DIR\"
    elm make src/Main.elm --output=main.js --optimize
    echo '   Built frontend/main.js'
"

# ─── PostgreSQL ───────────────────────────────────────────────────────────────
TESL_POSTGRES_PORT="${TESL_POSTGRES_PORT:-55432}"
TESL_POSTGRES_USER="${TESL_POSTGRES_USER:-tesl}"
export TESL_POSTGRES_PORT TESL_POSTGRES_USER

echo "▶  Starting PostgreSQL on port $TESL_POSTGRES_PORT..."
bash scripts/postgres-start.sh

createdb \
    -h 127.0.0.1 \
    -p "$TESL_POSTGRES_PORT" \
    -U "$TESL_POSTGRES_USER" \
    chat 2>/dev/null \
    && printf '   Created database "chat"\n' \
    || printf '   Database "chat" already exists\n'

# ─── Common DB env vars ──────────────────────────────────────────────────────
export CHAT_DB_NAME=chat
export CHAT_DB_USER="$TESL_POSTGRES_USER"
export CHAT_DB_PASSWORD=""
export CHAT_DB_HOST=127.0.0.1
export CHAT_DB_PORT="$TESL_POSTGRES_PORT"
export CHAT_DB_SOCKET=""

# ─── Start three backend instances ────────────────────────────────────────────
echo "build backend"
tesl compile example/chat/chat-backend.tesl

echo "▶  Starting backend instance on port 3000..."
CHAT_PORT=3000 TESL_VERBOSE=0 tesl run example/chat/chat-backend.tesl &
PID_3000=$!

echo "▶  Starting backend instance on port 3002..."
CHAT_PORT=3002 TESL_VERBOSE=0 tesl run example/chat/chat-backend.tesl &
PID_3002=$!

echo "▶  Starting backend instance on port 3004..."
CHAT_PORT=3004 TESL_VERBOSE=0 tesl run example/chat/chat-backend.tesl &
PID_3004=$!

# ─── Generate nginx cluster config ───────────────────────────────────────────
mkdir -p \
    "$RUN_DIR" \
    "$RUN_DIR/client_body_temp" \
    "$RUN_DIR/proxy_temp" \
    "$RUN_DIR/fastcgi_temp" \
    "$RUN_DIR/uwsgi_temp" \
    "$RUN_DIR/scgi_temp"

NGINX_MIME_TYPES="$(nix-shell -p nginx --run 'echo $(dirname $(which nginx))/../conf/mime.types' 2>/dev/null)" || true
if [ ! -f "${NGINX_MIME_TYPES:-}" ]; then
    NGINX_MIME_TYPES="$(find /nix/store -name mime.types -path '*/nginx/*' 2>/dev/null | head -1)"
fi
if [ ! -f "${NGINX_MIME_TYPES:-}" ]; then
    NGINX_MIME_TYPES="$RUN_DIR/mime.types"
    cat > "$NGINX_MIME_TYPES" <<'MIME'
types {
    text/html                             html htm;
    text/css                              css;
    application/javascript                js;
    application/json                      json;
    text/plain                            txt;
}
MIME
fi

CONFIG="$RUN_DIR/nginx.conf"
sed \
    -e "s|CHAT_NGINX_PID|$RUN_DIR/nginx.pid|g" \
    -e "s|CHAT_RUN_DIR|$RUN_DIR|g" \
    -e "s|CHAT_FRONTEND_DIR|$FRONTEND_DIR|g" \
    -e "s|NGINX_MIME_TYPES|$NGINX_MIME_TYPES|g" \
    "$SCRIPT_DIR/nginx-cluster.conf.template" > "$CONFIG"

# ─── Start nginx ─────────────────────────────────────────────────────────────
echo "▶  Starting nginx cluster proxy on port 8080..."
nix-shell -p nginx --run "nginx -c \"$CONFIG\" -p \"$RUN_DIR\""

# ─── Cleanup on exit ─────────────────────────────────────────────────────────
cleanup() {
    echo ""
    echo "▶  Stopping cluster..."
    nix-shell -p nginx --run "nginx -c \"$CONFIG\" -p \"$RUN_DIR\" -s stop" 2>/dev/null || true
    kill "$PID_3000" "$PID_3002" "$PID_3004" 2>/dev/null || true
    wait "$PID_3000" "$PID_3002" "$PID_3004" 2>/dev/null || true
    echo "▶  Cluster stopped."
}
trap cleanup EXIT INT TERM

echo ""
echo "┌─────────────────────────────────────────────────────────────────────┐"
echo "│  Tesl Chat Cluster  →  http://127.0.0.1:8080                       │"
echo "│  Backends:  :3000  :3002  :3004  (round-robin REST, sticky SSE)     │"
echo "│  Press Ctrl-C to stop all instances                                 │"
echo "└─────────────────────────────────────────────────────────────────────┘"
echo ""

# Wait for any backend to exit (indicates a crash)
wait -n "$PID_3000" "$PID_3002" "$PID_3004" 2>/dev/null || true
echo "⚠  One or more backend instances exited. Shutting down cluster."
