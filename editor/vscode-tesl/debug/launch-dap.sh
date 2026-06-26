#!/usr/bin/env bash
# launch-dap.sh — Launch the Tesl DAP server.
#
# Called by VSCode's debug adapter configuration. Resolves dap-server.rkt and
# the Racket PLTCOLLECTS path, then runs the server over stdin/stdout using
# Content-Length-framed JSON (the DAP protocol).
#
# Search order for dap-server.rkt:
#   1. TESL_REPO_ROOT env var   (set explicitly, or by the VSCode extension)
#   2. Dev/repo layout          (script is inside the repo at editor/vscode-tesl/debug/)
#   3. nix ~/.nix-profile       (nix profile install github:mtonnberg/tesl)
#   4. nix system profile       (/nix/var/nix/profiles/default)
#   5. tesl binary → repo root  (derive from the location of the `tesl` binary)

set -euo pipefail

# ── 1. Find Racket ────────────────────────────────────────────────────────────
if [[ -n "${TESL_RACKET_PATH:-}" ]]; then
  RACKET_BIN="${TESL_RACKET_PATH}"
elif command -v racket &>/dev/null; then
  RACKET_BIN="$(command -v racket)"
elif [[ -x "${HOME}/.nix-profile/bin/racket" ]]; then
  RACKET_BIN="${HOME}/.nix-profile/bin/racket"
elif [[ -x "/nix/var/nix/profiles/default/bin/racket" ]]; then
  RACKET_BIN="/nix/var/nix/profiles/default/bin/racket"
else
  echo "Error: racket not found. Set TESL_RACKET_PATH or add racket to PATH." >&2
  exit 1
fi

# ── 2. Find dap-server.rkt ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAP_SERVER=""
PLTCOLLECTS_EXTRA=""

find_dap() {
  local candidate="$1"
  local pltcollects="${2:-}"
  if [[ -f "${candidate}" ]]; then
    DAP_SERVER="${candidate}"
    PLTCOLLECTS_EXTRA="${pltcollects}"
    return 0
  fi
  return 1
}

# Strategy 0: TESL_DAP_SERVER set directly by extension.js (most reliable)
if [[ -n "${TESL_DAP_SERVER:-}" && -f "${TESL_DAP_SERVER}" ]]; then
  DAP_SERVER="${TESL_DAP_SERVER}"
  # PLTCOLLECTS is also set by extension.js in this case
fi

# Strategy 1: TESL_REPO_ROOT env var (only if it actually holds a repo checkout;
# the VSCode extension may set TESL_REPO_ROOT to the user's *project* dir, which
# has no dsl/debug/ — find_dap simply fails there and we fall through).
if [[ -z "${DAP_SERVER}" && -n "${TESL_REPO_ROOT:-}" ]]; then
  find_dap "${TESL_REPO_ROOT}/dsl/debug/dap-server.rkt" "${TESL_REPO_ROOT}" || true
fi

# Strategy 1a: TESL_COLLECTIONS_DIR — baked into the installed `tesl` wrapper's
# preamble, pointing at .../tesl-racket-collections/share/tesl-collections/tesl.
# The DAP server ships inside that same collections derivation, so this is the
# most reliable resolution for a flake-installed binary.
if [[ -z "${DAP_SERVER}" && -n "${TESL_COLLECTIONS_DIR:-}" ]]; then
  find_dap "${TESL_COLLECTIONS_DIR}/dsl/debug/dap-server.rkt" \
           "$(dirname "${TESL_COLLECTIONS_DIR}")" || true
fi

# Strategy 1b: scan PLTCOLLECTS for a collections root that contains the DAP
# server. The installed binary exports PLTCOLLECTS with the tesl collections
# entry (…/share/tesl-collections holding tesl/dsl/…), so this resolves even
# when ~/.nix-profile/share/ does not mirror the collections derivation — the
# exact failure the user hit (dap-server: NOT FOUND with PLTCOLLECTS set).
if [[ -z "${DAP_SERVER}" && -n "${PLTCOLLECTS:-}" ]]; then
  IFS=':' read -ra _tesl_pc_entries <<< "${PLTCOLLECTS}"
  for _entry in "${_tesl_pc_entries[@]}"; do
    [[ -n "${_entry}" ]] || continue
    if [[ -f "${_entry}/tesl/dsl/debug/dap-server.rkt" ]]; then
      find_dap "${_entry}/tesl/dsl/debug/dap-server.rkt" "${_entry}"
      break
    fi
  done
  unset _tesl_pc_entries _entry
fi

# Strategy 2: dev/repo layout — script lives at editor/vscode-tesl/debug/
# so repo root is three levels up
if [[ -z "${DAP_SERVER}" ]]; then
  find_dap "${SCRIPT_DIR}/../../../dsl/debug/dap-server.rkt" \
           "$(cd "${SCRIPT_DIR}/../../.." && pwd)" || true
fi

# ── Dev layout: create proper collection symlinks so (require tesl/dsl/...) resolves ──
# The nix build creates: tesl-collections/tesl/{dsl,tesl,lang}
# In dev layout PLTCOLLECTS points to the repo root, but the collection structure
# expects tesl/dsl/ not just dsl/ — so we create it under .tesl-collections/
if [[ -n "${PLTCOLLECTS_EXTRA}" && -d "${PLTCOLLECTS_EXTRA}/dsl" ]]; then
  REPO_ROOT="${PLTCOLLECTS_EXTRA}"
  COLL_DIR="${REPO_ROOT}/.tesl-collections"
  if [[ ! -L "${COLL_DIR}/tesl/dsl" ]]; then
    mkdir -p "${COLL_DIR}/tesl"
    [[ -d "${REPO_ROOT}/dsl"  ]] && ln -sf "${REPO_ROOT}/dsl"  "${COLL_DIR}/tesl/dsl"  || true
    [[ -d "${REPO_ROOT}/tesl" ]] && ln -sf "${REPO_ROOT}/tesl" "${COLL_DIR}/tesl/tesl" || true
    [[ -d "${REPO_ROOT}/lang" ]] && ln -sf "${REPO_ROOT}/lang" "${COLL_DIR}/tesl/lang" || true
  fi
  PLTCOLLECTS_EXTRA="${COLL_DIR}"
fi

# Strategy 3: nix ~/.nix-profile
if [[ -z "${DAP_SERVER}" ]]; then
  NIX_HOME="${HOME}/.nix-profile"
  find_dap "${NIX_HOME}/share/tesl-collections/tesl/dsl/debug/dap-server.rkt" \
           "${NIX_HOME}/share/tesl-collections" || true
fi

# Strategy 4: nix system profile
if [[ -z "${DAP_SERVER}" ]]; then
  find_dap "/nix/var/nix/profiles/default/share/tesl-collections/tesl/dsl/debug/dap-server.rkt" \
           "/nix/var/nix/profiles/default/share/tesl-collections" || true
fi

# Strategy 5: derive from the `tesl` binary location (follow symlinks)
if [[ -z "${DAP_SERVER}" ]]; then
  TESL_BIN=""
  if command -v tesl &>/dev/null; then
    TESL_BIN="$(command -v tesl)"
  elif [[ -x "${HOME}/.nix-profile/bin/tesl" ]]; then
    TESL_BIN="${HOME}/.nix-profile/bin/tesl"
  fi
  if [[ -n "${TESL_BIN}" ]]; then
    # Follow symlinks to get the real binary path
    TESL_REAL="$(readlink -f "${TESL_BIN}" 2>/dev/null || echo "${TESL_BIN}")"
    # Binary is at <root>/bin/tesl → <root> is the parent of bin/
    TESL_ROOT="$(dirname "$(dirname "${TESL_REAL}")")"
    find_dap "${TESL_ROOT}/dsl/debug/dap-server.rkt" "${TESL_ROOT}" || \
    find_dap "${TESL_ROOT}/share/tesl-collections/tesl/dsl/debug/dap-server.rkt" \
             "${TESL_ROOT}/share/tesl-collections" || true
  fi
fi

if [[ -z "${DAP_SERVER}" ]]; then
  echo "Error: dap-server.rkt not found. Set TESL_REPO_ROOT to your Tesl repo root, or install Tesl via nix (nix profile install github:mtonnberg/tesl)." >&2
  exit 1
fi

# ── 3. Set PLTCOLLECTS so Racket can find the tesl runtime ────────────────────
# When running from the nix store the dsl/tesl/lang collections are not on
# Racket's default collection path — we need to add them.
if [[ -n "${PLTCOLLECTS_EXTRA}" ]]; then
  export PLTCOLLECTS="${PLTCOLLECTS_EXTRA}:${PLTCOLLECTS:-}"
fi

# ── 4. Find tesl compiler binary and export for dap-server.rkt ───────────────
# Only set TESL_COMPILER if not already provided (extension.js sets it
# correctly when launched from the workspace, pointing to the locally
# compiled binary that supports --debug).
if [[ -z "${TESL_COMPILER:-}" ]]; then
  TESL_BIN=""
  REPO_ROOT_FOR_BIN="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
  LOCAL_COMPILER="${REPO_ROOT_FOR_BIN}/compiler/_build/default/bin/main.exe"

  if [[ -x "${LOCAL_COMPILER}" ]]; then
    TESL_BIN="${LOCAL_COMPILER}"
  elif [[ -n "${TESL_REPO_ROOT:-}" && -x "${TESL_REPO_ROOT}/compiler/_build/default/bin/main.exe" ]]; then
    TESL_BIN="${TESL_REPO_ROOT}/compiler/_build/default/bin/main.exe"
  elif command -v tesl &>/dev/null; then
    TESL_BIN="$(command -v tesl)"
  elif [[ -x "${HOME}/.nix-profile/bin/tesl" ]]; then
    TESL_BIN="${HOME}/.nix-profile/bin/tesl"
  elif [[ -x "/nix/var/nix/profiles/default/bin/tesl" ]]; then
    TESL_BIN="/nix/var/nix/profiles/default/bin/tesl"
  fi

  if [[ -n "${TESL_BIN}" ]]; then
    export TESL_COMPILER="${TESL_BIN}"
  fi
fi

# ── Bash-level log (written before Racket starts) ────────────────────────────
LOG="$HOME/tesl-dap.log"
{
  echo "=== launch-dap.sh ==="
  echo "RACKET_BIN=${RACKET_BIN}"
  echo "DAP_SERVER=${DAP_SERVER}"
  echo "TESL_COMPILER=${TESL_COMPILER:-UNSET}"
  echo "PLTCOLLECTS=${PLTCOLLECTS:-UNSET}"
  echo "TESL_REPO_ROOT=${TESL_REPO_ROOT:-UNSET}"
} >> "$LOG" 2>&1

exec "${RACKET_BIN}" "${DAP_SERVER}" "$@"
