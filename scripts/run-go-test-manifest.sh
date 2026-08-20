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
  for racket_path in $(git -C "$repo_root" ls-files 'tests/*.rkt' | sort); do
    source_path="${racket_path%.rkt}.tesl"
    if git -C "$repo_root" ls-files --error-unmatch "$source_path" >/dev/null 2>&1; then
      printf '%s\n' "$source_path"
    fi
  done
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
    git -C "$repo_root" ls-files --error-unmatch "${path#"$repo_root/"}" >/dev/null 2>&1 || {
      printf 'Go test manifest: file is not a tracked paired source: %s\n' "$source" >&2
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
  *)
    printf 'usage: run-go-test-manifest.sh [--list|--compile-file FILE.tesl|--compile-all]\n' >&2
    exit 2
    ;;
esac

printf 'Go test manifest OK (%s paired sources, mode=%s)\n' "${#paired_sources[@]}" "$mode" >&2
