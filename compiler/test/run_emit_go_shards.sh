#!/usr/bin/env bash
set -uo pipefail

test_exe="$1"
case "$test_exe" in
    */*) ;;
    *) test_exe="./$test_exe" ;;
esac
shard_count="${TESL_CI_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')}"
case "$shard_count" in
    ''|*[!0-9]*) shard_count=1 ;;
esac
[ "$shard_count" -lt 1 ] && shard_count=1

pids=()
for ((shard_index = 0; shard_index < shard_count; shard_index++)); do
    TESL_TEST_SHARD_COUNT="$shard_count" \
    TESL_TEST_SHARD_INDEX="$shard_index" \
        "$test_exe" &
    pids+=("$!")
done

failed=0
for pid in "${pids[@]}"; do
    wait "$pid" || failed=1
done
exit "$failed"
