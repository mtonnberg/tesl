#!/usr/bin/env bash
set -euo pipefail

repo_root=${TESL_REPO_ROOT:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}
manifest="$repo_root/roadmap/next/go-test-migration.json"

[[ -f "$manifest" ]] || {
  printf 'missing Go test migration manifest: %s\n' "$manifest" >&2
  exit 1
}

jq -e '
  type == "object" and .version == 1 and
  .scope == "tests/*.rkt" and
  (.paired.expected_count | type) == "number" and
  (.paired.source_suffix | type) == "string" and
  (.paired.owner | type) == "string" and .paired.owner != "" and
  (.paired.evidence | type) == "string" and .paired.evidence != "" and
  (.racket_only.expected_count | type) == "number" and
  (.racket_only.owner | type) == "string" and .racket_only.owner != "" and
  (.racket_only.evidence | type) == "string" and .racket_only.evidence != ""
' "$manifest" >/dev/null

mapfile -t racket_paths < <(git -C "$repo_root" ls-files 'tests/*.rkt' | sort)
paired=0
racket_only=0
untracked_pairs=()

for racket_path in "${racket_paths[@]}"; do
  tesl_path="${racket_path%.rkt}.tesl"
  if git -C "$repo_root" ls-files --error-unmatch "$tesl_path" >/dev/null 2>&1; then
    paired=$((paired + 1))
  else
    racket_only=$((racket_only + 1))
  fi
done

expected_paired=$(jq -r '.paired.expected_count' "$manifest")
expected_racket_only=$(jq -r '.racket_only.expected_count' "$manifest")
actual_total=${#racket_paths[@]}

if (( paired != expected_paired || racket_only != expected_racket_only )); then
  printf 'Go test inventory mismatch: root Racket=%s paired=%s Racket-only=%s; expected paired=%s Racket-only=%s\n' \
    "$actual_total" "$paired" "$racket_only" "$expected_paired" "$expected_racket_only" >&2
  exit 1
fi

printf 'Go test inventory OK (root Racket=%s, paired=%s, Racket-only=%s)\n' \
  "$actual_total" "$paired" "$racket_only"
