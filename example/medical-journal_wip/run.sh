#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Medical Journal — Backend runner
#
# Starts PostgreSQL, compiles MedicalJournalBackend.tesl → Racket, and runs
# the server.
#
# Usage (from repository root OR example/medical-journal/):
#   bash example/medical-journal/run.sh
#
# API available at http://localhost:8080 (or MJ_PORT)
# Press Ctrl-C to stop.
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"

# ─── Re-enter via nix-shell if needed ────────────────────────────────────────
if [ -z "${IN_NIX_SHELL:-}" ]; then
    echo "▶  Entering nix-shell (Racket + PostgreSQL)..."
    exec nix-shell "$REPO_ROOT/shell.nix" \
        --run "IN_NIX_SHELL=1 bash \"$SCRIPT_DIR/run.sh\""
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

# Create medical_journal database if it doesn't exist
createdb \
    -h 127.0.0.1 \
    -p "$TESL_POSTGRES_PORT" \
    -U "$TESL_POSTGRES_USER" \
    medical_journal 2>/dev/null \
    && printf '   Created database "medical_journal"\n' \
    || printf '   Database "medical_journal" already exists\n'

# ─── Environment variables ────────────────────────────────────────────────────
export MJ_DB="medical_journal"
export TESL_POSTGRES_PASSWORD=""
export TESL_POSTGRES_HOST="127.0.0.1"
export TESL_POSTGRES_SOCKET=""        # empty: use TCP, not Unix socket
export MJ_PORT="${MJ_PORT:-8080}"

# ─── Frontend build ───────────────────────────────────────────────────────────
FRONTEND_DIR="$SCRIPT_DIR/frontend"
if [ -d "$FRONTEND_DIR" ]; then
    echo "▶  Building frontend..."
    (cd "$FRONTEND_DIR" && npm install --quiet 2>/dev/null && npm run build)
    echo "   Built frontend/dist/"
fi

# ─── Compile dependencies ─────────────────────────────────────────────────────
MAIN_FILE="example/medical-journal/MedicalJournalBackend.tesl"
echo "▶  Compiling Tesl modules..."
DEPS=$("$REPO_ROOT/compiler/_build/default/bin/main.exe" --deps "$MAIN_FILE")
for dep in $DEPS; do
    # tesl compile writes <name>.rkt but the emitter requires kebab-case filenames.
    # Compile to stdout and redirect to the kebab-case path.
    dir=$(dirname "$dep")
    base=$(basename "$dep" .tesl)
    # Convert PascalCase to kebab-case: MedicalJournalDB → medical-journal-d-b
    kebab=$(echo "$base" | sed 's/\([A-Z]\)/-\L\1/g' | sed 's/^-//')
    rkt="$dir/$kebab.rkt"
    "$REPO_ROOT/compiler/_build/default/bin/main.exe" "$dep" > "$rkt"
    echo "   $dep → $rkt"
done
echo "   Dependencies compiled"

# ─── Compile and run ─────────────────────────────────────────────────────────
echo ""
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│  Medical Journal  →  http://127.0.0.1:$MJ_PORT               │"
echo "│  API + frontend on one port — no proxy needed                │"
echo "│  Press Ctrl-C to stop                                        │"
echo "└──────────────────────────────────────────────────────────────┘"
echo ""
TESL_VERBOSE=1 exec tesl run example/medical-journal/MedicalJournalBackend.tesl
