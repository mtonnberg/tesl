#!/usr/bin/env bash
# Focused Go CLI smoke. Full ci.sh remains the release gate; this script keeps
# the Go-backed CLI paths cheap to exercise during the migration.

set -uo pipefail

REPO_ROOT="${TESL_REPO_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
BODY="$REPO_ROOT/nix/tesl-cli-body.sh"
COMPILER="${TESL_OCAML_COMPILER:-$REPO_ROOT/compiler/_build/default/bin/main.exe}"

if [ ! -x "$COMPILER" ]; then
  echo "go-cli-smoke: compiler not built; skipping" >&2
  exit 77
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/tesl-go-cli.XXXXXXXX")"
run_pid=""
mcp_pid=""
cleanup() {
  [ -n "$mcp_pid" ] && kill "$mcp_pid" 2>/dev/null || true
  [ -n "$run_pid" ] && pkill -TERM -P "$run_pid" 2>/dev/null || true
  [ -n "$run_pid" ] && kill "$run_pid" 2>/dev/null || true
  [ -n "$run_pid" ] && wait "$run_pid" 2>/dev/null || true
  [ -n "$mcp_pid" ] && wait "$mcp_pid" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM HUP

run_cli() {
  TESL_REPO_ROOT="$REPO_ROOT" \
  TESL_OCAML_COMPILER="$COMPILER" \
  TESL_DEFAULT_BACKEND=go \
  TESL_GO="${TESL_GO:-go}" \
  bash "$BODY" "$@"
}

bash "$REPO_ROOT/scripts/check-go-test-inventory.sh"
bash "$REPO_ROOT/scripts/run-go-test-manifest.sh" --list >/dev/null
TESL_REPO_ROOT="$REPO_ROOT" TESL_OCAML_COMPILER="$COMPILER" \
  bash "$REPO_ROOT/scripts/run-go-test-manifest.sh" --run-all >/dev/null
TESL_REPO_ROOT="$REPO_ROOT" TESL_OCAML_COMPILER="$COMPILER" \
  bash "$REPO_ROOT/scripts/run-go-example-manifest.sh" --run-all >/dev/null

test_output="$(run_cli test example/learn/lesson00-hello-world.tesl 2>&1)" || {
  printf '%s\n' "$test_output" >&2
  echo "go-cli-smoke: default Go test failed" >&2
  exit 1
}
if ! printf '%s\n' "$test_output" | grep -q '^ok'; then
  printf '%s\n' "$test_output" >&2
  echo "go-cli-smoke: generated Go test produced no ok package" >&2
  exit 1
fi

mkdir -p "$TMP/project"
cp "$REPO_ROOT/example/todo-api.tesl" "$TMP/project/todo-api.tesl"
printf '%s\n' '[project]' 'name = "go-cli-smoke"' 'entrypoint = "todo-api.tesl"' > "$TMP/project/tesl.toml"

(cd "$TMP/project" && run_cli compile todo-api.tesl) || {
  echo "go-cli-smoke: default Go compile failed" >&2
  exit 1
}
[ -f "$TMP/project/.tesl-stuff/go-build/go.mod" ] || {
  echo "go-cli-smoke: default compile did not emit go.mod" >&2
  exit 1
}

context="$TMP/context"
(cd "$TMP/project" && run_cli build --backend go --container --no-docker --out "$context") || {
  echo "go-cli-smoke: Go Docker context staging failed" >&2
  exit 1
}
[ -f "$context/Dockerfile" ] && [ -f "$context/generated/cmd/app/main.go" ] || {
  echo "go-cli-smoke: incomplete Go Docker context" >&2
  exit 1
}

for template_spec in "minimal-go:minimal:none" "api-go:api:existing"; do
  IFS=: read -r project template postgres <<< "$template_spec"
  (cd "$TMP" && run_cli init "$project" --template "$template" --postgres "$postgres" --yes) || {
    echo "go-cli-smoke: $template template initialization failed" >&2
    exit 1
  }
  (cd "$TMP/$project" && run_cli compile app.tesl && run_cli test app.tesl &&
    run_cli build --no-docker --out "$TMP/$project-context") || {
    echo "go-cli-smoke: $template template Go workflow failed" >&2
    exit 1
  }
  [ -f "$TMP/$project-context/Dockerfile" ] || {
    echo "go-cli-smoke: $template template emitted no Docker context" >&2
    exit 1
  }
done

inspect_bin="$TMP/tesl-debug-inspect"
attach_bin="$TMP/tesl-debug-attach"
mcp_bin="$TMP/tesl-mcp"
(cd "$REPO_ROOT/runtime/go" && go build -o "$inspect_bin" ./cmd/tesl-debug-inspect) || {
  echo "go-cli-smoke: Go inspect build failed" >&2
  exit 1
}
(cd "$REPO_ROOT/runtime/go" && go build -o "$attach_bin" ./cmd/tesl-debug-attach) || {
  echo "go-cli-smoke: Go attach build failed" >&2
  exit 1
}
(cd "$REPO_ROOT/runtime/go" && go build -o "$mcp_bin" ./cmd/tesl-mcp) || {
  echo "go-cli-smoke: Go MCP build failed" >&2
  exit 1
}
inspect_output=""
inspect_ok=false
for attempt in 1 2 3; do
  if inspect_output="$(TESL_DEBUG_INSPECT_BIN="$inspect_bin" run_cli debug-inspect example/learn/lesson61-step-debugging.tesl --break-at 189 --mode test --timeout-ms 10000 2>&1)" &&
     printf '%s\n' "$inspect_output" | grep -q '"stopped":true'; then
    inspect_ok=true
    break
  fi
  sleep 1
done
$inspect_ok || {
  printf '%s\n' "$inspect_output" >&2
  echo "go-cli-smoke: default Go headless inspection failed after 3 attempts" >&2
  exit 1
}
printf '%s\n' "$inspect_output" | grep -q '"stopped":true' || {
  printf '%s\n' "$inspect_output" >&2
  echo "go-cli-smoke: headless inspection did not stop" >&2
  exit 1
}

# Real MCP-to-runtime attach: launch a Go debug server, arm through a real MCP
# stdio session, trigger the endpoint, and require the stopped event in the MCP
# response. This closes the phase-6 live-endpoint gap without using a fake
# attach helper.
if command -v curl >/dev/null 2>&1; then
  mkdir -p "$TMP/live-project"
  sed 's/port: 8086/port: 18086/' \
    "$REPO_ROOT/example/learn/lesson17-telemetry.tesl" > "$TMP/live-project/lesson17-telemetry.tesl"
  printf '%s\n' '[project]' 'name = "go-mcp-live-smoke"' 'entrypoint = "lesson17-telemetry.tesl"' \
    > "$TMP/live-project/tesl.toml"
  (
    cd "$TMP/live-project" && \
      TESL_REPO_ROOT="$REPO_ROOT" TESL_OCAML_COMPILER="$COMPILER" \
      TESL_DEFAULT_BACKEND=go TESL_GO="${TESL_GO:-go}" \
      bash "$BODY" run --backend go --debug lesson17-telemetry.tesl
  ) >"$TMP/live-run.log" 2>&1 &
  run_pid=$!
  live_ready=false
  for _attempt in $(seq 1 60); do
    if [ -S "$TMP/live-project/.tesl-stuff/debug.sock" ]; then
      live_ready=true
      break
    fi
    sleep 0.25
  done
  $live_ready || {
    cat "$TMP/live-run.log" >&2
    echo "go-cli-smoke: Go debug server did not publish an attach endpoint" >&2
    exit 1
  }
  mcp_payload='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"tesl.debug_attach","arguments":{"action":"once","project":"'"$TMP/live-project"'","break_at":["lesson17-telemetry.tesl:72"],"timeout_ms":10000}}}'
  mcp_length=$(printf '%s' "$mcp_payload" | wc -c | tr -d ' ')
  (
    {
      printf 'Content-Length: %s\r\n\r\n' "$mcp_length"
      printf '%s' "$mcp_payload"
    } | TESL_DEBUG_ATTACH="$attach_bin" TESL_COMPILER="$COMPILER" \
      TESL_REPO_ROOT="$REPO_ROOT" "$mcp_bin"
  ) >"$TMP/mcp-live.out" 2>&1 &
  mcp_pid=$!
  sleep 1
  curl --fail --silent --show-error "http://127.0.0.1:18086/health" >/dev/null || {
    cat "$TMP/live-run.log" "$TMP/mcp-live.out" >&2
    echo "go-cli-smoke: live Go server trigger failed" >&2
    exit 1
  }
  wait "$mcp_pid" || {
    cat "$TMP/mcp-live.out" >&2
    echo "go-cli-smoke: live MCP session failed" >&2
    exit 1
  }
  mcp_pid=""
  grep -q 'stopped' "$TMP/mcp-live.out" || {
    cat "$TMP/mcp-live.out" >&2
    echo "go-cli-smoke: MCP attach response contained no stopped event" >&2
    exit 1
  }
  pkill -TERM -P "$run_pid" 2>/dev/null || true
  kill "$run_pid" 2>/dev/null || true
  wait "$run_pid" 2>/dev/null || true
  run_pid=""
else
  echo "go-cli-smoke: curl unavailable; skipping live MCP attach" >&2
fi

echo "go-cli-smoke: ok"
