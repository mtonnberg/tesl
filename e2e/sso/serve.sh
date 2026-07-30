#!/usr/bin/env bash
# Bring up the SSO sandbox for a MANUAL browser session and leave it running:
# starts dex (loopback HTTPS, self-signed) + the Tesl backend, which serves the
# sandbox frontend. Open http://localhost:8080 in a browser, click "Log in with
# dex", and sign in as alice@example.com / password. Ctrl-C to stop.
#
# This is just the serve-and-wait mode of run.sh (SSO_E2E_SERVE=1); run.sh itself
# also has the full headless Playwright e2e and the SSO_E2E_SMOKE protocol check.
#
#   bash e2e/sso/serve.sh          # from the repo root, or from anywhere
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"
# racket + the linked `tesl` collections come from the repo dev shell; run.sh
# then re-execs into a `nix shell` that adds dex/openssl/mkpasswd.
exec env SSO_E2E_SERVE=1 nix develop "$REPO_ROOT" --command bash "$DIR/run.sh" "$@"
