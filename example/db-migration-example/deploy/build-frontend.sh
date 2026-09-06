#!/usr/bin/env bash
# Frontend compilation is independent of the backend/release build.
set -euo pipefail
APP_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$APP_DIR/frontend"
elm make src/Main.elm --output=main.js --optimize
