#!/usr/bin/env bash
set -euo pipefail

repo_root=${TESL_REPO_ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
manifest="$repo_root/tests/protocol/go-test-migration.json"

[[ -f "$manifest" ]] || {
  printf 'missing Go test migration manifest: %s\n' "$manifest" >&2
  exit 1
}

jq -e '
  type == "object" and .version == 1 and
  (.scope | type) == "string" and
  (.paired.expected_count | type) == "number" and
  (.paired.source_suffix | type) == "string" and
  (.paired.owner | type) == "string" and .paired.owner != "" and
  (.paired.evidence | type) == "string" and .paired.evidence != "" and
  .paired.status == "green" and
  (.go_replacements.expected_count | type) == "number" and
  (.go_replacements.green_count | type) == "number" and
  (.go_replacements.planned_count | type) == "number" and
  (.go_replacements.owner | type) == "string" and .go_replacements.owner != "" and
  (.go_replacements.evidence | type) == "string" and .go_replacements.evidence != "" and
  (.go_replacements.rows | type) == "array" and
  all(.go_replacements.rows[];
    (.path | type) == "string" and .path != "" and
    (.owner | type) == "string" and .owner != "" and
    (.replacement | type) == "string" and .replacement != "" and
    (.status | IN("planned", "green", "obsolete")))
' "$manifest" >/dev/null

mapfile -t tesl_paths < <(
  git -C "$repo_root" ls-files 'tests/*.tesl' |
    while IFS= read -r path; do
      [[ -f "$repo_root/$path" ]] && printf '%s\n' "$path"
    done | sort
)
paired=${#tesl_paths[@]}
expected_paired=$(jq -r '.paired.expected_count' "$manifest")
expected_replacements=$(jq -r '.go_replacements.expected_count' "$manifest")

if (( paired != expected_paired )); then
  printf 'Go test inventory mismatch: Tesl sources=%s; expected=%s\n' \
    "$paired" "$expected_paired" >&2
  exit 1
fi

expected_rows=$(jq -r '.go_replacements.rows | length' "$manifest")
if (( expected_rows != expected_replacements )); then
  printf 'Go test replacement manifest has %s rows; expected %s\n' \
    "$expected_rows" "$expected_replacements" >&2
  exit 1
fi
green_rows=$(jq '[.go_replacements.rows[] | select(.status == "green")] | length' "$manifest")
planned_rows=$(jq '[.go_replacements.rows[] | select(.status == "planned")] | length' "$manifest")
manifest_green=$(jq -r '.go_replacements.green_count' "$manifest")
manifest_planned=$(jq -r '.go_replacements.planned_count' "$manifest")
if (( green_rows != manifest_green || planned_rows != manifest_planned )); then
  printf 'Go test replacement status mismatch: green=%s planned=%s; manifest green=%s planned=%s\n' \
    "$green_rows" "$planned_rows" "$manifest_green" "$manifest_planned" >&2
  exit 1
fi

while IFS= read -r retired_path; do
  if [[ -f "$repo_root/$retired_path" ]]; then
    printf 'retired Racket-only test still exists: %s\n' "$retired_path" >&2
    exit 1
  fi
done < <(jq -r '.go_replacements.rows[].path' "$manifest")

printf 'Go test inventory OK (Tesl sources=%s, Go replacements=%s, retired Racket-only=0)\n' \
  "$paired" "$expected_replacements"
