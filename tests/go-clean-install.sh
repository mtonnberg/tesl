#!/usr/bin/env bash
# Verify the shipped Go profile works without racket/raco on PATH.
set -euo pipefail

tesl_bin=${TESL_BIN:?TESL_BIN must point at an installed tesl wrapper}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/tesl-clean-install.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT

clean_path=${TESL_CLEAN_PATH:-/usr/bin:/bin}
clean_env=(env -i HOME="$tmp/home" PATH="$clean_path")

if "${clean_env[@]}" command -v racket >/dev/null 2>&1 ||
   "${clean_env[@]}" command -v raco >/dev/null 2>&1; then
  printf 'clean install: Racket unexpectedly available on PATH\n' >&2
  exit 1
fi

mkdir -p "$tmp/home" "$tmp/work"
(
  cd "$tmp/work"
  "${clean_env[@]}" "$tesl_bin" init clean-app --template minimal --postgres none --yes >/dev/null
  cd clean-app
  "${clean_env[@]}" "$tesl_bin" emit go app.tesl >/dev/null
  "${clean_env[@]}" "$tesl_bin" build --no-docker --out "$tmp/context" >/dev/null
)

printf 'Go clean install OK (Racket absent, CLI emit/build passed)\n'
