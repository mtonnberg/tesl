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
  .paired.status == "green" and
  (.racket_only.expected_count | type) == "number" and
  (.racket_only.green_count | type) == "number" and
  (.racket_only.planned_count | type) == "number" and
  (.racket_only.owner | type) == "string" and .racket_only.owner != "" and
  (.racket_only.evidence | type) == "string" and .racket_only.evidence != "" and
  (.racket_only.rows | type) == "array" and
  all(.racket_only.rows[];
    (.path | type) == "string" and .path != "" and
    (.owner | type) == "string" and .owner != "" and
    (.replacement | type) == "string" and .replacement != "" and
    (.status | IN("planned", "green", "obsolete")))
' "$manifest" >/dev/null

mapfile -t racket_paths < <(git -C "$repo_root" ls-files 'tests/*.rkt' | sort)
paired=0
racket_only=0
racket_only_paths=()

for racket_path in "${racket_paths[@]}"; do
  tesl_path="${racket_path%.rkt}.tesl"
  if git -C "$repo_root" ls-files --error-unmatch "$tesl_path" >/dev/null 2>&1; then
    paired=$((paired + 1))
  else
    racket_only=$((racket_only + 1))
    racket_only_paths+=("$racket_path")
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

expected_rows=$(jq -r '.racket_only.rows | length' "$manifest")
if (( expected_rows != expected_racket_only )); then
  printf 'Go test inventory manifest has %s Racket-only rows; expected %s\n' \
    "$expected_rows" "$expected_racket_only" >&2
  exit 1
fi
green_rows=$(jq '[.racket_only.rows[] | select(.status == "green")] | length' "$manifest")
planned_rows=$(jq '[.racket_only.rows[] | select(.status == "planned")] | length' "$manifest")
manifest_green=$(jq -r '.racket_only.green_count' "$manifest")
manifest_planned=$(jq -r '.racket_only.planned_count' "$manifest")
if (( green_rows != manifest_green || planned_rows != manifest_planned )); then
  printf 'Go test inventory status mismatch: green=%s planned=%s; manifest green=%s planned=%s\n' \
    "$green_rows" "$planned_rows" "$manifest_green" "$manifest_planned" >&2
  exit 1
fi

actual_rows=$(mktemp)
manifest_rows=$(mktemp)
trap 'rm -f "$actual_rows" "$manifest_rows"' EXIT
printf '%s\n' "${racket_only_paths[@]}" | sort > "$actual_rows"
jq -r '.racket_only.rows[].path' "$manifest" | sort > "$manifest_rows"
if ! cmp -s "$actual_rows" "$manifest_rows"; then
  printf 'Go test inventory manifest paths differ from Racket-only root tests\n' >&2
  diff -u "$actual_rows" "$manifest_rows" >&2 || true
  exit 1
fi

printf 'Go test inventory OK (root Racket=%s, paired=%s, Racket-only=%s)\n' \
  "$actual_total" "$paired" "$racket_only"
