#!/usr/bin/env bash
# Optional feasibility screen, deliberately excluded from the deployed playground.
# First run playground/build.sh OUTDIR, then this script with the same OUTDIR.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${1:?usage: playground/elm-spike/build.sh EXISTING_PLAYGROUND_DIST}"
out="$(cd "$out" && pwd)"
test -f "$out/tesl_search.js"
test -f "$out/share.js"
(cd "$here" && elm make src/Main.elm --optimize --output="$out/elm-spike.js")
install -m 644 "$here/index.html" "$out/elm-spike.html"
install -m 644 "$here/bridge.js" "$out/elm-spike-bridge.js"
printf 'Elm feasibility screen: %s/elm-spike.html\n' "$out"
