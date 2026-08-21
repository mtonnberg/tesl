#!/usr/bin/env bash
set -euo pipefail

repo_root=${TESL_REPO_ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}

matrix="$repo_root/tests/protocol/go-capability-matrix.json"
abi="$repo_root/tests/protocol/go-debug-abi-v1.schema.json"
jq -e 'type == "object" and .version == 1 and (.id | type) == "string" and (.location.file | type) == "string" and (.location.line >= 1) and (.location.column >= 1) and (.locals | type) == "array"' "$repo_root/tests/protocol/debug-frame-v1.json" >/dev/null
jq -e 'type == "object" and .version == 1 and (.normalization.remove | length) > 0 and (.normalization.preserve | length) > 0 and (.fixtures | length) >= 4' "$repo_root/tests/protocol/transcript-index.json" >/dev/null
jq -e 'type == "object" and .version == 1 and (.diagnostics | type) == "array"' "$repo_root/tests/protocol/diagnostics-core.json" >/dev/null
jq -e 'type == "object" and .version == 1 and (.symbols | type) == "array"' "$repo_root/tests/protocol/semantic-core.json" >/dev/null
jq -e 'type == "object" and .version == 1 and (.capabilities | type) == "array" and (.capabilities | length) > 0 and all(.capabilities[]; (.id | type) == "string" and .id != "" and (.owner | type) == "string" and .owner != "" and (.test | type) == "string" and .test != "")' "$matrix" >/dev/null
jq -e 'type == "object" and ."$schema" != null and ."$id" != null and .properties.version.const == 1 and .properties.location != null and ."$defs".value != null' "$abi" >/dev/null
printf 'protocol contracts OK\n'
