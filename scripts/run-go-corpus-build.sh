#!/usr/bin/env bash
set -euo pipefail

repo_root=${TESL_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)}
compiler=${TESL_OCAML_COMPILER:-$repo_root/compiler/_build/default/bin/main.exe}
manifest="$repo_root/tests/protocol/go-corpus-build.json"
jobs=${TESL_CI_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')}
mode=${1:---build}

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

# These tracked files are release-recipe inputs, not independent compilation
# units: transition bodies acquire canonical paths and frozen predecessors only
# through the guarded generator. Count all inputs, then build every release below.
assembled=(example/db-three-upgrades example/queue-three-upgrades example/kubernetes-rolling)
for project in "${assembled[@]}"; do
  actual=0
  for source in "${sources[@]}"; do [[ $source == "$project/"* ]] && actual=$((actual + 1)); done
  wanted=$(jq -er --arg project "$project" '.assembled_examples[$project]' "$manifest")
  (( actual == wanted )) || {
    printf 'Go corpus recipe inventory mismatch: %s actual=%s expected=%s\n' "$project" "$actual" "$wanted" >&2
    exit 1
  }
done

if [[ ${1:-} == --list ]]; then
  printf '%s\n' "${sources[@]}"
  printf 'Go corpus OK (%s tracked recursive sources)\n' "${#sources[@]}" >&2
  exit 0
fi
[[ $# -eq 0 || $# -eq 1 && ( $mode == --build || $mode == --run-examples ) ]] || {
  printf 'usage: run-go-corpus-build.sh [--list|--build|--run-examples]\n' >&2
  exit 2
}

output_root=$(mktemp -d "${TMPDIR:-/tmp}/tesl-go-corpus.XXXXXXXX")
trap 'rm -rf "$output_root"' EXIT
mkdir -p "$output_root/modules"
standalone=()
selected_count=0
for source in "${sources[@]}"; do
  if [[ $mode == --run-examples && $source != example/* ]]; then continue; fi
  selected_count=$((selected_count + 1))
  case "$source" in
    example/db-three-upgrades/*|example/queue-three-upgrades/*|example/kubernetes-rolling/*) ;;
    *) standalone+=("$source") ;;
  esac
done
# Positional arguments expand in each child shell.
# shellcheck disable=SC2016
printf '%s\0' "${standalone[@]}" | xargs -0 -n1 -P "$jobs" bash -c '
  source=$4
  key=$(printf "%s" "$source" | sha256sum | cut -d" " -f1)
  case "$source" in
    example/playground/*)
      python3 "$2/scripts/playground-corpus-build.py" "$1" "$2/$source" "$3/$key"
      ;;
    *) "$1" --backend go "$2/$source" --out "$3/$key" >/dev/null ;;
  esac
' _ "$compiler" "$repo_root" "$output_root/modules"

mapfile -t outputs < <(printf '%s\n' "$output_root/modules"/*)
# Positional arguments and the session-key default expand in each child shell.
# shellcheck disable=SC2016
printf '%s\0' "${outputs[@]}" | xargs -0 -n1 -P "$jobs" bash -c '
  cd "$1" || exit 1
  if [[ $0 == --run-examples ]]; then
    LESSON80_SESSION_KEY="${LESSON80_SESSION_KEY:-anything}" go test -count=1 ./... >/dev/null
  else
    go test -run "^$" ./... >/dev/null
  fi
' "$mode"

for project in "${assembled[@]}"; do
  case "$project" in
    example/kubernetes-rolling)
      python3 "$repo_root/$project/build.py" --compiler "$compiler" --output "$output_root/${project##*/}"
      ;;
    *) python3 "$repo_root/$project/run.py" --build-only --output "$output_root/${project##*/}" ;;
  esac
done

printf 'Go corpus OK (%s tracked sources checked; %s standalone modules and %s assembled release histories build with their tests; jobs=%s)\n' \
  "$selected_count" "${#outputs[@]}" "${#assembled[@]}" "$jobs" >&2
