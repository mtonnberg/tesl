#!/usr/bin/env bash
# Verify the shipped Go profile works in an isolated environment.
set -euo pipefail

tesl_bin=${TESL_BIN:?TESL_BIN must point at an installed tesl launcher}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/tesl-clean-install.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT

clean_path=${TESL_CLEAN_PATH:-/usr/bin:/bin}
clean_env=(env -i HOME="$tmp/home" PATH="$clean_path")

mkdir -p "$tmp/home" "$tmp/work"
(
  cd "$tmp/work"
  "${clean_env[@]}" "$tesl_bin" init clean-app --template minimal --postgres none --yes --no-git >/dev/null
  cd clean-app
  "${clean_env[@]}" "$tesl_bin" emit go app.tesl >/dev/null
  "${clean_env[@]}" "$tesl_bin" build --no-docker --out "$tmp/context" >/dev/null
  # Lifted signatures must come from this installation, without a checkout or
  # TESL_REPO_ROOT. Compile and execute the accepted program as well as checking it.
  cat >library.tesl <<'TESL'
module Library exposing [size, leap]
import Tesl.Prelude exposing [Int, List, Bool(..)]
import Tesl.List exposing [List.length]
import Tesl.CivilTime exposing [CivilTime.isLeapYear]
fn size(values: List Int) -> Int = List.length values
fn leap(year: Int) -> Bool = CivilTime.isLeapYear year
test "installed standard library" {
  expect size [1, 2, 3] == 3
  expect leap 2000
  expect leap 1900 == False
}
TESL
  "${clean_env[@]}" "$tesl_bin" check-json library.tesl >"$tmp/library.json"
  "${clean_env[@]}" "$tesl_bin" test library.tesl >/dev/null
)

printf 'Go clean install OK (init/emit/build and installed stdlib check/test passed)\n'
