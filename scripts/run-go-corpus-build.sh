#!/usr/bin/env bash
set -euo pipefail

repo_root=${TESL_REPO_ROOT:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}
compiler=${TESL_OCAML_COMPILER:-$repo_root/compiler/_build/default/bin/main.exe}
manifest="$repo_root/tests/protocol/go-corpus-build.json"
jobs=${TESL_CI_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')}

[[ -x "$compiler" ]] || { printf 'Go corpus: compiler not executable: %s\n' "$compiler" >&2; exit 77; }
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { printf 'Go corpus: invalid TESL_CI_JOBS=%s\n' "$jobs" >&2; exit 2; }

mapfile -t sources < <(
  git -C "$repo_root" ls-files '*.tesl' |
    while IFS= read -r path; do
      case "$path" in
        example/*|tests/*|templates/*)
          [[ -f "$repo_root/$path" ]] && [[ ${path##*/} != tesl-lsp-*.tesl ]] && printf '%s\n' "$path"
          ;;
      esac
    done | LC_ALL=C sort
)

expected=$(jq -r '.expected_count' "$manifest")
jq -e 'type == "object" and .version == 1 and .status == "green" and
  (.scope | length) == 3 and (.expected_by_root.example + .expected_by_root.tests +
  .expected_by_root.templates) == .expected_count' "$manifest" >/dev/null
(( ${#sources[@]} == expected )) || {
  printf 'Go corpus inventory mismatch: actual=%s expected=%s\n' "${#sources[@]}" "$expected" >&2
  exit 1
}
for root in example tests templates; do
  actual=0
  for source in "${sources[@]}"; do [[ $source == "$root/"* ]] && actual=$((actual + 1)); done
  wanted=$(jq -r ".expected_by_root.$root" "$manifest")
  (( actual == wanted )) || {
    printf 'Go corpus %s inventory mismatch: actual=%s expected=%s\n' "$root" "$actual" "$wanted" >&2
    exit 1
  }
done

if [[ ${1:-} == --list ]]; then
  printf '%s\n' "${sources[@]}"
  printf 'Go corpus OK (%s tracked recursive sources)\n' "${#sources[@]}" >&2
  exit 0
fi
[[ $# -eq 0 || ${1:-} == --build ]] || {
  printf 'usage: run-go-corpus-build.sh [--list|--build]\n' >&2
  exit 2
}

output_root=$(mktemp -d "${TMPDIR:-/tmp}/tesl-go-corpus.XXXXXXXX")
trap 'rm -rf "$output_root"' EXIT
printf '%s\0' "${sources[@]}" | xargs -0 -n1 -P "$jobs" bash -c '
  source=$4
  key=$(printf "%s" "$source" | sha256sum | cut -d" " -f1)
  "$1" --backend go "$2/$source" --out "$3/$key" >/dev/null
' _ "$compiler" "$repo_root" "$output_root"

mapfile -t outputs < <(printf '%s\n' "$output_root"/*)
printf '%s\0' "${outputs[@]}" | xargs -0 -n1 -P "$jobs" bash -c '
  cd "$1"
  go test -run "^$" ./... >/dev/null
' _

printf 'Go corpus OK (%s tracked recursive sources compiled; generated tests build; jobs=%s)\n' \
  "${#sources[@]}" "$jobs" >&2
