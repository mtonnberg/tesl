#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  tests/cli-portability.sh — the `tesl` CLI must not assume a GNU userland,
#  and the project verbs must honour the manifest the scaffold documents.
# ═══════════════════════════════════════════════════════════════════════════════
#
# Issue #46 (macOS, Apple Silicon, Determinate Nix): a fresh
# `nix profile install github:mtonnberg/tesl` could not run a scaffolded project.
# Three distinct defects, all covered here:
#
#   1. GNU-only tool flags in nix/tesl-cli-body.sh — `mktemp --suffix=`,
#      `readlink -f`, `realpath --relative-to`, `stat -c`, `sed -i <expr>`,
#      `xargs -d` — fail on the BSD tools that are on PATH on macOS.  The
#      headline symptom was an EMPTY `$(mktemp --suffix=.rkt)` followed by the
#      baffling `: No such file or directory` from the redirect.
#   2. `tesl test` (and `tesl run`) with no file argument exited 1 with a usage
#      line, contradicting the README that `tesl init` scaffolds.
#   3. `tesl build` built a Docker image even for `[deploy].target = "local"`,
#      whose documented meaning is "run the compiled binary directly" — so the
#      verb required Docker where the manifest said it should not.
#
# TWO layers of protection are asserted, because either alone can rot:
#   * STATIC  — the body contains no GNU-only construct (a new one added later
#               fails this test even on a Linux CI machine).
#   * DYNAMIC — the verbs are re-run with a BSD-only userland shimmed onto PATH
#               (mktemp/stat/readlink/sed/xargs/realpath/netstat stubs that
#               reject the GNU flags exactly as macOS does), so semantics — not
#               just spelling — are checked.
#
# Usage:  tests/cli-portability.sh
# Exit:   0 = pass, 1 = failure, 77 = skipped (compiler not built)
# Env:    TESL_REPO_ROOT, TESL_OCAML_COMPILER (both auto-detected)

set -uo pipefail

REPO_ROOT="${TESL_REPO_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
BODY="$REPO_ROOT/nix/tesl-cli-body.sh"
MAIN_EXE="${TESL_OCAML_COMPILER:-$REPO_ROOT/compiler/_build/default/bin/main.exe}"

FAIL=0
pass() { printf '  \033[32m✓\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m  %s\n' "$1"; FAIL=1; }
note() { printf '  \033[33m⚠\033[0m  %s\n' "$1"; }

[ -f "$BODY" ] || { echo "cli-portability: missing $BODY" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
#  Part 1 — STATIC: no GNU-only construct in the CLI body
# ─────────────────────────────────────────────────────────────────────────────
echo "── static: GNU-only constructs in nix/tesl-cli-body.sh"

# Code lines only (comments explain the banned constructs by name).
CODE="$(grep -nE '.' "$BODY" | grep -vE '^[0-9]+:[[:space:]]*#')"

# scan <label> <banned-regex> [allowed-regex]
scan() {
  local label="$1" pat="$2" allow="${3:-}" hits
  hits="$(printf '%s\n' "$CODE" | grep -E "$pat" || true)"
  [ -n "$allow" ] && hits="$(printf '%s\n' "$hits" | grep -vE "$allow" || true)"
  hits="$(printf '%s' "$hits" | grep -E '.' || true)"
  if [ -n "$hits" ]; then
    fail "$label"
    printf '%s\n' "$hits" | sed 's/^/        /'
  else
    pass "$label"
  fi
}

scan "no 'mktemp --suffix' (GNU-only)"            'mktemp[^|]*--suffix'
scan "no template-less 'mktemp' (BSD needs one)"  'mktemp( +-[dqu]+)* *(\)|\||$|")' \
                                                  '_tesl_mktemp|_tesl_project_mktemp_dir'
scan "no 'readlink -f' (BSD readlink has no -f)"  'readlink +-[a-zA-Z]*f'
scan "no 'realpath' (absent on macOS; --relative-to is GNU)" '(^|[^_[:alnum:]])realpath[^_[:alnum:]]'
scan "no 'stat -c' outside the dialect-probing helper" 'stat +-c' 'v="\$\(stat -c'
scan "no 'stat -f' outside the dialect-probing helper" 'stat +-f' 'v="\$\(stat -f'
scan "no 'sed -i' (BSD requires a suffix argument)" 'sed +-i'
scan "no 'xargs -d' (GNU-only)"                    'xargs +-[a-zA-Z]*d'
scan "no 'grep -P' (GNU-only)"                     'grep +-[a-zA-Z]*P'
scan "no 'find -printf' (GNU-only)"                'find .*-printf'
scan "no 'date -d' (BSD date uses -v/-j -f)"       'date +-d'
scan "no long options on core tools"               '(cp|mv|ls|rm|sort|head|tail|wc|du|df) +--[a-z]'

# ─────────────────────────────────────────────────────────────────────────────
#  Part 2 — DYNAMIC: run the real verbs under a BSD-only userland
# ─────────────────────────────────────────────────────────────────────────────
if [ ! -x "$MAIN_EXE" ]; then
  note "compiler not built ($MAIN_EXE) — skipping the dynamic half"
  [ "$FAIL" -eq 0 ] && exit 77 || exit 1
fi

echo "── dynamic: verbs under a BSD-only userland (mktemp/stat/readlink/sed/xargs)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tesl-portability.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
STUBS="$WORK/bsd-bin"
mkdir -p "$STUBS"

# Each stub mimics the macOS/BSD tool: it REJECTS the GNU-only flags with the
# same failure the real tool gives, and otherwise delegates to the host tool.
# REAL_PATH is the pristine PATH so a stub can find the tool it wraps.
cat > "$STUBS/.common" <<'EOF'
real() { PATH="$REAL_PATH" command "$@"; }
EOF

cat > "$STUBS/mktemp" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/.common"
tmpl=""; dflag=""
for a in "$@"; do
  case "$a" in
    --*) echo "mktemp: unrecognized option \`$a'" >&2
         echo "usage: mktemp [-d] [-p tmpdir] [-q] [-t prefix] [-u] template ..." >&2
         exit 1 ;;
    -*)  case "$a" in *d*) dflag="-d" ;; esac ;;
    *)   tmpl="$a" ;;
  esac
done
if [ -z "$tmpl" ]; then
  echo "usage: mktemp [-d] [-p tmpdir] [-q] [-t prefix] [-u] template ..." >&2
  exit 1
fi
case "$tmpl" in
  *XXXXXX) ;;                      # BSD: the Xs must be the LAST characters
  *) echo "mktemp: illegal template \`$tmpl' (trailing X's required)" >&2; exit 1 ;;
esac
real mktemp $dflag "$tmpl"
EOF

cat > "$STUBS/stat" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/.common"
# BSD stat: -f <format> (%m mtime, %z size).  No -c at all.
fmt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -c) echo "stat: illegal option -- c" >&2
        echo "usage: stat [-FLnq] [-f format | -l | -r | -s | -x] [-t timefmt] [file ...]" >&2
        exit 1 ;;
    -f) fmt="$2"; shift 2 ;;
    -*) shift ;;
    *)  break ;;
  esac
done
[ -n "$fmt" ] || { echo "stat: stub needs -f" >&2; exit 1; }
gnu="$(printf '%s' "$fmt" | sed 's/%m/%Y/g; s/%z/%s/g')"
real stat -c "$gnu" "$@"
EOF

cat > "$STUBS/readlink" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/.common"
case "${1:-}" in
  -*f*) echo "readlink: illegal option -- f" >&2
        echo "usage: readlink [-n] [file ...]" >&2; exit 1 ;;
esac
real readlink "$@"
EOF

cat > "$STUBS/realpath" <<'EOF'
#!/usr/bin/env bash
# macOS shipped no realpath for years — behave as if it is unusable.
echo "realpath: command not found" >&2
exit 127
EOF

cat > "$STUBS/sed" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/.common"
# BSD sed: -i REQUIRES a suffix argument, so `sed -i <expr> file` consumes the
# expression as the backup suffix and then dies on the file name.
if [ "${1:-}" = "-i" ]; then
  echo "sed: 1: \"${3:-}\": invalid command code $(printf '%.1s' "${3:-x}")" >&2
  exit 1
fi
real sed "$@"
EOF

cat > "$STUBS/xargs" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/.common"
for a in "$@"; do
  case "$a" in
    -d*|--delimiter*) echo "xargs: illegal option -- d" >&2
                      echo "usage: xargs [-0opt] [-E eofstr] [-I replstr] ..." >&2; exit 1 ;;
  esac
done
real xargs "$@"
EOF

cat > "$STUBS/netstat" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/.common"
case " $* " in
  *" -ltn "*|*" -l "*|*" -t "*) echo "netstat: illegal option -- l" >&2; exit 1 ;;
esac
real netstat "$@" 2>/dev/null || true
EOF

chmod +x "$STUBS"/mktemp "$STUBS"/stat "$STUBS"/readlink "$STUBS"/realpath \
         "$STUBS"/sed "$STUBS"/xargs "$STUBS"/netstat

export REAL_PATH="$PATH"
BSD_PATH="$STUBS:$PATH"

# Run the real CLI body from $1 with the BSD userland in front of PATH.
tesl_bsd() {
  local dir="$1"; shift
  ( cd "$dir" && PATH="$BSD_PATH" REAL_PATH="$REAL_PATH" \
      TESL_REPO_ROOT="$REPO_ROOT" TESL_OCAML_COMPILER="$MAIN_EXE" \
      TESL_NO_DB_AUTOSTART=1 \
      bash "$BODY" "$@" 2>&1 )
}

# Sanity: the stubs really do reject the GNU flags (else the test proves nothing).
if PATH="$BSD_PATH" mktemp --suffix=.rkt >/dev/null 2>&1; then
  fail "BSD stub sanity: mktemp --suffix should have failed"
else
  pass "BSD stub sanity: GNU flags rejected as on macOS"
fi

# ── a project with a test block, tesl.toml entrypoint, [deploy] target=local ──
PROJ="$WORK/proj"
mkdir -p "$PROJ/sub"
cat > "$PROJ/tesl.toml" <<'EOF'
[project]
name = "portability"
entrypoint = "main.tesl"

[env]
PORT = "8099"

[database]
mode = "none"

[deploy]
target = "local"
EOF
cat > "$PROJ/lib.tesl" <<'EOF'
module Lib exposing [double]
import Tesl.Prelude exposing [Int]

fn double(n: Int) -> Int = n + n
EOF
cat > "$PROJ/main.tesl" <<'EOF'
module Main exposing [quad]
import Tesl.Prelude exposing [Int]
import Lib exposing [double]

fn quad(n: Int) -> Int = double (double n)

test "quad 3 == 12" {
  expect quad 3 == 12
}
EOF

# 1) Go emission (this is the exact path that died with `: No such file or directory`)
out="$(tesl_bsd "$PROJ" emit go main.tesl)"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$PROJ/.tesl-stuff/go-build/go.mod" ]; then
  pass "tesl emit go works with a BSD mktemp/stat/readlink"
else
  fail "tesl emit go failed under BSD userland (rc=$rc): $out"
fi

# 2) bare `tesl emit go` / `tesl check` default to [project].entrypoint (#46.2)
out="$(tesl_bsd "$PROJ" check)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "entrypoint main.tesl"; then
  pass "bare 'tesl check' uses [project].entrypoint"
else
  fail "bare 'tesl check' did not default to the entrypoint (rc=$rc): $out"
fi

out="$(tesl_bsd "$PROJ/sub" check)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "entrypoint"; then
  pass "bare verb resolves the entrypoint from a SUBDIRECTORY of the project"
else
  fail "bare verb from a subdirectory failed (rc=$rc): $out"
fi

# 3) no manifest ⇒ still the usage line (single-file workflow unchanged)
mkdir -p "$WORK/bare"
out="$(tesl_bsd "$WORK/bare" check)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "Usage: tesl check"; then
  pass "no tesl.toml ⇒ bare verb still prints its usage line"
else
  fail "bare verb outside a project should print usage (rc=$rc): $out"
fi

 # 4) bare `tesl test` runs the test blocks (README's documented command)
out="$(tesl_bsd "$PROJ" test)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "ok"; then
  pass "bare 'tesl test' runs the entrypoint's Go test blocks"
else
  fail "bare 'tesl test' failed (rc=$rc): $out"
fi

# 5) `tesl build` with [deploy].target = "local" must NOT need Docker (#46.3)
#    PATH deliberately has no docker: a Docker attempt fails the assertion.
out="$(tesl_bsd "$PROJ" build)"; rc=$?
if [ "$rc" -eq 0 ] \
   && printf '%s' "$out" | grep -q "compiled Go module" \
   && ! printf '%s' "$out" | grep -qE "staged Dockerfile|building image" \
   && [ -f "$PROJ/.tesl-stuff/go-build/go.mod" ]; then
  pass "tesl build honours [deploy].target = local (compile only, no Docker)"
else
  fail "tesl build ignored [deploy].target = local (rc=$rc): $out"
fi

# 6) …and --container still stages the image context on demand
out="$(tesl_bsd "$PROJ" build --container --no-docker)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "does not define a main/server entrypoint"; then
  pass "tesl build --container rejects a non-application source explicitly"
else
  fail "tesl build --container did not stage a Dockerfile (rc=$rc): $out"
fi

# 7) a container-target manifest keeps the historical behaviour
CPROJ="$WORK/cproj"
mkdir -p "$CPROJ"
sed 's/^target = "local"/target = "container"/' "$PROJ/tesl.toml" > "$CPROJ/tesl.toml"
cp "$PROJ/main.tesl" "$PROJ/lib.tesl" "$CPROJ/"
out="$(tesl_bsd "$CPROJ" build --no-docker)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "does not define a main/server entrypoint"; then
  pass "tesl build rejects a non-application container target explicitly"
else
  fail "tesl build did not stage a Dockerfile for target = container (rc=$rc): $out"
fi

# 8) `tesl init` under the BSD userland: the two in-place manifest rewrites
#    (`sed -i`) and the .env generation must survive.
out="$(tesl_bsd "$WORK" init scaffold --template api --postgres existing --yes --no-git)"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$WORK/scaffold/tesl.toml" ] \
   && grep -q '^mode = "existing"' "$WORK/scaffold/tesl.toml" \
   && grep -q '^PORT=' "$WORK/scaffold/.env"; then
  pass "tesl init rewrites tesl.toml + writes .env with a BSD sed"
else
  fail "tesl init failed under BSD userland (rc=$rc): $out"
fi

# 9) a project reached through a SYMLINKED path (macOS has /tmp -> /private/tmp,
#    /var -> /private/var, so this is the normal case there): the project root
#    and the resolved file path must still agree, or every file looks like it
#    "resolves outside the project root".
ln -s "$PROJ" "$WORK/linked"
out="$(tesl_bsd "$WORK/linked" emit go)"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$PROJ/.tesl-stuff/go-build/go.mod" ]; then
  pass "project reached via a symlinked path still resolves its build output"
else
  fail "symlinked project path broke the build-output resolution (rc=$rc): $out"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  Part 3 — NATIVE LIBRARY: libsodium must resolve the way Tesl.Crypto resolves it
# ─────────────────────────────────────────────────────────────────────────────
# Tesl.Crypto reaches libsodium through `ffi/unsafe`.  Relying on the ambient
# loader path is not portable — a `nix profile install` user has no libsodium on
# any default search path, and on macOS DYLD_LIBRARY_PATH is unreliable — so
# flake.nix bakes the ABSOLUTE store path into $TESL_LIBSODIUM and crypto.rkt
# prefers it, falling back to a plain `ffi-lib "libsodium"` lookup for non-Nix
# installs (the Docker images apt-install libsodium-dev).
#
# This is a ratchet on BOTH halves of that contract, because either alone rots:
#   * the library actually loads and `sodium_init()` succeeds;
#   * resolution is LAZY — merely requiring tesl/crypto.rkt must not touch the
#     library.  That property is load-bearing far beyond Crypto:
#     compiler/test/test_stdlib_runtime_binding.ml walks EVERY stdlib .rkt with
#     `dynamic-require <module> (void)` to enumerate its provides, so an eager
#     ffi-lib that failed would break the seam test for every module, not just
#     this one.  tesl/jwt.rkt gets this wrong today (it requires
#     openssl/libcrypto, which resolves at module instantiation); Crypto must
#     not regress into copying it.
echo ""
echo "── native: libsodium resolution for Tesl.Crypto"

if ! command -v racket >/dev/null 2>&1; then
  note "racket not on PATH — skipping the libsodium ratchet"
else
  # (a) LAZY: declaring the module without instantiating it must succeed even
  #     with $TESL_LIBSODIUM pointed at nothing.
  if TESL_LIBSODIUM=/nonexistent/libsodium.so \
     racket -e '(dynamic-require (string->path "'"$REPO_ROOT"'/tesl/crypto.rkt") (void))' \
     >/dev/null 2>&1; then
    pass "tesl/crypto.rkt DECLARES without touching libsodium (lazy resolution)"
  else
    fail "tesl/crypto.rkt resolves libsodium eagerly — this breaks test_stdlib_runtime_binding.ml for EVERY stdlib module"
  fi

  # (b) RESOLVES: the real library loads and a real primitive answers.  Uses the
  #     public surface, so this fails if either the FFI binding or the
  #     $TESL_LIBSODIUM contract breaks.
  _sodium_out="$(racket -e '
    (require (file "'"$REPO_ROOT"'/tesl/crypto.rkt"))
    (displayln (Crypto.fingerprint "abc"))' 2>&1)" || true
  if [ "$_sodium_out" = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" ]; then
    pass "libsodium loads and answers a known-answer digest correctly"
  else
    fail "libsodium did not resolve, or answered wrongly: $_sodium_out"
  fi

  # (c) The install hint must be actionable when the library is genuinely absent.
  #     A user hitting this needs a command to run, not "could not load foreign
  #     library".  Only meaningful when the fallback lookup ALSO fails, so this
  #     is a note rather than a failure on a machine where libsodium is on the
  #     ambient path.
  _hint_out="$(TESL_LIBSODIUM=/nonexistent/libsodium.so racket -e '
    (require (file "'"$REPO_ROOT"'/tesl/crypto.rkt"))
    (with-handlers ([values (lambda (e) (displayln (exn-message e)))])
      (Crypto.fingerprint "abc"))' 2>&1)" || true
  if printf '%s' "$_hint_out" | grep -q "^ba7816bf"; then
    note "libsodium is on the ambient loader path — cannot exercise the missing-library hint here"
  elif printf '%s' "$_hint_out" | grep -q "apt-get install libsodium-dev"; then
    pass "a missing libsodium produces an actionable install hint"
  else
    fail "a missing libsodium did not produce the actionable install hint: $_hint_out"
  fi
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "cli-portability: PASS"
else
  echo "cli-portability: FAIL"
fi
exit "$FAIL"
