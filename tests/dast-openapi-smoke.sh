#!/usr/bin/env bash
# Checked-in DAST smoke: compile a disposable Tesl staging app, prove that the
# selected server's OpenAPI document is scoped correctly, then import it into ZAP.
set -euo pipefail

REPO_ROOT="${TESL_REPO_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
COMPILER="${TESL_OCAML_COMPILER:-$REPO_ROOT/compiler/_build/default/bin/main.exe}"
BODY="$REPO_ROOT/nix/tesl-cli-body.sh"
SOURCE="$REPO_ROOT/example/learn/lesson81-openapi-dast.tesl"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tesl-dast-smoke.XXXXXXXX")"
RUN_PID=""

cleanup() {
  if [ -n "$RUN_PID" ]; then
    kill -TERM -- "-$RUN_PID" 2>/dev/null || true
    pkill -TERM -P "$RUN_PID" 2>/dev/null || true
    kill "$RUN_PID" 2>/dev/null || true
    wait "$RUN_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM HUP

[ -x "$COMPILER" ] || { echo "dast-smoke: compiler not executable: $COMPILER" >&2; exit 77; }
command -v curl >/dev/null 2>&1 || { echo "dast-smoke: curl not found" >&2; exit 77; }
command -v jq >/dev/null 2>&1 || { echo "dast-smoke: jq not found" >&2; exit 77; }

tesl() {
  TESL_REPO_ROOT="$REPO_ROOT" \
  TESL_OCAML_COMPILER="$COMPILER" \
  TESL_DEFAULT_BACKEND=go \
    bash "$BODY" "$@"
}

port="${TESL_DAST_SMOKE_PORT:-18081}"
while [ "$port" -lt 65535 ] && (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; do
  exec 3>&-
  port=$((port + 1))
done

app="$WORK/lesson81-openapi-dast.tesl"
sed "s/port: 8080/port: $port/" "$SOURCE" > "$app"
spec="$WORK/public.json"
"$COMPILER" generate-openapi "$app" PublicServer --output "$spec"
jq -e '
  .openapi == "3.1.0" and
  (.paths | has("/public")) and
  (.paths | has("/private")) and
  ((.paths | has("/internal")) | not)
' "$spec" >/dev/null

setsid env TESL_REPO_ROOT="$REPO_ROOT" TESL_OCAML_COMPILER="$COMPILER" \
  TESL_DEFAULT_BACKEND=go bash "$BODY" run "$app" >"$WORK/server.log" 2>&1 &
RUN_PID=$!
ready=0
for _ in $(seq 1 60); do
  if curl -fsS --max-time 1 "http://127.0.0.1:$port/public" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.25
done
[ "$ready" -eq 1 ] || { echo "dast-smoke: disposable app did not boot" >&2; exit 1; }

public_status="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/public")"
private_status="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/private")"
authorized_status="$(curl -sS -o /dev/null -w '%{http_code}' \
  -H 'Authorization: Bearer dast-lesson' "http://127.0.0.1:$port/private")"
[ "$public_status" = 200 ] || { echo "dast-smoke: public operation returned $public_status" >&2; exit 1; }
[ "$private_status" = 401 ] || { echo "dast-smoke: unauthenticated operation returned $private_status" >&2; exit 1; }
[ "$authorized_status" = 200 ] || { echo "dast-smoke: authenticated operation returned $authorized_status" >&2; exit 1; }

mkdir -p "$WORK/report"
TESL_DAST_AUTH='Bearer dast-lesson' tesl dast "http://127.0.0.1:$port" "$app" \
  --server PublicServer --active \
  --authorization-env TESL_DAST_AUTH --report-dir "$WORK/report"
jq -e '[.site[]?.alerts[]? | select((.riskcode // "0") | tonumber >= 2)] | length == 0' \
  "$WORK/report/zap-report.json" >/dev/null

echo "dast-openapi-smoke: PASS (PublicServer scope, auth boundary, ZAP import)"
