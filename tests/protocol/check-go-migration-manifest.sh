#!/usr/bin/env bash
set -euo pipefail

repo_root=${TESL_REPO_ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
manifest="$repo_root/tests/protocol/racket-traceability.json"

# Use tracked paths that still exist in the checkout. This keeps the manifest gate useful while
# an intentional deletion is present in a worktree but not yet staged; after commit the result is
# identical to `git ls-files '*.rkt'`. An empty result is valid after the Racket cleanup.
tracked_racket_files() {
  git -C "$repo_root" ls-files '*.rkt' |
    while IFS= read -r path; do
      [[ -f "$repo_root/$path" ]] && printf '%s\n' "$path"
    done
}

if [[ ${1:-} == "--write" ]]; then
  tracked_racket_files | jq -Rsc '
    split("\n")
    | map(select(length > 0))
    | map({
        path: ., 
        category: (if startswith("dsl/debug/") then "debug-runtime"
                   elif startswith("dsl/") then "runtime"
                   elif startswith("tesl/") then "language-surface"
                   elif startswith("editor/") then "editor-tooling"
                   elif startswith("example/") then "example"
                   elif startswith("templates/") then "template"
                   elif startswith("tests/") then "test"
                   else "other" end),
        owner: (if startswith("dsl/debug/") then "runtime/go/internal/dap + runtime/go/teslrt"
                elif startswith("dsl/") then "runtime/go/teslrt"
                elif startswith("tesl/") then "compiler/lib/emit_go.ml"
                elif startswith("editor/") then "runtime/go/cmd"
                elif startswith("example/") then "compiler/lib/emit_go.ml + runtime/go"
                elif startswith("templates/") then "compiler/lib/emit_go.ml + runtime/go"
                elif startswith("tests/") then "compiler/test + runtime/go"
                else "roadmap review" end),
        replacement: "go-migration",
        evidence: "roadmap/next/go_debugging_and_lsp.md",
        test: (if startswith("dsl/debug/") then "runtime/go/internal/dap + runtime/go/teslrt"
               elif startswith("dsl/") then "runtime/go/teslrt"
               elif startswith("tesl/") then "compiler/test/test_emit_go.ml"
               elif startswith("editor/") then "runtime/go/internal/lsp + runtime/go/internal/dap"
               elif startswith("example/") or startswith("templates/") then "compiler/test/test_emit_go.ml"
               elif startswith("tests/") then "runtime/go + tests/protocol"
               else "roadmap review" end),
        status: "inventory"
      })' > "$manifest"
  printf 'wrote %s\n' "$manifest"
  exit 0
fi

[[ -f "$manifest" ]] || { printf 'missing manifest: %s\n' "$manifest" >&2; exit 1; }

expected=$(mktemp)
actual=$(mktemp)
trap 'rm -f "$expected" "$actual"' EXIT
tracked_racket_files | sort > "$expected"
jq -r '.[].path' "$manifest" | sort > "$actual"
if ! cmp -s "$expected" "$actual"; then
  printf 'traceability manifest paths differ from tracked .rkt files\n' >&2
  diff -u "$expected" "$actual" >&2 || true
  exit 1
fi

jq -e '
  type == "array" and
  all(.[]; (.path | type) == "string" and .path != "" and
      (.category | type) == "string" and .category != "" and
      (.owner | type) == "string" and .owner != "" and
      (.replacement | type) == "string" and .replacement != "" and
      (.evidence | type) == "string" and .evidence != "" and
      (.test | type) == "string" and .test != "" and
      .status == "inventory")' "$manifest" >/dev/null
printf 'traceability manifest OK (%s rows)\n' "$(jq 'length' "$manifest")"

matrix="$repo_root/tests/protocol/go-capability-matrix.json"
abi="$repo_root/tests/protocol/go-debug-abi-v1.schema.json"
jq -e 'type == "object" and .version == 1 and (.id | type) == "string" and (.location.file | type) == "string" and (.location.line >= 1) and (.location.column >= 1) and (.locals | type) == "array"' "$repo_root/tests/protocol/debug-frame-v1.json" >/dev/null
jq -e 'type == "object" and .version == 1 and (.normalization.remove | length) > 0 and (.normalization.preserve | length) > 0 and (.fixtures | length) >= 4' "$repo_root/tests/protocol/transcript-index.json" >/dev/null
jq -e 'type == "object" and .version == 1 and (.diagnostics | type) == "array"' "$repo_root/tests/protocol/diagnostics-core.json" >/dev/null
jq -e 'type == "object" and .version == 1 and (.symbols | type) == "array"' "$repo_root/tests/protocol/semantic-core.json" >/dev/null
jq -e 'type == "object" and .version == 1 and (.capabilities | type) == "array" and (.capabilities | length) > 0 and all(.capabilities[]; (.id | type) == "string" and .id != "" and (.owner | type) == "string" and .owner != "" and (.test | type) == "string" and .test != "")' "$matrix" >/dev/null
jq -e 'type == "object" and ."$schema" != null and ."$id" != null and .properties.version.const == 1 and .properties.location != null and ."$defs".value != null' "$abi" >/dev/null
printf 'capability matrix and ABI schema OK\n'

"$repo_root/tests/protocol/check-go-test-inventory.sh"
