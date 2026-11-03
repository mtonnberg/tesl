#!/usr/bin/env bash
set -euo pipefail

repo_root=${TESL_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)}
compiler=${TESL_OCAML_COMPILER:-$repo_root/compiler/_build/default/bin/main.exe}
manifest="$repo_root/tests/protocol/go-example-migration.json"
mode=${1:---list}

[[ -x "$compiler" ]] || {
  printf 'Go example manifest: compiler not executable: %s\n' "$compiler" >&2
  exit 77
}

expected=$(jq -r '.expected_count' "$manifest")
mapfile -t examples < <(git -C "$repo_root" ls-files '*.tesl' | while IFS= read -r path; do
  case "$path" in
    example/*) printf '%s\n' "$path" ;;
  esac
done)

jq -e '
  type == "object" and .version == 1 and .scope == "example/**/*.tesl" and
  (.expected_count | type) == "number" and
  (.owner | type) == "string" and .owner != "" and
  (.evidence | type) == "string" and .evidence != "" and
  .status == "green"
' "$manifest" >/dev/null

if (( ${#examples[@]} != expected )); then
  printf 'Go example inventory mismatch: actual=%s expected=%s\n' "${#examples[@]}" "$expected" >&2
  exit 1
fi

case "$mode" in
  --list)
    printf '%s\n' "${examples[@]}"
    ;;
  --run-all)
    # Share the guarded release-recipe and rejected-starter/repair handling
    # with the build gate, but execute the generated example tests as well.
    bash "$repo_root/scripts/run-go-corpus-build.sh" --run-examples
    ;;
  *)
    printf 'usage: run-go-example-manifest.sh [--list|--run-all]\n' >&2
    exit 2
    ;;
esac

printf 'Go example manifest OK (%s sources, mode=%s)\n' "${#examples[@]}" "$mode" >&2
