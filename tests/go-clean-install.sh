#!/usr/bin/env bash
# Verify the shipped Go profile works in an isolated environment.
set -euo pipefail

tesl_bin=${TESL_BIN:?TESL_BIN must point at an installed tesl wrapper}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/tesl-clean-install.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT

clean_path=${TESL_CLEAN_PATH:-/usr/bin:/bin}
clean_env=(env -i HOME="$tmp/home" PATH="$clean_path")

mkdir -p "$tmp/home" "$tmp/work"
(
  cd "$tmp/work"
  "${clean_env[@]}" "$tesl_bin" init clean-app --template minimal --postgres none --yes >/dev/null
  cd clean-app
  "${clean_env[@]}" "$tesl_bin" emit go app.tesl >/dev/null
  # The output context may be under an unrelated, incomplete checkout. It must
  # not inherit that checkout's VCS metadata or fail Go's automatic VCS probe.
  mkdir "$tmp/.git"
  "${clean_env[@]}" "$tesl_bin" build --no-docker --out "$tmp/context" >/dev/null
)

printf 'Go clean install OK (CLI init/emit/build passed)\n'
