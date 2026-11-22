#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  tests/elm-client-compile.sh — every generated Elm client must compile
# ══════════════════════════════════════════════════════════════════════════════
#
# `tesl check` and `tesl test` never compile the Elm a `tesl generate elm` writes, so an
# emitter bug there was found only by the downstream project that committed the client
# (a mis-grouped Maybe encoder, an `Int` path segment
# appended to a String, an import of a module nobody generated).  This gate generates the
# client for every corpus program that declares an `api` and runs `elm make` on it.
#
# Offline by design: it uses the Elm package cache (~/.elm) and the dependency set the
# generated client needs.  It SKIPS — loudly, with exit 0 — when `elm` or a cached package
# is missing, as the other optional-tool phases of ci.sh do.
#
# Usage:  tests/elm-client-compile.sh [file.tesl ...]   (default: the corpus)
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPILER="${TESL_OCAML_COMPILER:-$REPO_ROOT/compiler/_build/default/bin/main.exe}"
ELM_HOME_DIR="${ELM_HOME:-$HOME/.elm}/0.19.1/packages"

if ! command -v elm >/dev/null 2>&1; then
  echo "elm-client-compile: SKIPPED (no elm on PATH)"; exit 0
fi
for package in elm/core/1.0.5 elm/json/1.1.3 elm/http/2.0.0 elm/bytes/1.0.8 elm/file/1.0.5 \
               elm/time/1.0.0 mtonnberg/refinement-proofs/5.0.1; do
  if [ ! -d "$ELM_HOME_DIR/$package" ]; then
    echo "elm-client-compile: SKIPPED (package $package not in the Elm cache)"; exit 0
  fi
done

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  mapfile -t files < <(cd "$REPO_ROOT" && git ls-files 'example/*.tesl' 'example/**/*.tesl' 'tests/*.tesl' \
    | xargs grep -l '^api ' 2>/dev/null | LC_ALL=C sort)
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat > "$work/elm.json" <<'JSON'
{
    "type": "application",
    "source-directories": ["src"],
    "elm-version": "0.19.1",
    "dependencies": {
        "direct": {
            "elm/core": "1.0.5",
            "elm/http": "2.0.0",
            "elm/json": "1.1.3",
            "mtonnberg/refinement-proofs": "5.0.1"
        },
        "indirect": {
            "elm/bytes": "1.0.8",
            "elm/file": "1.0.5",
            "elm/time": "1.0.0"
        }
    },
    "test-dependencies": { "direct": {}, "indirect": {} }
}
JSON

passed=0; failed=0; skipped=0
for file in "${files[@]}"; do
  rm -rf "$work/src" "$work/elm-stuff"
  mkdir -p "$work/src"
  # A program the generator refuses (no api, an unsupported shape) is not this gate's
  # business — `tesl check` owns refusals.
  if ! (cd "$REPO_ROOT" && "$COMPILER" --generate-elm "$file") > "$work/generated.elm" 2>/dev/null; then
    skipped=$((skipped + 1)); continue
  fi
  # The Elm module is named after the Tesl module, and Elm wants the file path to match.
  module=$(sed -n '1s/^module \([A-Za-z0-9_.]*\).*/\1/p' "$work/generated.elm")
  module_path="$work/src/$(echo "$module" | tr . /).elm"
  mkdir -p "$(dirname "$module_path")"
  mv "$work/generated.elm" "$module_path"
  # A client that delegates checks to a hand-written ApiHelpers module lists the exact
  # signatures in its header comment; stand in for the user's implementation.
  if grep -q '^import ApiHelpers' "$module_path"; then
    {
      names=$(sed -n 's/^       module ApiHelpers exposing (\(.*\))$/\1/p' "$module_path")
      echo "module ApiHelpers exposing ($names)"
      sed -n 's/^       \([a-z][A-Za-z0-9_]*\) : \(.*\)$/\1 : \2\n\1 = \\_ -> True/p' "$module_path" \
        | sed 's/^\([a-z][A-Za-z0-9_]*\) = \\_ -> True$/\1 _ = True/'
    } > "$work/src/ApiHelpers.elm"
  fi
  if (cd "$work" && elm make "${module_path#$work/}" --output=/dev/null) > "$work/log" 2>&1; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "✗ $file"
    sed -n '1,40p' "$work/log" | sed 's/^/    /'
  fi
done

echo "elm-client-compile: $passed compiled, $failed failed, $skipped not generated"
[ "$failed" -eq 0 ]
