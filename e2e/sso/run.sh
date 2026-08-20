#!/usr/bin/env bash
# End-to-end SSO test: a real headless browser -> a Tesl backend -> a real dex
# OpenID Connect IdP, all provisioned through Nix.  Run it inside the repo dev
# shell (which provides Go, the compiler, and the linked Tesl tools):
#
#   nix develop --command bash e2e/sso/run.sh              # full browser e2e
#   SSO_E2E_SMOKE=1 nix develop --command bash e2e/sso/run.sh   # protocol smoke, no browser
#
# It brings dex / openssl / node+playwright into PATH via `nix shell` and:
#   1. mints a loopback self-signed cert and starts dex over HTTPS,
#   2. compiles + boots the Go Tesl backend (Sso.oidc against dex; loopback TLS
#      escape on for the self-signed dev cert),
#   3. drives the login: with a browser (Playwright) or, in smoke mode, with
#      curl asserting the /auth/dex/login -> dex authorize redirect.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Re-exec once inside a nix shell that carries the extra tools (dex, openssl,
# node + playwright + the browser bundle).  Go and the Tesl compiler come from
# the surrounding `nix develop`.
if [ -z "${SSO_E2E_INNER:-}" ]; then
  # Smoke mode needs only dex + openssl; the full run adds node + playwright +
  # the browser bundle (a large realise, so it's opt-in via the full path).
  tools="nixpkgs#dex-oidc nixpkgs#openssl nixpkgs#mkpasswd"
  if [ -z "${SSO_E2E_SMOKE:-}" ] && [ -z "${SSO_E2E_SERVE:-}" ]; then
    tools="$tools nixpkgs#nodejs nixpkgs#playwright-test nixpkgs#playwright-driver.browsers"
  fi
  exec env SSO_E2E_INNER=1 nix shell $tools --command bash "${BASH_SOURCE[0]}" "$@"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tesl-sso-e2e.XXXXXX")"
DEX_PID=""; BACKEND_PID=""
cleanup() {
  [ -n "$BACKEND_PID" ] && kill "$BACKEND_PID" 2>/dev/null || true
  [ -n "$DEX_PID" ] && kill "$DEX_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

DEX_ISSUER="https://localhost:5556/dex"
APP_PORT="${TESL_SSO_PORT:-18080}"
APP_ORIGIN="http://localhost:$APP_PORT"

echo "[e2e] work dir: $WORK"

# 1. loopback self-signed cert for dex ---------------------------------------
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "$WORK/dex.key" -out "$WORK/dex.crt" \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1

cat > "$WORK/dex.yaml" <<EOF
issuer: $DEX_ISSUER
storage:
  type: memory
web:
  https: 127.0.0.1:5556
  tlsCert: $WORK/dex.crt
  tlsKey: $WORK/dex.key
oauth2:
  skipApprovalScreen: true
staticClients:
  - id: tesl-sandbox
    name: Tesl Sandbox
    secret: tesl-sandbox-secret
    redirectURIs:
      - $APP_ORIGIN/auth/dex/callback
enablePasswordDB: true
staticPasswords:
  - email: alice@example.com
    # bcrypt("password") — the well-known dex example hash
    hash: "__PWHASH__"
    username: alice
    userID: "08a8684b-db88-4b73-90a9-3cd1661f5466"
EOF
# dex requires a bcrypt hash; generate it for "password" rather than trusting a
# copied example (a stale/wrong example silently rejects the login).
PWHASH="$(mkpasswd -m bcrypt -R 10 password)"
sed -i "s|__PWHASH__|$PWHASH|" "$WORK/dex.yaml"

echo "[e2e] starting dex…"
dex serve "$WORK/dex.yaml" >"$WORK/dex.log" 2>&1 & DEX_PID=$!
for i in $(seq 1 50); do
  if curl -fsk "$DEX_ISSUER/.well-known/openid-configuration" >/dev/null 2>&1; then break; fi
  sleep 0.3
  if ! kill -0 "$DEX_PID" 2>/dev/null; then echo "[e2e] dex died:"; cat "$WORK/dex.log"; exit 1; fi
done
echo "[e2e] dex discovery is up."

# 2. compile + boot the Tesl backend -----------------------------------------
TESL_BIN="${TESL_OCAML_COMPILER:-$REPO_ROOT/compiler/_build/default/bin/main.exe}"
sed -e "s|http://localhost:8080|$APP_ORIGIN|g" \
    -e "s|port: 8080|port: $APP_PORT|g" \
    e2e/sso/backend.tesl > "$WORK/backend.tesl"
"$TESL_BIN" "$WORK/backend.tesl" --out "$WORK/go"
echo "[e2e] Go backend emitted."

(cd "$WORK/go" && "${TESL_GO:-go}" build -o "$WORK/backend" ./cmd/app)
echo "[e2e] Go backend built."

DEX_ISSUER="$DEX_ISSUER" \
DEX_CLIENT_ID="tesl-sandbox" \
DEX_CLIENT_SECRET="tesl-sandbox-secret" \
SESSION_KEY="$(openssl rand -hex 32)" \
TESL_HTTP_TLS_INSECURE_DEV=1 \
  "$WORK/backend" >"$WORK/backend.log" 2>&1 & BACKEND_PID=$!
for i in $(seq 1 50); do
  if curl -fs "$APP_ORIGIN/" >/dev/null 2>&1; then break; fi
  sleep 0.3
  if ! kill -0 "$BACKEND_PID" 2>/dev/null; then echo "[e2e] backend died:"; cat "$WORK/backend.log"; exit 1; fi
done
echo "[e2e] backend is up on $APP_ORIGIN."

# ── SERVE: leave dex + backend running for a manual browser session ──────────
if [ -n "${SSO_E2E_SERVE:-}" ]; then
  echo ""
  echo "  ┌──────────────────────────────────────────────────────────────┐"
  echo "  │  SSO sandbox is UP — open it in your browser:                  │"
  echo "  │                                                                │"
  echo "  │    $APP_ORIGIN"
  echo "  │    Click "Log in with dex"  →  alice@example.com / password    │"
  echo "  │                                                                │"
  echo "  │  dex ($DEX_ISSUER) uses a self-signed"
  echo "  │  loopback cert, so the browser shows a one-time certificate     │"
  echo "  │  warning on that page — click through it (dev only).           │"
  echo "  │                                                                │"
  echo "  │  Ctrl-C here to stop dex + the backend.                        │"
  echo "  └──────────────────────────────────────────────────────────────┘"
  echo ""
  wait
  exit 0
fi

# 3a. smoke: no browser — assert /auth/dex/login redirects to dex authorize ---
if [ -n "${SSO_E2E_SMOKE:-}" ]; then
  echo "[e2e] SMOKE: GET /auth/dex/login (full response)"
  resp="$(curl -sS -i "$APP_ORIGIN/auth/dex/login")"
  echo "----- response -----"; printf '%s\n' "$resp" | head -40; echo "--------------------"
  loc="$(printf '%s' "$resp" | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}')"
  echo "[e2e]   -> Location: $loc"
  case "$loc" in
    "$DEX_ISSUER/auth"*) echo "[e2e] SMOKE PASS: discovery + authorize-URL built against real dex"; exit 0 ;;
    *) echo "[e2e] SMOKE FAIL"; echo "--- backend.log ---"; cat "$WORK/backend.log"; echo "--- dex.log (tail) ---"; tail -20 "$WORK/dex.log"; exit 1 ;;
  esac
fi

# 3b. full browser e2e via Playwright ----------------------------------------
# The Nix playwright-driver.browsers bundle is a store path, not a PATH entry;
# point Playwright at it explicitly and skip the glibc/host-requirement probe.
if [ -z "${PLAYWRIGHT_BROWSERS_PATH:-}" ]; then
  PLAYWRIGHT_BROWSERS_PATH="$(nix build --no-link --print-out-paths nixpkgs#playwright-driver.browsers 2>/dev/null || true)"
fi
export PLAYWRIGHT_BROWSERS_PATH
export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true
export APP_ORIGIN
echo "[e2e] running Playwright (browsers: ${PLAYWRIGHT_BROWSERS_PATH:-<default>})…"
if ( cd e2e/sso && playwright test --config playwright.config.ts ); then
  echo "[e2e] PASS: browser SSO login verified end-to-end."
else
  echo "[e2e] Playwright FAILED — backend.log tail:"; tail -40 "$WORK/backend.log"; exit 1
fi
