#!/usr/bin/env bash
# Two request nodes behind a reverse proxy, with writes throughout V1 -> V7.
set -euo pipefail
APP_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
source "$APP_DIR/scripts/local-env.sh"
for tool in python3 go elm initdb pg_ctl psql; do
  command -v "$tool" >/dev/null || { echo "missing $tool; use the repository dev shell and Elm 0.19.1" >&2; exit 1; }
done
mkdir -p "$TODO_LOCAL_DIR"
RUN_DIR="$(mktemp -d "$TODO_LOCAL_DIR/releases.XXXXXX")"
echo "Release binaries and logs: $RUN_DIR"
# Compile before deployment: a failed build does not disturb healthy processes.
for revision in 1 2 3 4 5 6 7; do bash "$APP_DIR/build-revision.sh" "$revision" "$RUN_DIR/v$revision"; done
bash "$APP_DIR/build-frontend.sh"
bash "$APP_DIR/setup-local.sh"
bash "$APP_DIR/install-local.sh" "$RUN_DIR/v1/app"
python3 "$APP_DIR/scripts/cluster.py" "$RUN_DIR" "$APP_DIR/frontend" "${TODO_PROXY_PORT:-8085}"
