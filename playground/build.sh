#!/usr/bin/env bash
# Build the browser playground into a directory of plain static files.
#
#   playground/build.sh [OUTDIR]        # default OUTDIR = playground/dist
#
# Output is host-agnostic: plain static files, no server-side anything, no build-time knowledge of
# where it will be served from — every path in index.html is relative and there is
# no CDN, web font or image.  Publishing it is "copy this directory", on any forge
# or CDN.
#
# `scripts/playground-parity.sh` (ci.sh phase 14) checks the built artifact's
# diagnostics against `tesl --check-json`; run it after changing the driver.
#
# Requires js_of_ocaml + js_of_ocaml-compiler.  Both are in the nix dev shell
# (`nix develop`).  The dune stanza is gated on the RELEASE profile, and
# everything that must keep working without js_of_ocaml (plain `dune build`,
# `dune test`, the nix derivation) uses the dev profile.  See
# compiler/playground/dune for why an alias override does not achieve this.
# ci.sh's parity phase calls this script but SKIPs when js_of_ocaml is absent, so
# the gate still passes on a machine that cannot build the browser bundle.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
out="${1:-$here/dist}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

for required in python3 node npm elm; do
  command -v "$required" >/dev/null 2>&1 || { echo "error: $required is required for verified playground assets" >&2; exit 1; }
done

if ! command -v js_of_ocaml >/dev/null 2>&1; then
  cat >&2 <<'EOF'
error: js_of_ocaml is not on PATH.

  nix develop            # the dev shell ships js_of_ocaml + js_of_ocaml-compiler
  playground/build.sh

(Outside nix: opam install js_of_ocaml js_of_ocaml-compiler)
EOF
  exit 1
fi

echo "==> compiling the Tesl compiler to JavaScript"
# --profile release is what enables the stanza (see compiler/playground/dune).
# Without it dune skips the stanza entirely, which is what keeps plain
# `dune build` / ci.sh working on a machine with no js_of_ocaml.
#
# --build-dir keeps this out of the shared compiler/_build.  Dune invalidates a
# build directory when the profile changes, so building the playground in the
# default one would force a full dev-profile rebuild of the compiler on the next
# plain `dune build`, and back again on the next playground build.  A dedicated
# directory costs one cold compile and then nothing; it also takes its own dune
# lock, so it does not serialise against a `dune build` running elsewhere.
#
# It MUST stay inside the repo, and is therefore not configurable.  The
# embedded-docs rule in compiler/lib/dune runs gen/gen_docs.exe and PROMOTES the
# result into compiler/lib/embedded_docs.ml, and gen_docs finds the repo root by
# walking up from its own path in the build directory (gen/gen_docs.ml:41).  A
# build directory outside the repo makes that walk fail, gen_docs emits an empty
# document list, and dune promotes the truncated file into the source tree —
# silently deleting the embedded manual.  Verified the hard way.
builddir="$repo/compiler/_build-playground"
( cd "$repo/compiler" \
  && dune build --profile release --build-dir "$builddir" \
       playground/tesl_playground_js.bc.js playground/tesl_search_js.bc.js )

# Verify examples and catalog parity against the native compiler from this tree.
( cd "$repo/compiler" && dune build bin/main.exe )

artifact="$builddir/default/playground/tesl_playground_js.bc.js"

mkdir -p "$out"
install -m 644 "$artifact" "$out/tesl_playground.js"
install -m 644 "$here/index.html" "$out/index.html"
install -m 644 "$builddir/default/playground/tesl_search_js.bc.js" "$out/tesl_search.js"
for asset in playground.css editor.js bridge.js fix.js learning.js start.html why.html agents.md; do
  install -m 644 "$here/$asset" "$out/$asset"
done
( cd "$here/elm" && elm make src/Main.elm --optimize --output="$out/playground-elm.js" )
install -m 644 "$here/search.css" "$out/search.css"
install -m 644 "$here/share.js" "$out/share.js"
# Pinned packages are installed at build time; no CDN/runtime dependency.
( cd "$here" && npm ci --ignore-scripts --no-audit --no-fund && node build-editor.mjs "$out" )
python3 "$here/gen-workbench-assets.py" "$repo" "$out"
node "$repo/scripts/playground-examples-check.cjs" "$out"
python3 "$here/gen-search-assets.py" "$repo" "$out"

# ── The lesson index ────────────────────────────────────────────────────────
# One page linking every example/learn lesson into the checker, with its source
# in the share fragment. Generated from the `# lesson:` / `# summary:` headers —
# the same single source manual/lessons.md comes from — so the two catalogs
# cannot disagree, and adding a lesson needs no edit here.
#
# Deliberately a SEPARATE page rather than a picker inside index.html: the corpus
# is 750 KB raw / 190 KB gzipped, comparable to the whole compiler bundle, and
# every lesson gets a stable permalink this way. See the script's header.
if command -v python3 >/dev/null 2>&1; then
  echo "==> generating the lesson index"
  python3 "$here/gen-lessons-page.py" "$repo" "$out/lessons.html" "index.html"
else
  echo "warning: python3 not found — skipping lessons.html" >&2
fi

raw=$(wc -c < "$out/tesl_playground.js")
gz=$(gzip -9c "$out/tesl_playground.js" | wc -c)
echo "==> $out"
echo "    tesl_playground.js  $raw bytes raw, $gz bytes gzipped"
echo "    index.html          $(wc -c < "$out/index.html") bytes"
if [ -f "$out/lessons.html" ]; then
  echo "    lessons.html        $(wc -c < "$out/lessons.html") bytes"
fi
echo
echo "Serve it with any static file server, e.g.:"
echo "    python3 -m http.server -d $out 8000"
