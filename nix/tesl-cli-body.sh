# ─────────────────────────────────────────────────────────────────────────────
# Shared Tesl CLI body — the helper functions and `case "$CMD"` dispatch.
#
# This file is the SINGLE SOURCE OF TRUTH for the `tesl` command-line verbs.
# Both flake.nix and shell.nix splice it in verbatim via `builtins.readFile`,
# each prepending its own preamble that establishes the runtime env contract.
# Because it is read as a literal bash file (not a Nix `''` string), there is
# NO Nix interpolation here — `${...}` and `''` are ordinary bash.
#
# ENV CONTRACT (the preamble MUST set these before this body runs):
#   TESL_OCAML_COMPILER   path to the OCaml compiler binary (main.exe)
#   PATH                  must contain the Go toolchain for Go build/test flows
# OPTIONAL (set by the installed preamble so assets resolve without a repo):
#   TESL_TEMPLATES_DIR    store path holding templates/{minimal,api,docker}
#   TESL_ZAP              path to the default ZAP DAST scanner
#   TESL_NUCLEI            path to the complementary Nuclei scanner
# DEV fallback:
#   TESL_REPO_ROOT        repo checkout; templates + collections come from here.
# ─────────────────────────────────────────────────────────────────────────────

_tesl_require_compiler() {
  if [ ! -x "$TESL_OCAML_COMPILER" ]; then
    echo "error: Tesl compiler not found at $TESL_OCAML_COMPILER" >&2
    exit 1
  fi
}

_tesl_compile_to_stdout() {
  local FILE="$1"
  _tesl_require_compiler
  "$TESL_OCAML_COMPILER" "$FILE"
}

_tesl_compile_deps() {
  local FILE="$1"
  _tesl_require_compiler
  "$TESL_OCAML_COMPILER" --deps "$FILE"
}

_tesl_check() {
  [ $# -gt 0 ] || { echo "Usage: tesl check [file.tesl ...]" >&2; exit 1; }
  _tesl_require_compiler
  "$TESL_OCAML_COMPILER" --check "$@"
}

# ── Portable userland shims (macOS/BSD parity) ──────────────────────────────
# #46: this body used GNU-only tool flags — `mktemp --suffix=`, `readlink -f`,
# `realpath --relative-to`, `stat -c`, `sed -i <expr>`, `xargs -d` — so on a BSD
# userland (macOS) `tesl run`/`compile`/`test`/`init` failed, often with a
# CONFUSING secondary error: `$(mktemp --suffix=.go)` came back empty and the
# redirect then reported a bare `: No such file or directory`.
#
# Two independent defences, so a fresh macOS install works with zero user action:
#   1. the installed wrapper prepends a GNU userland to PATH (flake.nix /
#      shell.nix preamble), and
#   2. NO verb in this file uses a GNU-only flag — every construct below is
#      POSIX or feature-detects both dialects.
# Defence 2 is what keeps the body correct when it is run directly (ci.sh does)
# or from an environment whose PATH the user reset. tests/cli-portability.sh
# enforces it: it greps this file for the banned constructs AND re-runs the
# verbs with a BSD-only userland shimmed onto PATH.

# Absolute path of an existing file/dir, with the DIRECTORY part symlink-resolved
# (`cd -P`). Replaces plain `realpath` (absent on older macOS).
_tesl_abspath() {
  local p="$1" d b
  [ -n "$p" ] || return 1
  if [ -d "$p" ]; then ( cd -P -- "$p" 2>/dev/null && pwd -P ); return; fi
  d="$(dirname -- "$p")"; b="$(basename -- "$p")"
  d="$(cd -P -- "$d" 2>/dev/null && pwd -P)" || return 1
  case "$d" in
    /) printf '/%s\n' "$b" ;;
    *) printf '%s/%s\n' "$d" "$b" ;;
  esac
}

# Fully resolve a symlink chain (bounded), then absolutize — the portable
# equivalent of `readlink -f` (BSD readlink has no -f).
_tesl_resolve_link() {
  local p="$1" i=0 target
  while [ -L "$p" ] && [ "$i" -lt 32 ]; do
    target="$(readlink "$p" 2>/dev/null)" || break
    [ -n "$target" ] || break
    case "$target" in
      /*) p="$target" ;;
      *)  p="$(dirname -- "$p")/$target" ;;
    esac
    i=$((i + 1))
  done
  _tesl_abspath "$p" 2>/dev/null || printf '%s\n' "$p"
}

# Path of $2 relative to base $1 (both absolute, no trailing slash on $1).
# rc 1 when $2 is NOT under $1 — callers treat that as "outside the project
# root". Replaces `realpath --relative-to` (GNU-only).
_tesl_relpath() {
  local base="${1%/}" path="$2"
  [ -n "$base" ] && [ -n "$path" ] || return 1
  case "$path" in
    "$base")    printf '.\n';                    return 0 ;;
    "$base"/*)  printf '%s\n' "${path#"$base"/}"; return 0 ;;
    *)          return 1 ;;
  esac
}

# Modification time (epoch seconds) of a file: GNU `stat -c` or BSD `stat -f`.
_tesl_file_mtime() {
  local f="$1" v
  v="$(stat -c '%Y' "$f" 2>/dev/null)" || v=""
  [ -n "$v" ] || v="$(stat -f '%m' "$f" 2>/dev/null)" || v=""
  printf '%s\n' "${v:-0}"
}

# "<size>-<mtime>" identity for a file, in either stat dialect.
_tesl_file_stamp() {
  local f="$1" v
  v="$(stat -c '%s-%Y' "$f" 2>/dev/null)" || v=""
  [ -n "$v" ] || v="$(stat -f '%z-%m' "$f" 2>/dev/null)" || v=""
  printf '%s\n' "${v:-unknown}"
}

# Temp file / temp dir. BSD mktemp REQUIRES a template, so never call bare
# `mktemp`; both dialects accept an explicit trailing-X template.
_tesl_mktemp()     { mktemp  "${TMPDIR:-/tmp}/tesl.XXXXXXXX"; }
_tesl_mktemp_dir() { mktemp -d "${TMPDIR:-/tmp}/tesl.XXXXXXXX"; }

# Portable in-place sed. GNU accepts an optional suffix after -i; BSD requires
# one. Rewriting through a sibling temp file keeps both dialects equivalent.
_tesl_sed_inplace() {
  local expr="$1" file="$2" tmp
  tmp="$file.tesl-sed.$$"
  sed "$expr" "$file" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file"
}

# Project root for a DIRECTORY: the nearest ancestor (or itself) with tesl.toml.
_tesl_project_root_of_dir() {
  local d
  d="$(cd -P "$1" 2>/dev/null && pwd -P)" || return 1
  while :; do
    if [ -f "$d/tesl.toml" ]; then echo "$d"; return 0; fi
    [ "$d" = "/" ] && return 1
    d="$(dirname "$d")"
  done
}

# Project root for a .tesl FILE: nearest ancestor with tesl.toml, falling back
# to the file's own directory (a bare single-file project with no manifest).
_tesl_project_root() {
  local dir
  dir="$(cd -P "$(dirname "$1")" 2>/dev/null && pwd -P)" || return 1
  _tesl_project_root_of_dir "$dir" || echo "$dir"
}

# Effective build root for a project root ($1), honoring TESL_BUILD_DIR.
_tesl_build_root() {
  local root="$1"
  if [ -n "${TESL_BUILD_DIR:-}" ]; then
    case "$TESL_BUILD_DIR" in
      /*) echo "$TESL_BUILD_DIR" ;;
      *)  echo "$root/$TESL_BUILD_DIR" ;;
    esac
  else
    echo "$root/.tesl-stuff/build"
  fi
}

_tesl_project_mktemp_dir() {
  local file="$1" prefix="$2" project
  project="$(_tesl_project_root "$file")" || return 1
  mkdir -p "$project/.tesl-stuff" || return 1
  TMPDIR="$project/.tesl-stuff" _tesl_mktemp_dir
}

_tesl_test_go_file() {
  local file="$1" test_name="$2" test_kind="$3" root out status
  root="$(_tesl_project_mktemp_dir "$file" test-go)" || return 1
  out="$root/go"
  if ! "$TESL_OCAML_COMPILER" "$file" --out "$out"; then
    rm -rf "$root"
    return 1
  fi
  (cd "$out" && TESL_TEST_NAME="$test_name" TESL_TEST_KIND="$test_kind" \
    "${TESL_GO:-go}" test ./...)
  status=$?
  rm -rf "$root"
  return "$status"
}

_tesl_run_go_file() {
  local file="$1" debug="$2" project root out binary status
  shift 2
  project="$(_tesl_project_root "$file")" || return 1
  root="$(_tesl_project_mktemp_dir "$file" run-go)" || return 1
  out="$root/go"
  if [ "$debug" = "1" ]; then
    "$TESL_OCAML_COMPILER" "$file" --out "$out" --debug || { rm -rf "$root"; return 1; }
  else
    "$TESL_OCAML_COMPILER" "$file" --out "$out" || { rm -rf "$root"; return 1; }
  fi
  if [ ! -d "$out/cmd/app" ]; then
    echo "tesl run --backend go: $file does not define a main/server entrypoint" >&2
    rm -rf "$root"
    return 2
  fi
  binary="$root/tesl-app"
  (cd "$out" && "${TESL_GO:-go}" build -o "$binary" ./cmd/app) || { rm -rf "$root"; return 1; }
  if [ "$debug" = "1" ]; then
    TESL_DEBUG=1 TESL_DEBUG_ROOT="$project" "$binary" "$@"
  else
    "$binary" "$@"
  fi
  status=$?
  rm -rf "$root"
  return "$status"
}

_tesl_watch_go() {
  local file="$1" project root out binary pid="" previous="" current status
  shift
  project="$(_tesl_project_root "$file")" || return 1
  cleanup() {
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
    [ -n "$root" ] && rm -rf "$root"
  }
  trap 'exit 130' INT TERM HUP
  trap cleanup EXIT
  echo "[tesl watch] Watching $(_tesl_abspath "$file") and its imports (Ctrl+C to stop)"
  while true; do
    current="$file"
    deps="$(${TESL_OCAML_COMPILER} --deps "$file" 2>/dev/null || true)"
    while IFS= read -r dep; do
      [ -n "$dep" ] && current="${current}
$dep"
    done <<< "$deps"
    current="$(printf '%s\n' "$current" | while IFS= read -r dep; do printf '%s ' "$dep"; _tesl_file_mtime "$dep"; done | sort)"
    if [ "$current" != "$previous" ]; then
      previous="$current"
      [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
      [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
      [ -n "$root" ] && rm -rf "$root"
      root="$(_tesl_project_mktemp_dir "$file" watch-go)" || return 1
      out="$root/go"
      echo "[tesl watch] Compiling Go module..."
      if "$TESL_OCAML_COMPILER" "$file" --out "$out" && [ -d "$out/cmd/app" ] && \
          (cd "$out" && "${TESL_GO:-go}" build -o "$root/tesl-app" ./cmd/app); then
        binary="$root/tesl-app"
        echo "[tesl watch] Starting Go app..."
        "$binary" "$@" &
        pid=$!
        echo "[tesl watch] Go server running (pid $pid)"
      else
        echo "[tesl watch] Go compile failed — previous server was stopped" >&2
        pid=""
      fi
    fi
    sleep 0.3
  done
}

# Locate the templates dir (holds minimal/ api/ docker/).
# Prefer a live repo checkout (dev), else the store path baked by the preamble.
_tesl_templates_dir() {
  if [ -n "${TESL_REPO_ROOT:-}" ] && [ -d "$TESL_REPO_ROOT/templates" ]; then
    echo "$TESL_REPO_ROOT/templates"; return 0
  fi
  if [ -n "${TESL_TEMPLATES_DIR:-}" ] && [ -d "$TESL_TEMPLATES_DIR" ]; then
    echo "$TESL_TEMPLATES_DIR"; return 0
  fi
  return 1
}

# ── Bare invocation: default to the manifest's [project].entrypoint ─────────
# #46: the scaffolded README (and `tesl init`'s next-steps) document `tesl run`,
# `tesl test` and friends with NO file argument, but every file-taking verb
# hard-failed with a usage error — the README and the CLI contradicted each
# other. When a project verb is called with no file AND the nearest tesl.toml
# declares [project].entrypoint, use that (announced on stderr so the implicit
# choice is never silent). With no manifest / no entrypoint key the verb still
# prints its usage line, so a bare single-file workflow is unchanged.
_tesl_default_entry() {
  local usage="$1" root here entry path
  here="$(cd -P . 2>/dev/null && pwd -P)" || here="$PWD"
  root="$(_tesl_project_root_of_dir "$here")" || {
    echo "Usage: $usage" >&2
    echo "  (no tesl.toml in $here or a parent — no [project].entrypoint to default to)" >&2
    return 1; }
  entry="$(tesl_manifest_get "$root/tesl.toml" project entrypoint 2>/dev/null || true)"
  [ -n "$entry" ] || {
    echo "Usage: $usage" >&2
    echo "  ($root/tesl.toml declares no [project].entrypoint to default to)" >&2
    return 1; }
  case "$entry" in /*) path="$entry" ;; *) path="$root/$entry" ;; esac
  [ -f "$path" ] || {
    echo "error: [project].entrypoint \"$entry\" (from $root/tesl.toml) does not exist" >&2
    return 1; }
  # Keep the short spelling when we are already at the project root.
  [ "$root" = "$here" ] && path="$entry"
  echo "[tesl] no file given — using [project].entrypoint $path (from $root/tesl.toml)" >&2
  printf '%s\n' "$path"
}

# Quote a scalar for the small YAML plan passed to ZAP. Secrets never enter this
# plan: authentication values are referenced by environment variable name.
_tesl_yaml_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/}"
  value="${value//$'\r'/}"
  printf '"%s"' "$value"
}

# Run ZAP's local Automation Framework against a checked Tesl OpenAPI export.
# This deliberately does not start the application: callers choose the target
# deployment explicitly, which keeps CI and local scans equally predictable.
_tesl_dast() {
  local file="" target="" server="" spec="" report_dir="" scanner="zap"
  local active=0 allow_remote=0 auth_env="" cookie_env="" work="" plan="" generated=0 zap_port=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --server) server="${2:?tesl dast: --server requires a server name}"; shift 2 ;;
      --target) target="${2:?tesl dast: --target requires a URL}"; shift 2 ;;
      --spec) spec="${2:?tesl dast: --spec requires a file}"; shift 2 ;;
      --report-dir) report_dir="${2:?tesl dast: --report-dir requires a directory}"; shift 2 ;;
      --scanner) scanner="${2:?tesl dast: --scanner requires a scanner name}"; shift 2 ;;
      --zap-port) zap_port="${2:?tesl dast: --zap-port requires a port}"; shift 2 ;;
      --active) active=1; shift ;;
      --allow-remote) allow_remote=1; shift ;;
      --authorization-env) auth_env="${2:?tesl dast: --authorization-env requires an environment variable}"; shift 2 ;;
      --cookie-env) cookie_env="${2:?tesl dast: --cookie-env requires an environment variable}"; shift 2 ;;
      --help|-h)
        cat <<'EOF'
Usage: tesl dast <URL> [file.tesl] [options]
       tesl dast <file.tesl> <server> --target <URL> [options]

Options:
  --server NAME             Select the Tesl server for OpenAPI generation
  --target URL              Scan target (required unless given as first argument)
  --spec FILE               Use an existing OpenAPI file instead of generating one
  --report-dir DIR          Output directory (default: .tesl-stuff/dast)
  --scanner zap              Scanner backend (default: zap)
  --zap-port PORT            ZAP proxy port (default: TESL_ZAP_PORT or 8090)
  --active                  Enable active checks (otherwise passive baseline only)
  --allow-remote            Permit --active against a non-loopback target
  --authorization-env NAME  Inject Authorization header from an environment variable
  --cookie-env NAME         Inject Cookie header from an environment variable
EOF
        return 0
        ;;
      http://*|https://*)
        [ -z "$target" ] || { echo "tesl dast: multiple target URLs" >&2; return 2; }
        target="$1"; shift ;;
      *.tesl)
        [ -z "$file" ] || { echo "tesl dast: multiple source files" >&2; return 2; }
        file="$1"; shift ;;
      *)
        if [ -n "$file" ] && [ -z "$server" ]; then
          server="$1"; shift
        elif [ -z "$target" ] && [ -z "$file" ]; then
          target="$1"; shift
        else
          echo "tesl dast: unexpected argument $1" >&2; return 2
        fi
        ;;
    esac
  done

  [ -n "$target" ] || { echo "tesl dast: target URL is required" >&2; return 2; }
  case "$target" in
    http://*|https://*) ;;
    *) echo "tesl dast: target must start with http:// or https://" >&2; return 2 ;;
  esac
  case "$scanner" in
    zap) ;;
    *) echo "tesl dast: unsupported scanner '$scanner' (supported: zap)" >&2; return 2 ;;
  esac
  if [ "$active" -eq 1 ] && [ "$allow_remote" -ne 1 ]; then
    local authority host port_suffix
    authority="${target#*://}"
    authority="${authority%%[/?#]*}"
    case "$authority" in
      *'@'*) echo "tesl dast: target URL userinfo is not allowed" >&2; return 2 ;;
    esac
    case "$authority" in
      \[*\]*)
        host="${authority%%]*}]"
        port_suffix="${authority#"$host"}"
        ;;
      *)
        host="${authority%%:*}"
        port_suffix="${authority#"$host"}"
        ;;
    esac
    case "$port_suffix" in
      ''|:[0-9]*) ;;
      *) echo "tesl dast: invalid target URL authority" >&2; return 2 ;;
    esac
    case "$port_suffix" in *[!0-9:]*) echo "tesl dast: invalid target URL port" >&2; return 2 ;; esac
    case "$host" in
      localhost|127.0.0.1|'[::1]') ;;
      *) echo "tesl dast: --active against a non-loopback target requires --allow-remote" >&2; return 2 ;;
    esac
  fi
  local secret_env
  for secret_env in "$auth_env" "$cookie_env"; do
    [ -z "$secret_env" ] && continue
    case "$secret_env" in
      [0-9]*|*[!A-Za-z0-9_]*|'')
        echo "tesl dast: invalid environment variable name '$secret_env'" >&2; return 2 ;;
    esac
    [ -n "${!secret_env:-}" ] || {
      echo "tesl dast: authentication environment variable '$secret_env' is unset or empty" >&2
      return 2
    }
  done

  if [ -z "$file" ] && [ -z "$spec" ]; then
    file="$(_tesl_default_entry "tesl dast <URL> [file.tesl] [options]")" || return 1
  fi
  if [ -n "$file" ]; then
    [ -f "$file" ] || { echo "tesl dast: source file not found: $file" >&2; return 2; }
    file="$(_tesl_abspath "$file")" || { echo "tesl dast: cannot resolve source file: $file" >&2; return 2; }
  fi
  if [ -n "$spec" ]; then
    [ -f "$spec" ] || { echo "tesl dast: OpenAPI file not found: $spec" >&2; return 2; }
    spec="$(_tesl_abspath "$spec")" || { echo "tesl dast: cannot resolve OpenAPI file: $spec" >&2; return 2; }
  fi

  if [ -n "$file" ] && [ -z "$server" ]; then
    local servers server_count
    servers="$(awk '$1 == "server" { print $2 }' "$file" | sort -u)"
    server_count="$(printf '%s\n' "$servers" | awk 'NF { n++ } END { print n + 0 }')"
    if [ "$server_count" -ne 1 ]; then
      echo "tesl dast: source must define exactly one server when --server is omitted" >&2
      [ "$server_count" -gt 1 ] && echo "  servers: $(printf '%s' "$servers" | tr '\n' ' ')" >&2
      echo "  use --server NAME to select one" >&2
      return 2
    fi
    server="$servers"
  fi

  local root
  if [ -n "$file" ]; then root="$(_tesl_project_root "$file")"; else root="$PWD"; fi
  report_dir="${report_dir:-$root/.tesl-stuff/dast}"
  case "$report_dir" in
    /*) ;;
    *) report_dir="$PWD/$report_dir" ;;
  esac
  mkdir -p "$report_dir" || { echo "tesl dast: cannot create report directory: $report_dir" >&2; return 1; }
  chmod 700 "$report_dir" || { echo "tesl dast: cannot protect report directory: $report_dir" >&2; return 1; }
  report_dir="$(_tesl_abspath "$report_dir")" || {
    echo "tesl dast: cannot resolve report directory: $report_dir" >&2
    return 1
  }

  work="$(_tesl_mktemp_dir)" || { echo "tesl dast: cannot create temporary workspace" >&2; return 1; }
  cleanup() { trap - RETURN; rm -rf "$work"; }
  trap cleanup RETURN
  mkdir -p "$work/home"
  if [ -z "$spec" ]; then
    spec="$work/openapi.json"
    generated=1
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" generate-openapi "$file" "$server" --output "$spec" || {
      echo "tesl dast: OpenAPI generation failed" >&2
      return 1
    }
  fi

  local target_q include_q spec_q report_q auth_job cookie_job active_job auth_ref zap_bin
  zap_port="${zap_port:-${TESL_ZAP_PORT:-8090}}"
  target_q="$(_tesl_yaml_quote "$target")"
  include_q="$(_tesl_yaml_quote "$target/.*")"
  spec_q="$(_tesl_yaml_quote "$spec")"
  report_q="$(_tesl_yaml_quote "$report_dir")"
  auth_job=""
  if [ -n "$auth_env" ]; then
    auth_ref='${'"$auth_env"'}'
    auth_job="  - type: replacer
    parameters:
      deleteAllRules: false
    rules:
      - description: Tesl Authorization header
        matchType: req_header
        matchString: Authorization
        replacementString: \"$auth_ref\"
"
  fi
  cookie_job=""
  if [ -n "$cookie_env" ]; then
    auth_ref='${'"$cookie_env"'}'
    cookie_job="  - type: replacer
    parameters:
      deleteAllRules: false
    rules:
      - description: Tesl Cookie header
        matchType: req_header
        matchString: Cookie
        replacementString: \"$auth_ref\"
"
  fi
  active_job=""
  if [ "$active" -eq 1 ]; then
    active_job="  - type: activeScan
    parameters:
      context: tesl
      defaultStrength: Low
      defaultThreshold: Medium
      maxScanDurationInMins: 1
      delayInMs: 100
"
  fi
  plan="$work/plan.yaml"
  cat > "$plan" <<EOF
%YAML 1.2
---
env:
  contexts:
    - name: tesl
      urls:
        - $target_q
      includePaths:
        - $include_q
jobs:
$auth_job$cookie_job  - type: openapi
    parameters:
      apiFile: $spec_q
      targetUrl: $target_q
      context: tesl
  - type: passiveScan-wait
    parameters:
      maxDuration: 1
$active_job  - type: report
    parameters:
      template: traditional-json
      reportDir: $report_q
      reportFile: zap-report.json
  - type: exitStatus
    parameters:
      errorLevel: High
      warnLevel: Medium
      errorExitValue: 1
      warnExitValue: 1
      okExitValue: 0
EOF

  zap_bin="${TESL_ZAP:-zap}"
  case "$zap_port" in
    ''|*[!0-9]*|0) echo "tesl dast: ZAP port must be a positive number" >&2; return 2 ;;
  esac
  [ "$zap_port" -le 65535 ] || { echo "tesl dast: ZAP port must be at most 65535" >&2; return 2; }
  # A local app commonly listens on 8090 (and the target may use any port), so do not
  # let ZAP fail before scanning merely because its default proxy port is occupied.
  while [ "$zap_port" -lt 65535 ] && (exec 3<>"/dev/tcp/127.0.0.1/$zap_port") 2>/dev/null; do
    exec 3>&-
    zap_port=$((zap_port + 1))
  done
  if [ ! -x "$zap_bin" ]; then zap_bin="$(command -v "$zap_bin" 2>/dev/null || true)"; fi
  [ -n "$zap_bin" ] && [ -x "$zap_bin" ] || {
    echo "tesl dast: ZAP not found; install the Nix profile or set TESL_ZAP" >&2
    return 1
  }
  echo "tesl dast: scanning $target (reports: $report_dir)"
  if [ "$generated" -eq 1 ]; then echo "tesl dast: generated OpenAPI for $server"; fi
  # ZAP expands ${ENV_NAME} inside the plan; the secret itself stays outside
  # the generated specification and report files.
  # Keep scanner state isolated. The Nix wrapper seeds a writable, versioned
  # config under $HOME/.ZAP before ZAP opens the directory.
  HOME="$work/home" "$zap_bin" -dir "$work/home/.ZAP" -port "$zap_port" -silent -cmd -autorun "$plan"
}

# ── tesl.toml manifest reader (mirrors scripts/tesl-manifest.sh) ───────────
# tesl_manifest_get <file> <section> <key> -> prints value, rc 0 if found.
tesl_manifest_get() {
  local file="$1" section="$2" key="$3"
  [ -n "$file" ] && [ -n "$section" ] && [ -n "$key" ] || { echo "tesl_manifest_get: usage: <file> <section> <key>" >&2; return 2; }
  [ -f "$file" ] || { return 2; }
  awk -v want_section="$section" -v want_key="$key" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    {
      t = trim($0)
      if (t == "" || substr(t, 1, 1) == "#") next
      if (t ~ /^\[[^]]*\]$/) { cur = trim(substr(t, 2, length(t) - 2)); next }
      eq = index(t, "="); if (eq == 0) next
      k = trim(substr(t, 1, eq - 1)); v = trim(substr(t, eq + 1))
      if (cur != want_section || k != want_key) next
      if (substr(v, 1, 1) == "\"") {
        rest = substr(v, 2); endq = index(rest, "\"")
        if (endq > 0) print substr(rest, 1, endq - 1); else print rest
        found = 1; exit
      }
      hash = index(v, "#"); if (hash > 0) v = trim(substr(v, 1, hash - 1))
      print v; found = 1; exit
    }
    END { if (!found) exit 1 }
  ' "$file"
}

# Resolve postgres binaries: prefer PATH, else the flake's .#postgresql output.
_tesl_pg_resolve() {
  if command -v initdb >/dev/null 2>&1 && command -v pg_ctl >/dev/null 2>&1; then
    _TESL_PG_BIN=""; return 0
  fi
  local flake="${TESL_REPO_ROOT:-github:mtonnberg/tesl}"
  echo "tesl db: postgres not on PATH; resolving via 'nix build $flake#postgresql' ..." >&2
  if command -v nix >/dev/null 2>&1; then
    # `postgresql` is a multi-output derivation: --print-out-paths lists ALL of
    # them (e.g. the `-man` output sorts FIRST), so we must NOT just take the
    # first line — only the main `out` carries bin/initdb. Scan every printed
    # path and pick the one that actually has the binaries.
    local out paths
    paths="$(nix build "$flake#postgresql" --no-link --print-out-paths 2>/dev/null)"
    for out in $paths; do
      if [ -n "$out" ] && [ -x "$out/bin/initdb" ] && [ -x "$out/bin/pg_ctl" ]; then
        _TESL_PG_BIN="$out/bin"; return 0
      fi
    done
  fi
  echo "error: tesl could not find PostgreSQL binaries (initdb/pg_ctl) for the managed database." >&2
  echo "  Fix it one of these ways:" >&2
  echo "    - ensure 'nix' is available and online so 'tesl' can fetch PostgreSQL automatically, or" >&2
  echo "    - install PostgreSQL yourself so initdb/pg_ctl are on PATH, or" >&2
  echo "    - switch this project to an external database: set [database] mode = \"existing\" in tesl.toml" >&2
  echo "      and point TESL_POSTGRES_* at it." >&2
  return 1
}
_pg() { local tool="$1"; shift; if [ -n "${_TESL_PG_BIN:-}" ]; then "$_TESL_PG_BIN/$tool" "$@"; else "$tool" "$@"; fi; }

# Is something listening on 127.0.0.1:<port>?  Best-effort: prefer ss/netstat,
# fall back to a bash /dev/tcp probe.  rc 0 = in use.
_tesl_port_in_use() {
  local port="$1"
  # A connect attempt is the ONE probe with no tool-flag dialect: identical on
  # Linux, macOS and busybox. #46: macOS netstat has no `-ltn` (BSD flags), so
  # the netstat branch used to error out and report every port as free.
  ( exec 3<>"/dev/tcp/127.0.0.1/$port" ) >/dev/null 2>&1 && return 0
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -qE "127\.0\.0\.1:$port[[:space:]]|\*:$port[[:space:]]|0\.0\.0\.0:$port[[:space:]]" && return 0
    return 1
  fi
  if command -v netstat >/dev/null 2>&1; then
    # GNU netstat: -ltn.  BSD/macOS netstat: -an -p tcp (no -l/-t), and its
    # address column separates the port with a DOT (127.0.0.1.5432).
    { netstat -ltn 2>/dev/null || netstat -an -p tcp 2>/dev/null; } \
      | grep -qE "(127\.0\.0\.1|0\.0\.0\.0|\*|\[::\]|::)[.:]$port[[:space:]]" && return 0
    return 1
  fi
  return 1
}

# Does OUR managed cluster (at $PGDATA) own the listener on <port>?  rc 0 = yes.
#
# Reads $PGDATA/postmaster.pid FIRST (line 1 = PID, line 4 = port) so ownership
# can be decided WITHOUT the postgres binaries. This matters because
# _tesl_effective_managed_port runs before _tesl_pg_resolve: in a nix-managed
# project pg_ctl is not yet on PATH, so the old pg_ctl-only check always failed
# and our own running cluster was mistaken for a FOREIGN process holding the
# port — the resolver then picked a different (dead) port and `tesl run` timed
# out against it.  The pid file is written by postgres itself and needs no tools.
_tesl_pg_owns_port() {
  local pgdata="$1" port="$2"
  local pidfile="$pgdata/postmaster.pid"
  if [ -f "$pidfile" ]; then
    local pid pport
    pid="$(sed -n '1p' "$pidfile" 2>/dev/null)"
    pport="$(sed -n '4p' "$pidfile" 2>/dev/null)"
    # Stale pid file (process gone) => we do NOT own the port.
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
    [ "$pport" = "$port" ] && return 0
    return 1
  fi
  # No pid file: fall back to pg_ctl (only meaningful once pg is resolved).
  local status
  status="$(_pg pg_ctl -D "$pgdata" status 2>/dev/null)" || return 1
  echo "$status" | grep -q -- "-p\" \"$port\"\|-p $port\| $port " && return 0
  # Last resort: if our cluster is running at all, assume it owns its own port.
  _pg pg_ctl -D "$pgdata" status >/dev/null 2>&1
}

# Pick a stable, collision-resistant TCP port for a managed cluster, derived
# from the project's destination path so re-init of the same project is stable
# but two different projects rarely clash. Range 54000-54999 avoids the common
# 5432 (system Postgres) collision. Probes for a free port near the seed.
_tesl_pick_managed_port() {
  local seed_str="$1" base seed p i
  seed="$(printf '%s' "$seed_str" | cksum | cut -d' ' -f1)"
  base=$(( 54000 + (seed % 1000) ))
  for i in $(seq 0 50); do
    p=$(( base + i )); [ "$p" -gt 54999 ] && p=$(( 54000 + (p - 54999) ))
    if ! _tesl_port_in_use "$p"; then echo "$p"; return 0; fi
  done
  echo "$base"  # give up gracefully; start will report a clear error if taken
}

# Determine the EFFECTIVE managed-Postgres port for the project in $PWD, given
# the manifest's configured port. Writes the resolved port to stdout (rc 0), or
# rc 1 if no free port could be found (truly unrecoverable). Side effect: may
# persist a chosen port to <pgdir>/PORT so it is STABLE across runs.
#
#   $1 = configured port (from manifest/.env)   $2 = PGDIR (.tesl-postgres)
#   $3 = PGDATA
#
# Resolution order:
#   (a) a port already persisted in <pgdir>/PORT  -> reuse it (stable)
#   (b) the configured port is free OR owned by OUR cluster -> use it (normal case)
#   (c) the configured port is held by a FOREIGN process -> pick a free high port,
#       note it, and persist it to <pgdir>/PORT.
# A note explaining (c) is printed to stderr the first time a foreign collision
# is detected (i.e. when we have to deviate from the configured port).
_tesl_effective_managed_port() {
  local cfg_port="$1" pgdir="$2" pgdata="$3"
  local port_file="$pgdir/PORT"

  # (a) reuse a previously-persisted choice for stability across runs.
  if [ -f "$port_file" ]; then
    local saved; saved="$(tr -dc '0-9' < "$port_file" 2>/dev/null)"
    if [ -n "$saved" ]; then echo "$saved"; return 0; fi
  fi

  # (b) configured port is usable as-is: free, or already ours.
  if ! _tesl_port_in_use "$cfg_port" || _tesl_pg_owns_port "$pgdata" "$cfg_port"; then
    echo "$cfg_port"; return 0
  fi

  # (c) foreign process holds the configured port — pick a free one and persist.
  local picked; picked="$(_tesl_pick_managed_port "$pgdata")"
  if _tesl_port_in_use "$picked" && ! _tesl_pg_owns_port "$pgdata" "$picked"; then
    # Could not find a free port at all (the picked one is also occupied).
    return 1
  fi
  echo "tesl db: configured port $cfg_port is in use by another process;" \
       "using free port $picked for this project's managed database" >&2
  mkdir -p "$pgdir" 2>/dev/null || true
  echo "$picked" > "$port_file" 2>/dev/null || true
  echo "$picked"; return 0
}

# ── tesl db start|stop|status ──────────────────────────────────────────────
_tesl_db() {
  local SUB="${1:-status}"; shift || true
  local MANIFEST="./tesl.toml"
  local PGPORT PGUSER PGDB
  PGPORT="$(tesl_manifest_get "$MANIFEST" env TESL_POSTGRES_PORT 2>/dev/null || true)"; PGPORT="${PGPORT:-5432}"
  PGUSER="$(tesl_manifest_get "$MANIFEST" env TESL_POSTGRES_USER 2>/dev/null || true)"; PGUSER="${PGUSER:-app}"
  PGDB="$(tesl_manifest_get "$MANIFEST" env TESL_POSTGRES_DATABASE 2>/dev/null || true)"; PGDB="${PGDB:-app}"

  local PGDIR="${PWD}/.tesl-postgres"
  local PGDATA="$PGDIR/data"
  local PGLOG="$PGDIR/postgres.log"

  # Resolve the EFFECTIVE port: reuse a persisted choice, use the configured
  # port if free/ours, or fall back to a free high port if a FOREIGN process
  # holds the configured one (persisting it for stability). This lets EXISTING
  # projects whose manifest still says 5432 (or any occupied port) run cleanly.
  local EFFPORT
  if ! EFFPORT="$(_tesl_effective_managed_port "$PGPORT" "$PGDIR" "$PGDATA")"; then
    echo "tesl db: ERROR — configured port $PGPORT is in use and no free port could be found" >&2
    echo "  Set a free port in tesl.toml [env] TESL_POSTGRES_PORT (and .env), then retry." >&2
    return 1
  fi
  PGPORT="$EFFPORT"

  # Unix-socket paths are capped at ~107 bytes, so keep the socket in a short
  # stable tmp dir; the app connects over TCP (127.0.0.1) regardless.
  local PGSOCK="${TMPDIR:-/tmp}/tesl-pg-$(echo "$PGDATA" | cksum | cut -d' ' -f1)"
  mkdir -p "$PGSOCK" 2>/dev/null || true

  case "$SUB" in
    start)
      _tesl_pg_resolve || return 1
      if [ ! -f "$PGDATA/PG_VERSION" ]; then
        echo "tesl db: initializing managed Postgres cluster at $PGDATA"
        mkdir -p "$PGDIR"
        _pg initdb -D "$PGDATA" -A trust -U "$PGUSER" --locale=C >/dev/null
      fi
      if _pg pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
        echo "tesl db: Postgres already running ($PGDATA, port $PGPORT)"
      else
        # Guard against a foreign Postgres (e.g. a system install) already
        # holding our effective TCP port: if we proceed, pg_ctl can't bind and
        # the app would silently connect to the wrong server. Detect and abort
        # clearly. (The effective port was chosen to avoid this, but a race or
        # a stale persisted PORT could still collide.)
        if _tesl_port_in_use "$PGPORT" && ! _tesl_pg_owns_port "$PGDATA" "$PGPORT"; then
          echo "tesl db: ERROR — port $PGPORT (127.0.0.1) is already in use by another process" >&2
          echo "  This is not our managed cluster ($PGDATA)." >&2
          echo "  Set a free port in tesl.toml [env] TESL_POSTGRES_PORT (and .env), then retry." >&2
          return 1
        fi
        echo "tesl db: starting Postgres on port $PGPORT (data: $PGDATA)"
        if ! _pg pg_ctl -D "$PGDATA" -l "$PGLOG" \
          -o "-F -k '$PGSOCK' -p $PGPORT -c listen_addresses='127.0.0.1'" \
          -w start >/dev/null; then
          echo "tesl db: ERROR — Postgres failed to start on port $PGPORT" >&2
          [ -f "$PGLOG" ] && { echo "  --- last lines of $PGLOG ---" >&2; tail -n 15 "$PGLOG" >&2; }
          return 1
        fi
      fi
      if ! _pg createdb -h 127.0.0.1 -p "$PGPORT" -U "$PGUSER" "$PGDB" >/dev/null 2>&1; then
        # createdb fails harmlessly if the database already exists; only treat a
        # genuine inability to reach/create as an error.
        if ! _pg psql -h 127.0.0.1 -p "$PGPORT" -U "$PGUSER" -d "$PGDB" -tAc 'select 1' >/dev/null 2>&1; then
          echo "tesl db: ERROR — could not create or reach database '$PGDB' on 127.0.0.1:$PGPORT as '$PGUSER'" >&2
          return 1
        fi
      fi
      echo "tesl db: ready — database '$PGDB' as user '$PGUSER' at 127.0.0.1:$PGPORT"
      ;;
    stop)
      _tesl_pg_resolve || return 1
      if [ ! -f "$PGDATA/PG_VERSION" ]; then echo "tesl db: no managed cluster at $PGDATA"; return 0; fi
      if _pg pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
        _pg pg_ctl -D "$PGDATA" -m fast -w stop >/dev/null
        echo "tesl db: stopped Postgres at $PGDATA"
      else
        echo "tesl db: Postgres not running for $PGDATA"
      fi
      ;;
    status)
      _tesl_pg_resolve || return 1
      if [ ! -f "$PGDATA/PG_VERSION" ]; then echo "tesl db: no managed cluster (run 'tesl db start')"; return 0; fi
      if _pg pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
        echo "tesl db: running ($PGDATA, port $PGPORT)"
        _pg pg_isready -h 127.0.0.1 -p "$PGPORT" || true
      else
        echo "tesl db: stopped ($PGDATA)"
      fi
      ;;
    *) echo "Usage: tesl db <start|stop|status>" >&2; return 1 ;;
  esac
}

# If the current project is managed-mode, ensure Postgres is up AND point the
# app at the EFFECTIVE managed port (which may differ from the manifest/.env
# port when a foreign process holds the configured one). Exports
# TESL_POSTGRES_PORT/HOST so the running app overrides any stale .env value.
# Opt out of the autostart (but not the env override) with TESL_NO_DB_AUTOSTART=1.
# (Called by the `run` verb AFTER _tesl_load_dotenv.)
_tesl_db_autostart_if_managed() {
  [ -f "./tesl.toml" ] || return 0
  local mode; mode="$(tesl_manifest_get ./tesl.toml database mode 2>/dev/null || true)"
  [ "$mode" = "managed" ] || return 0

  local PGDIR="${PWD}/.tesl-postgres"
  local PGDATA="$PGDIR/data"
  local PGPORT; PGPORT="$(tesl_manifest_get ./tesl.toml env TESL_POSTGRES_PORT 2>/dev/null || true)"; PGPORT="${PGPORT:-5432}"

  # Resolve and pin the effective port so both `tesl db start` (below) and the
  # app agree. Persisting happens inside the resolver for the foreign-collision
  # case; here we just learn the value and export it for the app.
  local EFFPORT
  if EFFPORT="$(_tesl_effective_managed_port "$PGPORT" "$PGDIR" "$PGDATA")"; then
    export TESL_POSTGRES_PORT="$EFFPORT"
    export TESL_POSTGRES_HOST="127.0.0.1"
  fi

  [ "${TESL_NO_DB_AUTOSTART:-0}" = "1" ] && return 0
  # Surface (don't swallow) a PostgreSQL-resolution failure: otherwise the app
  # just fails later with a bare "connection refused" on the configured port.
  if ! _tesl_pg_resolve; then
    echo "tesl run: WARNING — could not start the managed database (PostgreSQL binaries unavailable);" \
         "the app will likely fail to connect to ${TESL_POSTGRES_HOST:-localhost}:${EFFPORT:-$PGPORT}." >&2
    return 0
  fi
  if _pg pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then return 0; fi
  echo "tesl run: managed database not running — starting it (TESL_NO_DB_AUTOSTART=1 to skip)" >&2
  if ! _tesl_db start >&2; then
    echo "tesl run: WARNING — managed database failed to start; the app may not be able to connect." >&2
  fi
}

# `tesl run` convenience: load ./.env (KEY="value" lines) into the environment
# for vars that are not already set, so a freshly-scaffolded managed project
# connects without a manual `source .env`. Already-set env wins; comments and
# malformed lines are skipped. Opt out with TESL_NO_DOTENV=1.
_tesl_load_dotenv() {
  [ "${TESL_NO_DOTENV:-0}" = "1" ] && return 0
  [ -f ./.env ] || return 0
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    key=${line%%=*}
    case "$key" in *[!A-Za-z0-9_]*|'') continue ;; esac
    printenv "$key" >/dev/null 2>&1 && continue   # already set: do not override
    val=${line#*=}
    val=${val#\"}; val=${val%\"}                  # strip one layer of double quotes
    export "$key=$val"
  done < ./.env
}

# Generate AGENTS.md (and a CLAUDE.md copy) for a scaffolded project.
_tesl_init_agents_md() {
  local out="$1" name="$2" template="$3" pgmode="$4"
  {
    echo "# Working on $name with an AI coding agent"
    echo ""
    echo "This project was scaffolded by \`tesl init\` (template: **$template**, database: **$pgmode**)."
    echo "This file (and its twin \`CLAUDE.md\`) tells a coding agent how to be productive here."
    echo ""
    echo "## What this project is"
    echo ""
    echo "A Tesl web service. The application lives in \`app.tesl\`; the project manifest is"
    echo "\`tesl.toml\`. Tesl's signature feature is **compile-time proofs**: values carry"
    echo "facts (e.g. \`::: TitleSafe title\`) that only a \`check\`/\`auth\`/\`codec\` boundary can"
    echo "mint, so a handler can trust its inputs without re-validating, and the type checker"
    echo "rejects code that drops a required proof."
    echo ""
    echo "## Commands (run from the project root)"
    echo ""
    echo '```sh'
    echo "tesl check app.tesl     # type-check + enforce proofs (do this after every edit)"
    echo "tesl run app.tesl       # compile and serve on \$PORT"
    echo "tesl test app.tesl      # run the test \"...\" blocks"
    echo "tesl build              # type-check + compile ([deploy].target in tesl.toml)"
    echo "tesl build --container  # ...or build a runnable Docker image"
    echo "#  the file argument is optional: with none, the verbs above use"
    echo "#  [project].entrypoint from tesl.toml"
    [ "$pgmode" = "managed" ] && echo "tesl db start|stop|status   # manage the project-local PostgreSQL"
    echo '```'
    echo ""
    echo "After ANY change to \`app.tesl\`, run \`tesl check app.tesl\` — proofs and the"
    echo "capability system are enforced there, and the error messages tell you exactly"
    echo "what is missing."
    echo ""
    echo "## Gotchas to watch for"
    echo ""
    echo "- **Capabilities are explicit.** A \`fn\`/\`handler\` can only do what its"
    echo "  \`requires [...]\` clause allows; \`main\`/\`serve\` decides which capabilities to grant."
    echo "- **Proofs cannot be fabricated.** Only a \`check\`, \`auth\`, or \`codec ... via\` can"
    echo "  produce a \`:::\` fact. Returning a value that carries a proof satisfies a \`?\`"
    echo "  return spec; minting one by hand will not type-check."
    if [ "$pgmode" != "none" ]; then
      echo "- **Database connection** comes from \`TESL_POSTGRES_*\` env (see \`.env\` / \`tesl.toml\`"
      echo "  \`[env]\`). Tables are auto-created on first boot — no migration step."
    fi
    echo ""
    echo "## Editor + MCP server + agent skills"
    echo ""
    echo "Tesl ships an MCP server and editor integration that give an agent live"
    echo "type-checking, jump-to-definition, and documentation search:"
    echo ""
    echo "- **MCP server** (\`editor/tesl-mcp\`): install it so your agent can call"
    echo "  \`tesl check\`/\`semantic-json\` and search the manual programmatically. See the"
    echo "  Tesl repo's \`editor/tesl-mcp/README.md\` for the install + client-config steps,"
    echo "  then point your agent client (Claude Code, etc.) at the server."
    echo "- **Agent skills**: the Tesl repo provides debugging/dev skills under its"
    echo "  \`.claude/\` directory; install or reference them so the agent knows the Tesl"
    echo "  workflow (check -> run -> test -> build) and the proof/capability idioms."
    echo "- **Docs for agents**: \`tesl help manual full\` prints the entire manual in one"
    echo "  shot — feed it to the model when it needs language reference."
    echo ""
    echo "## A good \"next change\""
    echo ""
    echo "Open \`app.tesl\`, add a new route to the \`api\` block plus a \`handler\` for it,"
    echo "wire it into the \`server\` block, then \`tesl check app.tesl\`. Add a \`test \"...\"\`"
    echo "block to cover it and run \`tesl test app.tesl\`."
  } > "$out"
}

# Emit .vscode/launch.json with Tesl debug + test profiles so F5/debug and the
# test codelens work out of the box (no manual copy from the repo). In managed
# mode the env block points the debugger at the project-local Postgres so a
# debug session connects without a separate `tesl db start`.
_tesl_init_vscode() {
  local dest="$1" pgmode="$2" pgport="$3" pguser="$4" pgdb="$5"
  local pghost="${6:-localhost}" pgpass="${7:-app}"
  mkdir -p "$dest/.vscode"
  # Always set TESL_DAP_LOG=stderr so a debug session emits verbose diagnostics
  # (compiler/dap resolution, breakpoints, DB connect) to the Debug Console —
  # makes "it didn't stop / it crashed" self-explanatory instead of silent.
  local pg_vars=""
  if [ "$pgmode" = "managed" ] || [ "$pgmode" = "existing" ]; then
    pg_vars=$(cat <<EOF
,
        "TESL_POSTGRES_HOST": "$pghost",
        "TESL_POSTGRES_PORT": "$pgport",
        "TESL_POSTGRES_USER": "$pguser",
        "TESL_POSTGRES_PASSWORD": "$pgpass",
        "TESL_POSTGRES_DATABASE": "$pgdb"
EOF
)
  fi
  local env_block
  env_block=$(cat <<EOF
      "env": {
        "TESL_DAP_LOG": "stderr"$pg_vars
      },
EOF
)
  {
    echo '{'
    echo '  "version": "0.2.0",'
    echo '  "configurations": ['
    echo '    {'
    echo '      "type": "tesl",'
    echo '      "request": "launch",'
    echo '      "name": "Debug Tesl program",'
    [ -n "$env_block" ] && echo "$env_block"
    echo '      "program": "${file}",'
    echo '      "mode": "program"'
    echo '    },'
    echo '    {'
    echo '      "type": "tesl",'
    echo '      "request": "launch",'
    echo '      "name": "Debug Tesl tests",'
    [ -n "$env_block" ] && echo "$env_block"
    echo '      "program": "${file}",'
    echo '      "mode": "test"'
    echo '    },'
    echo '    {'
    echo '      "type": "tesl",'
    echo '      "request": "attach",'
    echo '      "name": "Attach to running app (tesl run --debug)",'
    [ -n "$env_block" ] && echo "$env_block"
    echo '      "project": "${workspaceFolder}"'
    echo '    }'
    echo '  ]'
    echo '}'
  } > "$dest/.vscode/launch.json"
}

# ── tesl init ──────────────────────────────────────────────────────────────
_tesl_init() {
  local NAME="" TEMPLATE="" PGMODE="" YES=0 NOGIT=0 ans
  while [ $# -gt 0 ]; do
    case "$1" in
      --template) TEMPLATE="${2:?--template needs a value}"; shift 2 ;;
      --postgres) PGMODE="${2:?--postgres needs a value}"; shift 2 ;;
      --yes|-y)   YES=1; shift ;;
      --no-git)   NOGIT=1; shift ;;
      --help|-h)
        echo "Usage: tesl init [name] [--template api|minimal] [--postgres managed|existing|none] [--yes] [--no-git]"
        echo "  Scaffold a new Tesl project. With no flags, prompts interactively."
        return 0 ;;
      -*)         echo "tesl init: unknown flag $1" >&2; return 1 ;;
      *)          if [ -z "$NAME" ]; then NAME="$1"; else echo "tesl init: unexpected arg $1" >&2; return 1; fi; shift ;;
    esac
  done

  if [ -z "$NAME" ]; then
    if [ "$YES" = "1" ]; then NAME="demoapp"; else
      printf 'Project name [demoapp]: '; read -r NAME || true; NAME="${NAME:-demoapp}"
    fi
  fi
  if [ -z "$TEMPLATE" ]; then
    if [ "$YES" = "1" ]; then TEMPLATE="api"; else
      echo "Question 1 of 3  [#--]"
      echo "Template — what kind of app?"
      echo "  1) api      a PostgreSQL-backed CRUD service with proofs (recommended)"
      echo "  2) minimal  a tiny no-database service with proofs"
      printf 'Choose [1]: '; read -r ans || true
      case "${ans:-1}" in 2|minimal) TEMPLATE="minimal" ;; *) TEMPLATE="api" ;; esac
    fi
  fi
  case "$TEMPLATE" in api|minimal) ;; *) echo "tesl init: unknown template '$TEMPLATE' (api|minimal)" >&2; return 1 ;; esac

  local DEFAULT_PG; if [ "$TEMPLATE" = "api" ]; then DEFAULT_PG="managed"; else DEFAULT_PG="none"; fi
  if [ -z "$PGMODE" ]; then
    if [ "$YES" = "1" ] || [ "$TEMPLATE" = "minimal" ]; then PGMODE="$DEFAULT_PG"; else
      echo "Question 2 of 3  [##-]"
      echo "Database — where should your app store data?"
      echo "  1) managed   set one up for me (no install, lives in this project) (recommended)"
      echo "  2) existing  I'll connect my own Postgres"
      echo "  3) none      no database"
      printf 'Choose [1]: '; read -r ans || true
      case "${ans:-1}" in 2|existing) PGMODE="existing" ;; 3|none) PGMODE="none" ;; *) PGMODE="managed" ;; esac
    fi
  fi
  case "$PGMODE" in managed|existing|none) ;; *) echo "tesl init: unknown postgres mode '$PGMODE'" >&2; return 1 ;; esac

  local DEST="./$NAME"
  [ -e "$DEST" ] && { echo "tesl init: '$DEST' already exists" >&2; return 1; }

  if [ "$YES" != "1" ]; then
    echo "Question 3 of 3  [###]"
    echo "About to create: $DEST  (template=$TEMPLATE, postgres=$PGMODE, git=$([ "$NOGIT" = 1 ] && echo no || echo yes))"
    printf 'Proceed? [Y/n]: '; read -r ans || true
    case "${ans:-Y}" in n|N|no|NO) echo "Aborted."; return 1 ;; esac
  fi

  local TPL_ROOT; TPL_ROOT="$(_tesl_templates_dir)" || { echo "tesl init: cannot locate templates dir (set TESL_REPO_ROOT or reinstall)" >&2; return 1; }
  local TPL_DIR="$TPL_ROOT/$TEMPLATE"
  [ -d "$TPL_DIR" ] || { echo "tesl init: template dir missing: $TPL_DIR" >&2; return 1; }

  mkdir -p "$DEST"
  local f
  for f in app.tesl tesl.toml README.md; do
    sed "s/__APP_NAME__/$NAME/g" "$TPL_DIR/$f" > "$DEST/$f"
  done

  if [ "$PGMODE" != "$DEFAULT_PG" ]; then
    _tesl_sed_inplace "s/^mode = \".*\"/mode = \"$PGMODE\"/" "$DEST/tesl.toml" \
      || echo "tesl init: warning — could not set [database].mode in $DEST/tesl.toml" >&2
  fi

  # Managed mode: the project-local Postgres must NOT default to 5432, which a
  # system Postgres install commonly occupies — that collision is the headline
  # "tesl run -> connection refused / wrong database" failure. Pick a stable,
  # project-derived high port and bake it into tesl.toml [env] so `tesl db` and
  # the app agree. (Docker all-in-one keeps 5432 — it runs in an isolated netns.)
  if [ "$PGMODE" = "managed" ] && grep -q '^TESL_POSTGRES_PORT' "$DEST/tesl.toml"; then
    local MANAGED_PORT; MANAGED_PORT="$(_tesl_pick_managed_port "$(cd "$DEST" 2>/dev/null && pwd || echo "$DEST")")"
    _tesl_sed_inplace "s/^TESL_POSTGRES_PORT = \".*\"/TESL_POSTGRES_PORT = \"$MANAGED_PORT\"/" "$DEST/tesl.toml" \
      || echo "tesl init: warning — could not set [env].TESL_POSTGRES_PORT in $DEST/tesl.toml" >&2
  fi

  {
    echo "# Generated by 'tesl init' from tesl.toml [env] defaults."
    echo "# In managed mode these point at the project-local Postgres ('tesl db start')."
    awk '
      /^\[/{ sec=$0 }
      sec=="[env]" && /=/ && $1 !~ /^#/ {
        line=$0; sub(/[ \t]*#.*$/,"",line)
        eq=index(line,"="); if(eq==0) next
        k=line; sub(/[ \t]*=.*/,"",k); gsub(/[ \t]/,"",k)
        v=substr(line,eq+1); sub(/^[ \t]*/,"",v); sub(/[ \t]*$/,"",v)
        gsub(/^"|"$/,"",v)
        if(k!="") print k"="v
      }
    ' "$DEST/tesl.toml"
  } > "$DEST/.env"

  {
    echo "# Managed Postgres data (recreate with \`tesl db start\`)"
    echo ".tesl-postgres/"
    echo "# Local environment overrides"
    echo ".env"
    echo "# Nix build symlink"
    echo "result"
    echo "# Tesl build output (compiled Go module; recreate with any tesl command)"
    echo ".tesl-stuff/"
  } > "$DEST/.gitignore"

  _tesl_init_agents_md "$DEST/AGENTS.md" "$NAME" "$TEMPLATE" "$PGMODE"
  cp "$DEST/AGENTS.md" "$DEST/CLAUDE.md"

  # VSCode/VSCodium debug + test profiles so F5 and the test codelens work
  # out of the box (no manual launch.json copy).
  # Derive ALL connection vars from tesl.toml so launch.json agrees with
  # .env/tesl.toml — hardcoding host=127.0.0.1 / password="" here disagreed with
  # the manifest (localhost / app) and made a debug session fail auth against an
  # `existing` (password-protected) database.
  local VSC_PORT VSC_USER VSC_DB VSC_HOST VSC_PASS
  VSC_PORT="$(tesl_manifest_get "$DEST/tesl.toml" env TESL_POSTGRES_PORT 2>/dev/null || true)"; VSC_PORT="${VSC_PORT:-5432}"
  VSC_USER="$(tesl_manifest_get "$DEST/tesl.toml" env TESL_POSTGRES_USER 2>/dev/null || true)"; VSC_USER="${VSC_USER:-app}"
  VSC_DB="$(tesl_manifest_get "$DEST/tesl.toml" env TESL_POSTGRES_DATABASE 2>/dev/null || true)"; VSC_DB="${VSC_DB:-app}"
  VSC_HOST="$(tesl_manifest_get "$DEST/tesl.toml" env TESL_POSTGRES_HOST 2>/dev/null || true)"; VSC_HOST="${VSC_HOST:-localhost}"
  VSC_PASS="$(tesl_manifest_get "$DEST/tesl.toml" env TESL_POSTGRES_PASSWORD 2>/dev/null || true)"; VSC_PASS="${VSC_PASS:-app}"
  _tesl_init_vscode "$DEST" "$PGMODE" "$VSC_PORT" "$VSC_USER" "$VSC_DB" "$VSC_HOST" "$VSC_PASS"

  if [ "$NOGIT" != "1" ] && command -v git >/dev/null 2>&1; then
    ( cd "$DEST" && git init -q && git add -A && git commit -q -m "tesl init: scaffold $NAME ($TEMPLATE)" 2>/dev/null ) || true
  fi

  local PORT; PORT="$(tesl_manifest_get "$DEST/tesl.toml" env PORT 2>/dev/null || true)"; PORT="${PORT:-8086}"

  echo ""
  echo "Created '$NAME' with the '$TEMPLATE' template (postgres: $PGMODE)."
  echo ""
  echo "Next steps:"
  echo "  cd $NAME"
  [ "$PGMODE" = "managed" ] && echo "  tesl db start          # start the project-local Postgres"
  echo "  tesl run               # serve on http://localhost:$PORT (uses [project].entrypoint)"
  echo "  tesl test              # run the test \"...\" blocks"
  echo "  tesl build             # type-check + compile ([deploy].target = local)"
  echo "  tesl build --container # ...or produce a runnable Docker image"
  echo ""
  echo "Files: app.tesl, tesl.toml, .env, .gitignore, README.md, AGENTS.md, CLAUDE.md, .vscode/launch.json"
  echo "Learn more: tesl help manual   |   agent guide: AGENTS.md"
}

# ── tesl build ───────────────────────────────────────────────────────────
# The MODE comes from [deploy].target in tesl.toml (#46 — `tesl build` used to
# stage a Dockerfile and shell out to `docker` even for target = "local", whose
# documented meaning is "run the compiled binary directly"; that made the verb
# require Docker where the manifest said it should not):
#
#   target = "local"      -> compile the project (proofs enforced) into
#                            .tesl-stuff/go-build/ and build tesl-app for
#                            application modules. No Dockerfile, no docker,
#                            no daemon needed.
#   target = "container"  -> build a Linux tesl-app, stage a runtime-only
#                            Dockerfile, and build the image.
#   [deploy] absent       -> container, preserving the historical behaviour of
#                            manifests written before this key existed.
#
# `--local` / `--container` override the manifest; so do the container-only
# flags (--app-only/--with-postgres/--tag/--out/--no-docker), since asking for
# an image variant is itself a request for the container path.
_tesl_compile_go_file() {
  local entry="$1" requested_out="$2" project out
  project="$(_tesl_project_root "$entry")" || return 1
  if [ -n "$requested_out" ]; then
    out="$requested_out"
    case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
    if [ -e "$out" ]; then
      echo "tesl build --backend go: output directory already exists: $out" >&2
      return 1
    fi
  else
    out="$project/.tesl-stuff/go-build"
    rm -rf "$out"
  fi
  "$TESL_OCAML_COMPILER" "$entry" --out "$out" >/dev/null || return 1
  printf '%s\n' "$out"
}

_tesl_build_go() {
  local entry="$1" name="$2" requested_out="$3" out
  out="$(_tesl_compile_go_file "$entry" "$requested_out")" || return 1
  if [ -d "$out/cmd/app" ]; then
    (cd "$out" && "${TESL_GO:-go}" build -trimpath -o "$out/tesl-app" ./cmd/app) || return 1
    echo "tesl build: $name built Go binary — $entry → $out/tesl-app"
  else
    (cd "$out" && "${TESL_GO:-go}" build ./...) || return 1
    echo "tesl build: $name compiled Go module — $entry → $out"
  fi
}

_tesl_build() {
  _tesl_require_compiler
  local VARIANT="" TAG="" NO_DOCKER=0 OUT="" MODE=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --app-only)      VARIANT="app-only";  MODE="container"; shift ;;
      --with-postgres) VARIANT="all-in-one"; MODE="container"; shift ;;
      --tag)           TAG="${2:?--tag needs a value}"; MODE="container"; shift 2 ;;
      --no-docker)     NO_DOCKER=1; MODE="container"; shift ;;
      --out)           OUT="${2:?--out needs a value}"; MODE="container"; shift 2 ;;
      --container)     MODE="container"; shift ;;
      --local)         MODE="local"; shift ;;
      --help|-h)
        echo "Usage: tesl build [--local|--container] [--app-only|--with-postgres]"
        echo "                  [--tag NAME] [--no-docker] [--out DIR]"
        echo "  Build the project named by tesl.toml. Without a flag the mode comes from"
        echo "  [deploy].target: \"local\" compiles into .tesl-stuff/go-build/ (no Docker),"
        echo "  \"container\" stages a Dockerfile and builds the image."
        return 0 ;;
      -*)              echo "tesl build: unknown flag $1" >&2; return 1 ;;
      *)               echo "tesl build: unexpected arg $1" >&2; return 1 ;;
    esac
  done

  local MANIFEST="./tesl.toml"
  [ -f "$MANIFEST" ] || { echo "tesl build: no tesl.toml in $(pwd) (run 'tesl init' first)" >&2; return 1; }

  local NAME ENTRY PORT DBMODE TARGET
  NAME="$(tesl_manifest_get "$MANIFEST" project name 2>/dev/null || true)"; NAME="${NAME:-app}"
  ENTRY="$(tesl_manifest_get "$MANIFEST" project entrypoint 2>/dev/null || true)"; ENTRY="${ENTRY:-app.tesl}"
  PORT="$(tesl_manifest_get "$MANIFEST" env PORT 2>/dev/null || true)"; PORT="${PORT:-8086}"
  DBMODE="$(tesl_manifest_get "$MANIFEST" database mode 2>/dev/null || true)"; DBMODE="${DBMODE:-none}"
  TARGET="$(tesl_manifest_get "$MANIFEST" deploy target 2>/dev/null || true)"

  [ -f "$ENTRY" ] || { echo "tesl build: entrypoint '$ENTRY' not found" >&2; return 1; }

  if [ -z "$MODE" ]; then
    case "$TARGET" in
      local)     MODE="local" ;;
      container) MODE="container" ;;
      "")        MODE="container" ;;   # pre-[deploy] manifests: unchanged behaviour
      *)         echo "tesl build: unknown [deploy].target \"$TARGET\" (local|container); assuming container" >&2
                 MODE="container" ;;
    esac
  fi

  # ── Local build: compile + go-build the binary, no Docker involved ──────────
  if [ "$MODE" = "local" ]; then
    _tesl_build_go "$ENTRY" "$NAME" "" || return 1
    echo ""
    echo "Run it:"
    [ "$DBMODE" = "managed" ] && echo "  tesl db start          # start the project-local Postgres"
    echo "  tesl run $ENTRY   # serve on http://localhost:$PORT"
    echo ""
    echo "For a Docker image instead: tesl build --container (or set [deploy].target = \"container\")."
    return 0
  fi

  if [ -z "$VARIANT" ]; then
    if [ "$DBMODE" = "managed" ]; then VARIANT="all-in-one"; else VARIANT="app-only"; fi
  fi
  [ -z "$TAG" ] && TAG="$NAME"

  _tesl_build_go_container "$ENTRY" "$NAME" "$PORT" "$DBMODE" "$VARIANT" "$TAG" "$NO_DOCKER" "$OUT"
}

_tesl_build_go_container() {
  local entry="$1" name="$2" port="$3" dbmode="$4" variant="$5" tag="$6" no_docker="$7" requested_out="$8"
  local ctx generated template go revision created source
  if [ -n "$requested_out" ]; then
    ctx="$requested_out"
    mkdir -p "$ctx"
  else
    ctx="$(_tesl_project_mktemp_dir "$entry" container)" || return 1
  fi
  generated="$ctx/generated"
  rm -rf "$generated"
  if ! "$TESL_OCAML_COMPILER" "$entry" --out "$generated" >/dev/null; then
    echo "tesl build --backend go: failed to emit $entry" >&2
    return 1
  fi
  [ -d "$generated/cmd/app" ] || {
    echo "tesl build --backend go: $entry does not define a main/server entrypoint" >&2
    return 2
  }
  go="${TESL_GO:-go}"
  # This directory contains compiler output, not an application checkout. Go's
  # automatic VCS discovery can find an unrelated or incomplete parent .git.
  # The image's source revision is recorded explicitly below from the entrypoint.
  (cd "$generated" && GOOS=linux CGO_ENABLED=0 "$go" build -buildvcs=false -trimpath -o "$ctx/tesl-app" ./cmd/app) || {
    echo "tesl build --backend go: failed to build $entry for Linux" >&2
    return 1
  }
  rm -rf "$generated"
  if [ "$variant" = "all-in-one" ]; then
    template="$(_tesl_templates_dir)/docker/Dockerfile.all-in-one.tmpl"
  else
    template="$(_tesl_templates_dir)/docker/Dockerfile.app-only.tmpl"
  fi
  [ -f "$template" ] || {
    echo "tesl build --backend go: Docker template not found: $template" >&2
    return 1
  }
  revision="unknown"
  if command -v git >/dev/null 2>&1; then
    revision="$(git -C "$(dirname "$ENTRY")" rev-parse HEAD 2>/dev/null || true)"
  fi
  [ -n "$revision" ] || revision="unknown"
  created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  source="https://github.com/mtonnberg/tesl"
  sed -e "s|__APP_NAME__|$name|g" \
       -e "s|__PORT__|$port|g" \
       -e "s|__REVISION__|$revision|g" \
       -e "s|__CREATED__|$created|g" \
       -e "s|__SOURCE__|$source|g" "$template" > "$ctx/Dockerfile"
  cat > "$ctx/.dockerignore" <<'EOF'
*
!tesl-app
!Dockerfile
!.dockerignore
EOF
  echo "tesl build: staged Go binary Docker context at $ctx (port=$port)"
  if [ "$no_docker" = "1" ]; then
    echo "tesl build: --no-docker set; build context ready at $ctx"
    echo "  docker build -t $tag \"$ctx\""
    return 0
  fi
  command -v docker >/dev/null 2>&1 || { echo "tesl build: docker not found; context staged at $ctx" >&2; return 1; }
  docker build -t "$tag" "$ctx" || { echo "tesl build: docker build failed" >&2; return 1; }
  echo "Built Go image: $tag"
}

CMD="${1:-help}"
shift || true

# Public Go source emission command. `compile` remains an unadvertised
# compatibility alias for older scripts and editor integrations.
if [ "$CMD" = "emit" ]; then
  [ "${1:-}" = "go" ] || { echo "Usage: tesl emit go [file.tesl] [--out DIR]" >&2; exit 1; }
  shift
  CMD="compile"
fi

case "$CMD" in
  --test-name)
    # Top-level convenience form for running one Go test block.
    [ $# -ge 2 ] || { echo "Usage: tesl --test-name <name> [--test-kind <kind>] <file.tesl>" >&2; exit 1; }
    TEST_NAME="$1"; shift
    TEST_KIND=""
    if [ "${1:-}" = "--test-kind" ]; then
      TEST_KIND="${2:?--test-kind requires a kind argument}"
      shift 2
    fi
    [ $# -eq 1 ] || { echo "Usage: tesl --test-name <name> [--test-kind <kind>] <file.tesl>" >&2; exit 1; }
    _tesl_require_compiler
    _tesl_test_go_file "$1" "$TEST_NAME" "$TEST_KIND"
    exit $?
    ;;
  --debug)
    # Top-level Go debug emission. The compiler writes a temporary Go module and
    # prints its path; use `tesl run --debug` for launch/attach workflows.
    [ $# -ge 1 ] || { echo "Usage: tesl --debug [--test-name <name>] <file.tesl>" >&2; exit 1; }
    _tesl_require_compiler
    exec "$TESL_OCAML_COMPILER" --debug "$@"
    ;;
  --exe)
    [ $# -ge 1 ] || { echo "Usage: tesl --exe <file.tesl> [--out <path>]" >&2; exit 1; }
    _tesl_require_compiler
    exec "$TESL_OCAML_COMPILER" --exe "$@"
    ;;
  --deps)
    # Print all transitively imported local .tesl files, one per line. Used by
    # Go watch/debug tooling to build the dependency set to monitor.
    [ $# -ge 1 ] || { echo "Usage: tesl --deps <file.tesl>" >&2; exit 1; }
    _tesl_require_compiler
    exec "$TESL_OCAML_COMPILER" --deps "$@"
    ;;
  debug-inspect)
    FILE="${1:?debug-inspect requires a source file}"
    shift
    TESL_COMPILER="${TESL_COMPILER:-$TESL_OCAML_COMPILER}" \
      exec "${TESL_DEBUG_INSPECT_BIN:-tesl-debug-inspect}" --file "$FILE" "$@"
    ;;
  debug-attach)
    # Live attach to an ALREADY-RUNNING `tesl run --debug` process. The Go
    # client preserves the public flags and endpoint discovery.
    exec "${TESL_DEBUG_ATTACH_BIN:-tesl-debug-attach}" "$@"
    ;;
  compile)
    if [ "${1:-}" = "--backend" ]; then
      [ "${2:-}" = "go" ] || { echo "tesl emit go: only the Go backend is supported" >&2; exit 2; }
      shift 2
    fi
    if [ $# -eq 0 ]; then
      _TESL_ENTRY="$(_tesl_default_entry "tesl emit go [file.tesl]")" || exit 1
      set -- "$_TESL_ENTRY"
    fi
    FILE="$1"
    shift
    OUT_GO=""
    if [ "${1:-}" = "--out" ]; then
      OUT_GO="${2:?--out requires a directory}"
      shift 2
    fi
    [ $# -eq 0 ] || { echo "tesl emit go: unexpected argument $1" >&2; exit 2; }
    _tesl_require_compiler
    OUT_GO="$(_tesl_compile_go_file "$FILE" "$OUT_GO")" || exit 1
    echo "compiled Go module: $FILE → $OUT_GO"
    exit 0
    ;;
  dast)
    _tesl_dast "$@"
    exit $?
    ;;
  check)
    if [ $# -eq 0 ]; then
      _TESL_ENTRY="$(_tesl_default_entry "tesl check [file.tesl ...]")" || exit 1
      set -- "$_TESL_ENTRY"
    fi
    _tesl_check "$@"
    ;;
  check-json)
    [ $# -gt 0 ] || { echo "Usage: tesl check-json <file.tesl>" >&2; exit 1; }
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" --check-json "$@"
    ;;
  definition-json)
    [ $# -eq 3 ] || { echo "Usage: tesl definition-json <file.tesl> <line> <col>" >&2; exit 1; }
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" --definition-json "$@"
    ;;
  occurrences-json)
    [ $# -eq 3 ] || { echo "Usage: tesl occurrences-json <file.tesl> <line> <col>" >&2; exit 1; }
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" --occurrences-json "$@"
    ;;
  type-at-json)
    [ $# -eq 3 ] || { echo "Usage: tesl type-at-json <file.tesl> <line> <col>" >&2; exit 1; }
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" --type-at-json "$@"
    ;;
  field-at-json)
    [ $# -eq 3 ] || { echo "Usage: tesl field-at-json <file.tesl> <line> <col>" >&2; exit 1; }
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" --field-at-json "$@"
    ;;
  completions-json)
    [ $# -eq 3 ] || { echo "Usage: tesl completions-json <file.tesl> <line> <col>" >&2; exit 1; }
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" --completions-json "$@"
    ;;
  local-bindings-json)
    [ $# -gt 0 ] || { echo "Usage: tesl local-bindings-json <file.tesl>" >&2; exit 1; }
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" --local-bindings-json "$@"
    ;;
  semantic-json)
    [ $# -gt 0 ] || { echo "Usage: tesl semantic-json <file.tesl>" >&2; exit 1; }
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" --semantic-json "$@"
    ;;
  lint)
    [ $# -gt 0 ] || { echo "Usage: tesl lint <file.tesl> [more.tesl ...]" >&2; exit 1; }
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" --lint "$@"
    ;;
  fmt|format)
    [ $# -gt 0 ] || { echo "Usage: tesl fmt <file.tesl> [more.tesl ...]" >&2; exit 1; }
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" --fmt "$@"
    ;;
  fmt-check)
    [ $# -gt 0 ] || { echo "Usage: tesl fmt-check <file.tesl> [more.tesl ...]" >&2; exit 1; }
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" --fmt-check "$@"
    ;;
  run)
    # --debug: start the app with live thsl-src! checkpoints and the attach
    # control channel (unix socket / loopback TCP under .tesl-stuff/) so a
    # debugger can attach to the RUNNING process — arm/re-arm breakpoints,
    # inspect, resume — without relaunching. Costs checkpoint overhead; a
    # plain `tesl run` stays byte-for-byte the zero-residue release build.
    RUN_BACKEND="${TESL_BACKEND:-${TESL_DEFAULT_BACKEND:-go}}"
    TESL_RUN_DEBUG=0
    while true; do
      case "${1:-}" in
        --backend) RUN_BACKEND="${2:?--backend requires a backend name}"; shift 2 ;;
        --debug) TESL_RUN_DEBUG=1; shift ;;
        *) break ;;
      esac
    done
    if [ $# -eq 0 ]; then
      _TESL_ENTRY="$(_tesl_default_entry "tesl run [--debug] [file.tesl] [args…]")" || exit 1
      set -- "$_TESL_ENTRY"
    fi
    FILE="$1"
    shift
    [ "$RUN_BACKEND" = "go" ] || { echo "tesl run: only the Go backend is supported" >&2; exit 2; }
    _tesl_require_compiler
    _tesl_run_go_file "$FILE" "$TESL_RUN_DEBUG" "$@"
    exit $?
    ;;
  test)
    # Run generated Go tests in a temporary module.
    # Optional: --test-name "name"  runs only the named test case.
    #           --test-kind KIND    (test|api-test|load-test|doctest) disambiguates
    #           same-named blocks of different kinds — required to run a single
    #           api-test / load-test / doctest in isolation.
    TEST_NAME=""
    TEST_KIND=""
    TEST_BACKEND="go"
    TEST_WITH_DAST=0
    TEST_DAST_TARGET=""
    TEST_DAST_SERVER=""
    TEST_DAST_ACTIVE=0
    TEST_DAST_ALLOW_REMOTE=0
    while true; do
      case "${1:-}" in
        --backend)
          [ "${2:-}" = "go" ] || { echo "tesl test: only the Go backend is supported" >&2; exit 2; }
          shift 2
          ;;
        --test-name) TEST_NAME="${2:?--test-name requires a test name argument}"; shift 2 ;;
        --test-kind) TEST_KIND="${2:?--test-kind requires a kind argument}"; shift 2 ;;
        --with-dast|--also-run-dast) TEST_WITH_DAST=1; shift ;;
        --dast-target) TEST_DAST_TARGET="${2:?--dast-target requires a URL}"; shift 2 ;;
        --dast-server) TEST_DAST_SERVER="${2:?--dast-server requires a server name}"; shift 2 ;;
        --dast-active) TEST_DAST_ACTIVE=1; shift ;;
        --dast-allow-remote) TEST_DAST_ALLOW_REMOTE=1; shift ;;
        *) break ;;
      esac
    done
    if [ $# -eq 0 ]; then
       _TESL_ENTRY="$(_tesl_default_entry "tesl test [--test-name <name>] [--test-kind <kind>] [--with-dast --dast-target URL] [file.tesl ...]")" || exit 1
       set -- "$_TESL_ENTRY"
     fi
     if [ "$TEST_WITH_DAST" -eq 1 ] && [ "$#" -ne 1 ]; then
       echo "tesl test: --with-dast requires exactly one source file" >&2
       exit 2
     fi
    case "$TEST_BACKEND" in
      go)
        _tesl_require_compiler
        RET=0
         for FILE in "$@"; do
           _tesl_test_go_file "$FILE" "$TEST_NAME" "$TEST_KIND" || RET=$?
         done
         if [ "$RET" -eq 0 ] && [ "$TEST_WITH_DAST" -eq 1 ]; then
           DAST_ARGS=("$FILE" --target "$TEST_DAST_TARGET")
           [ -n "$TEST_DAST_SERVER" ] && DAST_ARGS+=(--server "$TEST_DAST_SERVER")
           [ "$TEST_DAST_ACTIVE" -eq 1 ] && DAST_ARGS+=(--active)
           [ "$TEST_DAST_ALLOW_REMOTE" -eq 1 ] && DAST_ARGS+=(--allow-remote)
           _tesl_dast "${DAST_ARGS[@]}" || RET=$?
         fi
         exit "$RET"
        ;;
    esac
    ;;
  mutate)
    # Mutation testing: perturb the program and confirm the tests catch it.
     # Forwards to the compiler's `--mutate <file>
    # [extra-test-files…]`, which
    # compiles + runs each mutant and prints a "Mutation score" report. This is
    # the first-class command the docs (best-practices) reference as `tesl mutate`.
     [ $# -gt 0 ] || { echo "Usage: tesl mutate <file.tesl> [more-test-files.tesl ...]" >&2; exit 1; }
    _tesl_require_compiler
    exec "$TESL_OCAML_COMPILER" --mutate "$@"
    ;;
  watch)
    if [ "${1:-}" = "--backend" ]; then
      [ "${2:-}" = "go" ] || { echo "tesl watch: only the Go backend is supported" >&2; exit 2; }
      shift 2
    fi
    if [ $# -eq 0 ]; then
      _TESL_ENTRY="$(_tesl_default_entry "tesl watch [file.tesl]")" || exit 1
      set -- "$_TESL_ENTRY"
    fi
    FILE="$1"
    shift
    _tesl_require_compiler
    _tesl_watch_go "$FILE" "$@"
    exit $?
    ;;
  generate)
    SUBCMD="${1:-help}"
    shift || true
    case "$SUBCMD" in
      ir)
        FILE="${1:?Usage: tesl generate ir <file.tesl>}"
        _tesl_require_compiler
        "$TESL_OCAML_COMPILER" --ir "$FILE"
        ;;
      ts)
        FILE="${1:?Usage: tesl generate ts <file.tesl>}"
        shift || true
        _tesl_require_compiler
        if [ "${1:-}" = "--out" ]; then
          "$TESL_OCAML_COMPILER" --generate-ts "$FILE" --out "${2:?--out requires a filename}"
        else
          "$TESL_OCAML_COMPILER" --generate-ts "$FILE"
        fi
        ;;
      elm)
        FILE="${1:?Usage: tesl generate elm <file.tesl>}"
        shift || true
        _tesl_require_compiler
        if [ "${1:-}" = "--out" ]; then
          "$TESL_OCAML_COMPILER" --generate-elm "$FILE" --out "${2:?--out requires a filename}"
        else
          "$TESL_OCAML_COMPILER" --generate-elm "$FILE"
        fi
        ;;
      help|*)
        echo "Usage: tesl generate <ir|ts|elm> <file.tesl> [--out <file>]"
        ;;
    esac
    ;;
  validate)
    if [ $# -eq 0 ]; then
      _TESL_ENTRY="$(_tesl_default_entry "tesl validate [file.tesl ...]")" || exit 1
      set -- "$_TESL_ENTRY"
    fi
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" --check "$@" \
      && "$TESL_OCAML_COMPILER" --lint "$@" \
      && "$TESL_OCAML_COMPILER" --fmt-check "$@"
    ;;
  init)
    _tesl_init "$@"
    ;;
  db)
    _tesl_db "$@"
    ;;
  build)
    _tesl_build "$@"
    ;;
  clean)
    # Remove known transient compiler, binary, test, and debug outputs. Keep
    # unrelated .tesl-stuff subdirectories (for example a future cache) and
    # never touch .tesl-postgres/ (real data).
    ROOT="$(_tesl_project_root_of_dir "$PWD")" || ROOT="$PWD"
    BUILD_ROOT="$(_tesl_build_root "$ROOT")"
    STUFF_ROOT="$ROOT/.tesl-stuff"
    removed=0
    for path in "$BUILD_ROOT" "$ROOT/.tesl-stuff/go-build" \
                "$ROOT/.tesl-stuff/debug.sock" "$ROOT/.tesl-stuff/debug.port" "$ROOT/.tesl-stuff/debug.token" \
                "$ROOT/.tesl-stuff"/tesl.* "$ROOT/.tesl-stuff"/go-emit-*; do
      [ -e "$path" ] || [ -L "$path" ] || continue
      rm -rf "$path"
      echo "tesl clean: removed $path"
      removed=1
    done
    [ "$removed" -eq 1 ] || echo "tesl clean: nothing to remove ($STUFF_ROOT has no generated output)"
    ;;
  version|--version|-v)
    # A stable version string plus the resolved compiler path — the latter's Nix
    # store hash disambiguates which of several installed store builds is running.
    echo "tesl ${TESL_VERSION:-dev}"
    [ -n "${TESL_OCAML_COMPILER:-}" ] && echo "compiler: $TESL_OCAML_COMPILER"
    ;;
  doc|--doc-json|explain)
    # `tesl doc` / `tesl doc <name>` / `tesl doc Tesl.<Module>` / `tesl explain <CODE>`
    # are pure compiler surfaces, so they forward verbatim.
    #
    # These were UNREACHABLE from an installed CLI until 2026-07-29: there was no
    # arm for them, so the `*)` branch printed "unknown command" while
    # `main.exe doc` worked fine — i.e. the documented stdlib-transparency
    # command failed for everyone who installed via the flake, and only worked
    # for people running the compiler out of a checkout. That matters
    # disproportionately for Tesl.Crypto, whose whole rule-4 promise is that
    # `tesl doc` names the primitive underneath every friendly function name.
    _tesl_require_compiler
    if [ "$CMD" = "--doc-json" ]; then
      "$TESL_OCAML_COMPILER" --doc-json "$@"
    else
      "$TESL_OCAML_COMPILER" "$CMD" "$@"
    fi
    ;;
  help|--help|-h)
    if [ -n "$1" ]; then
      # Pass help subcommands to the compiler
      _tesl_require_compiler
      "$TESL_OCAML_COMPILER" --help "$@"
    else
      cat <<'EOF'
Tesl language CLI

Usage:
  tesl init                [name] [--template api|minimal]   Scaffold a new project
                           [--postgres managed|existing|none] [--yes] [--no-git]
  tesl db                  start|stop|status                 Manage the project-local Postgres
    tesl build               [--local|--container]  Build the project
                           [--app-only|--with-postgres]      ([deploy].target = "local") or a
                           [--tag NAME] [--no-docker]        runnable Docker image
                           [--out DIR]                       ([deploy].target = "container")
    tesl emit go             [file.tesl]  Emit Go source (advanced)
  tesl clean                                              Delete the project's build output (.tesl-stuff/)
  tesl check               [file.tesl ...]               Type-check without output
  tesl lint                <file.tesl> [more.tesl ...]   Run the opinionated linter
  tesl fmt                 <file.tesl> [more.tesl ...]   Format in-place
  tesl fmt-check           <file.tesl> [more.tesl ...]   Check formatting without modifying
  tesl validate            [file.tesl ...]               Run check + lint + fmt-check
   tesl run                 [--debug] [file.tesl] [args…]  Compile then execute
                            (--debug: live checkpoints + attach endpoint under .tesl-stuff/)
   tesl dast                 <URL> [file.tesl]             Run ZAP against the checked OpenAPI surface
                            [--server NAME] [--active]     (active remote scans also require --allow-remote)
   tesl debug-attach        [--project DIR] [command…]     Attach to a `tesl run --debug` process
                           (arm breakpoints, inspect, resume — see tesl debug-attach --help)
     tesl test                [file.tesl ...]  Compile and run tests
                            [--with-dast --dast-target URL] optionally scan after tests pass
   tesl mutate              <file>  Run mutation testing
    tesl watch               [file.tesl] [args…]  Watch and restart on changes

  A [file.tesl] argument is OPTIONAL inside a project: with none, the verb uses
  [project].entrypoint from the nearest tesl.toml.
  tesl generate ir         <file.tesl>                   Emit API IR as JSON
  tesl generate ts         <file.tesl> [--out <file>]    Emit TypeScript + Zod client
  tesl generate elm        <file.tesl> [--out <file>]    Emit Elm HTTP client

Documentation:
  tesl help manual                                             Show full documentation index
  tesl help manual <section>                                   Show specific documentation section
  tesl help manual full                                        Show ALL documentation (for LLMs)
  tesl help examples                                           List all examples
  tesl help search <query>                                     Search documentation

Editor / Language Server (LSP) flags:
  tesl check-json          <file.tesl>                   Type-check, diagnostics as IR-2 JSON
  tesl local-bindings-json <file.tesl>                   Inferred local binding types as JSON
  tesl semantic-json       <file.tesl>                   Full module semantic snapshot as JSON
  tesl definition-json     <file.tesl> <line> <col>      Jump-to-definition location as JSON
  tesl occurrences-json    <file.tesl> <line> <col>      Same-file symbol occurrences as JSON
  tesl type-at-json        <file.tesl> <line> <col>      Inferred type at cursor as JSON
  tesl field-at-json       <file.tesl> <line> <col>      Record field info at cursor as JSON
  tesl completions-json    <file.tesl> <line> <col>      Context-aware completions as JSON

Verbose logging:
  TESL_VERBOSE=1 tesl run your-api.tesl

Logs HTTP requests/responses, SQL queries, queue operations, and
pub/sub events to stderr. Zero overhead when TESL_VERBOSE is unset.
EOF
    fi
    ;;
  *)
    echo "unknown command: $CMD  (try: tesl help)" >&2
    exit 1
    ;;
esac
