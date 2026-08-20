#!/usr/bin/env bash
set -euo pipefail

repo_root=${TESL_REPO_ROOT:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}
runs=${RKT_STABILITY_RUNS:-2}
timeout_seconds=${RKT_STABILITY_TIMEOUT:-120}

command -v racket >/dev/null 2>&1 || { printf 'racket unavailable\n' >&2; exit 1; }
command -v timeout >/dev/null 2>&1 || { printf 'timeout unavailable\n' >&2; exit 1; }

for ((run = 1; run <= runs; run++)); do
  for test_file in "$repo_root"/tests/dap-*.rkt; do
    [ -f "$test_file" ] || continue
    name=${test_file##*/}
    printf 'stability run %d/%d: %s\n' "$run" "$runs" "$name"
    if ! TESL_REPO_ROOT="$repo_root" timeout --signal=KILL "${timeout_seconds}s" racket "$test_file"; then
      printf 'Racket stability failure: run=%d test=%s\n' "$run" "$name" >&2
      exit 1
    fi
  done
done
printf 'Racket DAP stability OK (%d runs)\n' "$runs"
