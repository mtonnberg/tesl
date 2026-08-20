#!/usr/bin/env bash
set -euo pipefail

repo_root=${TESL_REPO_ROOT:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}
compiler=${TESL_OCAML_COMPILER:-$repo_root/compiler/_build/default/bin/main.exe}
mode=${1:---list}

[[ -x "$compiler" ]] || {
  printf 'Go test manifest: compiler not executable: %s\n' "$compiler" >&2
  exit 77
}

mapfile -t paired_sources < <(
  git -C "$repo_root" ls-files 'tests/*.tesl' |
    while IFS= read -r source_path; do
      [[ -f "$repo_root/$source_path" ]] && printf '%s\n' "$source_path"
    done | sort
)

case "$mode" in
  --list)
    printf '%s\n' "${paired_sources[@]}"
    ;;
  --compile-file)
    source=${2:?usage: run-go-test-manifest.sh --compile-file FILE.tesl}
    case "$source" in
      /*) path=$source ;;
      *) path="$repo_root/$source" ;;
    esac
    [[ -f "$path" ]] || {
      printf 'Go test manifest: file is not an existing Tesl source: %s\n' "$source" >&2
      exit 2
    }
    output_root=$(mktemp -d "${TMPDIR:-/tmp}/tesl-go-test.XXXXXXXX")
    output="$output_root/generated"
    trap 'rm -rf "$output_root"' EXIT
    "$compiler" --backend go "$path" --out "$output"
    ;;
  --compile-all)
    output_root=$(mktemp -d "${TMPDIR:-/tmp}/tesl-go-tests.XXXXXXXX")
    output="$output_root/generated"
    trap 'rm -rf "$output_root"' EXIT
    failures=0
    for source in "${paired_sources[@]}"; do
      target="$output/${source##*/}"
      if ! "$compiler" --backend go "$repo_root/$source" --out "$target" >/dev/null; then
        printf 'Go test manifest: compile failed: %s\n' "$source" >&2
        failures=$((failures + 1))
      fi
    done
    (( failures == 0 )) || exit 1
    ;;
  --run-all)
    body=${TESL_CLI_BODY:-$repo_root/nix/tesl-cli-body.sh}
    [[ -f "$body" ]] || {
      printf 'Go test manifest: CLI body not found: %s\n' "$body" >&2
      exit 2
    }
    failures=0
    for source in "${paired_sources[@]}"; do
      if ! (cd "$repo_root" && TESL_REPO_ROOT="$repo_root" TESL_OCAML_COMPILER="$compiler" \
        TESL_DEFAULT_BACKEND=go bash "$body" test --backend go "$source"); then
        printf 'Go test manifest: run failed: %s\n' "$source" >&2
        failures=$((failures + 1))
      fi
    done
    (( failures == 0 )) || exit 1
    ;;
  *)
    printf 'usage: run-go-test-manifest.sh [--list|--compile-file FILE.tesl|--compile-all|--run-all]\n' >&2
    exit 2
    ;;
esac

printf 'Go test manifest OK (%s paired sources, mode=%s)\n' "${#paired_sources[@]}" "$mode" >&2
