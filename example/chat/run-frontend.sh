#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Tesl Chat — Frontend runner
#
# Builds the Elm application and starts nginx as a reverse proxy on port 8080.
# nginx serves static files AND proxies /rooms, /users, /login, /ws to the
# Tesl backend on port 3000 — everything appears same-origin so cookies work.
#
# Usage (from repository root OR example/chat/):
#   bash example/chat/run-frontend.sh
#
# Frontend: http://localhost:8080
# Backend must be running on port 3000 (run-backend.sh)
# Press Ctrl-C to stop.
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
FRONTEND_DIR="$SCRIPT_DIR/frontend"
RUN_DIR="/tmp/tesl-chat-nginx"

# ─── Build Elm ────────────────────────────────────────────────────────────────
echo "▶  Building Elm frontend..."
nix-shell -p elmPackages.elm --run "
    set -e
    cd \"$FRONTEND_DIR\"
    elm make src/Main.elm --output=main.js --optimize
    echo '   Built frontend/main.js'
"

# ─── Generate nginx config ────────────────────────────────────────────────────
mkdir -p \
    "$RUN_DIR" \
    "$RUN_DIR/client_body_temp" \
    "$RUN_DIR/proxy_temp" \
    "$RUN_DIR/fastcgi_temp" \
    "$RUN_DIR/uwsgi_temp" \
    "$RUN_DIR/scgi_temp"

# Locate nginx's built-in mime.types
NGINX_MIME_TYPES="$(nix-shell -p nginx --run 'echo $(dirname $(which nginx))/../conf/mime.types' 2>/dev/null)" || true
if [ ! -f "${NGINX_MIME_TYPES:-}" ]; then
    NGINX_MIME_TYPES="$(find /nix/store -name mime.types -path '*/nginx/*' 2>/dev/null | head -1)"
fi
if [ ! -f "${NGINX_MIME_TYPES:-}" ]; then
    # Fallback: minimal inline mime types
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
    "$SCRIPT_DIR/nginx.conf.template" > "$CONFIG"

# ─── Start nginx ─────────────────────────────────────────────────────────────
cleanup() {
    echo ""
    echo "Stopping nginx..."
    nix-shell -p nginx --run "nginx -c \"$CONFIG\" -p \"$RUN_DIR\" -s stop" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "▶  Starting nginx proxy..."
nix-shell -p nginx --run "nginx -c \"$CONFIG\" -p \"$RUN_DIR\""

echo ""
echo "┌──────────────────────────────────────────────────────────┐"
echo "│  Tesl Chat  http://localhost:8080                       │"
echo "│  Frontend: static files (nginx)                         │"
echo "│  Backend:  proxied to http://localhost:3000             │"
echo "│  SSE: proxied to http://localhost:3000/events/              │"
echo "│  Press Ctrl-C to stop                                   │"
echo "└──────────────────────────────────────────────────────────┘"
echo ""

# Wait until interrupted
while true; do sleep 1; done
