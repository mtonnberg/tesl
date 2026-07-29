#!/usr/bin/env bash
# Build the browser playground into a directory of plain static files.
#
#   playground/build.sh [OUTDIR]        # default OUTDIR = playground/dist
#
# Output is host-agnostic: two files, no server-side anything, no build-time
# knowledge of where it will be served from (every path in index.html is
# relative).  Publishing it is "copy this directory", on any forge or CDN.
#
# Requires js_of_ocaml + js_of_ocaml-compiler.  Both are in the nix dev shell
# (`nix develop`).  Deliberately NOT wired into ci.sh: the dune stanza is gated
# on the RELEASE profile, and everything that must keep working without
# js_of_ocaml (plain `dune build`, `dune test`, ci.sh, the nix derivation) uses
# the dev profile.  See compiler/playground/dune for why an alias override does
# not achieve this.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
out="${1:-$here/dist}"

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
       playground/tesl_playground_js.bc.js )

artifact="$builddir/default/playground/tesl_playground_js.bc.js"

mkdir -p "$out"
install -m 644 "$artifact" "$out/tesl_playground.js"
install -m 644 "$here/index.html" "$out/index.html"

raw=$(wc -c < "$out/tesl_playground.js")
gz=$(gzip -9c "$out/tesl_playground.js" | wc -c)
echo "==> $out"
echo "    tesl_playground.js  $raw bytes raw, $gz bytes gzipped"
echo "    index.html          $(wc -c < "$out/index.html") bytes"
echo
echo "Serve it with any static file server, e.g.:"
echo "    python3 -m http.server -d $out 8000"
