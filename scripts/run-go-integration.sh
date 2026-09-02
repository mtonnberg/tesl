#!/usr/bin/env bash
# scripts/run-go-integration.sh — full-chain integration tests for the Go backend.
#
# The deleted Racket suites (test_httpclient_integration, test_email_integration)
# proved the WHOLE chain: compile a real Tesl program, run the generated code,
# and watch it hold a real network conversation. This script is that proof for
# the Go backend:
#
#   1. HTTP library chain — tests/integration/http_fullchain.tesl is compiled,
#      a harness test is injected into the emitted module, and `go test` runs
#      the emitted handler against an httptest upstream over real TCP
#      (GET + non-2xx marker + POST with headers/body).
#   2. HTTP server chain — the same fixture's cmd/app binary listens on a free
#     port and its /upstream route performs the outbound call through the
#     running process, exercised by the helper's `get`.
#   3. Email chain — tests/integration/email_fullchain.tesl's emitted send +
#     worker functions deliver through DeliverEmail into a capture SMTP server
#     listening on the fixed port the fixture bakes in (18025).
#
# Environment:
#   TESL_REPO_ROOT        repo root (default: derived from this script)
#   TESL_OCAML_COMPILER   compiler binary (default: compiler/_build/default/bin/main.exe)
#
# Exit codes: 0 all chains proved; 1 a chain failed; 77 tools missing (skip).
set -euo pipefail

repo_root=${TESL_REPO_ROOT:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}
compiler=${TESL_OCAML_COMPILER:-$repo_root/compiler/_build/default/bin/main.exe}
fixtures="$repo_root/tests/integration"
harness_dir="$repo_root/scripts/go-integration"

[[ -x "$compiler" ]] || { printf 'Go integration: compiler not executable: %s\n' "$compiler" >&2; exit 77; }
command -v go >/dev/null || { printf 'Go integration: go not on PATH\n' >&2; exit 77; }

work=$(mktemp -d "${TMPDIR:-/tmp}/tesl-go-integration.XXXXXXXX")
upstream_pid=
app_pid=
cleanup() {
    [ -n "$app_pid" ] && kill "$app_pid" 2>/dev/null || true
    [ -n "$upstream_pid" ] && kill "$upstream_pid" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

printf 'Building integration helper…\n'
go build -o "$work/helper" "$harness_dir/helper/main.go"

inject_harness() {
    # $1 = emitted module dir; $2 = template file; $3 = output test file name.
    local pkg
    pkg=$(basename "$(dirname "$(find "$1/internal" -name module.go -print -quit)")")
    [ -n "$pkg" ] || { printf 'Go integration: no module.go under %s/internal\n' "$1" >&2; exit 1; }
    sed "s/__PACKAGE__/$pkg/g" "$2" > "$1/internal/$pkg/$3"
}

# ── 1+2. HTTP: compile, inject the library-chain harness, go test ────────────
printf 'Compiling http_fullchain.tesl…\n'
"$compiler" --backend go "$fixtures/http_fullchain.tesl" --out "$work/http" >/dev/null
inject_harness "$work/http" "$harness_dir/http_chain_test.go.tmpl" http_chain_external_test.go

printf 'Running emitted handlers against a live upstream (library chain)…\n'
( cd "$work/http" && go test -count=1 -run 'TestFullChain' ./internal/... )

printf 'Running the compiled binary as a real server (server chain)…\n'
( cd "$work/http" && go build -o "$work/app" ./cmd/app )
port=$("$work/helper" freeport)
"$work/helper" upstream >"$work/upstream.log" 2>&1 &
upstream_pid=$!
for _ in $(seq 1 100); do
    grep -q '^READY ' "$work/upstream.log" 2>/dev/null && break
    sleep 0.1
done
grep -q '^READY ' "$work/upstream.log" || {
    printf 'Go integration: upstream helper never became ready\n' >&2
    exit 1
}
upstream_addr=$(sed -n 's/^READY //p' "$work/upstream.log")

FULLCHAIN_PORT="$port" FULLCHAIN_UPSTREAM_URL="http://$upstream_addr/source" "$work/app" &
app_pid=$!
answer=
for _ in $(seq 1 100); do
    answer=$("$work/helper" get "http://127.0.0.1:$port/upstream" 2>/dev/null) && break
    sleep 0.3
done
# The route answers JSON, so the body arrives quoted ("upstream-ok").
case "$answer" in
    200*upstream-ok*) ;;
    *)
        printf 'Go integration: GET /upstream through the running binary returned %s\n' "${answer:-<no answer>}" >&2
        exit 1
        ;;
esac
kill "$app_pid" 2>/dev/null || true; app_pid=
kill "$upstream_pid" 2>/dev/null || true; upstream_pid=

# ── 3. Email: compile, inject the delivery harness, go test ──────────────────
printf 'Compiling email_fullchain.tesl…\n'
"$compiler" --backend go "$fixtures/email_fullchain.tesl" --out "$work/email" >/dev/null
inject_harness "$work/email" "$harness_dir/email_chain_test.go.tmpl" email_chain_external_test.go

printf 'Delivering generated email through real SMTP (email chain)…\n'
( cd "$work/email" && SMTP_HOST=127.0.0.1 go test -count=1 -timeout 120s -run 'TestFullChainEmailDeliversOverRealSMTP' ./internal/... )

printf 'Go integration OK (HTTP library chain, HTTP server chain, SMTP delivery chain)\n'
